from __future__ import annotations

import re
from typing import Dict, List, Optional

from ..models import Compressed, Section
from .common import clip, group_signals, lines_of

NOISE = [
    ("downloads", re.compile(r"^\s*(Downloading|Collecting|Using cached|Obtaining|Fetching|Resolving|Downloaded|Progress:|Unpacking|Preparing|Building wheel|Created wheel|Stored in directory|Looking in indexes)\b")),
    ("already satisfied", re.compile(r"^\s*Requirement already satisfied\b")),
    ("deprecations", re.compile(r"^(npm WARN deprecated|npm warn deprecated|warning .*: .*deprecated|WARN\s+deprecated)", re.I)),
    ("progress", re.compile(r"^[\s⠀-⣿|/\\\-]*$|^\s*\[\d+/\d+\]|^(reify|idealTree|timing|http fetch)\b|^\s*\d+%")),
]
SUMMARY = re.compile(
    r"(?i)^(added \d+|removed \d+|changed \d+|up to date|audited \d+|found \d+ vulnerabilit|\d+ (low|moderate|high|critical)|"
    r"\d+ packages? (are|is) looking for funding|Successfully installed|Successfully uninstalled|Installing collected|Done in|"
    r"Packages: |Progress: resolved .* done|Restored |All projects are up-to-date|Lockfile is up to date|Already up to date|"
    r"\+ \S+ \d|Installed \d+ packages|Resolved \d+ packages|Audited \d+ packages|Prepared \d+ packages)"
)
FAIL = re.compile(r"(?i)^(npm ERR!|npm error|ERROR:|error |ERR_PNPM|error:|E: |fatal:|Traceback)")


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    max_chars = ctx["maxLineChars"]
    exit_code = ctx.get("exit_code")
    counts: Dict[str, int] = {}
    deprecated: List[str] = []
    summary: List[str] = []
    errors: List[str] = []
    for idx, line in enumerate(lines, 1):
        if not line.strip():
            continue
        if SUMMARY.search(line.strip()):
            summary.append(f"L{idx}: {clip(line.strip(), max_chars)}")
            continue
        if FAIL.search(line.strip()):
            errors.append(f"L{idx}: {clip(line.strip(), max_chars)}")
            continue
        for name, pattern in NOISE:
            if pattern.search(line):
                counts[name] = counts.get(name, 0) + 1
                if name == "deprecations":
                    match = re.search(r"deprecated\s+(\S+)", line, re.I)
                    if match:
                        deprecated.append(match.group(1).rstrip(":"))
                break
    failed = exit_code not in (None, 0) or bool(errors)
    out = Compressed(type="package-manager", parser="package-manager", confidence="medium", status="failed" if failed else "passed")
    out.headline.append(f"PACKAGE MANAGER {'FAILED' if failed else 'OK'}" + (f" (exit {exit_code})" if exit_code is not None else ""))
    if counts:
        out.headline.append("Collapsed: " + ", ".join(f"{v} {k} lines" for k, v in counts.items()))
    if deprecated:
        shown = ", ".join(deprecated[:12]) + (f", ... (+{len(deprecated) - 12})" if len(deprecated) > 12 else "")
        out.headline.append(f"Deprecated packages ({len(deprecated)}): {shown}")
    if errors:
        out.sections.append(Section("errors", errors[:60], priority=5, title="ERRORS", essential=True))
    if summary:
        out.sections.append(Section("summary", summary[-15:], priority=10, title="SUMMARY"))
    others = group_signals(lines, max_chars, limit=20)
    others = [o for o in others if "deprecated" not in o.lower() and o not in errors]
    if others:
        out.sections.append(Section("warnings", others, priority=20, title="OTHER WARNINGS"))
    if not (errors or summary or others):
        tail = [f"L{i + 1}: {clip(lines[i], max_chars)}" for i in range(max(0, len(lines) - 15), len(lines)) if lines[i].strip()]
        out.sections.append(Section("tail", tail, priority=10, title="TAIL"))
    return out
