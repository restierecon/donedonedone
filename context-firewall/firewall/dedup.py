from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from .adapters.common import ANSI, VOLATILE
from .store import ArtifactStore, _atomic_write, to_bytes

MAX_DELIVERED = 200
MAX_ACTIVE = 50


def exact_hash(command: str, text: str, exit_code: Optional[int]) -> str:
    return hashlib.sha256(to_bytes(f"{command.strip()}\x00{exit_code}\x00{text}")).hexdigest()


def normalized_hash(command: str, text: str, exit_code: Optional[int]) -> str:
    out = ANSI.sub("", text)
    for pattern, repl in VOLATILE:
        out = pattern.sub(repl, out)
    return hashlib.sha256(to_bytes(f"{command.strip()}\x00{exit_code}\x00{out}")).hexdigest()


def _path(store: ArtifactStore, session: str) -> Path:
    safe = "".join(ch for ch in (session or "default") if ch.isalnum() or ch in "-_")[:80] or "default"
    return store.root / "state" / f"{safe}.json"


def load(store: ArtifactStore, session: str) -> Dict[str, Any]:
    path = _path(store, session)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            data.setdefault("delivered", [])
            data.setdefault("active_files", {})
            return data
    except (OSError, ValueError):
        pass
    return {"delivered": [], "active_files": {}}


def save(store: ArtifactStore, session: str, state: Dict[str, Any]) -> None:
    store.ensure()
    state["delivered"] = state["delivered"][-MAX_DELIVERED:]
    active = sorted(state["active_files"].items(), key=lambda kv: kv[1])[-MAX_ACTIVE:]
    state["active_files"] = dict(active)
    _atomic_write(_path(store, session), json.dumps(state, sort_keys=True).encode())


def check(state: Dict[str, Any], exact: str, normal: str, window: int, now: Optional[float] = None) -> Optional[Tuple[str, str, float]]:
    now = now or time.time()
    for entry in reversed(state["delivered"]):
        age = now - entry["ts"]
        if age > window:
            break
        if entry["exact"] == exact:
            return entry["id"], "identical to", age
        if entry["normal"] == normal:
            return entry["id"], "same as (only timings/timestamps/ids differ)", age
    return None


def remember(state: Dict[str, Any], artifact_id: str, exact: str, normal: str, now: Optional[float] = None) -> None:
    state["delivered"].append({"id": artifact_id, "exact": exact, "normal": normal, "ts": now or time.time()})


def touch_file(state: Dict[str, Any], path: str, now: Optional[float] = None) -> None:
    state["active_files"][path] = now or time.time()


def active_files(state: Dict[str, Any], cwd: str) -> list:
    out = []
    prefix = cwd.replace("\\", "/").rstrip("/") + "/"
    for path in sorted(state["active_files"], key=lambda p: -state["active_files"][p]):
        norm = path.replace("\\", "/")
        out.append(norm[len(prefix):] if norm.startswith(prefix) else norm)
    return out
