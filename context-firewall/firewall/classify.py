from __future__ import annotations

import json
import re
import shlex
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

from .models import CommandResult

TYPES = (
    "git-status",
    "git-diff",
    "git-log",
    "search",
    "directory-listing",
    "test",
    "build",
    "lint",
    "package-manager",
    "stack-trace",
    "generic-log",
    "generic-command",
    "source-code",
    "json",
)

FILTERS = {
    "head", "tail", "grep", "egrep", "rg", "wc", "sort", "uniq", "jq", "sed", "awk", "cut", "less", "more",
    "select-object", "select-string", "measure-object", "format-table", "out-string", "tr", "column", "xargs",
}
WRAPPERS = {"npx", "pnpx", "bunx", "time", "env", "nice", "nohup", "command", "exec", "uv", "poetry", "pipenv"}
SETUP = {"cd", "pushd", "popd", "export", "set", "source", ".", "set-location", "sl", "true", ":"}
VIEWERS = {"cat", "head", "tail", "less", "more", "bat", "type", "get-content", "gc", "sed", "nl", "view"}
SOURCE_EXT = {
    "py", "pyi", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "java", "kt", "kts", "go", "rs", "rb", "php",
    "cs", "c", "h", "cc", "cpp", "cxx", "hpp", "swift", "scala", "sh", "bash", "ps1", "psm1", "sql", "vue",
    "svelte", "html", "css", "scss", "md", "toml", "yaml", "yml", "xml", "gradle", "lua", "dart", "ex", "exs",
}
SEARCH = {"rg", "grep", "egrep", "fgrep", "ag", "ack", "findstr", "select-string", "sls", "git-grep"}
LISTING = {"find", "tree", "fd", "fdfind", "get-childitem", "gci", "dir"}
TEST_TOOLS = {"pytest", "py.test", "jest", "vitest", "mocha", "ava", "tap", "invoke-pester", "phpunit", "rspec", "tox", "nox", "karma"}
BUILD_TOOLS = {"tsc", "make", "cmake", "ninja", "webpack", "rollup", "esbuild", "vite", "msbuild", "gcc", "g++", "clang", "clang++", "javac", "ant", "bazel", "turbo", "nx", "next", "swc"}
LINT_TOOLS = {"eslint", "ruff", "flake8", "pylint", "mypy", "pyright", "golangci-lint", "shellcheck", "prettier", "stylelint", "rubocop", "biome", "tslint", "black", "isort", "bandit", "semgrep", "invoke-scriptanalyzer", "hadolint", "markdownlint"}
PKG_TOOLS = {"npm", "yarn", "pnpm", "bun", "pip", "pip3", "poetry", "pipenv", "uv", "cargo", "dotnet", "mvn", "gradle", "gradlew", "go", "composer", "bundle", "gem", "nuget", "choco", "winget"}
PKG_VERBS = {"install", "i", "ci", "add", "update", "upgrade", "restore", "sync", "remove", "uninstall", "fetch", "get", "download", "audit", "outdated"}
RUNNERS = {"npm", "yarn", "pnpm", "bun"}


@dataclass
class Classification:
    type: str
    reason: str
    confidence: str = "high"
    filtered: bool = False
    argv: List[str] = field(default_factory=list)
    subcommand: str = ""


def split_segments(command: str) -> List[Tuple[str, str]]:
    segments: List[Tuple[str, str]] = []
    buf: List[str] = []
    quote: Optional[str] = None
    i = 0
    sep = ""
    while i < len(command):
        ch = command[i]
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            elif ch == "\\" and quote == '"' and i + 1 < len(command):
                buf.append(command[i + 1])
                i += 1
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
            continue
        two = command[i:i + 2]
        if two in ("&&", "||"):
            segments.append((sep, "".join(buf).strip()))
            buf, sep = [], two
            i += 2
            continue
        if ch in ";|\n":
            segments.append((sep, "".join(buf).strip()))
            buf, sep = [], ch
            i += 1
            continue
        buf.append(ch)
        i += 1
    segments.append((sep, "".join(buf).strip()))
    return [(s, seg) for s, seg in segments if seg]


def words(segment: str) -> List[str]:
    try:
        parts = shlex.split(segment, posix=True)
    except ValueError:
        parts = segment.split()
    while parts and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", parts[0]):
        parts = parts[1:]
    return parts


