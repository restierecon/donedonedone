import posixpath
import re
import subprocess
import sys

SKIP_DIRS = {"node_modules", ".venv", "venv", ".git", ".gate", "vault", ".worktrees", "vendor", "__pycache__"}
OUTPUT_DIRS = {"target", "build", "dist", "coverage", "out"}
MAX_BYTES = 1_000_000
DOC_EXT = {".md", ".rst", ".txt", ".adoc"}
DATA_EXT = {".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".lock", ".csv", ".svg", ".xml", ".html", ".htm", ".css", ".env", ".gitignore", ".gitattributes", ""}
TEST_FILE = re.compile(r"(^|/)(tests?|__tests__|spec)/|(^|/)test_[^/]*\.py$|_test\.(py|go)$|\.(test|spec)\.[jt]sx?$|Tests?\.(java|kt)$|(^|/)(run-)?tests?[^/]*\.sh$")


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit("codebase-graph.py: git %s failed: %s" % (" ".join(args), result.stderr.strip()))
    return result.stdout


def extension(path):
    name = posixpath.basename(path)
    if name.startswith(".") and name.count(".") == 1:
        return name
    return posixpath.splitext(name)[1].lower()


def module_of(path):
    return posixpath.dirname(path) or "."


def is_test(path):
    return bool(TEST_FILE.search(path))


def is_doc(path):
    return extension(path) in DOC_EXT


def is_data(path):
    return extension(path) in DATA_EXT


BUILD_MANIFESTS = {"package.json", "Cargo.toml", "pom.xml", "build.gradle", "build.gradle.kts", "pyproject.toml", "setup.py", "go.mod", "composer.json"}


def package_roots(paths):
    return {"/".join(p.split("/")[:-1]) for p in paths if p.split("/")[-1] in BUILD_MANIFESTS}


def skipped_dir(path, roots=frozenset()):
    parts = path.split("/")[:-1]
    if any(part in SKIP_DIRS for part in parts):
        return True
    return any(part in OUTPUT_DIRS and (i == 0 or "/".join(parts[:i]) in roots) for i, part in enumerate(parts))


def listing(rev):
    entries = []
    for line in git("ls-tree", "-r", "-l", "-z", rev).split("\0"):
        if not line:
            continue
        meta, path = line.split("\t", 1)
        kind, size = meta.split()[1], meta.split()[3]
        if kind == "blob":
            entries.append((path, int(size) if size.isdigit() else 0))
    return entries


def read_tree(rev):
    texts, skipped = {}, {"vendored": 0, "too large": 0, "binary": 0}
    wanted, entries = [], listing(rev)
    roots = package_roots(p for p, _ in entries)
    for path, size in entries:
        if skipped_dir(path, roots):
            skipped["vendored"] += 1
        elif size > MAX_BYTES:
            skipped["too large"] += 1
        else:
            wanted.append(path)
    for path, body in blobs(rev, wanted):
        if body is None:
            skipped["unreadable"] = skipped.get("unreadable", 0) + 1
        elif b"\0" in body[:8000]:
            skipped["binary"] += 1
        else:
            texts[path] = body.decode("utf-8", errors="replace")
    return texts, skipped


def blobs(rev, paths):
    if not paths:
        return
    request = "".join("%s:%s\n" % (rev, p) for p in paths).encode()
    out = subprocess.run(["git", "cat-file", "--batch"], input=request, capture_output=True, check=True).stdout
    pos = 0
    for path in paths:
        header_end = out.index(b"\n", pos)
        header = out[pos:header_end].split()
        if len(header) < 3 or not header[2].isdigit():
            pos = header_end + 1
            yield path, None
            continue
        size = int(header[2])
        yield path, out[header_end + 1:header_end + 1 + size]
        pos = header_end + 1 + size + 1


def churn_counts(rev, days):
    counts = {}
    for line in git("log", "--format=", "--name-only", "--since=%d days ago" % days, rev).splitlines():
        if line:
            counts[line] = counts.get(line, 0) + 1
    return counts


def short_rev(rev):
    return git("rev-parse", "--short", rev).strip()


def line_count(text):
    return text.count("\n") + (0 if text.endswith("\n") or not text else 1)
