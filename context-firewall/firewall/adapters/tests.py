from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

from ..models import Compressed, Section
from .common import clip, group_signals, lines_of
from .stacktrace import FRAMEWORK


@dataclass
class Failure:
    name: str
    start: int
    end: int
    location: str = ""
    details: List[str] = field(default_factory=list)


@dataclass
class Report:
    framework: str
    counts: Dict[str, int] = field(default_factory=dict)
    summary: List[str] = field(default_factory=list)
    failures: List[Failure] = field(default_factory=list)
    failed: Optional[bool] = None


KEY = re.compile(r"error|exception|\b(expected|received|actual|assert\w*|mismatch|got|want|should|to equal|to be|not ok|panicked)\b|!=|==|^\s*[-+]\s?\S", re.I)
PY_LOC = re.compile(r"^(\S+\.py):(\d+):")
PY_FILE = re.compile(r'^\s*File "([^"]+)", line (\d+)')
JS_LOC = re.compile(r"\(?((?:[A-Za-z]:)?[^\s():]+\.(?:[cm]?[jt]sx?|vue|svelte)):(\d+):(\d+)\)?")
COUNT = re.compile(r"(\d+) (passed|failed|errors?|skipped|xfailed|xpassed|deselected|warnings?|rerun)")
DETAILS = {"strict": 40, "balanced": 8, "aggressive": 3}
FAILURES = {"strict": 200, "balanced": 20, "aggressive": 8}


def _library_frame(line: str) -> bool:
    if re.match(r"^\s*\d+: (core|std|alloc|__rustc|test)::|^\s*at /rustc/", line):
        return True
    return bool(re.match(r"^\s*at ", line) and FRAMEWORK.search(re.sub(r"^\s*at\s+(async\s+)?", "", line)))


def _details(lines: List[str], start: int, end: int, limit: int, prefer: Optional[re.Pattern] = None) -> List[str]:
    picked: List[str] = []
    pattern = prefer or KEY
    for line in lines[start:end]:
        if _library_frame(line):
            continue
        if line.strip() and pattern.search(line):
            picked.append(line.strip())
        if len(picked) >= limit:
            break
    if not picked:
        picked = [line.strip() for line in lines[start:end] if line.strip()][:min(limit, 4)]
    return picked


def _count_from(line: str) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for n, word in COUNT.findall(line):
        word = {"error": "errors", "warning": "warnings"}.get(word, word)
        out[word] = out.get(word, 0) + int(n)
    return out


def pytest(lines: List[str], limit: int) -> Optional[Report]:
    summary_idx = None
    for idx in range(len(lines) - 1, -1, -1):
        line = lines[idx]
        if re.match(r"^=+ .*\b(passed|failed|errors?|skipped|no tests ran|deselected|xfailed)\b.* in [\d.]+s", line):
            summary_idx = idx
            break
    if summary_idx is None:
        return None
    report = Report("pytest", counts=_count_from(lines[summary_idx]), summary=[lines[summary_idx].strip("= ").strip()])
    report.failed = bool(report.counts.get("failed") or report.counts.get("errors"))
    blocks: List[Tuple[str, int]] = []
    in_fail = False
    for idx, line in enumerate(lines[:summary_idx]):
        if re.match(r"^=+ (FAILURES|ERRORS) =+$", line):
            in_fail = True
            continue
        if re.match(r"^=+ .* =+$", line) and in_fail and not re.match(r"^=+ (FAILURES|ERRORS) =+$", line):
            in_fail = False
            blocks.append(("", idx))
            continue
        match = re.match(r"^_{3,} (.+?) _{3,}$", line)
        if in_fail and match:
            blocks.append((match.group(1), idx))
    for i, (name, start) in enumerate(blocks):
        if not name:
            continue
        end = blocks[i + 1][1] if i + 1 < len(blocks) else summary_idx
        location = ""
        for line in lines[start:end]:
            loc = PY_LOC.match(line)
            if loc:
                location = f"{loc.group(1)}:{loc.group(2)}"
        report.failures.append(Failure(name, start + 1, end, location, _details(lines, start, end, limit, re.compile(r"^E\s|^>|Error|assert", re.I))))
    if not report.failures:
        for idx, line in enumerate(lines[:summary_idx + 1]):
            match = re.match(r"^(FAILED|ERROR) (\S+)(?: - (.*))?$", line)
            if match:
                report.failures.append(Failure(match.group(2), idx + 1, idx + 1, match.group(2).split("::")[0], [line.strip()]))
    return report