def base(word: str) -> str:
    name = re.split(r"[\\/]", word)[-1].lower()
    for ext in (".exe", ".cmd", ".bat", ".ps1", ".sh"):
        if name.endswith(ext):
            name = name[: -len(ext)]
    return name


def _strip_wrappers(argv: List[str]) -> List[str]:
    while argv and base(argv[0]) in WRAPPERS:
        argv = argv[1:]
        while argv and argv[0].startswith("-"):
            argv = argv[1:]
        if argv and base(argv[0]) == "run" and len(argv) > 1:
            argv = argv[1:]
    if len(argv) >= 3 and base(argv[0]) in ("python", "python3", "py") and argv[1] == "-m":
        argv = argv[2:]
    if len(argv) >= 2 and base(argv[0]) in ("python", "python3", "py") and argv[1] == "-3":
        argv = [argv[0], *argv[2:]]
    return argv


def _git_sub(argv: List[str]) -> Tuple[str, List[str]]:
    rest = argv[1:]
    while rest:
        head = rest[0]
        if head in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") and len(rest) > 1:
            rest = rest[2:]
        elif head.startswith("-"):
            rest = rest[1:]
        else:
            return head, rest[1:]
    return "", []


def _script_name(argv: List[str]) -> str:
    if len(argv) < 2:
        return ""
    verb = argv[1]
    if verb in ("run", "run-script") and len(argv) > 2:
        return argv[2].lower()
    if verb in ("test", "t", "tst"):
        return "test"
    return verb.lower()


def classify_argv(argv: List[str]) -> Optional[Classification]:
    argv = _strip_wrappers(argv)
    if not argv:
        return None
    tool = base(argv[0])
    args = [a for a in argv[1:]]
    if tool == "git":
        sub, rest = _git_sub(argv)
        if sub == "status":
            return Classification("git-status", "git status", argv=argv, subcommand=sub)
        if sub in ("diff", "show", "format-patch"):
            return Classification("git-diff", f"git {sub}", argv=argv, subcommand=sub)
        if sub in ("log", "reflog", "whatchanged", "shortlog"):
            return Classification("git-log", f"git {sub}", argv=argv, subcommand=sub)
        if sub == "grep":
            return Classification("search", "git grep", argv=argv, subcommand=sub)
        if sub in ("ls-files", "ls-tree"):
            return Classification("directory-listing", f"git {sub}", argv=argv, subcommand=sub)
        return Classification("generic-command", f"git {sub}", "medium", argv=argv, subcommand=sub)
    if tool in SEARCH:
        return Classification("search", tool, argv=argv)
    if tool in LISTING or (tool == "ls" and any(a.startswith("-") and "R" in a for a in args)):
        return Classification("directory-listing", tool, argv=argv)
    if tool in VIEWERS:
        targets = [a for a in args if not a.startswith("-")]
        exts = {t.rsplit(".", 1)[-1].lower() for t in targets if "." in t}
        if exts & SOURCE_EXT:
            return Classification("source-code", f"{tool} of source file", argv=argv)
        if "json" in exts:
            return Classification("json", f"{tool} of json file", argv=argv)
        if exts & {"log", "out", "txt"}:
            return Classification("generic-log", f"{tool} of log file", "medium", argv=argv)
        return Classification("source-code", f"{tool} of a file", "medium", argv=argv)
    if tool in TEST_TOOLS or (tool == "node" and "--test" in args) or (tool == "unittest"):
        return Classification("test", tool, argv=argv)
    if tool in ("go", "cargo", "dotnet", "mvn", "mvnw", "gradle", "gradlew", "bazel", "deno", "bun"):
        verbs = [a.lower() for a in args if not a.startswith("-")]
        first = verbs[0] if verbs else ""
        if first in ("test", "verify") or "test" in verbs[:2]:
            return Classification("test", f"{tool} {first}", argv=argv)
        if first in ("build", "compile", "package", "check", "vet", "clippy", "assemble", "publish"):
            return Classification("build", f"{tool} {first}", argv=argv)
        if first in PKG_VERBS or first in ("mod", "tidy"):
            return Classification("package-manager", f"{tool} {first}", argv=argv)
    if tool in RUNNERS:
        script = _script_name(argv)
        if script in PKG_VERBS:
            return Classification("package-manager", f"{tool} {script}", argv=argv)
        if script.startswith("test") or script.endswith(":test") or script in ("spec", "e2e", "coverage"):
            return Classification("test", f"{tool} {script}", "medium", argv=argv)
        if "lint" in script or script in ("typecheck", "type-check", "check-types", "format:check"):
            return Classification("lint", f"{tool} {script}", "medium", argv=argv)
        if "build" in script or script in ("compile", "bundle", "dist"):
            return Classification("build", f"{tool} {script}", "medium", argv=argv)
    if tool in PKG_TOOLS and args and args[0].lower() in PKG_VERBS:
        return Classification("package-manager", f"{tool} {args[0]}", argv=argv)
    if tool in BUILD_TOOLS:
        return Classification("build", tool, argv=argv)
    if tool in LINT_TOOLS or tool == "gate":
        return Classification("lint", tool, argv=argv)
    if tool in ("ls",):
        return Classification("directory-listing", "ls", "medium", argv=argv)
    return None


