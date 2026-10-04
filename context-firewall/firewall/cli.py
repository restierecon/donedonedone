from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path
from typing import List, Optional

from . import capture, config, hook, pipeline, rank, retrieval, rewrite, stats
from .models import CommandResult
from .store import ArtifactStore, find_root, printable
from .tokens import estimate, fmt

SUBCOMMANDS = {"run", "ingest", "hook", "pre", "artifact", "show", "recent", "search", "lookup", "source", "context", "stats", "bench", "prune", "config", "test", "build", "lint", "help", "-h", "--help"}


def _out(text: str) -> None:
    sys.stdout.write(printable(text))
    if text and not text.endswith("\n"):
        sys.stdout.write("\n")
    sys.stdout.flush()


def _err(text: str) -> None:
    sys.stderr.write(printable(text) + ("\n" if not text.endswith("\n") else ""))


def _store(args: argparse.Namespace) -> ArtifactStore:
    return ArtifactStore.for_cwd(getattr(args, "cwd", None) or os.getcwd())


def _session(args: argparse.Namespace) -> str:
    return getattr(args, "session", None) or os.environ.get("DDD_SESSION") or "cli"


def _emit(result: CommandResult, args: argparse.Namespace) -> int:
    store = _store(args)
    settings = config.load(store.root, getattr(args, "mode", None))
    if not settings.enabled:
        sys.stdout.write(printable(result.stdout))
        sys.stderr.write(printable(result.stderr))
        return result.exit_code if result.exit_code is not None else 0
    outcome = pipeline.process(result, settings, store, session=_session(args), origin=getattr(args, "origin", "cli"))
    if outcome.passthrough:
        sys.stdout.write(printable(result.stdout))
        sys.stdout.flush()
        sys.stderr.write(printable(result.stderr))
        if result.timed_out:
            _err(f"[ddd] timed out after {args.timeout}s; partial output above" + (f"; stored as {outcome.artifact.id}" if outcome.artifact else ""))
    else:
        _out(outcome.text or "")
    return result.exit_code if result.exit_code is not None else 0


def cmd_run(args: argparse.Namespace) -> int:
    argv = list(args.argv)
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        _err("ddd run: nothing to run (ddd run -- <command> [args])")
        return 2
    shell = "pwsh" if args.pwsh else ("sh" if args.shell else None)
    result = capture.run(argv, cwd=os.getcwd(), timeout=args.timeout, shell=shell, display=" ".join(argv))
    return _emit(result, args)


def _project_command(step: str) -> Optional[str]:
    root = find_root(os.getcwd())
    project = root / "vault" / "project.md"
    if project.is_file():
        for line in project.read_text(encoding="utf-8", errors="replace").splitlines():
            match = re.match(rf"^[-*]\s*gate\.{step}:\s*`?(.+?)`?\s*$", line)
            if match and match.group(1).strip() != "none":
                return match.group(1).strip()
    package = root / "package.json"
    if package.is_file():
        try:
            scripts = json.loads(package.read_text(encoding="utf-8")).get("scripts", {})
        except ValueError:
            scripts = {}
        if step in scripts:
            return f"npm run {step}" if step != "test" else "npm test"
    if step == "test" and ((root / "pytest.ini").exists() or (root / "pyproject.toml").exists() or (root / "tests").is_dir()):
        return "python -m pytest -q" if shutil.which("python") or shutil.which("python3") else None
    return None


def cmd_step(args: argparse.Namespace) -> int:
    command = _project_command(args.step)
    if not command:
        _err(f"ddd {args.step}: no command found (vault/project.md gate.{args.step}, package.json scripts.{args.step}); use ddd run -- <command>")
        return 2
    extra = " ".join(args.extra)
    full = f"{command} {extra}".strip()
    result = capture.run([full], cwd=os.getcwd(), timeout=args.timeout, shell="sh", display=full)
    return _emit(result, args)


def cmd_search(args: argparse.Namespace) -> int:
    paths = args.paths or ["."]
    if shutil.which("rg"):
        argv = ["rg", "-n", "--no-heading", "--color", "never", args.query, *paths]
    elif shutil.which("git") and (find_root(os.getcwd()) / ".git").exists():
        argv = ["git", "grep", "-n", "-I", "--", args.query, *paths] if args.paths else ["git", "grep", "-n", "-I", args.query]
    else:
        argv = ["grep", "-rnI", args.query, *paths]
    result = capture.run(argv, cwd=os.getcwd(), timeout=args.timeout)
    return _emit(result, args)