def jest(lines: List[str], limit: int) -> Optional[Report]:
    tests_idx = next((i for i in range(len(lines) - 1, -1, -1) if re.match(r"^Tests:\s+", lines[i])), None)
    if tests_idx is None:
        return None
    report = Report("jest", summary=[lines[i].strip() for i in range(max(0, tests_idx - 1), min(len(lines), tests_idx + 4)) if re.match(r"^(Test Suites|Tests|Snapshots|Time):", lines[i])])
    for n, word in re.findall(r"(\d+) (failed|passed|skipped|todo|pending|total)", lines[tests_idx]):
        report.counts[word] = int(n)
    report.failed = report.counts.get("failed", 0) > 0
    starts = [(i, lines[i].strip()[2:].strip()) for i in range(tests_idx) if re.match(r"^\s*● .+", lines[i]) and "›" in lines[i] or re.match(r"^\s*● (?!Console)", lines[i])]
    for k, (idx, name) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else tests_idx
        block = lines[idx:end]
        location = ""
        for line in block:
            if "node_modules" in line:
                continue
            loc = JS_LOC.search(line)
            if loc and (".test." in loc.group(1) or ".spec." in loc.group(1) or "__tests__" in loc.group(1)):
                location = f"{loc.group(1)}:{loc.group(2)}"
                break
        report.failures.append(Failure(name, idx + 1, end, location, _details(lines, idx + 1, end, limit, re.compile(r"Expected|Received|expect\(|Error|toBe|toEqual|^\s*>\s*\d+ \|", re.I))))
    return report


def vitest(lines: List[str], limit: int) -> Optional[Report]:
    tests_idx = next((i for i in range(len(lines) - 1, -1, -1) if re.match(r"^\s*Tests\s+\d+", lines[i])), None)
    if tests_idx is None:
        return None
    report = Report("vitest", summary=[lines[i].strip() for i in range(max(0, tests_idx - 2), min(len(lines), tests_idx + 4)) if re.match(r"^\s*(Test Files|Tests|Duration|Start at)\s", lines[i])])
    for n, word in re.findall(r"(\d+) (failed|passed|skipped|todo)", lines[tests_idx]):
        report.counts[word] = int(n)
    report.failed = report.counts.get("failed", 0) > 0
    starts = [i for i in range(tests_idx) if re.match(r"^\s*FAIL\s+\S+.*>\s", lines[i])]
    for k, idx in enumerate(starts):
        end = starts[k + 1] if k + 1 < len(starts) else tests_idx
        name = re.sub(r"^\s*FAIL\s+", "", lines[idx]).strip()
        location = ""
        for line in lines[idx:end]:
            loc = re.search(r"❯\s+(\S+?):(\d+):(\d+)", line) or JS_LOC.search(line)
            if loc and "node_modules" not in line:
                location = f"{loc.group(1)}:{loc.group(2)}"
                break
        report.failures.append(Failure(name, idx + 1, end, location, _details(lines, idx + 1, end, limit, re.compile(r"Error|expected|Expected|Received|^\s*[-+] ", re.I))))
    return report


def gotest(lines: List[str], limit: int) -> Optional[Report]:
    if not any(re.match(r"^\s*--- (FAIL|PASS|SKIP): |^(ok|FAIL)\s+\S+\s+(\([\w ]+\)|[\d.]+s)|^\?\s+\S+\s+\[no test files\]|^=== RUN ", line) for line in lines):
        return None
    report = Report("go test")
    report.counts = {
        "passed": sum(1 for line in lines if re.match(r"^\s*--- PASS:", line)),
        "failed": sum(1 for line in lines if re.match(r"^\s*--- FAIL:", line)),
        "skipped": sum(1 for line in lines if re.match(r"^\s*--- SKIP:", line)),
    }
    report.summary = [line.strip() for line in lines if re.match(r"^(ok|FAIL)\s+\S+", line)][:30]
    report.failed = report.counts["failed"] > 0 or any(re.match(r"^FAIL\b", line) for line in lines)
    for idx, line in enumerate(lines):
        match = re.match(r"^(\s*)--- FAIL: (\S+)", line)
        if not match:
            continue
        indent = len(match.group(1))
        end = idx + 1
        while end < len(lines) and (lines[end].startswith(" " * (indent + 4)) or not lines[end].strip()) and not re.match(r"^\s*--- ", lines[end]):
            end += 1
        body = [b for b in lines[idx + 1:end] if b.strip()]
        before = idx - 1
        while before >= 0 and lines[before].startswith("    ") and not re.match(r"^\s*(---|===) ", lines[before]):
            before -= 1
        body = [b for b in lines[before + 1:idx] if b.strip()] + body
        loc = next((re.search(r"(\S+_test\.go):(\d+)", b) for b in body if re.search(r"\S+_test\.go:\d+", b)), None)
        report.failures.append(Failure(match.group(2), idx + 1, end, f"{loc.group(1)}:{loc.group(2)}" if loc else "", [b.strip() for b in body[:limit]]))
    return report


