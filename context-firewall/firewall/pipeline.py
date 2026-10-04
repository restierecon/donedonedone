from __future__ import annotations

import time
import traceback
from dataclasses import dataclass, field
from typing import List, Optional

from . import adapters, assemble, dedup
from .classify import classify
from .config import Settings
from .models import Artifact, CommandResult
from .store import ArtifactStore, combined_text
from .tokens import estimate

NEVER_COMPRESS = {"source-code"}


@dataclass
class Outcome:
    text: Optional[str]
    artifact: Optional[Artifact] = None
    reason: str = ""
    omitted: List[str] = field(default_factory=list)

    @property
    def passthrough(self) -> bool:
        return self.text is None


def _event(store: ArtifactStore, kind: str, **fields) -> None:
    try:
        store.log_event(kind, **fields)
    except OSError:
        pass


def process(result: CommandResult, settings: Settings, store: ArtifactStore, session: str = "", origin: str = "cli") -> Outcome:
    started = time.perf_counter()
    artifact: Optional[Artifact] = None
    raw = combined_text(result.stdout, result.stderr)
    raw_tokens = estimate(raw)
    try:
        cls = classify(result)
        artifact = store.create(result, cls.type, settings.limit("maxRawArtifactBytes"), session=session, origin=origin,
                                metadata={"classifiedBy": cls.reason, "classConfidence": cls.confidence, "filtered": cls.filtered})
        state = dedup.load(store, session)
        reason = ""
        if cls.type in NEVER_COMPRESS:
            reason = "source code is passed through exactly"
        elif raw_tokens <= settings.passthrough_tokens:
            reason = "small output"
        elif cls.filtered and raw_tokens <= settings.tool_budget:
            reason = "already filtered by a pipe and within budget"
        exact = dedup.exact_hash(result.command, raw, result.exit_code)
        normal = dedup.normalized_hash(result.command, raw, result.exit_code)
        if reason:
            dedup.remember(state, artifact.id, exact, normal)
            dedup.save(store, session, state)
            return _finish(store, artifact, None, reason, raw_tokens, raw_tokens, started, [])
        if settings.dedup_enabled:
            hit = dedup.check(state, exact, normal, settings.dedup_window)
            if hit:
                prev_id, how, age = hit
                text = assemble.duplicate_notice(artifact, prev_id, age, how, settings.command)
                artifact.parent_artifact_ids.append(prev_id)
                artifact.metadata["duplicateOf"] = prev_id
                return _finish(store, artifact, text, "duplicate", raw_tokens, estimate(text), started, [])
        ctx = {
            "mode": settings.mode,
            "maxLineChars": settings.limit("maxLineChars"),
            "budget": settings.tool_budget,
            "exit_code": result.exit_code,
            "argv": cls.argv,
            "tool": result.tool,
            "active_files": dedup.active_files(state, result.cwd),
        }
        comp = adapters.compress(cls.type, raw, ctx)
        text, omitted, partial = assemble.render(comp, artifact, settings.mode, settings.tool_budget, raw_tokens, settings.command)
        sent_tokens = estimate(text)
        dedup.remember(state, artifact.id, exact, normal)
        dedup.save(store, session, state)
        artifact.type = comp.type
        artifact.related_files = list(dict.fromkeys(comp.related_files))[:200]
        artifact.related_symbols = list(dict.fromkeys(comp.related_symbols))[:200]
        artifact.metadata.update({"parser": comp.parser, "confidence": comp.confidence, "status": comp.status, "partialSections": partial})
        if sent_tokens >= raw_tokens:
            return _finish(store, artifact, None, "compression did not reduce size", raw_tokens, raw_tokens, started, [])
        return _finish(store, artifact, text, "compressed", raw_tokens, sent_tokens, started, omitted)
    except Exception as exc:
        _event(store, "failure", error=f"{type(exc).__name__}: {exc}", trace=traceback.format_exc()[-2000:],
               command=result.command[:300], artifact=artifact.id if artifact else None)
        return Outcome(text=None, artifact=artifact, reason=f"firewall error: {type(exc).__name__}")


def _finish(store: ArtifactStore, artifact: Artifact, text: Optional[str], reason: str, raw_tokens: int, sent_tokens: int, started: float, omitted: List[str]) -> Outcome:
    elapsed = round((time.perf_counter() - started) * 1000, 1)
    artifact.metadata.update({"outcome": reason, "rawTokens": raw_tokens, "sentTokens": sent_tokens, "omitted": omitted, "firewallMs": elapsed})
    if text is not None:
        sha, _ = store.put_blob(text)
        artifact.metadata["sentSha"] = sha
    store.save(artifact)
    _event(store, "intercept", artifact=artifact.id, type=artifact.type, outcome=reason, raw=raw_tokens, sent=sent_tokens, ms=elapsed, origin=artifact.origin, session=artifact.session)
    return Outcome(text=text, artifact=artifact, reason=reason, omitted=omitted)
