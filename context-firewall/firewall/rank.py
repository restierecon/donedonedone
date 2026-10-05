from __future__ import annotations

import re
import subprocess
import time
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

from . import budget, dedup, symbols
from .adapters import tests
from .config import Settings
from .models import ContextItem
from .store import ArtifactStore, find_root

WEIGHTS: Dict[str, int] = {
    "currently failing test": 50,
    "current error": 45,
    "explicitly requested symbol": 40,
    "explicitly requested file": 40,
    "named in the task": 35,
    "edited in this session": 30,
    "referenced by a failing test": 15,
    "dependency of a requested symbol": 20,
    "modified in the working tree": 15,
    "recent command result": 5,
    "stale (older than 30 min)": -10,
}
STALE_SECONDS = 1800
SCAN_FILES = 5000
SCAN_BYTES = 1_000_000
DECL_TEMPLATE = r"^\s*(?:export\s+)?(?:default\s+)?(?:public\s+|private\s+|protected\s+|internal\s+|static\s+|async\s+|abstract\s+)*(?:def|class|function|func|fn|interface|struct|enum|trait|type|record)\s+{name}\b|^\s*(?:export\s+)?(?:const|let|var)\s+{name}\s*="


def score(reasons: Iterable[str]) -> int:
    return sum(WEIGHTS.get(r, 0) for r in reasons)


def _item(source: str, type_: str, reasons: List[str], text: str, confidence: str = "high", artifact_id: Optional[str] = None, key: str = "") -> ContextItem:
    return ContextItem(source=source, type=type_, reason=list(dict.fromkeys(reasons)), confidence=confidence, text=text, artifact_id=artifact_id, score=score(reasons), key=key or source)


def task_symbols(task: str) -> List[str]:
    found = re.findall(r"\b([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)+|[A-Z][a-z0-9]+[A-Z]\w*|[a-z]+_[a-z_0-9]+)\s*(?:\(\))?", task or "")
    return list(dict.fromkeys(found))


def _git_files(root: Path) -> List[str]:
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            return [line for line in out.stdout.splitlines() if line][:SCAN_FILES * 4]
    except (OSError, subprocess.SubprocessError):
        pass
    return []


