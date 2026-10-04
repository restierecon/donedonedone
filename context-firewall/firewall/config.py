from __future__ import annotations

import copy
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional

MODES = ("strict", "balanced", "aggressive")

DEFAULTS: Dict[str, Any] = {
    "enabled": True,
    "mode": "balanced",
    "budgets": {
        "toolOutputTokens": 5000,
        "activeContextTokens": 12000,
        "historyTokens": 4000,
    },
    "limits": {
        "maxRawArtifactBytes": 50_000_000,
        "maxInlineOutputTokens": 5000,
        "passthroughTokens": 400,
        "maxLineChars": 300,
        "retrievalLines": 300,
    },
    "dedup": {"enabled": True, "windowSeconds": 1200},
    "command": "",
}

MODE_SCALE = {
    "strict": {"budget": 3.0, "passthrough": 3.0},
    "balanced": {"budget": 1.0, "passthrough": 1.0},
    "aggressive": {"budget": 0.4, "passthrough": 0.5},
}


@dataclass
class Settings:
    data: Dict[str, Any]
    mode: str
    mode_source: str

    @property
    def enabled(self) -> bool:
        return bool(self.data.get("enabled", True))

    def limit(self, key: str) -> int:
        return int(self.data["limits"][key])

    def budget(self, key: str) -> int:
        return int(self.data["budgets"][key])

    @property
    def tool_budget(self) -> int:
        base = min(self.budget("toolOutputTokens"), self.limit("maxInlineOutputTokens"))
        return int(base * MODE_SCALE[self.mode]["budget"])

    @property
    def passthrough_tokens(self) -> int:
        return int(self.limit("passthroughTokens") * MODE_SCALE[self.mode]["passthrough"])

    @property
    def dedup_enabled(self) -> bool:
        return bool(self.data["dedup"].get("enabled", True)) and self.mode != "strict"

    @property
    def dedup_window(self) -> int:
        return int(self.data["dedup"].get("windowSeconds", 1200))

    @property
    def command(self) -> str:
        return self.data.get("command") or default_command()


def default_command() -> str:
    return os.environ.get("DDD_COMMAND") or "~/.claude/scripts/ddd"


def _merge(base: Dict[str, Any], extra: Dict[str, Any]) -> Dict[str, Any]:
    out = copy.deepcopy(base)
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def _read(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if isinstance(data, dict) and isinstance(data.get("contextFirewall"), dict):
        return data["contextFirewall"]
    return data if isinstance(data, dict) else {}


def load(store_root: Optional[Path] = None, mode: Optional[str] = None) -> Settings:
    data = copy.deepcopy(DEFAULTS)
    candidates = [Path(__file__).resolve().parent.parent / "config.json"]
    if store_root is not None:
        candidates.append(store_root / "config.json")
    source = "default"
    for path in candidates:
        if path.is_file():
            loaded = _read(path)
            data = _merge(data, loaded)
            if "mode" in loaded:
                source = str(path)
    if os.environ.get("DDD_DISABLE") == "1":
        data["enabled"] = False
    env_mode = os.environ.get("DDD_MODE")
    if env_mode:
        data["mode"] = env_mode
        source = "DDD_MODE"
    if mode:
        data["mode"] = mode
        source = "flag"
    chosen = data.get("mode") if data.get("mode") in MODES else "balanced"
    if chosen != data.get("mode"):
        source = "default (unknown mode ignored)"
    return Settings(data=data, mode=chosen, mode_source=source)
