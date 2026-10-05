from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from ..models import Compressed, Section
from .common import clip, lines_of

STATUS_CAP = {"strict": 400, "balanced": 60, "aggressive": 25}
LONG_STATE = re.compile(r"^\t(?:(new file|modified|deleted|renamed|copied|typechange|both modified|both added|both deleted|added by us|added by them|deleted by us|deleted by them):\s+)?(.+?)(?: \((?:new commits|modified content|untracked content)[^)]*\))?$")
HEADINGS = {
    "Changes to be committed:": "staged",
    "Changes not staged for commit:": "unstaged",
    "Untracked files:": "untracked",
    "Unmerged paths:": "conflicts",
    "Ignored files:": "ignored",
}
PORCELAIN = re.compile(r"^([ MADRCUT?!])([ MADRCUT?!]) (.+)$")
CODES = {"M": "modified", "A": "new file", "D": "deleted", "R": "renamed", "C": "copied", "T": "typechange", "U": "unmerged"}
CONFLICT_CODES = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}
SECTION_TITLES = [
    ("conflicts", "Conflicts", 5),
    ("staged", "Staged", 10),
    ("unstaged", "Modified (not staged)", 15),
    ("untracked", "Untracked", 25),
    ("ignored", "Ignored", 40),
]


def status(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    groups: Dict[str, List[str]] = {k: [] for k, _, _ in SECTION_TITLES}
    branch: List[str] = []
    notes: List[str] = []
    current = None
    parsed = False
    for line in lines:
        if not line.strip():
            continue
        if line.startswith("## "):
            branch.append(line[3:])
            parsed = True
            continue
        if line.startswith(("On branch ", "HEAD detached", "Not currently on any branch")):
            branch.append(line)
            parsed = True
            continue
        if line.startswith(("Your branch", "and have ", "You are currently", "You have unmerged", "All conflicts fixed", "nothing to commit", "nothing added to commit", "no changes added", "Interactive rebase", "Last command", "Next command", "rebase in progress", "You are in the middle")):
            notes.append(line)
            parsed = True
            continue
        if line in HEADINGS:
            current = HEADINGS[line]
            parsed = True
            continue
        if line.lstrip().startswith("(use ") or line.lstrip().startswith("(fix conflicts") or line.lstrip().startswith("(all conflicts"):
            continue
        match = LONG_STATE.match(line)
        if current and match:
            state = match.group(1)
            path = match.group(2)
            if current in ("untracked", "ignored") and not state:
                groups[current].append(path)
            else:
                groups[current].append(f"{state or 'changed'}: {path}")
            continue
        porcelain = PORCELAIN.match(line)
        if porcelain:
            parsed = True
            x, y, path = porcelain.group(1), porcelain.group(2), porcelain.group(3)
            if x + y == "??":
                groups["untracked"].append(path)
            elif x + y == "!!":
                groups["ignored"].append(path)
            elif x + y in CONFLICT_CODES:
                groups["conflicts"].append(f"{x}{y}: {path}")
            else:
                if x != " ":
                    groups["staged"].append(f"{CODES.get(x, x)}: {path}")
                if y != " ":
                    groups["unstaged"].append(f"{CODES.get(y, y)}: {path}")
            continue
        if current is None:
            notes.append(line)
    if not parsed:
        return None
    cap = 10 ** 9 if ctx.get("unbounded") else STATUS_CAP[ctx["mode"]]
    out = Compressed(type="git-status", parser="git-status", confidence="high")
    out.headline.append("GIT STATUS")
    out.headline.extend(f"Branch: {b}" for b in branch)
    out.headline.extend(notes[:6])
    counts = [f"{title.split(' ')[0].lower()} {len(groups[key])}" for key, title, _ in SECTION_TITLES if groups[key]]
    if counts:
        out.headline.append("Counts: " + ", ".join(counts))
    for key, title, prio in SECTION_TITLES:
        items = groups[key]
        if not items:
            continue
        shown = _grouped(items, cap, ctx["maxLineChars"], key, bool(ctx.get("unbounded")))
        out.sections.append(Section(key, shown, priority=prio, title=f"{title} ({len(items)}):", verbatim=False, essential=key == "conflicts"))
        out.related_files.extend(i.split(": ", 1)[-1] for i in items[:200])
    if not any(groups.values()):
        out.status = "clean"
    return out


def _grouped(items: List[str], cap: int, max_chars: int, key: str, unbounded: bool) -> List[str]:
    if unbounded or len(items) <= 12:
        out = [f"- {clip(i, max_chars)}" for i in items[:cap]]
        if len(items) > cap:
            out.append(f"... {len(items) - cap} more (--section {key})")
        return out
    by_dir: Dict[str, List[str]] = {}
    for item in items:
        state, _, path = item.rpartition(": ")
        folder = path.rsplit("/", 1)[0] + "/" if "/" in path.rstrip("/") else ""
        by_dir.setdefault(f"{state}: {folder}" if state else folder, []).append(item)
    out: List[str] = []
    for folder, members in by_dir.items():
        if len(members) >= 6:
            names = [m.rpartition(": ")[2].rsplit("/", 1)[-1] for m in members[:3]]
            out.append(f"- {folder or './'} ({len(members)} entries: {', '.join(names)}, ...; --section {key})")
        else:
            out.extend(f"- {clip(m, max_chars)}" for m in members)
        if len(out) >= cap:
            out.append(f"... more (--section {key})")
            break
    return out


@dataclass
class FileDiff:
    old: str
    new: str
    start: int
    end: int = 0
    status: str = "M"
    added: int = 0
    removed: int = 0
    binary: bool = False
    similarity: str = ""
    mode: str = ""
    hunks: List[Tuple[int, List[str]]] = field(default_factory=list)
    symbols: List[str] = field(default_factory=list)

    @property
    def path(self) -> str:
        return self.new if self.new != "/dev/null" else self.old


DIFF_HEAD = re.compile(r'^diff --git "?a/(.+?)"? "?b/(.+?)"?$')
COMBINED_HEAD = re.compile(r"^diff --(?:cc|combined) (.+)$")
HUNK = re.compile(r"^@@+ [^@]* @@+ ?(.*)$")
DECL = re.compile(
    r"^\s*(?:export\s+)?(?:default\s+)?(?:public\s+|private\s+|protected\s+|internal\s+|static\s+|async\s+|abstract\s+|override\s+|final\s+)*"
    r"(?:def|class|function|func|fn|interface|type|struct|enum|impl|trait|module|record)\s+([A-Za-z_$][\w$]*)"
)
METHOD = re.compile(r"^\s*(?:public|private|protected|internal|static|async|override|virtual|final|\s)+[\w<>\[\],. ?]*\s+([A-Za-z_]\w*)\s*\([^;]*$")
NOISE = re.compile(
    r"(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Cargo\.lock|composer\.lock|Gemfile\.lock|go\.sum|uv\.lock|Pipfile\.lock|packages\.lock\.json)$"
    r"|\.min\.(js|css)$|\.map$|\.snap$|(^|/)(dist|build|vendor|node_modules|__snapshots__|\.next|coverage|out)/|\.(pb\.go|g\.dart|generated\.\w+)$"
)
CONTEXT_KEEP = {"strict": 3, "balanced": 1, "aggressive": 0}
COMMIT = re.compile(r"^commit ([0-9a-f]{7,40})(.*)$")
SHELL_FUNC = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{")


def _decl(text: str, header: bool = False) -> str:
    text = text or ""
    match = DECL.match(text) or SHELL_FUNC.match(text) or (METHOD.match(text) if header else None)
    if not match:
        return ""
    name = match.group(1)
    return "" if name in ("if", "for", "while", "switch", "catch", "return", "else", "new") else name


def parse_diff(lines: List[str]) -> List[FileDiff]:
    files: List[FileDiff] = []
    current: Optional[FileDiff] = None
    hunk: Optional[List[str]] = None
    for idx, line in enumerate(lines):
        head = DIFF_HEAD.match(line) or COMBINED_HEAD.match(line)
        if head:
            if current:
                current.end = idx
            groups = head.groups()
            current = FileDiff(old=groups[0], new=groups[-1], start=idx + 1)
            files.append(current)
            hunk = None
            continue
        if current is None:
            continue
        if COMMIT.match(line):
            current.end = idx
            current = None
            hunk = None
            continue
        match = HUNK.match(line)
        if match:
            hunk = [line]
            current.hunks.append((idx + 1, hunk))
            decl = _decl(match.group(1), header=True)
            if decl and decl not in current.symbols:
                current.symbols.append(decl)
            continue
        if hunk is None:
            if line.startswith("new file mode"):
                current.status = "A"
            elif line.startswith("deleted file mode"):
                current.status = "D"
            elif line.startswith("rename from "):
                current.status = "R"
                current.old = line[len("rename from "):]
            elif line.startswith("rename to "):
                current.new = line[len("rename to "):]
            elif line.startswith("copy from "):
                current.status = "C"
            elif line.startswith("similarity index "):
                current.similarity = line[len("similarity index "):]
            elif line.startswith(("old mode ", "new mode ")):
                current.mode = line
                if current.status == "M":
                    current.status = "M"
            elif line.startswith("Binary files ") or line == "GIT binary patch":
                current.binary = True
            continue
        if line.startswith("+") and not line.startswith("+++"):
            current.added += 1
            decl = _decl(line[1:])
            if decl and decl not in current.symbols:
                current.symbols.append(decl)
        elif line.startswith("-") and not line.startswith("---"):
            current.removed += 1
            decl = _decl(line[1:])
            if decl and decl not in current.symbols:
                current.symbols.append(decl)
        elif not (line.startswith(" ") or line.startswith("\\") or line == ""):
            if current.end == 0:
                current.end = idx
            hunk = None
            continue
        hunk.append(line)
    if current and not current.end:
        current.end = len(lines)
    for f in files:
        if f.end == 0:
            f.end = len(lines)
    return files


def _trim_hunk(hunk: List[str], keep: int, max_chars: int) -> List[str]:
    body = hunk[1:]
    changed = [i for i, line in enumerate(body) if line.startswith(("+", "-"))]
    if keep >= 3 or not changed:
        return [hunk[0]] + [clip(line, max_chars) for line in body]
    wanted = set()
    for i in changed:
        wanted.update(range(i - keep, i + keep + 1))
    out = [hunk[0]]
    skipped = 0
    for i, line in enumerate(body):
        if i in wanted or line.startswith("\\"):
            if skipped:
                out.append(f" ... ({skipped} unchanged lines)")
                skipped = 0
            out.append(clip(line, max_chars))
        else:
            skipped += 1
    if skipped:
        out.append(f" ... ({skipped} unchanged lines)")
    return out


def _file_row(f: FileDiff) -> str:
    name = f"{f.old} -> {f.new}" if f.status in ("R", "C") and f.old != f.new else f.path
    parts = [f"{'B' if f.binary else f.status} {name}"]
    if f.binary:
        parts.append("(binary)")
    else:
        parts.append(f"+{f.added} -{f.removed}")
    if f.similarity:
        parts.append(f"(similarity {f.similarity})")
    if f.mode and not f.hunks:
        parts.append("(mode change)")
    if f.symbols:
        parts.append("[" + ", ".join(f.symbols[:6]) + (", ..." if len(f.symbols) > 6 else "") + "]")
    return "  ".join(parts)


def _commits(lines: List[str], max_chars: int) -> List[str]:
    out = []
    i = 0
    while i < len(lines):
        match = COMMIT.match(lines[i])
        if not match:
            i += 1
            continue
        sha = match.group(1)[:10]
        author = date = subject = ""
        j = i + 1
        while j < len(lines) and not COMMIT.match(lines[j]):
            line = lines[j]
            if line.startswith("Author:"):
                author = line[7:].strip().split(" <")[0]
            elif line.startswith(("Date:", "AuthorDate:")):
                date = line.split(":", 1)[1].strip()
            elif line.startswith("    ") and not subject and line.strip():
                subject = line.strip()
            elif line.startswith("diff --git"):
                break
            j += 1
        out.append(clip(f"{sha} {date} {author} | {subject}".replace("  ", " "), max_chars))
        i = j
    return out


def diff(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    files = parse_diff(lines)
    commits = _commits(lines, ctx["maxLineChars"]) if any(COMMIT.match(line) for line in lines[:2000]) else []
    if not files:
        if commits:
            return log(text, ctx)
        if ctx.get("exit_code") in (0, None) and not "".join(lines).strip():
            return None
        return None
    mode = ctx["mode"]
    keep = CONTEXT_KEEP[mode]
    active = set(ctx.get("active_files") or [])
    out = Compressed(type="git-diff", parser="unified-diff", confidence="high")
    adds = sum(f.added for f in files)
    dels = sum(f.removed for f in files)
    out.headline.append("GIT DIFF")
    out.headline.append(f"Files changed: {len(files)}  Insertions: +{adds}  Deletions: -{dels}")
    if commits:
        out.sections.append(Section("commits", commits[:50] + ([f"... {len(commits) - 50} more commits"] if len(commits) > 50 else []), priority=8, title=f"COMMITS ({len(commits)}):", verbatim=False))
    rows = [_file_row(f) for f in files]
    out.sections.append(Section("files", rows, priority=5, title="FILES:", verbatim=False, essential=True))
    for order, f in enumerate(files):
        out.related_files.append(f.path)
        out.related_symbols.extend(f.symbols[:10])
        if f.binary or not f.hunks:
            continue
        noisy = bool(NOISE.search(f.path))
        body: List[str] = []
        for _, hunk in f.hunks:
            body.extend(_trim_hunk(hunk, keep, ctx["maxLineChars"]))
        if noisy and mode != "strict" and not ctx.get("unbounded"):
            continue
        prio = 40 + min(order, 50)
        if f.path in active or any(f.path.endswith(a) or a.endswith(f.path) for a in active):
            prio = 15
        title = f"--- {f.path}  (raw L{f.start}-{f.end})"
        out.sections.append(Section(f"file:{f.path}", body, priority=prio, title=title, verbatim=True))
    noisy_files = [f.path for f in files if NOISE.search(f.path) and f.hunks]
    if noisy_files and mode != "strict" and not ctx.get("unbounded"):
        out.headline.append(f"Hunks hidden for {len(noisy_files)} lock/generated file(s): " + ", ".join(noisy_files[:5]) + (" ..." if len(noisy_files) > 5 else ""))
    return out


def retrieve_file(text: str, path: str) -> Optional[List[str]]:
    lines = text.split("\n")
    files = parse_diff(lines_of(text))
    hits = [f for f in files if f.path == path or f.old == path] or [f for f in files if f.path.endswith(path)]
    if not hits:
        return None
    out: List[str] = []
    for f in hits:
        out.extend(lines[f.start - 1:f.end])
    return out


def log(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    max_chars = ctx["maxLineChars"]
    if any(line.startswith("diff --git") for line in lines):
        return diff(text, ctx)
    commits = _commits(lines, max_chars)
    out = Compressed(type="git-log", parser="git-log", confidence="high")
    if not commits:
        oneline = [line for line in lines if re.match(r"^[*|/\\ ]*[0-9a-f]{7,40}\b", line)]
        if len(oneline) < max(1, len([line for line in lines if line.strip()]) // 2):
            return None
        commits = [clip(line, max_chars) for line in oneline]
        out.parser = "git-log:oneline"
    cap = 10 ** 9 if ctx.get("unbounded") else {"strict": 200, "balanced": 60, "aggressive": 25}[ctx["mode"]]
    out.headline.append(f"GIT LOG  commits: {len(commits)}")
    shown = commits[:cap]
    if len(commits) > cap:
        shown.append(f"... {len(commits) - cap} more commits (--section commits)")
    out.sections.append(Section("commits", shown, priority=10, title=None, verbatim=False, essential=True))
    stat = [line for line in lines if re.match(r"^ \S.* \| +(\d+|Bin)", line)]
    if stat:
        out.sections.append(Section("stat", [clip(s, max_chars) for s in stat], priority=40, title="STAT:"))
    return out
