from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from . import adapters, symbols
from .adapters import tests
from .config import Settings
from .models import Artifact
from .store import ArtifactStore, find_root


class RetrievalError(Exception):
    pass


def _log(store: ArtifactStore, artifact_id: str, how: str, lines: int) -> None:
    try:
        store.log_event("retrieve", artifact=artifact_id, how=how, lines=lines)
    except OSError:
        pass


def get_artifact(store: ArtifactStore, artifact_id: str) -> Artifact:
    artifact = store.get(artifact_id)
    if artifact is None:
        matches = [a for a in store.all() if a.id.startswith(artifact_id)]
        if len(matches) == 1:
            return matches[0]
        raise RetrievalError(f"no artifact {artifact_id} in {store.root}")
    return artifact


def raw(store: ArtifactStore, artifact_id: str, stream: str = "combined") -> Tuple[Artifact, str]:
    artifact = get_artifact(store, artifact_id)
    if stream == "stdout":
        text = store.stdout(artifact)
    elif stream == "stderr":
        text = store.stderr(artifact)
    elif stream == "sent":
        text = store.get_blob(artifact.metadata.get("sentSha", "")) or "(nothing was substituted: the model saw the raw output)"
    else:
        text = store.text(artifact)
    _log(store, artifact.id, f"raw:{stream}", text.count("\n") + 1)
    return artifact, text


def get_lines(store: ArtifactStore, artifact_id: str, start: int, end: Optional[int]) -> List[str]:
    artifact, text = raw(store, artifact_id)
    lines = text.split("\n")
    end = len(lines) if end is None else min(end, len(lines))
    if start < 1 or start > len(lines):
        raise RetrievalError(f"{artifact.id} has {len(lines)} lines; asked for {start}-{end}")
    return [f"{n}: {lines[n - 1]}" for n in range(start, end + 1)]


def get_section(store: ArtifactStore, artifact_id: str, section: str, settings: Settings) -> List[str]:
    artifact, text = raw(store, artifact_id)
    if section in ("stdout", "stderr"):
        return store.stdout(artifact).split("\n") if section == "stdout" else store.stderr(artifact).split("\n")
    if section == "sent":
        return raw(store, artifact_id, "sent")[1].split("\n")
    lines = text.split("\n")
    if section == "head":
        return lines[:100]
    if section == "tail":
        return lines[-100:]
    ctx = {"mode": settings.mode, "maxLineChars": 100000, "budget": 10 ** 9, "exit_code": artifact.exit_code, "unbounded": True, "argv": [], "tool": "Bash"}
    comp = adapters.compress(artifact.type, text, ctx)
    names = [s.name for s in comp.sections]
    for candidate in comp.sections:
        if candidate.name == section or candidate.name == f"file:{section}":
            return ([candidate.title] if candidate.title else []) + candidate.lines
    if section == "summary":
        return comp.headline
    raise RetrievalError(f"{artifact.id} has no section '{section}'. Sections: {', '.join(names + ['summary', 'stdout', 'stderr', 'head', 'tail', 'sent'])}")


def get_file(store: ArtifactStore, artifact_id: str, path: str) -> List[str]:
    artifact, text = raw(store, artifact_id)
    retriever = adapters.FILE_RETRIEVERS.get(artifact.type)
    found = retriever(text, path) if retriever else None
    if found is None:
        needle = path.replace("\\", "/")
        found = [line for line in text.split("\n") if needle in line.replace("\\", "/")]
    if not found:
        raise RetrievalError(f"{artifact.id} ({artifact.type}) mentions no '{path}'")
    return found


def get_test(store: ArtifactStore, artifact_id: str, selector: str) -> List[str]:
    artifact, text = raw(store, artifact_id)
    found = tests.retrieve_failure(text, selector)
    if found is None:
        names = [f"{i}. {f.name}" for i, f in enumerate(tests.failures(text), 1)]
        raise RetrievalError(f"{artifact.id}: no failure matching '{selector}'" + (". Failures: " + "; ".join(names[:20]) if names else " (no failures parsed)"))
    return found