def unittest(lines: List[str], limit: int) -> Optional[Report]:
    ran = next((i for i in range(len(lines) - 1, -1, -1) if re.match(r"^Ran \d+ tests? in", lines[i])), None)
    if ran is None:
        return None
    total = int(re.findall(r"\d+", lines[ran])[0])
    verdict = next((lines[i] for i in range(ran + 1, min(len(lines), ran + 4)) if re.match(r"^(OK|FAILED)\b", lines[i])), "")
    counts = {k: int(v) for k, v in re.findall(r"(failures|errors|skipped|expected failures|unexpected successes)=(\d+)", verdict)}
    failed = counts.get("failures", 0) + counts.get("errors", 0)
    report = Report("unittest", counts={"total": total, "failed": counts.get("failures", 0), "errors": counts.get("errors", 0), "skipped": counts.get("skipped", 0), "passed": total - failed - counts.get("skipped", 0)}, summary=[lines[ran].strip(), verdict.strip()], failed=verdict.startswith("FAILED"))
    heads = [i for i in range(ran) if re.match(r"^(FAIL|ERROR): ", lines[i]) and i > 0 and lines[i - 1].startswith("=====")]
    for k, idx in enumerate(heads):
        end = heads[k + 1] - 1 if k + 1 < len(heads) else ran - 1
        frames = [PY_FILE.match(line) for line in lines[idx:end]]
        frames = [f for f in frames if f]
        location = f"{frames[-1].group(1)}:{frames[-1].group(2)}" if frames else ""
        body = [line.strip() for line in lines[idx + 1:end] if line.strip() and not line.startswith(("---", "==="))]
        tail = [line for line in body if not line.startswith(("File ", "Traceback"))][-limit:]
        report.failures.append(Failure(lines[idx].split(": ", 1)[1], idx + 1, end, location, tail))
    return report


def mocha(lines: List[str], limit: int) -> Optional[Report]:
    passing = next((i for i, line in enumerate(lines) if re.match(r"^\s+\d+ passing\b", line)), None)
    if passing is None:
        return None
    report = Report("mocha")
    for line in lines[passing:passing + 4]:
        match = re.match(r"^\s+(\d+) (passing|failing|pending)", line)
        if match:
            report.counts[{"passing": "passed", "failing": "failed", "pending": "skipped"}[match.group(2)]] = int(match.group(1))
            report.summary.append(line.strip())
    report.failed = report.counts.get("failed", 0) > 0
    heads = [i for i in range(passing + 1, len(lines)) if re.match(r"^\s+\d+\) ", lines[i])]
    for k, idx in enumerate(heads):
        end = heads[k + 1] if k + 1 < len(heads) else len(lines)
        name_lines = [lines[idx].strip()]
        j = idx + 1
        while j < end and lines[j].strip() and not re.search(r"Error|assert", lines[j]):
            name_lines.append(lines[j].strip())
            j += 1
        location = ""
        for line in lines[idx:end]:
            loc = JS_LOC.search(line)
            if loc and "node_modules" not in line and "node:internal" not in line:
                location = f"{loc.group(1)}:{loc.group(2)}"
                break
        name = re.sub(r"^\d+\) ", "", " ".join(name_lines)).rstrip(":")
        report.failures.append(Failure(name, idx + 1, end, location, _details(lines, j, end, limit)))
    return report


