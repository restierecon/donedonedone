from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from ..models import Compressed, Section
from .common import clip, group_signals, lines_of, normalize

MSBUILD = re.compile(r"^\s*(?P<file>[^\s(][^(]*?)\((?P<line>\d+)(?:,(?P<col>\d+))?(?:,\d+,\d+)?\): (?P<sev>error|warning|info|message) (?P<code>[A-Za-z]+\d+)?:? ?(?P<msg>.*?)(?: \[[^\]]+\])?$")
TSC_PRETTY = re.compile(r"^(?P<file>[^\s:][^:]*?):(?P<line>\d+):(?P<col>\d+) - (?P<sev>error|warning) (?P<code>TS\d+): (?P<msg>.*)$")
GCC = re.compile(r"^(?P<file>(?:[A-Za-z]:)?[^\s:]+\.[A-Za-z0-9]+):(?P<line>\d+):(?:(?P<col>\d+):)? *(?:(?P<sev>fatal error|error|warning|note|info|style|convention|refactor)(?:\[(?P<code0>[^\]]+)\])?:)? *(?:(?P<code>[A-Z]{1,4}\d{2,5}|SC\d{4})\b(?: \[\*\])? ?)?(?P<msg>.+?)(?:\s+\[(?P<code2>[\w-]+)\])?$")
MAVEN = re.compile(r"^\[(?P<sev>ERROR|WARNING)\] (?P<file>\S+?):\[(?P<line>\d+),(?P<col>\d+)\] (?P<msg>.*)$")
HEADER_DIAG = re.compile(r"^(?P<sev>error|warning)(?:\[(?P<code>[A-Z]+\d+)\])?: (?P<msg>.+)$")
WEBPACK = re.compile(r"^(?P<sev>ERROR|WARNING) in (?P<file>\S+?)(?: (?P<line>\d+):(?P<col>\d+)(?:-\d+)?)?$")
RUFF_HEAD = re.compile(r"^(?P<code>[A-Z]{1,4}\d{2,5})(?: \[\*\])? (?P<msg>.+)$")
ARROW = re.compile(r"^\s*--> (?P<file>[^:]+):(?P<line>\d+):(?P<col>\d+)")
STYLISH_ROW = re.compile(r"^\s+(?P<line>\d+):(?P<col>\d+)\s+(?P<sev>error|warning)\s+(?P<msg>.+?)(?:\s{2,}(?P<code>[@\w/-]+))?$")
STYLISH_FILE = re.compile(r"^(?:[A-Za-z]:\\|/|\.{0,2}/)?\S+\.[A-Za-z0-9]+$")
SUCCESS = re.compile(r"(?i)\b(build succeeded|build success|compiled successfully|compiled with \d+ warning|built in|done in|finished .* in|total time|successfully (built|compiled)|webpack .*compiled|\d+ (problems?|errors?|warnings?)|found \d+ errors?|no issues found|all checks passed|0 errors?|success:|elapsed|duration)\b")
CAP = {"strict": 500, "balanced": 30, "aggressive": 12}


@dataclass
class Diag:
    sev: str
    file: str
    line: int
    col: Optional[int]
    code: str
    msg: str
    raw: int
    extra: List[str] = field(default_factory=list)

    @property
    def location(self) -> str:
        return f"{self.file}:{self.line}" + (f":{self.col}" if self.col else "")


def _sev(value: Optional[str]) -> str:
    v = (value or "").lower()
    if v in ("fatal error", "error"):
        return "error"
    if v in ("warning",):
        return "warning"
    if v in ("note", "info", "message", "style", "convention", "refactor"):
        return "note"
    return "issue"


def parse(lines: List[str]) -> List[Diag]:
    diags: List[Diag] = []
    stylish_file: Optional[str] = None
    pending: Optional[Tuple[str, str, str, int]] = None
    for idx, line in enumerate(lines, 1):
        if not line.strip():
            stylish_file = None
            continue
        arrow = ARROW.match(line)
        if arrow and pending:
            sev, code, msg, raw = pending
            diags.append(Diag(sev, arrow.group("file").strip(), int(arrow.group("line")), int(arrow.group("col")), code, msg, raw))
            pending = None
            continue
        match = TSC_PRETTY.match(line) or MSBUILD.match(line) or MAVEN.match(line)
        if match:
            d = match.groupdict()
            diags.append(Diag(_sev(d.get("sev")), d["file"].strip(), int(d["line"]), int(d["col"]) if d.get("col") else None, d.get("code") or "", d["msg"].strip(), idx))
            continue
        match = GCC.match(line)
        if match and not line.startswith(("http:", "https:")):
            d = match.groupdict()
            code = d.get("code") or d.get("code0") or d.get("code2") or ""
            diags.append(Diag(_sev(d.get("sev")), d["file"], int(d["line"]), int(d["col"]) if d.get("col") else None, code, d["msg"].strip(), idx))
            continue
        pack = WEBPACK.match(line)
        if pack:
            nxt = next((lines[j] for j in range(idx, min(idx + 3, len(lines))) if lines[j].strip()), "")
            diags.append(Diag(_sev(pack.group("sev")), pack.group("file"), int(pack.group("line") or 0), int(pack.group("col")) if pack.group("col") else None, "", nxt.strip(), idx))
            continue
        head = HEADER_DIAG.match(line)
        if head:
            pending = (_sev(head.group("sev")), head.group("code") or "", head.group("msg"), idx)
            continue
        ruff = RUFF_HEAD.match(line)
        if ruff:
            pending = ("issue", ruff.group("code"), ruff.group("msg"), idx)
            continue
        row = STYLISH_ROW.match(line)
        if row and stylish_file:
            d = row.groupdict()
            diags.append(Diag(_sev(d["sev"]), stylish_file, int(d["line"]), int(d["col"]), d.get("code") or "", d["msg"].strip(), idx))
            continue
        if STYLISH_FILE.match(line.strip()) and not line.startswith(" "):
            stylish_file = line.strip()
            continue
    return diags


