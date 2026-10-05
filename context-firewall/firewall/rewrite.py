from __future__ import annotations

import json
import os
import re
import shlex
import shutil
from typing import Any, Dict, Optional

from . import config, permissions
from .classify import classify_argv
from .hook import ALREADY_COMPACT, DDD_CALL, RAW_REQUEST
from .store import ArtifactStore

REWRITE_TYPES = {"test", "build", "lint", "git-diff", "git-log", "git-status", "search", "directory-listing"}
SHELL_SYNTAX = re.compile(r"[;&|<>`$(){}\[\]*?~!#\\\n\r]|^\s*[A-Za-z_][A-Za-z0-9_]*=")


def self_command() -> Optional[str]:
    path = os.environ.get("DDD_SELF")
    if not path:
        return None
    return shlex.quote(path.replace("\\", "/"))


def plan(payload: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if payload.get("hook_event_name") not in (None, "PreToolUse") or payload.get("tool_name") != "Bash":
        return None
    tool_input = payload.get("tool_input") or {}
    command = str(tool_input.get("command") or "").strip()
    cwd = payload.get("cwd") or "."
    if not command or tool_input.get("run_in_background") or SHELL_SYNTAX.search(command):
        return None
    if DDD_CALL.search(command) or RAW_REQUEST.search(command) or ALREADY_COMPACT.search(command):
        return None
    store = ArtifactStore.for_cwd(cwd)
    if not config.load(store.root).enabled:
        return None
    try:
        argv = shlex.split(command)
    except ValueError:
        return None
    if not argv:
        return None
    if "/" in argv[0] or "\\" in argv[0]:
        target = os.path.join(cwd, argv[0])
        resolved = target if os.path.isfile(target) and os.access(target, os.X_OK) else None
    else:
        resolved = shutil.which(argv[0])
    if not resolved:
        return None
    if os.name == "nt" and not resolved.lower().endswith((".exe", ".cmd", ".bat", ".com")):
        return None
    found = classify_argv(argv)
    if found is None or found.type not in REWRITE_TYPES:
        return None
    if permissions.verdict(command, cwd, str(payload.get("permission_mode") or "default")) != "allow":
        return None
    me = self_command()
    if me is None:
        return None
    session = re.sub(r"[^A-Za-z0-9_-]", "", str(payload.get("session_id") or ""))[:80] or "hook"
    wrapped = f"{me} run --session {session} --origin hook -- {command}"
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "context firewall: your settings already allow this command; its output is compacted, full output kept",
            "updatedInput": dict(tool_input, command=wrapped),
        }
    }


def main(raw: str) -> str:
    try:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return ""
        result = plan(payload)
    except Exception as exc:
        try:
            ArtifactStore.for_cwd(json.loads(raw).get("cwd", ".")).log_event("failure", error=f"pre: {type(exc).__name__}: {exc}")
        except Exception:
            pass
        return ""
    return json.dumps(result, ensure_ascii=True) if result else ""
