from __future__ import annotations

from typing import List, Optional, Tuple

from .models import Artifact, Compressed, Section
from .tokens import estimate, fmt

MIN_PARTIAL_TOKENS = 60


def retrieval_flag(section: Section) -> str:
    if section.name.startswith("file:"):
        return f"--file {section.name[5:]}"
    return f"--section {section.name}"


def _section_text(section: Section, lines: List[str]) -> List[str]:
    return ([section.title] if section.title else []) + lines


def _fit(section: Section, budget: int) -> Tuple[List[str], int]:
    kept: List[str] = []
    used = estimate(section.title or "")
    for line in section.lines:
        cost = estimate(line) + 1
        if used + cost > budget:
            break
        kept.append(line)
        used += cost
    return kept, len(section.lines) - len(kept)


def header(artifact: Artifact, comp: Compressed, mode: str, raw_tokens: int, out_tokens: Optional[int]) -> str:
    parts = [f"[ddd] {comp.type}", artifact.id]
    if artifact.exit_code is not None:
        parts.append(f"exit {artifact.exit_code}")
    if artifact.timed_out:
        parts.append("TIMED OUT (partial output)")
    elif artifact.interrupted:
        parts.append("INTERRUPTED (partial output)")
    if artifact.truncated:
        parts.append("raw over size cap: middle not stored")
    parts.append(f"{comp.parser}/{comp.confidence}")
    if mode != "balanced":
        parts.append(f"mode {mode}")
    if out_tokens is not None:
        parts.append(f"~{fmt(raw_tokens)}->{fmt(out_tokens)} tok est")
    return " | ".join(parts)


def render(comp: Compressed, artifact: Artifact, mode: str, budget: int, raw_tokens: int, command: str) -> Tuple[str, List[str], List[str]]:
    head_lines = list(comp.headline)
    remaining = max(budget - estimate("\n".join(head_lines)) - 60, MIN_PARTIAL_TOKENS * 2)
    plan = {}
    omitted: List[str] = []
    partial: List[str] = []
    for section in sorted(comp.sections, key=lambda s: (not s.essential, s.priority)):
        cost = estimate("\n".join(_section_text(section, section.lines))) + len(section.lines)
        if cost <= remaining:
            plan[id(section)] = section.lines
            remaining -= cost
            continue
        if remaining >= MIN_PARTIAL_TOKENS or section.essential:
            kept, dropped = _fit(section, max(remaining, MIN_PARTIAL_TOKENS))
            if kept:
                plan[id(section)] = kept + [f"... {dropped} more lines ({retrieval_flag(section)})"]
                partial.append(section.name)
                remaining -= estimate("\n".join(kept)) + len(kept)
                continue
        omitted.append(section)
    body: List[str] = []
    for section in comp.sections:
        if id(section) in plan:
            body.extend(_section_text(section, plan[id(section)]))
    names = [s.name for s in omitted]
    footer = _footer(artifact, omitted, command)
    text_core = "\n".join(head_lines + body + [footer])
    out_tokens = estimate(text_core) + 25
    top = header(artifact, comp, mode, raw_tokens, out_tokens)
    return "\n".join([top] + head_lines + body + [footer]), names, partial


def _footer(artifact: Artifact, omitted: List[Section], command: str) -> str:
    base = f"{command} artifact {artifact.id}"
    if not omitted:
        return f"[ddd] full output: {base} [--section NAME | --lines A-B | --raw]"
    flags = [retrieval_flag(s) for s in omitted[:8]]
    more = f" (+{len(omitted) - 8} more sections)" if len(omitted) > 8 else ""
    return f"[ddd] omitted for budget: {', '.join(flags)}{more} | retrieve: {base} <flag> | full: --raw"


def duplicate_notice(artifact: Artifact, previous_id: str, age_seconds: float, how: str, command: str) -> str:
    age = f"{int(age_seconds)}s" if age_seconds < 120 else f"{int(age_seconds // 60)}m"
    return (
        f"[ddd] NO NEW INFORMATION | {artifact.id} | {how} the output of {previous_id} ({age} ago)\n"
        f"[ddd] that result is above in this conversation; if it is no longer visible: {command} artifact {previous_id}"
    )