def _group(diags: List[Diag]) -> List[Tuple[Diag, List[Diag]]]:
    groups: Dict[Tuple[str, str, str], List[Diag]] = {}
    order: List[Tuple[str, str, str]] = []
    for d in diags:
        key = (d.sev, d.code, normalize(d.msg, numbers=True))
        if key not in groups:
            groups[key] = []
            order.append(key)
        if all(o.location != d.location for o in groups[key]):
            groups[key].append(d)
    return [(groups[k][0], groups[k]) for k in order]


def _render(groups: List[Tuple[Diag, List[Diag]]], cap: int, max_chars: int) -> List[str]:
    out: List[str] = []
    for first, members in groups[:cap]:
        code = f" {first.code}" if first.code else ""
        out.append(clip(f"{first.location}{code} {first.msg}", max_chars))
        if len(members) > 1:
            more = ", ".join(m.location for m in members[1:6])
            extra = f", ... (+{len(members) - 6})" if len(members) > 6 else ""
            exact = all(m.msg == first.msg for m in members)
            out.append(f"  same at: {more}{extra}  [x{len(members)}{'' if exact else ' similar'}]")
    if len(groups) > cap:
        out.append(f"... {len(groups) - cap} more distinct diagnostics (--section {{name}})")
    return out


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    kind = ctx.get("type", "build")
    diags = parse(lines)
    exit_code = ctx.get("exit_code")
    max_chars = ctx["maxLineChars"]
    cap = 10 ** 9 if ctx.get("unbounded") else CAP[ctx["mode"]]
    errors = [d for d in diags if d.sev == "error"]
    warnings = [d for d in diags if d.sev == "warning"]
    issues = [d for d in diags if d.sev == "issue"]
    notes = [d for d in diags if d.sev == "note"]
    label = {"build": "BUILD", "lint": "LINT"}.get(kind, "DIAGNOSTICS")
    failed = exit_code not in (None, 0) or bool(errors)
    if not diags and exit_code in (None, 0) and not failed:
        summary = [clip(line.strip(), max_chars) for line in lines if SUCCESS.search(line)][-6:]
        out = Compressed(type=kind, parser=f"{kind}:summary", confidence="medium", status="passed")
        out.headline.append(f"{label} PASSED" + (f" (exit {exit_code})" if exit_code is not None else ""))
        out.headline.append(f"{len([x for x in lines if x.strip()])} output lines, no diagnostics parsed")
        if summary:
            out.sections.append(Section("summary", summary, priority=10, title="SUMMARY LINES"))
        signals = group_signals(lines, max_chars, limit=30)
        if signals:
            out.sections.append(Section("warnings", signals, priority=5, title="WARNING / ERROR LINES (unparsed)", essential=True))
        return out
    status = "FAILED" if failed else "PASSED"
    out = Compressed(type=kind, parser=f"{kind}:diagnostics" if diags else f"{kind}:signals", confidence="high" if diags else "low", status=status.lower())
    out.headline.append(f"{label} {status}" + (f" (exit {exit_code})" if exit_code is not None else ""))
    counts = [f"Errors: {len(errors)}", f"Warnings: {len(warnings)}"]
    if issues:
        counts.append(f"Issues: {len(issues)}")
    if notes:
        counts.append(f"Notes: {len(notes)}")
    out.headline.append("  ".join(counts) + ("  (repeats collapsed below)" if len(_group(diags)) < len(diags) else ""))
    summary = [clip(line.strip(), max_chars) for line in lines if SUCCESS.search(line)][-3:]
    out.headline.extend(summary)
    for name, title, items, prio in (("errors", "ERRORS", errors, 5), ("issues", "ISSUES", issues, 10), ("warnings", "WARNINGS", warnings, 20), ("notes", "NOTES", notes, 40)):
        if items:
            rendered = [r.replace("{name}", name) for r in _render(_group(items), cap, max_chars)]
            out.sections.append(Section(name, rendered, priority=prio, title=f"{title} ({len(items)}):", verbatim=False, essential=name == "errors"))
            out.related_files.extend(sorted({d.file for d in items})[:100])
    if not diags:
        signals = group_signals(lines, max_chars, limit=30)
        tail = [f"L{i + 1}: {clip(lines[i], max_chars)}" for i in range(max(0, len(lines) - 20), len(lines)) if lines[i].strip()]
        if signals:
            out.sections.append(Section("signals", signals, priority=5, title="ERROR / WARNING LINES", essential=True))
        out.sections.append(Section("tail", tail, priority=15, title="TAIL"))
    return out


def retrieve_file(text: str, path: str) -> Optional[List[str]]:
    raw = text.split("\n")
    hits = [d for d in parse(lines_of(text)) if d.file == path or d.file.endswith(path)]
    if not hits:
        return None
    return [raw[d.raw - 1] for d in hits]
