from __future__ import annotations

import json
import re
from typing import Any, Dict, Optional

from . import config, dedup, pipeline
from .models import CommandResult
from .store import ArtifactStore, printable

SHELL_TOOLS = {"Bash", "PowerShell"}
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
DDD_CALL = re.compile(r"(^|[\s/\\'\"])ddd(\.py|\.ps1|\.cmd)?(['\"])?(\s|$)")
RAW_REQUEST = re.compile(r"(^|\s)DDD_RAW=1(\s|$)|\$env:DDD_RAW\s*=")
ALREADY_COMPACT = re.compile(r"(^|[\s/\\])gate\.sh(\s|$)")


def _exit_code(response: Dict[str, Any]) -> Optional[int]:
    for key in ("exit_code", "exitCode", "returnCode", "code"):
        value = response.get(key)
        if isinstance(value, int) and not isinstance(value, bool):
            return value
    return None


def handle(payload: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if payload.get("hook_event_name") not in (None, "PostToolUse"):
        return None
    tool = payload.get("tool_name") or ""
    cwd = payload.get("cwd") or "."
    session = str(payload.get("session_id") or "")
    tool_input = payload.get("tool_input") or {}
    store = ArtifactStore.for_cwd(cwd)
    settings = config.load(store.root)
    if not settings.enabled:
        return None
    if tool in EDIT_TOOLS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path")
        if path:
            state = dedup.load(store, session)
            dedup.touch_file(state, str(path))
            dedup.save(store, session, state)
        return None
    if tool not in SHELL_TOOLS:
        return None
    command = str(tool_input.get("command") or "")
    if not command or tool_input.get("run_in_background") or DDD_CALL.search(command) or RAW_REQUEST.search(command) or ALREADY_COMPACT.search(command):
        return None
    response = payload.get("tool_response")
    if isinstance(response, str):
        stdout, stderr, shape = response, "", "string"
        response_dict: Dict[str, Any] = {}
    elif isinstance(response, dict):
        if response.get("isImage") or response.get("backgroundTaskId"):
            return None
        stdout = response.get("stdout")
        stderr = response.get("stderr") or ""
        if not isinstance(stdout, str) or not isinstance(stderr, str):
            return None
        shape, response_dict = "dict", response
    else:
        return None
    result = CommandResult(
        command=command,
        cwd=cwd,
        stdout=stdout,
        stderr=stderr,
        exit_code=_exit_code(response_dict),
        interrupted=bool(response_dict.get("interrupted")),
        tool=tool,
    )
    outcome = pipeline.process(result, settings, store, session=session, origin="hook")
    if outcome.passthrough:
        return None
    if shape == "string":
        updated: Any = printable(outcome.text or "")
    else:
        updated = dict(response_dict)
        updated["stdout"] = printable(outcome.text or "")
        updated["stderr"] = ""
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": updated}}


def main(raw: str) -> str:
    try:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return ""
        result = handle(payload)
    except Exception as exc:
        try:
            payload_cwd = json.loads(raw).get("cwd", ".") if raw else "."
            ArtifactStore.for_cwd(payload_cwd).log_event("failure", error=f"hook: {type(exc).__name__}: {exc}")
        except Exception:
            pass
        return ""
    return json.dumps(result, ensure_ascii=True) if result else ""