def cmd_ingest(args: argparse.Namespace) -> int:
    def read(name: Optional[str]) -> str:
        if not name:
            return ""
        if name == "-":
            return sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
        return Path(name).read_bytes().decode("utf-8", "surrogateescape")

    result = CommandResult(command=args.command, cwd=os.getcwd(), stdout=read(args.stdout), stderr=read(args.stderr), exit_code=args.exit)
    args.origin = "ingest"
    store = _store(args)
    settings = config.load(store.root, args.mode)
    if args.budget:
        settings.data["budgets"]["toolOutputTokens"] = args.budget
        settings.data["limits"]["maxInlineOutputTokens"] = max(args.budget, settings.limit("maxInlineOutputTokens"))
    if args.passthrough is not None:
        settings.data["limits"]["passthroughTokens"] = args.passthrough
    if args.no_dedup:
        settings.data["dedup"]["enabled"] = False
    outcome = pipeline.process(result, settings, store, session=_session(args), origin="ingest")
    if outcome.passthrough:
        if args.quiet_passthrough:
            return 3
        sys.stdout.write(printable(result.stdout))
        sys.stderr.write(printable(result.stderr))
        return 0
    body = outcome.text or ""
    if args.body_only:
        body = "\n".join(line for line in body.split("\n") if not line.startswith("[ddd] full output:"))
    _out(body)
    return 0


def cmd_hook(args: argparse.Namespace) -> int:
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    started = time.perf_counter()
    out = hook.main(raw)
    if out:
        sys.stdout.write(out)
    if os.environ.get("DDD_HOOK_DEBUG"):
        _err(f"[ddd hook] {round((time.perf_counter() - started) * 1000, 1)} ms, replaced={bool(out)}")
    return 0


def cmd_pre(args: argparse.Namespace) -> int:
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    out = rewrite.main(raw)
    if out:
        sys.stdout.write(out)
    return 0


def _print_lines(lines: List[str], args: argparse.Namespace, settings: config.Settings, label: str) -> None:
    shown, info = retrieval.bounded(lines, settings.limit("retrievalLines"), getattr(args, "all", False))
    _out("\n".join(shown))
    if info["shown"] < info["total"]:
        _out(f"[ddd] {label}: showing {info['shown']} of {info['total']} lines; add --all for everything or narrow with --lines A-B")


def _range(spec: str) -> tuple:
    match = re.match(r"^(\d+)(?:[-:](\d*))?$", spec.strip())
    if not match:
        raise retrieval.RetrievalError(f"bad line range '{spec}' (use 130-170 or 130-)")
    start = int(match.group(1))
    end = int(match.group(2)) if match.group(2) else (None if match.group(2) == "" else start)
    return start, end


