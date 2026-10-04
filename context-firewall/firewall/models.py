from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional


@dataclass
class CommandResult:
    command: str
    cwd: str
    stdout: str = ""
    stderr: str = ""
    exit_code: Optional[int] = None
    duration_ms: Optional[int] = None
    timed_out: bool = False
    interrupted: bool = False
    tool: str = "Bash"


@dataclass
class Artifact:
    id: str
    command: str
    cwd: str
    timestamp: float
    exit_code: Optional[int]
    type: str
    size_bytes: int
    stdout_sha: str
    stderr_sha: str
    stdout_bytes: int
    stderr_bytes: int
    truncated: bool = False
    timed_out: bool = False
    interrupted: bool = False
    session: str = ""
    origin: str = ""
    parent_artifact_ids: List[str] = field(default_factory=list)
    related_files: List[str] = field(default_factory=list)
    related_symbols: List[str] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_json(cls, data: Dict[str, Any]) -> "Artifact":
        known = {k: data[k] for k in cls.__dataclass_fields__ if k in data}
        return cls(**known)


@dataclass
class Section:
    name: str
    lines: List[str]
    priority: int = 50
    title: Optional[str] = None
    verbatim: bool = True
    essential: bool = False


@dataclass
class Compressed:
    type: str
    parser: str
    confidence: str
    headline: List[str] = field(default_factory=list)
    sections: List[Section] = field(default_factory=list)
    related_files: List[str] = field(default_factory=list)
    related_symbols: List[str] = field(default_factory=list)
    status: Optional[str] = None


@dataclass
class ContextItem:
    source: str
    type: str
    reason: List[str]
    confidence: str
    text: str
    artifact_id: Optional[str] = None
    score: float = 0.0
    tokens: int = 0
    key: str = ""
