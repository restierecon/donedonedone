from __future__ import annotations

import os
import shutil
import subprocess
import time
from typing import List, Optional

from .models import CommandResult
from .store import from_bytes

TIMEOUT_EXIT = 124


def _resolve(argv: List[str]) -> List[str]:
    found = shutil.which(argv[0])
    return [found, *argv[1:]] if found else argv


def _shell_argv(command: str, shell: str) -> List[str]:
    if shell == "pwsh":
        exe = shutil.which("pwsh") or shutil.which("powershell") or "powershell"
        return [exe, "-NoProfile", "-NonInteractive", "-Command", command]
    if os.name == "nt":
        return [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/s", "/c", command]
    return [shutil.which("bash") or "/bin/sh", "-c", command]


def run(
    argv: List[str],
    cwd: Optional[str] = None,
    timeout: Optional[float] = None,
    shell: Optional[str] = None,
    display: Optional[str] = None,
) -> CommandResult:
    cwd = cwd or os.getcwd()
    command = display or " ".join(argv)
    target = _shell_argv(" ".join(argv), shell) if shell else _resolve(argv)
    start = time.monotonic()
    try:
        proc = subprocess.Popen(target, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
    except OSError as exc:
        return CommandResult(command=command, cwd=cwd, stderr=f"{argv[0]}: {exc.strerror or exc}\n", exit_code=127, duration_ms=0)
    timed_out = False
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        proc.kill()
        out, err = proc.communicate()
    elapsed = int((time.monotonic() - start) * 1000)
    return CommandResult(
        command=command,
        cwd=cwd,
        stdout=from_bytes(out or b""),
        stderr=from_bytes(err or b""),
        exit_code=TIMEOUT_EXIT if timed_out else proc.returncode,
        duration_ms=elapsed,
        timed_out=timed_out,
    )