def cmd_artifact(args: argparse.Namespace) -> int:
    store = _store(args)
    settings = config.load(store.root)
    aid = args.id
    if args.meta:
        artifact = retrieval.get_artifact(store, aid)
        _out(json.dumps(artifact.to_json(), indent=2, sort_keys=True))
        return 0
    if args.raw or args.stream:
        artifact, text = retrieval.raw(store, aid, args.stream or "combined")
        sys.stdout.write(printable(text))
        return 0
    if args.sent:
        _out(retrieval.raw(store, aid, "sent")[1])
        return 0
    if args.lines:
        start, end = _range(args.lines)
        lines = retrieval.get_lines(store, aid, start, end)
        label = "lines"
    elif args.file:
        lines = retrieval.get_file(store, aid, args.file)
        label = f"file {args.file}"
    elif args.test or args.failure:
        lines = retrieval.get_test(store, aid, args.test or str(args.failure))
        label = "failure"
    elif args.error:
        lines = retrieval.get_error(store, aid, args.error, settings)
        label = "error"
    elif args.section:
        lines = retrieval.get_section(store, aid, args.section, settings)
        label = f"section {args.section}"
    else:
        artifact, text = retrieval.raw(store, aid)
        lines = [f"{n}: {line}" for n, line in enumerate(text.split("\n"), 1)]
        label = "artifact"
    _print_lines(lines, args, settings, label)
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    store = _store(args)
    artifact = retrieval.get_artifact(store, args.id)
    meta = artifact.metadata
    retrievals = [e for e in store.events() if e.get("kind") == "retrieve" and e.get("artifact") == artifact.id]
    when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(artifact.timestamp))
    rows = [
        f"ARTIFACT {artifact.id}",
        f"command      {artifact.command}",
        f"cwd          {artifact.cwd}",
        f"time         {when}  origin {artifact.origin or '?'}  session {artifact.session or '-'}",
        f"exit         {artifact.exit_code}" + ("  TIMED OUT" if artifact.timed_out else "") + ("  INTERRUPTED" if artifact.interrupted else ""),
        f"type         {artifact.type}  (classified by: {meta.get('classifiedBy', '?')}; parser {meta.get('parser', '-')}/{meta.get('confidence', '-')})",
        f"raw          {artifact.stdout_bytes} B stdout + {artifact.stderr_bytes} B stderr, ~{fmt(meta.get('rawTokens', 0))} tokens" + ("  (capped: middle omitted)" if artifact.truncated else ""),
        f"sent         ~{fmt(meta.get('sentTokens', 0))} tokens  outcome: {meta.get('outcome', '?')}  firewall {meta.get('firewallMs', '?')} ms",
        f"omitted      {', '.join(meta.get('omitted') or []) or '-'}" + (f"  partial: {', '.join(meta.get('partialSections'))}" if meta.get("partialSections") else ""),
        f"duplicate of {meta['duplicateOf']}" if meta.get("duplicateOf") else "",
        f"files        {', '.join(artifact.related_files[:10]) or '-'}",
        f"symbols      {', '.join(artifact.related_symbols[:10]) or '-'}",
        f"retrievals   {len(retrievals)}" + ("".join(f"\n  {time.strftime('%H:%M:%S', time.localtime(e['ts']))} {e.get('how')} ({e.get('lines')} lines)" for e in retrievals[-10:])),
        "--- sent to the model ---",
        store.get_blob(meta.get("sentSha", "")) if meta.get("sentSha") else "(raw output passed through unchanged)",
        f"--- raw: {config.load(store.root).command} artifact {artifact.id} --raw ---",
    ]
    _out("\n".join(r for r in rows if r != ""))
    return 0


def cmd_recent(args: argparse.Namespace) -> int:
    store = _store(args)
    for artifact in retrieval.recent(store, args.n):
        when = time.strftime("%H:%M:%S", time.localtime(artifact.timestamp))
        meta = artifact.metadata
        _out(f"{artifact.id}  {when}  {artifact.type:<17} exit {artifact.exit_code!s:<4} {fmt(meta.get('rawTokens', 0)):>6}->{fmt(meta.get('sentTokens', 0)):<6} {artifact.command[:70]}")
    return 0


def cmd_find(args: argparse.Namespace) -> int:
    for line in retrieval.search_artifacts(_store(args), args.query, args.limit):
        _out(line)
    return 0


def cmd_source(args: argparse.Namespace) -> int:
    store = _store(args)
    settings = config.load(store.root)
    cwd = os.getcwd()
    if args.symbol:
        lines = retrieval.get_source_symbol(cwd, args.file, args.symbol)
    elif args.outline:
        lines = retrieval.get_outline(cwd, args.file)
    elif args.lines:
        start, end = _range(args.lines)
        lines = retrieval.get_source_file(cwd, args.file, start, end)
    else:
        lines = retrieval.get_source_file(cwd, args.file)
    try:
        store.log_event("retrieve", artifact=f"source:{args.file}", how="symbol" if args.symbol else "source", lines=len(lines))
    except OSError:
        pass
    _print_lines(lines, args, settings, "source")
    return 0


def cmd_context(args: argparse.Namespace) -> int:
    store = _store(args)
    settings = config.load(store.root)
    chosen, left = rank.build(os.getcwd(), store, settings, task=args.task or "", wanted_symbols=args.symbol, wanted_files=args.file,
                              session=args.session or "", budget_tokens=args.budget)
    if not chosen and not left:
        _out("[ctx] nothing to rank: no recent artifacts, edited/changed files, or named symbols found")
        return 0
    _out(rank.render(chosen, left, settings.command))
    return 0


