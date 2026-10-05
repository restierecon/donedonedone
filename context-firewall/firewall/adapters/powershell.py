from __future__ import annotations

import re
from typing import Dict, List, Optional, Tuple

from ..models import Compressed, Section
from .common import clip, lines_of, normalize

AT = re.compile(r"^At (?:line:\d+ char:\d+|.+:\d+ char:\d+)$")
CATEGORY = re.compile(r"^\s*\+ (CategoryInfo|FullyQualifiedErrorId)\s*:\s*(.*)$")
SOURCE = re.compile(r"^\s*\+ ")


def has_error_records(lines: List[str]) -> bool:
    return any(CATEGORY.match(line) for line in lines)


def records(lines: List[str]) -> List[Dict[str, Tuple[int, str]]]:
    found: List[Dict[str, Tuple[int, str]]] = []
    current: Dict[str, Tuple[int, str]] = {}
    for idx, line in enumerate(lines, 1):
        text = line.strip()
        if not text:
            continue
        cat = CATEGORY.match(line)
        if cat:
            current[cat.group(1)] = (idx, text)
            if cat.group(1) == "FullyQualifiedErrorId":
                found.append(current)
                current = {}
            continue
        if AT.match(text):
            current["At"] = (idx, text)
            continue
        if SOURCE.match(line):
            continue
        if "message" in current and "At" not in current:
            current["message"] = (current["message"][0], current["message"][1] + " " + text)
        elif "message" not in current:
            current["message"] = (idx, text)
        else:
            found.append(current)
            current = {"message": (idx, text)}
    if current:
        found.append(current)
    return found


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    if not has_error_records(lines):
        return None
    max_chars = ctx["maxLineChars"]
    found = records(lines)
    groups: Dict[str, List[Dict[str, Tuple[int, str]]]] = {}
    order: List[str] = []
    for record in found:
        key = normalize(record.get("message", (0, ""))[1], numbers=True) + "|" + record.get("FullyQualifiedErrorId", (0, ""))[1]
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(record)
    body: List[str] = []
    for key in order:
        members = groups[key]
        first = members[0]
        for field in ("message", "At", "CategoryInfo", "FullyQualifiedErrorId"):
            if field in first:
                idx, value = first[field]
                body.append(f"L{idx}: {clip(value, max_chars)}")
        if len(members) > 1:
            places = [m["At"][1][3:] for m in members[1:6] if "At" in m]
            exact = all(m.get("message", (0, ""))[1] == first.get("message", (0, ""))[1] for m in members)
            body.append(f"  same error again: {', '.join(places)}{' ...' if len(members) > 6 else ''}  [x{len(members)}{'' if exact else ' similar'}]")
    out = Compressed(type="generic-command", parser="powershell:error-records", confidence="medium")
    out.headline.append(f"POWERSHELL  error records: {len(found)}  distinct: {len(order)}  (source echo and ~~~ underlines dropped)")
    out.sections.append(Section("errors", body, priority=5, title=None, essential=True, verbatim=False))
    return out
