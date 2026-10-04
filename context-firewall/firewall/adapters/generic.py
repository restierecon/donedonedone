from __future__ import annotations

from typing import Dict, List, Optional

from ..models import Compressed, Section
from ..tokens import estimate
from .common import clip, collapse, group_signals, lines_of, normalize, numbered

HEAD = {"strict": 40, "balanced": 20, "aggressive": 8}
TAIL = {"strict": 60, "balanced": 30, "aggressive": 12}
TEMPLATES = {"strict": 25, "balanced": 15, "aggressive": 8}


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    mode = ctx["mode"]
    max_chars = ctx["maxLineChars"]
    lines = lines_of(text)
    while lines and not lines[-1]:
        lines.pop()
    collapsed = collapse(lines)
    kind = ctx.get("type", "generic-command")
    out = Compressed(type=kind, parser="generic", confidence="low")
    if estimate("\n".join(collapsed)) <= ctx["budget"] * 0.8 and not _repetitive(lines):
        out.parser = "generic:dedup"
        out.headline.append(f"{len(lines)} lines, {len(lines) - len(collapsed)} repeated lines collapsed")
        out.sections.append(Section("output", [clip(line, max_chars) for line in collapsed], priority=10, title=None))
        return out
    out.headline.append(f"{len(lines)} lines (showing head, tail and error/warning lines)")
    signals = group_signals(lines, max_chars)
    if signals:
        out.sections.append(Section("signals", signals, priority=10, title="ERRORS / WARNINGS", essential=True))
    if kind == "generic-log" or _repetitive(lines):
        templates = _templates(lines, TEMPLATES[mode], max_chars)
        if templates:
            out.sections.append(Section("templates", templates, priority=25, title="MOST REPEATED LINES"))
        unusual = _unusual(lines, signals, max_chars)
        if unusual:
            out.sections.append(Section("unusual", unusual, priority=12, title="LINES THAT FIT NO REPEATED PATTERN"))
    head_n, tail_n = HEAD[mode], TAIL[mode]
    if kind == "generic-log" or _repetitive(lines):
        head_n, tail_n = max(3, head_n // 4), max(5, tail_n // 3)
    out.sections.append(Section("head", numbered(enumerate(lines[:head_n], 1), max_chars), priority=30, title="HEAD"))
    start = max(head_n, len(lines) - tail_n)
    out.sections.append(Section("tail", numbered(((i + 1, lines[i]) for i in range(start, len(lines))), max_chars), priority=20, title="TAIL"))
    return out


def _repetitive(lines: List[str]) -> bool:
    filled = [line for line in lines if line.strip()]
    if len(filled) < 100:
        return False
    counts: Dict[str, int] = {}
    for line in filled:
        key = normalize(line, numbers=True)
        counts[key] = counts.get(key, 0) + 1
    return max(counts.values()) >= 0.5 * len(filled)


def _unusual(lines: List[str], signals: List[str], max_chars: int, limit: int = 30) -> List[str]:
    counts: Dict[str, int] = {}
    for line in lines:
        if line.strip():
            key = normalize(line, numbers=True)
            counts[key] = counts.get(key, 0) + 1
    shown = {s.split(": ", 1)[0] for s in signals}
    rare = [(i, line) for i, line in enumerate(lines, 1) if line.strip() and counts[normalize(line, numbers=True)] == 1 and f"L{i}" not in shown]
    out = numbered(rare[:limit], max_chars)
    if len(rare) > limit:
        out.append(f"... {len(rare) - limit} more (--section unusual)")
    return out


def _templates(lines: List[str], limit: int, max_chars: int) -> List[str]:
    counts: Dict[str, List[int]] = {}
    for idx, line in enumerate(lines, 1):
        if line.strip():
            counts.setdefault(normalize(line, numbers=True), []).append(idx)
    ranked = sorted(((len(v), v[0]) for v in counts.values() if len(v) > 2), key=lambda t: (-t[0], t[1]))
    return [f"L{first}: {clip(lines[first - 1].strip(), max_chars)}  [x{n} similar]" for n, first in ranked[:limit]]
