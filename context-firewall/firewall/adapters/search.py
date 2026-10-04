from __future__ import annotations

import re
from typing import Dict, List, Optional, Tuple

from ..models import Compressed, Section
from .common import clip, lines_of

WITH_LINE = re.compile(r"^((?:[A-Za-z]:[\\/])?[^:\n]*?[^:\n\s]):(\d+):(?:(\d+):)?(.*)$")
CONTEXT_LINE = re.compile(r"^((?:[A-Za-z]:[\\/])?[^:\n]*?\.[\w]+)-(\d+)-(.*)$")
HEADING_MATCH = re.compile(r"^(\d+)(?::(\d+))?:(.*)$")
HEADING_CONTEXT = re.compile(r"^(\d+)-(.*)$")
NO_LINE = re.compile(r"^((?:[A-Za-z]:[\\/])?[^:\n\s][^:\n]*\.[A-Za-z0-9]{1,8}):(.*)$")
VALUE_OPTS = {"-e", "-f", "-g", "--glob", "-t", "--type", "-T", "--type-not", "-A", "-B", "-C", "-m", "--max-count",
              "--context", "--after-context", "--before-context", "-j", "--threads", "--include", "--exclude",
              "--exclude-dir", "-d", "--max-depth", "--color", "--colors", "-r", "--replace", "-E", "--encoding",
              "-Pattern", "-Path", "-Include", "-Exclude", "--sort", "--type-add", "-M", "--max-columns"}
PER_FILE = {"strict": 50, "balanced": 3, "aggressive": 1}
MAX_FILES = {"strict": 400, "balanced": 40, "aggressive": 15}


def query_of(argv: List[str]) -> str:
    if not argv:
        return ""
    args = argv[1:]
    if argv and argv[0].lower().endswith("git") and args and args[0] == "grep":
        args = args[1:]
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("-e", "--regexp", "-Pattern"):
            return args[i + 1] if i + 1 < len(args) else ""
        if arg.startswith("--regexp="):
            return arg.split("=", 1)[1]
        if arg in VALUE_OPTS:
            i += 2
            continue
        if arg.startswith("-"):
            i += 1
            continue
        return arg
    return ""


def parse(lines: List[str]) -> Tuple[Dict[str, List[Tuple[int, int, str]]], List[str], str]:
    files: Dict[str, List[Tuple[int, int, str]]] = {}
    order: List[str] = []
    style = ""
    heading: Optional[str] = None

    def add(path: str, raw_line: int, line_no: int, text: str) -> None:
        if path not in files:
            files[path] = []
            order.append(path)
        files[path].append((raw_line, line_no, text))

    non_empty = [line for line in lines if line.strip()]
    flat = sum(1 for line in non_empty[:500] if WITH_LINE.match(line))
    headed = sum(1 for line in non_empty[:500] if HEADING_MATCH.match(line))
    if headed > flat:
        style = "heading"
        for idx, line in enumerate(lines, 1):
            if not line.strip():
                heading = None
                continue
            match = HEADING_MATCH.match(line)
            if match and heading:
                add(heading, idx, int(match.group(1)), match.group(3))
                continue
            if HEADING_CONTEXT.match(line) and heading:
                continue
            if line == "--":
                continue
            heading = line.strip()
        return files, order, style
    if flat:
        style = "path:line"
        for idx, line in enumerate(lines, 1):
            match = WITH_LINE.match(line)
            if match:
                add(match.group(1), idx, int(match.group(2)), match.group(4))
        return files, order, style
    bare = sum(1 for line in non_empty[:500] if NO_LINE.match(line))
    if non_empty and bare >= 0.8 * min(len(non_empty), 500):
        style = "path:text"
        for idx, line in enumerate(lines, 1):
            match = NO_LINE.match(line)
            if match:
                add(match.group(1), idx, 0, match.group(2))
        return files, order, style
    paths = [line.strip() for line in non_empty]
    if paths and all(re.match(r"^[^\s:]+\.[A-Za-z0-9]+$|^[^\s:]*/[^\s:]*$", p) for p in paths[:500]):
        style = "files"
        for idx, line in enumerate(lines, 1):
            if line.strip():
                add(line.strip(), idx, 0, "")
    return files, order, style


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    files, order, style = parse(lines)
    if not files:
        if ctx.get("exit_code") == 1 and not text.strip():
            return None
        return None
    mode = ctx["mode"]
    unbounded = ctx.get("unbounded")
    per_file = 10 ** 9 if unbounded else PER_FILE[mode]
    max_files = 10 ** 9 if unbounded else MAX_FILES[mode]
    max_chars = min(ctx["maxLineChars"], 200)
    active = ctx.get("active_files") or []
    ranked = sorted(order, key=lambda p: (0 if any(p.endswith(a) or a.endswith(p) for a in active) else 1, order.index(p)))
    total = sum(len(v) for v in files.values())
    out = Compressed(type="search", parser=f"search:{style}", confidence="high" if style in ("path:line", "heading") else "medium")
    out.headline.append("SEARCH")
    query = query_of(ctx.get("argv") or [])
    if query:
        out.headline.append(f"Query: {query}")
    out.headline.append(f"Matches: {total}  Files: {len(files)}" if style != "files" else f"Files: {len(files)}")
    body: List[str] = []
    for path in ranked[:max_files]:
        hits = files[path]
        if style == "files":
            body.append(path)
            continue
        numbers = [str(h[1]) for h in hits if h[1]]
        listed = ", ".join(numbers[:20]) + (f", ... (+{len(numbers) - 20})" if len(numbers) > 20 else "")
        body.append(f"{path} ({len(hits)}){': ' + listed if numbers else ''}")
        for raw_line, line_no, snippet in hits[:per_file]:
            prefix = f"{line_no}: " if line_no else ""
            body.append(f"  {prefix}{clip(snippet.strip(), max_chars)}")
        if len(hits) > per_file:
            body.append(f"  ... {len(hits) - per_file} more in this file (--file {path})")
    if len(ranked) > max_files:
        rest = ranked[max_files:]
        body.append(f"... {len(rest)} more files with {sum(len(files[p]) for p in rest)} matches (--section matches)")
    out.sections.append(Section("matches", body, priority=10, title=None, verbatim=False, essential=True))
    out.related_files.extend(order[:200])
    return out


def retrieve_file(text: str, path: str) -> Optional[List[str]]:
    raw = text.split("\n")
    files, order, _ = parse(lines_of(text))
    key = path if path in files else next((p for p in order if p.endswith(path)), None)
    if key is None:
        return None
    return [raw[idx - 1] for idx, _, _ in files[key]]