def tap(lines: List[str], limit: int) -> Optional[Report]:
    if not any(re.match(r"^# (pass|fail|tests) \d+", line) for line in lines):
        return None
    report = Report("tap")
    for line in lines:
        match = re.match(r"^# (pass|fail|skipped|skip|todo|tests|cancelled) (\d+)", line)
        if match:
            key = {"pass": "passed", "fail": "failed", "skip": "skipped", "tests": "total"}.get(match.group(1), match.group(1))
            report.counts[key] = int(match.group(2))
            if match.group(1) in ("tests", "pass", "fail"):
                report.summary.append(line)
    report.failed = report.counts.get("failed", 0) > 0
    for idx, line in enumerate(lines):
        match = re.match(r"^(\s*)not ok \d+ - (.+?)(\s+#.*)?$", line)
        if not match:
            continue
        indent = len(match.group(1))
        end = idx + 1
        while end < len(lines) and (lines[end].startswith(" " * (indent + 2)) or not lines[end].strip()) and not re.match(r"^\s*(not )?ok \d+", lines[end]):
            end += 1
        block = lines[idx + 1:end]
        if not any("error:" in b or "location:" in b for b in block) and any(re.match(r"^\s*(not )?ok \d+", b) for b in lines[idx + 1:idx + 2]):
            continue
        location = ""
        for b in block:
            loc = re.search(r"location: '?([^']+?):(\d+):\d+'?", b)
            if loc:
                location = f"{loc.group(1)}:{loc.group(2)}"
        details: List[str] = []
        skipping = False
        for b in block:
            text = b.strip()
            if re.match(r"^(stack|duration_ms|type|failureType|location|code|\.\.\.|---)\b", text) or text in ("...", "---"):
                skipping = text.startswith("stack")
                continue
            if skipping and not re.match(r"^\w+:", text):
                continue
            skipping = False
            if text:
                details.append(text)
        report.failures.append(Failure(match.group(2), idx + 1, end, location, details[:limit]))
    return report


def node_spec(lines: List[str], limit: int) -> Optional[Report]:
    marks = [i for i, line in enumerate(lines) if re.match(r"^\u2139 (tests|pass|fail|skipped|todo|cancelled|suites|duration_ms) ", line)]
    if not marks:
        return None
    report = Report("node:test spec")
    for i in marks:
        match = re.match(r"^\u2139 (\w+) ([\d.]+)", lines[i])
        if match and match.group(1) in ("tests", "pass", "fail", "skipped", "todo", "cancelled"):
            key = {"tests": "total", "pass": "passed", "fail": "failed"}.get(match.group(1), match.group(1))
            report.counts[key] = int(float(match.group(2)))
            if match.group(1) in ("tests", "pass", "fail"):
                report.summary.append(lines[i])
    report.failed = report.counts.get("failed", 0) > 0
    start = next((i for i, line in enumerate(lines) if line.startswith("\u2716 failing tests:")), None)
    if start is None:
        return report
    heads = [i for i in range(start + 1, len(lines)) if re.match(r"^test at (.+):(\d+):\d+$", lines[i])]
    for k, h in enumerate(heads):
        end = heads[k + 1] if k + 1 < len(heads) else len(lines)
        loc = re.match(r"^test at (.+):(\d+):\d+$", lines[h])
        name_line = lines[h + 1] if h + 1 < end else ""
        name = re.sub(r"^\u2716 |\s*\([\d.]+m?s\)$", "", name_line.strip())
        report.failures.append(Failure(name, h + 1, end, f"{loc.group(1)}:{loc.group(2)}", _details(lines, h + 2, end, limit)))
    return report


def dotnet(lines: List[str], limit: int) -> Optional[Report]:
    idx = next((i for i in range(len(lines) - 1, -1, -1) if re.match(r"^\s*(Passed|Failed)!\s+-", lines[i]) or re.match(r"^\s*Total tests: \d+", lines[i])), None)
    if idx is None:
        return None
    report = Report("dotnet test", summary=[lines[idx].strip()])
    for word, n in re.findall(r"(Failed|Passed|Skipped|Total):\s+(\d+)", " ".join(lines[idx:idx + 6])):
        report.counts[{"Failed": "failed", "Passed": "passed", "Skipped": "skipped", "Total": "total"}[word]] = int(n)
    report.failed = report.counts.get("failed", 0) > 0
    heads = [i for i in range(len(lines)) if re.match(r"^\s*Failed (\S+) \[", lines[i])]
    for k, h in enumerate(heads):
        end = heads[k + 1] if k + 1 < len(heads) else idx
        location = ""
        for line in lines[h:end]:
            loc = re.search(r" in (.+?):line (\d+)", line)
            if loc:
                location = f"{loc.group(1)}:{loc.group(2)}"
                break
        name = re.match(r"^\s*Failed (\S+)", lines[h]).group(1)
        msg_start = next((j for j in range(h, end) if "Error Message:" in lines[j]), h)
        report.failures.append(Failure(name, h + 1, end, location, [line.strip() for line in lines[msg_start + 1:end] if line.strip() and "Stack Trace:" not in line and not _library_frame(line)][:limit]))
    return report