def _changed(root: Path) -> List[str]:
    try:
        out = subprocess.run(["git", "-C", str(root), "status", "--porcelain"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return []
    return [line[3:].split(" -> ")[-1] for line in out.stdout.splitlines() if len(line) > 3]


def find_definitions(root: Path, name: str, files: List[str]) -> List[Tuple[str, symbols.Symbol]]:
    leaf = name.split(".")[-1]
    owner = name.split(".")[0] if "." in name else ""
    decl = re.compile(DECL_TEMPLATE.replace("{name}", re.escape(owner or leaf)), re.M)
    hits: List[Tuple[str, symbols.Symbol]] = []
    scanned = 0
    for rel in files:
        ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
        if ext not in symbols.BRACE_EXT and ext not in ("py", "pyi"):
            continue
        path = root / rel
        try:
            if path.stat().st_size > SCAN_BYTES:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        scanned += 1
        if scanned > SCAN_FILES:
            break
        if not decl.search(text) and not (owner and re.search(r"\b" + re.escape(leaf) + r"\b", text) and re.search(r"\b" + re.escape(owner) + r"\b", text)):
            continue
        for sym in symbols.find(path, name):
            hits.append((rel, sym))
        if len(hits) >= 5:
            break
    return hits


def build(cwd: str, store: ArtifactStore, settings: Settings, task: str = "", wanted_symbols: Optional[List[str]] = None,
          wanted_files: Optional[List[str]] = None, session: str = "", budget_tokens: Optional[int] = None) -> Tuple[List[ContextItem], List[ContextItem]]:
    root = find_root(cwd)
    now = time.time()
    items: List[ContextItem] = []
    state = dedup.load(store, session)
    edited = set(dedup.active_files(state, str(root)))
    changed = set(_changed(root))
    task_names = task_symbols(task)
    names = list(dict.fromkeys((wanted_symbols or []) + task_names))
    failing_files: set = set()
    seen_types = set()
    for artifact in store.all()[:50]:
        age = now - artifact.timestamp
        stale = ["stale (older than 30 min)"] if age > STALE_SECONDS else []
        if artifact.type == "test" and "test" not in seen_types:
            seen_types.add("test")
            text = store.text(artifact)
            for n, failure in enumerate(tests.failures(text)[:20], 1):
                body = "\n".join([f"{failure.name}", f"  {failure.location}" if failure.location else ""] + [f"  {d}" for d in failure.details[:6]])
                if failure.location:
                    failing_files.add(failure.location.rsplit(":", 1)[0])
                reasons = ["currently failing test"] + stale
                if any(failure.location.startswith(e) or e in failure.location for e in edited if failure.location):
                    reasons.append("edited in this session")
                items.append(_item(f"{artifact.id} failure {n}", "test-failure", reasons, body.replace("\n\n", "\n"), artifact_id=artifact.id, key=f"failure:{failure.name}"))
        elif artifact.type in ("build", "lint") and artifact.type not in seen_types and artifact.exit_code not in (0, None):
            seen_types.add(artifact.type)
            sent = store.get_blob(artifact.metadata.get("sentSha", "")) or store.text(artifact)
            items.append(_item(f"{artifact.id}", artifact.type, ["current error"] + stale, "\n".join(sent.split("\n")[:40]), artifact_id=artifact.id))
        elif len([i for i in items if i.type == "recent-result"]) < 5:
            items.append(_item(artifact.id, "recent-result", ["recent command result"] + stale,
                               f"{artifact.type}: {artifact.command[:100]} (exit {artifact.exit_code}, {artifact.metadata.get('outcome', '')})",
                               confidence="medium", artifact_id=artifact.id))
    files = _git_files(root) if names else []
    for name in names:
        explicit = name in (wanted_symbols or [])
        for rel, sym in find_definitions(root, name, files):
            path = root / rel
            body = symbols.source(path, sym)
            reasons = ["explicitly requested symbol" if explicit else "named in the task"]
            if rel in edited:
                reasons.append("edited in this session")
            if rel in failing_files:
                reasons.append("referenced by a failing test")
            if rel in changed:
                reasons.append("modified in the working tree")
            text = f"{rel}:{sym.start}-{sym.end} {sym.kind} {sym.qualified}\n" + "\n".join(f"{sym.start + i}: {line}" for i, line in enumerate(body))
            items.append(_item(f"{rel}#{sym.qualified}", "source-symbol", reasons, text, key=f"sym:{rel}:{sym.qualified}"))
            for dep in symbols.identifiers(body)[:25]:
                if dep in (sym.name, sym.qualified.split(".")[0]):
                    continue
                for dep_rel, dep_sym in find_definitions(root, dep, files)[:1]:
                    signature = (root / dep_rel).read_text(encoding="utf-8", errors="replace").split("\n")[dep_sym.start - 1].strip()
                    items.append(_item(f"{dep_rel}#{dep_sym.qualified}", "dependency", ["dependency of a requested symbol"],
                                       f"{dep_rel}:{dep_sym.start}-{dep_sym.end} {dep_sym.kind} {dep_sym.qualified}: {signature[:160]}",
                                       key=f"dep:{dep_rel}:{dep_sym.qualified}"))
    for rel in wanted_files or []:
        reasons = ["explicitly requested file"] + (["edited in this session"] if rel in edited else [])
        path = symbols.resolve(root, rel)
        if path is None:
            continue
        outline = symbols.outline(path)
        text = "\n".join([rel] + [f"  {s.kind} {s.qualified} L{s.start}-{s.end}" for s in outline[:60]]) if outline else f"{rel} (no symbols recognised; read it directly)"
        items.append(_item(rel, "file-outline", reasons, text, key=f"file:{rel}"))
    for rel in sorted(edited | changed):
        if any(i.source == rel for i in items):
            continue
        reasons = (["edited in this session"] if rel in edited else []) + (["modified in the working tree"] if rel in changed else [])
        if rel in failing_files:
            reasons.append("referenced by a failing test")
        items.append(_item(rel, "changed-file", reasons, rel, confidence="high", key=f"file:{rel}"))
    limit = budget_tokens or settings.budget("activeContextTokens")
    return budget.select(items, limit)


def render(chosen: List[ContextItem], left: List[ContextItem], command: str) -> str:
    out: List[str] = []
    for n, item in enumerate(chosen, 1):
        ref = f" | {item.artifact_id}" if item.artifact_id and item.artifact_id not in item.source else ""
        out.append(f"[ctx {n}] score {item.score:g} | {item.type} | {item.source}{ref} | conf {item.confidence}")
        out.append("  because: " + "; ".join(item.reason))
        out.extend(f"  {line}" for line in item.text.split("\n"))
    if left:
        out.append(f"[ctx] not included ({len(left)}, over budget or duplicate):")
        for item in left[:20]:
            out.append(f"  - score {item.score:g} {item.type} {item.source} ({'; '.join(item.reason)})")
        out.append(f"  retrieve: {command} source <file> --symbol <name> | {command} artifact <id>")
    return "\n".join(out)