def cmd_stats(args: argparse.Namespace) -> int:
    store = _store(args)
    since = time.time() - args.hours * 3600 if args.hours else None
    data = stats.collect(store, session=args.session, since=since)
    _out(json.dumps(data, indent=2, sort_keys=True) if args.json else stats.render(data, str(store.root)))
    return 0


def cmd_bench(args: argparse.Namespace) -> int:
    folder = Path(args.dir)
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        store = ArtifactStore(Path(tmp))
        for mode in args.modes.split(","):
            settings = config.load(None, mode)
            settings.data["dedup"]["enabled"] = False
            for cmd_file in sorted(folder.glob("*.cmd")):
                name = cmd_file.stem
                out_file = folder / f"{name}.out"
                err_file = folder / f"{name}.err"
                exit_file = folder / f"{name}.exit"
                result = CommandResult(
                    command=cmd_file.read_text(encoding="utf-8").strip(),
                    cwd=tmp,
                    stdout=out_file.read_text(encoding="utf-8", errors="surrogateescape") if out_file.exists() else "",
                    stderr=err_file.read_text(encoding="utf-8", errors="surrogateescape") if err_file.exists() else "",
                    exit_code=int(exit_file.read_text().strip()) if exit_file.exists() else 0,
                )
                started = time.perf_counter()
                outcome = pipeline.process(result, settings, store, session=f"bench-{mode}-{name}")
                ms = (time.perf_counter() - started) * 1000
                raw = estimate(result.stdout) + estimate(result.stderr)
                sent = estimate(outcome.text) if outcome.text else raw
                rows.append((mode, name, outcome.artifact.type if outcome.artifact else "?", raw, sent, ms, outcome.reason))
    _out(f"{'mode':<10} {'fixture':<28} {'type':<18} {'raw':>7} {'sent':>7} {'saved':>6} {'ms':>6}  outcome")
    for mode, name, type_, raw, sent, ms, reason in rows:
        saved = (1 - sent / raw) * 100 if raw else 0
        _out(f"{mode:<10} {name:<28} {type_:<18} {raw:>7} {sent:>7} {saved:>5.0f}% {ms:>6.1f}  {reason}")
    for mode in args.modes.split(","):
        raw = sum(r[3] for r in rows if r[0] == mode)
        sent = sum(r[4] for r in rows if r[0] == mode)
        _out(f"TOTAL {mode}: raw ~{fmt(raw)} -> sent ~{fmt(sent)} tokens ({(1 - sent / raw) * 100 if raw else 0:.1f}% reduction, estimates)")
    return 0


def cmd_prune(args: argparse.Namespace) -> int:
    removed = _store(args).prune(args.days * 86400)
    _out(f"pruned {removed} artifacts older than {args.days} days")
    return 0