def pester(lines: List[str], limit: int) -> Optional[Report]:
    idx = next((i for i in range(len(lines) - 1, -1, -1) if re.match(r"^\s*Tests Passed: \d+", lines[i])), None)
    if idx is None:
        return None
    report = Report("pester", summary=[lines[idx].strip()])
    for word, n in re.findall(r"(Passed|Failed|Skipped|NotRun|Inconclusive): (\d+)", lines[idx]):
        report.counts[{"Passed": "passed", "Failed": "failed", "Skipped": "skipped"}.get(word, word.lower())] = int(n)
    report.failed = report.counts.get("failed", 0) > 0
    heads = [i for i in range(idx) if re.match(r"^\s*\[-\] ", lines[i])]
    for k, h in enumerate(heads):
        end = heads[k + 1] if k + 1 < len(heads) else idx
        nxt = next((j for j in range(h + 1, end) if re.match(r"^\s*\[[+!?]\] |^(Describing|Context) ", lines[j])), end)
        location = ""
        for line in lines[h:nxt]:
            loc = re.search(r"at .*?, (.+?):(\d+)", line) or re.search(r"(\S+\.ps1):(\d+)", line)
            if loc:
                location = f"{loc.group(1)}:{loc.group(2)}"
                break
        report.failures.append(Failure(re.sub(r"\s+\d+(\.\d+)?m?s(\s*\(.*\))?$", "", lines[h].strip()[4:]), h + 1, nxt, location, [line.strip() for line in lines[h + 1:nxt] if line.strip()][:limit]))
    return report


def maven(lines: List[str], limit: int) -> Optional[Report]:
    totals = [i for i, line in enumerate(lines) if re.search(r"Tests run: \d+, Failures: \d+, Errors: \d+, Skipped: \d+$", line)]
    if not totals:
        return None
    idx = totals[-1]
    report = Report("maven surefire", summary=[lines[idx].strip()])
    for word, n in re.findall(r"(Tests run|Failures|Errors|Skipped): (\d+)", lines[idx]):
        report.counts[{"Tests run": "total", "Failures": "failed", "Errors": "errors", "Skipped": "skipped"}[word]] = int(n)
    report.counts["passed"] = report.counts.get("total", 0) - report.counts.get("failed", 0) - report.counts.get("errors", 0) - report.counts.get("skipped", 0)
    report.failed = report.counts.get("failed", 0) + report.counts.get("errors", 0) > 0
    for i, line in enumerate(lines):
        match = re.match(r"^\[ERROR\]\s+(\S+?)[.:#](\w+):(\d+) (.*)$", line) or re.match(r"^\[ERROR\]\s+(\S+)\.(\w+)\s+Time elapsed.*<<< (FAILURE|ERROR)!", line)
        if match and ("Tests run" not in line):
            loc = f"{match.group(1)}:{match.group(3)}" if match.lastindex and match.lastindex >= 4 else ""
            report.failures.append(Failure(f"{match.group(1)}.{match.group(2)}", i + 1, i + 1 + limit, loc, [line.strip()] + [b.strip() for b in lines[i + 1:i + limit] if b.strip() and not b.startswith("[") and not _library_frame(b)][: limit - 1]))
    seen = set()
    unique = []
    for f in report.failures:
        key = ".".join(f.name.split(".")[-2:])
        if key not in seen:
            seen.add(key)
            unique.append(f)
    report.failures = unique
    return report


