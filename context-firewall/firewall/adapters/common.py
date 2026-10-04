from __future__ import annotations

import re
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-Z\\-_]")
COUNT_MARK = re.compile(r"  \[x(\d+)( similar)?\]$")
CLIP_MARK = re.compile(r" \.\.\.\[\+\d+ chars\]$")
LINE_REF = re.compile(r"^L\d+(-\d+)?: ")
SIGNAL = re.compile(
    r"\b(error|errors|fail|failed|failure|fatal|exception|panic|traceback|denied|refused|not found|"
    r"cannot|could not|unable to|segmentation fault|timed? ?out|warn|warning|deprecated)\b|[\u2716\u2717\u2718\u274c\u00d7\u26a0]",
    re.I,
)
STRONG = re.compile(r"\b(error|fail|failed|failure|fatal|exception|panic|traceback|denied|refused|cannot|unable to)\b", re.I)
VOLATILE = [
    (re.compile(r"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"), "<ts>"),
    (re.compile(r"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"), "<time>"),
    (re.compile(r"\b0x[0-9a-fA-F]+\b"), "<hex>"),
    (re.compile(r"\b[0-9a-f]{12,64}\b"), "<sha>"),
    (re.compile(r"\b\d+(?:\.\d+)?\s?(?:ms|s|sec|secs|seconds|m|min)\b"), "<dur>"),
    (re.compile(r"(/tmp/|\\Temp\\|/var/folders/)[^\s'\"]+"), "<tmp>"),
    (re.compile(r"\bpid[ =:]?\d+\b", re.I), "pid <n>"),
]
NUMBER = re.compile(r"\d+")


def clean(text: str) -> str:
    text = ANSI.sub("", text)
    if "\r" in text:
        text = text.replace("\r\n", "\n")
        text = "\n".join(seg.rsplit("\r", 1)[-1] for seg in text.split("\n"))
    return text


def lines_of(text: str) -> List[str]:
    return [line.rstrip() for line in clean(text).split("\n")]


def clip(line: str, max_chars: int) -> str:
    if max_chars and len(line) > max_chars:
        return f"{line[:max_chars]} ...[+{len(line) - max_chars} chars]"
    return line


def normalize(line: str, numbers: bool = False) -> str:
    out = line
    for pattern, repl in VOLATILE:
        out = pattern.sub(repl, out)
    if numbers:
        out = NUMBER.sub("<n>", out)
    return out.strip()


def collapse(lines: Sequence[str]) -> List[str]:
    out: List[str] = []
    i = 0
    n = len(lines)
    while i < n:
        best = (1, 1)
        for period in range(1, 9):
            if i + 2 * period > n:
                break
            block = lines[i:i + period]
            reps = 1
            while lines[i + reps * period:i + (reps + 1) * period] == block:
                reps += 1
            if reps >= 2 and reps * period > best[0] * best[1] and (period == 1 or reps >= 3):
                best = (period, reps)
        period, reps = best
        if reps > 1:
            if period == 1:
                out.append(f"{lines[i]}  [x{reps}]")
            else:
                for j, line in enumerate(lines[i:i + period]):
                    out.append(f"{line}  [x{reps}]" if j == 0 else line)
            i += period * reps
        else:
            out.append(lines[i])
            i += 1
    return out


def numbered(pairs: Iterable[Tuple[int, str]], max_chars: int) -> List[str]:
    return [f"L{n}: {clip(text, max_chars)}" for n, text in pairs]


def group_signals(lines: Sequence[str], max_chars: int, limit: int = 40, strong_only: bool = False) -> List[str]:
    seen: Dict[str, List[int]] = {}
    order: List[str] = []
    first: Dict[str, str] = {}
    pattern = STRONG if strong_only else SIGNAL
    for idx, line in enumerate(lines, 1):
        if not line.strip() or not pattern.search(line):
            continue
        key = normalize(line, numbers=True)
        if key not in seen:
            seen[key] = []
            order.append(key)
            first[key] = line
        seen[key].append(idx)
    out: List[str] = []
    for key in order[:limit]:
        hits = seen[key]
        text = f"L{hits[0]}: {clip(first[key].strip(), max_chars)}"
        if len(hits) > 1:
            text += f"  [x{len(hits)} similar]"
        out.append(text)
    if len(order) > limit:
        out.append(f"... {len(order) - limit} more distinct signal lines")
    return out


def strip_markers(line: str) -> str:
    line = COUNT_MARK.sub("", line)
    line = CLIP_MARK.sub("", line)
    line = LINE_REF.sub("", line)
    return line


def find_line(lines: Sequence[str], pattern: re.Pattern, start: int = 0) -> Optional[int]:
    for idx in range(start, len(lines)):
        if pattern.search(lines[idx]):
            return idx
    return None


def plural(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"
