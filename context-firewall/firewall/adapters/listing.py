from __future__ import annotations

import re
from typing import Dict, List, Optional, Tuple

from ..models import Compressed, Section
from .common import lines_of

HEAVY = {"node_modules", ".git", "__pycache__", ".venv", "venv", "dist", "build", "target", ".next", ".cache", "coverage", "bin", "obj", ".tox", ".mypy_cache", ".pytest_cache", ".gradle", ".idea", ".vs"}
TREE_PREFIX = re.compile(r"^((?:[│|]\s{3}|\s{4})*)(?:[├└|`]── |[|`]-- )(.*)$")
GCI_DIR = re.compile(r"^\s*Directory: (.+)$")
GCI_ROW = re.compile(r"^(?P<mode>[d\-][a-z\-]{4,5})\s+\S+\s+\S+(?:\s+[AP]M)?\s+(?P<len>\d+)?\s+(?P<name>.+)$")
CMD_DIR = re.compile(r"^ Directory of (.+)$")
CMD_ROW = re.compile(r"^\d{2}[/.-]\d{2}[/.-]\d{2,4}\s+\d{2}:\d{2}(?:\s?[AP]M)?\s+(?P<dir><DIR>|[\d,.]+)\s+(?P<name>.+)$")
DEPTH = {"strict": 6, "balanced": 2, "aggressive": 1}
PER_DIR = {"strict": 200, "balanced": 25, "aggressive": 10}


def _norm(path: str) -> str:
    path = path.replace("\\", "/").strip()
    while path.startswith("./"):
        path = path[2:]
    return path.rstrip("/") if path not in ("/", "") else path


def paths_from(lines: List[str]) -> Tuple[List[Tuple[str, bool]], str]:
    entries: List[Tuple[str, bool]] = []
    if any(TREE_PREFIX.match(line) for line in lines[:50]):
        stack: List[str] = []
        for line in lines:
            match = TREE_PREFIX.match(line)
            if not match:
                continue
            depth = len(match.group(1)) // 4
            name = match.group(2).strip()
            stack = stack[:depth] + [name]
            entries.append(("/".join(stack), False))
        known_dirs = {p.rsplit("/", 1)[0] for p, _ in entries if "/" in p}
        return [(p, p in known_dirs) for p, _ in entries], "tree"
    if any(GCI_DIR.match(line) for line in lines[:20]):
        base = ""
        for line in lines:
            d = GCI_DIR.match(line)
            if d:
                base = d.group(1).strip()
                continue
            row = GCI_ROW.match(line)
            if row and base:
                entries.append((_norm(f"{base}/{row.group('name').strip()}"), row.group("mode").startswith("d")))
        return _relative(entries), "get-childitem"
    if any(CMD_DIR.match(line) for line in lines[:20]):
        base = ""
        for line in lines:
            d = CMD_DIR.match(line)
            if d:
                base = d.group(1).strip()
                continue
            row = CMD_ROW.match(line)
            if row and base and row.group("name") not in (".", ".."):
                entries.append((_norm(f"{base}/{row.group('name').strip()}"), row.group("dir") == "<DIR>"))
        return _relative(entries), "dir"
    if any(re.match(r"^\S.*:$", line) for line in lines[:5]) and any(not line.strip() for line in lines):
        base = ""
        for line in lines:
            if re.match(r"^\S.*:$", line):
                base = _norm(line[:-1])
                continue
            if line.strip() and not line.startswith("total "):
                for name in line.split():
                    is_dir = name.endswith("/")
                    entries.append((_norm(f"{base}/{name}" if base and base != "." else name), is_dir))
        return entries, "ls -R"
    for line in lines:
        if line.strip():
            entries.append((_norm(line), line.rstrip().endswith("/")))
    dirs = {p.rsplit("/", 1)[0] for p, _ in entries if "/" in p}
    return [(p, d or p in dirs) for p, d in entries], "paths"


def _relative(entries: List[Tuple[str, bool]]) -> List[Tuple[str, bool]]:
    if not entries:
        return entries
    roots = [p.rsplit("/", 1)[0] for p, _ in entries]
    common = min(roots, key=len)
    while common and not all(r == common or r.startswith(common + "/") for r in roots):
        common = common.rsplit("/", 1)[0] if "/" in common else ""
    if not common:
        return entries
    return [(p[len(common) + 1:], d) for p, d in entries]


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    entries, style = paths_from(lines)
    if len(entries) < 2:
        return None
    unbounded = ctx.get("unbounded")
    max_depth = 10 ** 6 if unbounded else DEPTH[ctx["mode"]]
    per_dir = 10 ** 9 if unbounded else PER_DIR[ctx["mode"]]
    children: Dict[str, List[str]] = {}
    is_dir: Dict[str, bool] = {}
    total_files: Dict[str, int] = {}
    for path, d in entries:
        if not path or path == ".":
            continue
        parts = path.split("/")
        for depth in range(1, len(parts) + 1):
            node = "/".join(parts[:depth])
            parent = "/".join(parts[:depth - 1])
            if node not in is_dir:
                is_dir[node] = depth < len(parts) or d
                children.setdefault(parent, []).append(node)
            elif depth < len(parts):
                is_dir[node] = True
        if not d:
            for depth in range(0, len(parts)):
                anc = "/".join(parts[:depth])
                total_files[anc] = total_files.get(anc, 0) + 1
    body: List[str] = []

    def walk(node: str, depth: int) -> None:
        kids = sorted(children.get(node, []), key=lambda k: (not is_dir[k], k.lower()))
        shown = 0
        for kid in kids:
            name = kid.rsplit("/", 1)[-1]
            indent = "  " * depth
            if shown >= per_dir:
                body.append(f"{indent}... {len(kids) - shown} more entries (--file {node or '.'})")
                break
            shown += 1
            if is_dir[kid]:
                files = total_files.get(kid, 0)
                heavy = name in HEAVY and not unbounded
                if depth + 1 >= max_depth or heavy or not children.get(kid):
                    count = f" ({files} files)" if files else ""
                    body.append(f"{indent}{name}/{count}")
                else:
                    body.append(f"{indent}{name}/")
                    walk(kid, depth + 1)
            else:
                body.append(f"{indent}{name}")

    walk("", 0)
    out = Compressed(type="directory-listing", parser=f"listing:{style}", confidence="high" if style != "paths" else "medium")
    n_dirs = sum(1 for v in is_dir.values() if v)
    n_files = sum(1 for v in is_dir.values() if not v)
    out.headline.append(f"LISTING  entries: {len(entries)}  files: {n_files}  dirs: {n_dirs}  (depth {DEPTH[ctx['mode']]} shown; heavy dirs collapsed)")
    out.sections.append(Section("tree", body, priority=10, title=None, verbatim=False, essential=True))
    return out


def retrieve_file(text: str, prefix: str) -> Optional[List[str]]:
    entries, _ = paths_from(lines_of(text))
    want = _norm(prefix)
    hits = [p + ("/" if d else "") for p, d in entries if want in (".", "") or p == want or p.startswith(want + "/")]
    return hits or None