def cargo(lines: List[str], limit: int) -> Optional[Report]:
    results = [i for i, line in enumerate(lines) if line.startswith("test result: ")]
    if not results:
        return None
    report = Report("cargo test", summary=[lines[i].strip() for i in results])
    for i in results:
        for n, word in re.findall(r"(\d+) (passed|failed|ignored|measured|filtered out)", lines[i]):
            key = {"ignored": "skipped"}.get(word, word)
            report.counts[key] = report.counts.get(key, 0) + int(n)
    report.failed = report.counts.get("failed", 0) > 0
    for i, line in enumerate(lines):
        match = re.match(r"^---- (\S+) stdout ----$", line)
        if not match:
            continue
        end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("---- ") or lines[j] == "failures:"), len(lines))
        loc = next((re.search(r"(\S+\.rs):(\d+):\d+", b) for b in lines[i:end] if re.search(r"\S+\.rs:\d+:\d+", b)), None)
        report.failures.append(Failure(match.group(1), i + 1, end, f"{loc.group(1)}:{loc.group(2)}" if loc else "", _details(lines, i + 1, end, limit, re.compile(r"panicked|assert|left|right|expected", re.I))))
    return report


PARSERS: List[Callable[[List[str], int], Optional[Report]]] = [pytest, vitest, jest, unittest, tap, node_spec, cargo, gotest, mocha, dotnet, pester, maven]


def parse(lines: List[str], limit: int = 8) -> Optional[Report]:
    for parser in PARSERS:
        try:
            report = parser(lines, limit)
        except (IndexError, ValueError, AttributeError):
            report = None
        if report and (any(report.counts.values()) or report.failures):
            return report
    return None


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    lines = lines_of(text)
    mode = ctx["mode"]
    report = parse(lines, DETAILS[mode])
    max_chars = ctx["maxLineChars"]
    exit_code = ctx.get("exit_code")
    if report is None:
        return None
    failed = report.failed or bool(report.failures)
    if exit_code not in (None, 0) and not failed:
        status = f"FAILED (exit {exit_code}, no failing test parsed)"
    elif exit_code == 0 and failed:
        status = "FAILED (per runner output; exit 0)"
    else:
        status = "FAILED" if failed else "PASSED"
    out = Compressed(type="test", parser=report.framework, confidence="high", status=status)
    out.headline.append("TEST RESULT")
    out.headline.append(f"Status: {status}")
    order = ["passed", "failed", "errors", "skipped", "xfailed", "xpassed", "todo", "deselected", "warnings", "total"]
    counted = [f"{k.capitalize()}: {report.counts[k]}" for k in order if k in report.counts]
    if counted:
        out.headline.append("  ".join(counted))
    out.headline.extend(clip(s, max_chars) for s in report.summary[:6])
    cap = 10 ** 9 if ctx.get("unbounded") else FAILURES[mode]
    body: List[str] = []
    for n, failure in enumerate(report.failures[:cap], 1):
        body.append(f"{n}. {clip(failure.name, max_chars)}")
        if failure.location:
            body.append(f"   {failure.location}")
        body.extend(f"   {clip(d, max_chars)}" for d in failure.details)
        body.append(f"   (raw L{failure.start}-{failure.end}; --failure {n})")
    if len(report.failures) > cap:
        body.append(f"... {len(report.failures) - cap} more failures (--section failures)")
    if body:
        out.sections.append(Section("failures", body, priority=5, title="FAILURES", verbatim=False, essential=True))
        out.related_files.extend(f.location.rsplit(":", 1)[0] for f in report.failures if f.location)
        out.related_symbols.extend(f.name for f in report.failures[:50])
    elif failed or (exit_code not in (None, 0)):
        signals = group_signals(lines, max_chars, limit=25, strong_only=True)
        tail = [f"L{i + 1}: {clip(lines[i], max_chars)}" for i in range(max(0, len(lines) - 25), len(lines)) if lines[i].strip()]
        if signals:
            out.sections.append(Section("signals", signals, priority=8, title="ERROR LINES", essential=True))
        out.sections.append(Section("tail", tail, priority=12, title="TAIL"))
    return out


def failures(text: str) -> List[Failure]:
    report = parse(lines_of(text), 10 ** 6)
    return report.failures if report else []


def retrieve_failure(text: str, selector: str) -> Optional[List[str]]:
    found = failures(text)
    if not found:
        return None
    raw = text.split("\n")
    picked: List[Failure] = []
    if selector.isdigit():
        n = int(selector)
        if 1 <= n <= len(found):
            picked = [found[n - 1]]
    else:
        low = selector.lower()
        picked = [f for f in found if low in f.name.lower()]
    if not picked:
        return None
    out: List[str] = []
    for f in picked:
        out.extend(raw[f.start - 1:max(f.end, f.start)])
    return out