def get_error(store: ArtifactStore, artifact_id: str, n: int, settings: Settings) -> List[str]:
    artifact, text = raw(store, artifact_id)
    for name in ("errors", "failures", "signals", "issues"):
        try:
            lines = get_section(store, artifact.id, name, settings)
        except RetrievalError:
            continue
        items: List[List[str]] = []
        for line in lines[1:] if lines and lines[0].isupper() else lines:
            if line.startswith((" ", "\t")) and items:
                items[-1].append(line)
            else:
                items.append([line])
        if 1 <= n <= len(items):
            return items[n - 1]
        raise RetrievalError(f"{artifact.id}: {len(items)} {name}; asked for #{n}")
    raise RetrievalError(f"{artifact.id} has no parsed errors")


def recent(store: ArtifactStore, limit: int = 10) -> List[Artifact]:
    return store.all()[:limit]


def search_artifacts(store: ArtifactStore, query: str, limit: int = 40) -> List[str]:
    pattern = re.compile(re.escape(query), re.I)
    out: List[str] = []
    for artifact in store.all():
        if pattern.search(artifact.command) or any(pattern.search(f) for f in artifact.related_files + artifact.related_symbols):
            out.append(f"{artifact.id}  {artifact.type}  {artifact.command[:80]}  (command/related)")
        text = store.text(artifact)
        for n, line in enumerate(text.split("\n"), 1):
            if pattern.search(line):
                out.append(f"{artifact.id}:L{n}: {line.strip()[:160]}")
                if len(out) >= limit:
                    return out
    return out


def source_root(cwd: str) -> Path:
    return find_root(cwd)


def get_source_file(cwd: str, rel: str, start: Optional[int] = None, end: Optional[int] = None) -> List[str]:
    root = source_root(cwd)
    path = symbols.resolve(root, rel) or symbols.resolve(Path(cwd), rel)
    if path is None:
        raise RetrievalError(f"no file {rel} inside {root}")
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    start = start or 1
    end = min(end or len(lines), len(lines))
    return [f"{n}: {lines[n - 1]}" for n in range(start, end + 1)]


def get_outline(cwd: str, rel: str) -> List[str]:
    root = source_root(cwd)
    path = symbols.resolve(root, rel) or symbols.resolve(Path(cwd), rel)
    if path is None:
        raise RetrievalError(f"no file {rel} inside {root}")
    found = symbols.outline(path)
    if not found:
        raise RetrievalError(f"no symbols recognised in {rel} (supported: Python, JS/TS, Java, C#, Go, Rust, C/C++, Kotlin, Swift, PHP, PowerShell)")
    out = [rel]
    for sym in found:
        depth = sym.qualified.count(".")
        out.append(f"{'  ' * (depth + 1)}{sym.kind} {sym.name}  L{sym.start}-{sym.end}")
    return out


def get_source_symbol(cwd: str, rel: str, name: str) -> List[str]:
    root = source_root(cwd)
    path = symbols.resolve(root, rel) or symbols.resolve(Path(cwd), rel)
    if path is None:
        raise RetrievalError(f"no file {rel} inside {root}")
    found = symbols.find(path, name)
    if not found:
        names = ", ".join(s.qualified for s in symbols.outline(path)[:40])
        raise RetrievalError(f"no symbol {name} in {rel}. Symbols: {names}")
    out: List[str] = []
    for sym in found:
        out.append(f"{rel}:{sym.start}-{sym.end} {sym.kind} {sym.qualified}")
        body = symbols.source(path, sym)
        out.extend(f"{sym.start + i}: {line}" for i, line in enumerate(body))
    return out


def bounded(lines: List[str], limit: int, everything: bool) -> Tuple[List[str], Dict[str, int]]:
    if everything or len(lines) <= limit:
        return lines, {"shown": len(lines), "total": len(lines)}
    return lines[:limit], {"shown": limit, "total": len(lines)}
