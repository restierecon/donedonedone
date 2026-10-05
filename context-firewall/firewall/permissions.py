from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

from .store import find_root

MANAGED = [
    Path("/etc/claude-code/managed-settings.json"),
    Path("/Library/Application Support/ClaudeCode/managed-settings.json"),
    Path("C:/ProgramData/ClaudeCode/managed-settings.json"),
]


def _home() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def trusted(root: Path) -> bool:
    state = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home()) / ".claude.json"
    try:
        projects = json.loads(state.read_text(encoding="utf-8")).get("projects", {})
    except (OSError, ValueError, AttributeError):
        return False
    wanted = {str(root), str(root).replace("\\", "/"), str(root.resolve())}
    return any(isinstance(v, dict) and v.get("hasTrustDialogAccepted") is True for k, v in projects.items() if k in wanted)


def settings_files(cwd: str) -> List[Tuple[Path, bool]]:
    home = _home()
    root = find_root(cwd)
    project_allow = trusted(root)
    return [
        (home / "settings.json", True),
        (home / "settings.local.json", True),
        (root / ".claude" / "settings.json", project_allow),
        (root / ".claude" / "settings.local.json", project_allow),
        *[(m, True) for m in MANAGED],
    ]


def load_rules(files: Iterable[Tuple[Path, bool]]) -> Optional[Dict[str, List[str]]]:
    rules: Dict[str, List[str]] = {"allow": [], "ask": [], "deny": []}
    for path, allow_counts in files:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        perms = data.get("permissions") if isinstance(data, dict) else None
        if not isinstance(perms, dict):
            continue
        for kind in rules:
            if kind == "allow" and not allow_counts:
                continue
            values = perms.get(kind) or []
            if not isinstance(values, list):
                return None
            rules[kind].extend(v for v in values if isinstance(v, str))
    return rules


def _pattern(rule: str) -> Optional[str]:
    rule = rule.strip()
    if rule == "Bash":
        return "*"
    match = re.match(r"^Bash\((.*)\)$", rule, re.S)
    return match.group(1) if match else None


def matches(rule: str, command: str) -> bool:
    pattern = _pattern(rule)
    if pattern is None:
        return False
    command = command.strip()
    if pattern.endswith(":*"):
        prefix = pattern[:-2]
        return command == prefix or command.startswith(prefix + " ")
    if "*" in pattern:
        regex = ".*".join(re.escape(part) for part in pattern.split("*"))
        return re.fullmatch(regex, command, re.S) is not None
    return command == pattern


def verdict(command: str, cwd: str, mode: str, files: Optional[List[Tuple[Path, bool]]] = None) -> str:
    rules = load_rules(files if files is not None else settings_files(cwd))
    if rules is None:
        return "unknown"
    if any(matches(r, command) for r in rules["deny"]):
        return "deny"
    if any(matches(r, command) for r in rules["ask"]):
        return "ask"
    if mode == "bypassPermissions":
        return "allow"
    if any(matches(r, command) for r in rules["allow"]):
        return "allow"
    return "unlisted"
