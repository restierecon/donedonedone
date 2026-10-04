from __future__ import annotations

from typing import Callable, Dict, List, Optional

from ..models import Compressed
from . import build, generic, git, jsonout, listing, npm, powershell, search, stacktrace, tests

Compressor = Callable[[str, Dict], Optional[Compressed]]

COMPRESSORS: Dict[str, Compressor] = {
    "git-status": git.status,
    "git-diff": git.diff,
    "git-log": git.log,
    "search": search.compress,
    "test": tests.compress,
    "build": build.compress,
    "lint": build.compress,
    "package-manager": npm.compress,
    "stack-trace": stacktrace.compress,
    "directory-listing": listing.compress,
    "json": jsonout.compress,
    "generic-log": generic.compress,
    "generic-command": generic.compress,
}

FALLBACKS: Dict[str, List[Compressor]] = {
    "test": [stacktrace.compress, build.compress],
    "build": [stacktrace.compress],
    "lint": [stacktrace.compress],
    "generic-command": [powershell.compress, stacktrace.compress],
    "generic-log": [stacktrace.compress],
    "package-manager": [],
}

FILE_RETRIEVERS = {
    "git-diff": git.retrieve_file,
    "search": search.retrieve_file,
    "directory-listing": listing.retrieve_file,
    "build": build.retrieve_file,
    "lint": build.retrieve_file,
}


def compress(type_: str, text: str, ctx: Dict) -> Compressed:
    ctx = dict(ctx, type=type_)
    chain: List[Compressor] = []
    if type_ in ("generic-command", "generic-log"):
        chain.extend(FALLBACKS[type_])
    if type_ in COMPRESSORS:
        chain.append(COMPRESSORS[type_])
    if ctx.get("tool") == "PowerShell" and powershell.compress not in chain:
        chain.insert(0, powershell.compress)
    chain.extend(c for c in FALLBACKS.get(type_, []) if c not in chain)
    for compressor in chain:
        result = compressor(text, ctx)
        if result is not None and (result.sections or result.headline):
            return result
    fallback = generic.compress(text, dict(ctx, type="generic-command" if type_ != "generic-log" else type_)) or Compressed(type_, "none", "low")
    if type_ not in ("generic-command", "generic-log"):
        fallback.parser = f"generic (no {type_} structure recognised)"
    return fallback
