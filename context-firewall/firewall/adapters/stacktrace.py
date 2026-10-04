from __future__ import annotations

import re
from typing import Dict, List, Optional, Tuple

from ..models import Compressed, Section
from .common import clip, lines_of

PY_FRAME = re.compile(r'^\s*File "(?P<file>[^"]+)", line (?P<line>\d+)(?:, in (?P<fn>.+))?$')
JS_FRAME = re.compile(r"^\s+at (?:(?P<fn>.+?) \()?(?P<file>(?:[A-Za-z]:)?[^():]+|node:[^():]+|<anonymous>):(?P<line>\d+)(?::(?P<col>\d+))?\)?$")
JAVA_FRAME = re.compile(r"^\s+at (?P<fn>[\w$.<>/]+)\((?P<file>[^:)]+)(?::(?P<line>\d+))?\)$")
NET_FRAME = re.compile(r"^\s+at (?P<fn>.+?)(?: in (?P<file>.+):line (?P<line>\d+))?$")
MORE = re.compile(r"^\s+\.\.\. \d+ more$")
FRAMEWORK = re.compile(
    r"site-packages|dist-packages|[\\/]lib[\\/]python\d|<frozen |importlib|node_modules|node:internal|^internal/|"
    r"^(java|javax|jdk|sun|kotlin|scala|org\.junit|org\.springframework|org\.apache|com\.sun|org\.gradle|io\.netty|reactor\.)\.|"
    r"^(System|Microsoft|Xunit|NUnit)\.|<anonymous>"
)
HEADER = re.compile(r"^(Traceback \(most recent call last\):|Exception in thread|Caused by:|During handling of the above exception|The above exception was the direct cause|Unhandled exception|Uncaught )")
APP_CAP = {"strict": 200, "balanced": 12, "aggressive": 5}


def _frame(line: str) -> Optional[Tuple[str, str, bool]]:
    for pattern in (PY_FRAME, JAVA_FRAME, JS_FRAME, NET_FRAME):
        match = pattern.match(line)
        if match:
            target = f"{match.group('fn') or ''} {match.group('file') or ''}"
            if pattern is NET_FRAME and not match.group("file") and not line.strip().startswith("at "):
                return None
            return line, match.group("file") or "", bool(FRAMEWORK.search(match.group("file") or "") or FRAMEWORK.search(match.group("fn") or "") or FRAMEWORK.search(target.strip()))
    return None


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    max_chars = ctx["maxLineChars"]
    cap = 10 ** 9 if ctx.get("unbounded") else APP_CAP[ctx["mode"]]
    out_lines: List[str] = []
    framework_run = 0
    app_in_trace = 0
    traces = 0
    frames_total = 0
    frames_kept = 0
    exceptions: List[str] = []
    code_line: Optional[bool] = None

    def flush() -> None:
        nonlocal framework_run
        if framework_run:
            out_lines.append(f"    ... {framework_run} framework/library frames")
            framework_run = 0

    for idx, line in enumerate(lines, 1):
        if code_line is not None:
            keep, code_line = code_line, None
            if line.startswith("    ") and not _frame(line):
                if keep:
                    out_lines.append(clip(line, max_chars))
                continue
        frame = _frame(line)
        if frame:
            frames_total += 1
            framework = frame[2]
            python = bool(PY_FRAME.match(line))
            if framework:
                framework_run += 1
                code_line = False if python else None
                continue
            flush()
            app_in_trace += 1
            if app_in_trace > cap:
                if app_in_trace == cap + 1:
                    out_lines.append(f"    ... more application frames (--lines {idx}-)")
                code_line = False if python else None
                continue
            frames_kept += 1
            out_lines.append(f"L{idx}: {clip(line, max_chars)}")
            code_line = True if python else None
            continue
        flush()
        if not line.strip():
            continue
        if HEADER.match(line.strip()):
            traces += 1
            app_in_trace = 0
        elif not line.startswith((" ", "\t")) and re.match(r"^[\w$.]+(Error|Exception|Warning|Fault|Interrupt|Exit)\b", line):
            if line.strip() not in exceptions:
                exceptions.append(line.strip())
        out_lines.append(f"L{idx}: {clip(line, max_chars)}" if not MORE.match(line) else line)
    flush()
    if frames_total == 0:
        return None
    out = Compressed(type="stack-trace", parser="stack-trace", confidence="medium")
    out.headline.append(f"STACK TRACE  traces: {max(traces, 1)}  frames: {frames_total} ({frames_kept} application frames shown, library frames collapsed)")
    for e in exceptions[:5]:
        out.headline.append(f"Exception: {clip(e, max_chars)}")
    out.sections.append(Section("trace", out_lines, priority=5, title=None, essential=True))
    return out