def cmd_config(args: argparse.Namespace) -> int:
    store = _store(args)
    settings = config.load(store.root)
    _out(json.dumps({"store": str(store.root), "mode": settings.mode, "modeSource": settings.mode_source,
                     "toolBudgetTokens": settings.tool_budget, "passthroughTokens": settings.passthrough_tokens,
                     "settings": settings.data}, indent=2, sort_keys=True))
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ddd", description="DoneDoneDone context firewall: compact tool output, full output kept as artifacts.")
    sub = p.add_subparsers(dest="cmd")

    def common(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--mode", choices=config.MODES)
        sp.add_argument("--session")
        sp.add_argument("--timeout", type=float)
        sp.add_argument("--origin", default="cli")

    sp = sub.add_parser("run", help="run a command through the firewall")
    common(sp)
    sp.add_argument("--shell", action="store_true", help="run the words as one shell command line")
    sp.add_argument("--pwsh", action="store_true", help="run the words through PowerShell")
    sp.add_argument("argv", nargs=argparse.REMAINDER)
    sp.set_defaults(fn=cmd_run)

    for step in ("test", "build", "lint"):
        sp = sub.add_parser(step, help=f"run the project's {step} command through the firewall")
        common(sp)
        sp.add_argument("extra", nargs=argparse.REMAINDER)
        sp.set_defaults(fn=cmd_step, step=step)

    sp = sub.add_parser("search", help="rg/git grep/grep through the firewall")
    common(sp)
    sp.add_argument("query")
    sp.add_argument("paths", nargs="*")
    sp.set_defaults(fn=cmd_search)

    sp = sub.add_parser("ingest", help="compress output that already exists (a log file or stdin)")
    sp.add_argument("--command", required=True)
    sp.add_argument("--stdout", default="-")
    sp.add_argument("--stderr")
    sp.add_argument("--exit", type=int)
    sp.add_argument("--mode", choices=config.MODES)
    sp.add_argument("--session")
    sp.add_argument("--budget", type=int)
    sp.add_argument("--passthrough", type=int)
    sp.add_argument("--quiet-passthrough", action="store_true", help="exit 3 and print nothing when the output is not worth compressing")
    sp.add_argument("--no-dedup", action="store_true", help="always send the full compressed view, even for a repeat")
    sp.add_argument("--body-only", action="store_true")
    sp.set_defaults(fn=cmd_ingest)

    sp = sub.add_parser("hook", help="Claude Code PostToolUse hook (reads the payload on stdin)")
    sp.set_defaults(fn=cmd_hook)

    sp = sub.add_parser("pre", help="Claude Code PreToolUse hook: wraps simple, already-allowed noisy commands in ddd run")
    sp.set_defaults(fn=cmd_pre)

    sp = sub.add_parser("artifact", help="retrieve an artifact or part of it")
    sp.add_argument("id")
    sp.add_argument("--section")
    sp.add_argument("--lines")
    sp.add_argument("--file")
    sp.add_argument("--test")
    sp.add_argument("--failure", type=int)
    sp.add_argument("--error", type=int)
    sp.add_argument("--raw", action="store_true")
    sp.add_argument("--stream", choices=("stdout", "stderr"))
    sp.add_argument("--sent", action="store_true")
    sp.add_argument("--meta", action="store_true")
    sp.add_argument("--all", action="store_true")
    sp.set_defaults(fn=cmd_artifact)

    sp = sub.add_parser("show", help="drill into one artifact: command, sizes, what was sent, what was omitted, retrievals")
    sp.add_argument("id")
    sp.set_defaults(fn=cmd_show)

    sp = sub.add_parser("recent", help="list recent artifacts")
    sp.add_argument("-n", type=int, default=15)
    sp.set_defaults(fn=cmd_recent)

    sp = sub.add_parser("lookup", help="search stored artifacts (command, related files/symbols, raw text)")
    sp.add_argument("query")
    sp.add_argument("--limit", type=int, default=40)
    sp.set_defaults(fn=cmd_find)

    sp = sub.add_parser("source", help="exact source: a file, a line range, an outline or one symbol")
    sp.add_argument("file")
    sp.add_argument("--symbol")
    sp.add_argument("--outline", action="store_true")
    sp.add_argument("--lines")
    sp.add_argument("--all", action="store_true")
    sp.set_defaults(fn=cmd_source)

    sp = sub.add_parser("context", help="rank candidate context for a task and fit it to the active-context budget")
    sp.add_argument("--task")
    sp.add_argument("--symbol", action="append", default=[])
    sp.add_argument("--file", action="append", default=[])
    sp.add_argument("--budget", type=int)
    sp.add_argument("--session")
    sp.set_defaults(fn=cmd_context)

    sp = sub.add_parser("stats", help="context economy statistics")
    sp.add_argument("--json", action="store_true")
    sp.add_argument("--session")
    sp.add_argument("--hours", type=float)
    sp.set_defaults(fn=cmd_stats)

    sp = sub.add_parser("bench", help="measure raw vs compressed size over a fixture folder (<name>.cmd/.out/.err/.exit)")
    sp.add_argument("dir")
    sp.add_argument("--modes", default="strict,balanced,aggressive")
    sp.set_defaults(fn=cmd_bench)

    sp = sub.add_parser("prune", help="delete artifacts older than N days")
    sp.add_argument("--days", type=float, default=14)
    sp.set_defaults(fn=cmd_prune)

    sp = sub.add_parser("config", help="print effective settings")
    sp.set_defaults(fn=cmd_config)
    return p


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    if argv and argv[0] not in SUBCOMMANDS and not argv[0].startswith("-"):
        argv = ["run", "--", *argv]
    args = parser().parse_args(argv)
    if not getattr(args, "fn", None):
        parser().print_help()
        return 0
    try:
        return int(args.fn(args) or 0)
    except retrieval.RetrievalError as exc:
        _err(f"ddd: {exc}")
        return 1
    except BrokenPipeError:
        return 0
