from __future__ import annotations

import gzip
import hashlib
import json
import os
import secrets
import time
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple

from .models import Artifact, CommandResult

ENCODING = "utf-8"
ERRORS = "surrogateescape"
STDERR_MARK = "[stderr]"


def find_root(cwd: str) -> Path:
    start = Path(cwd or os.getcwd()).resolve()
    for candidate in [start, *start.parents]:
        if (candidate / ".git").exists():
            return candidate
    return start


def default_store_path(cwd: str) -> Path:
    override = os.environ.get("DDD_HOME")
    if override:
        return Path(override).expanduser()
    return find_root(cwd) / ".ddd"


def to_bytes(text: str) -> bytes:
    return text.encode(ENCODING, ERRORS)


def from_bytes(data: bytes) -> str:
    return data.decode(ENCODING, ERRORS)


def printable(text: str) -> str:
    return to_bytes(text).decode(ENCODING, "replace")


def combined_text(stdout: str, stderr: str) -> str:
    if not stderr:
        return stdout
    if not stdout:
        return stderr
    joiner = "" if stdout.endswith("\n") else "\n"
    return f"{stdout}{joiner}{STDERR_MARK}\n{stderr}"


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(3)}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def _cap(text: str, max_bytes: int) -> Tuple[str, bool]:
    data = to_bytes(text)
    if max_bytes <= 0 or len(data) <= max_bytes:
        return text, False
    half = max_bytes // 2
    omitted = len(data) - 2 * half
    marker = f"\n[ddd: {omitted} bytes omitted from the middle - over maxRawArtifactBytes]\n".encode()
    return from_bytes(data[:half] + marker + data[-half:]), True


class ArtifactStore:
    def __init__(self, root: Path):
        self.root = Path(root)

    @classmethod
    def for_cwd(cls, cwd: str) -> "ArtifactStore":
        return cls(default_store_path(cwd))

    def ensure(self) -> None:
        for sub in ("artifacts", "blobs", "state"):
            (self.root / sub).mkdir(parents=True, exist_ok=True)
        ignore = self.root / ".gitignore"
        if not ignore.exists():
            ignore.write_text("*\n", encoding="utf-8")

    def _blob_path(self, sha: str) -> Path:
        return self.root / "blobs" / sha[:2] / f"{sha[2:]}.gz"

    def put_blob(self, text: str) -> Tuple[str, int]:
        data = to_bytes(text)
        sha = hashlib.sha256(data).hexdigest()
        path = self._blob_path(sha)
        if not path.exists():
            _atomic_write(path, gzip.compress(data, compresslevel=1))
        return sha, len(data)

    def get_blob(self, sha: str) -> str:
        if not sha:
            return ""
        return from_bytes(gzip.decompress(self._blob_path(sha).read_bytes()))

    def _artifact_path(self, artifact_id: str) -> Path:
        safe = "".join(ch for ch in artifact_id if ch.isalnum() or ch == "-")
        return self.root / "artifacts" / f"{safe}.json"

    def create(
        self,
        result: CommandResult,
        type_: str,
        max_bytes: int,
        session: str = "",
        origin: str = "",
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Artifact:
        self.ensure()
        stdout, cut_out = _cap(result.stdout, max_bytes)
        stderr, cut_err = _cap(result.stderr, max_bytes)
        out_sha, out_bytes = self.put_blob(stdout)
        err_sha, err_bytes = self.put_blob(stderr) if stderr else ("", 0)
        seed = f"{time.time_ns()}:{os.getpid()}:{secrets.token_hex(8)}:{out_sha}:{err_sha}"
        artifact = Artifact(
            id="art-" + hashlib.sha256(seed.encode()).hexdigest()[:10],
            command=result.command,
            cwd=result.cwd,
            timestamp=time.time(),
            exit_code=result.exit_code,
            type=type_,
            size_bytes=len(to_bytes(result.stdout)) + len(to_bytes(result.stderr)),
            stdout_sha=out_sha,
            stderr_sha=err_sha,
            stdout_bytes=out_bytes,
            stderr_bytes=err_bytes,
            truncated=cut_out or cut_err,
            timed_out=result.timed_out,
            interrupted=result.interrupted,
            session=session,
            origin=origin,
            metadata=dict(metadata or {}),
        )
        if result.duration_ms is not None:
            artifact.metadata["durationMs"] = result.duration_ms
        self.save(artifact)
        return artifact

    def save(self, artifact: Artifact) -> None:
        payload = json.dumps(artifact.to_json(), ensure_ascii=True, sort_keys=True).encode()
        _atomic_write(self._artifact_path(artifact.id), payload)

    def get(self, artifact_id: str) -> Optional[Artifact]:
        path = self._artifact_path(artifact_id)
        if not path.is_file():
            return None
        return Artifact.from_json(json.loads(path.read_text(encoding="utf-8")))

    def stdout(self, artifact: Artifact) -> str:
        return self.get_blob(artifact.stdout_sha)

    def stderr(self, artifact: Artifact) -> str:
        return self.get_blob(artifact.stderr_sha)

    def text(self, artifact: Artifact) -> str:
        return combined_text(self.stdout(artifact), self.stderr(artifact))

    def all(self) -> List[Artifact]:
        folder = self.root / "artifacts"
        if not folder.is_dir():
            return []
        found = []
        for path in folder.glob("art-*.json"):
            try:
                found.append(Artifact.from_json(json.loads(path.read_text(encoding="utf-8"))))
            except (OSError, ValueError, TypeError):
                continue
        found.sort(key=lambda a: a.timestamp, reverse=True)
        return found

    def log_event(self, kind: str, **fields: Any) -> None:
        self.ensure()
        record = {"ts": round(time.time(), 3), "kind": kind, **fields}
        line = json.dumps(record, ensure_ascii=True, sort_keys=True) + "\n"
        with open(self.root / "events.jsonl", "a", encoding="utf-8") as handle:
            handle.write(line)

    def events(self) -> Iterator[Dict[str, Any]]:
        path = self.root / "events.jsonl"
        if not path.is_file():
            return
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue

    def prune(self, older_than_seconds: float) -> int:
        cutoff = time.time() - older_than_seconds
        keep_blobs = set()
        removed = 0
        for artifact in self.all():
            if artifact.timestamp < cutoff:
                self._artifact_path(artifact.id).unlink(missing_ok=True)
                removed += 1
            else:
                keep_blobs.update(
                    s for s in (artifact.stdout_sha, artifact.stderr_sha, artifact.metadata.get("sentSha", "")) if s
                )
        blobs = self.root / "blobs"
        if blobs.is_dir():
            for path in blobs.glob("*/*.gz"):
                if path.parent.name + path.name[:-3] not in keep_blobs:
                    path.unlink(missing_ok=True)
        return removed