TRACE_PY = re.compile(r"^Traceback \(most recent call last\):", re.M)
TRACE_JS = re.compile(r"^\s+at .+[:(].+:\d+(:\d+)?\)?\s*$", re.M)
TRACE_JAVA = re.compile(r"^\s+at [\w$.<>]+\([\w$.]+:\d+\)\s*$", re.M)
TRACE_NET = re.compile(r"^\s+at .+ in .+:line \d+\s*$", re.M)
DIFF = re.compile(r"^diff --git ", re.M)
LOCATION = re.compile(r"^(?:[A-Za-z]:)?[^\s:]*[\w-]\.[A-Za-z][\w]{0,7}:\d+[:-]", re.M)
TIMESTAMP = re.compile(r"^\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}|^\[?\d{2}:\d{2}:\d{2}", re.M)
TEST_SUMMARY = re.compile(
    r"^=+ .*\b(passed|failed|error)\b.* in [\d.]+s|^Tests?:\s+\d+|^Test Files\s+\d+|^\s*\d+ passing \(|^# (pass|fail) \d+|"
    r"^Ran \d+ tests? in|^--- (FAIL|PASS): |^test result: |^Tests run: \d+, Failures:|^(Passed|Failed)!\s+-|^Tests Passed: \d+",
    re.M,
)


def sniff(text: str) -> Optional[Classification]:
    head = text[:200_000]
    stripped = head.lstrip()
    if stripped[:1] in ("{", "[") and len(text) < 20_000_000:
        try:
            json.loads(text)
            return Classification("json", "parses as JSON")
        except ValueError:
            pass
    if DIFF.search(head):
        return Classification("git-diff", "contains a unified git diff", "medium")
    if TEST_SUMMARY.search(text[-400_000:]) or TEST_SUMMARY.search(head):
        return Classification("test", "contains a test-runner summary", "medium")
    if TRACE_PY.search(head) or len(TRACE_JS.findall(head)) >= 3 or len(TRACE_JAVA.findall(head)) >= 3 or len(TRACE_NET.findall(head)) >= 2:
        return Classification("stack-trace", "contains a stack trace", "medium")
    lines = head.splitlines()[:2000]
    if len(lines) >= 20:
        if sum(1 for line in lines if TIMESTAMP.match(line)) >= 0.5 * len(lines):
            return Classification("generic-log", "timestamped lines", "medium")
        if len(LOCATION.findall(head)) >= 0.6 * len(lines):
            return Classification("search", "path:line lines", "low")
    return None


def classify(result: CommandResult) -> Classification:
    try:
        segments = split_segments(result.command or "")
        primary: List[str] = []
        filtered = False
        for i, (sep, segment) in enumerate(segments):
            argv = words(segment)
            if not argv:
                continue
            if sep == "|" and base(argv[0]) in FILTERS:
                filtered = True
                continue
            if base(argv[0]) in SETUP:
                continue
            primary = argv
        found = classify_argv(primary) if primary else None
        text = result.stdout if len(result.stdout) >= len(result.stderr) else result.stderr
        if found is None or (found.type in ("generic-command", "lint", "build") and found.confidence != "high"):
            sniffed = sniff(text) or sniff(result.stderr) if text else None
            if sniffed and (found is None or sniffed.type in ("test", "stack-trace")):
                sniffed.argv = primary
                found = sniffed
        if found is None:
            found = Classification("generic-command", "no rule matched", "low", argv=primary)
        found.filtered = filtered
        return found
    except Exception:
        return Classification("generic-command", "classifier error", "low")
