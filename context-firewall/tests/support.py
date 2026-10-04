from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from firewall import config, pipeline
from firewall.models import CommandResult
from firewall.store import ArtifactStore

FIXTURES = HERE / "fixtures"
GOLDEN = HERE / "golden"
ID = re.compile(r"art-[0-9a-f]{10}")

os.environ["DDD_COMMAND"] = "ddd"
os.environ.pop("DDD_MODE", None)
os.environ.pop("DDD_HOME", None)
os.environ.pop("DDD_DISABLE", None)


def names():
    return sorted(p.stem for p in FIXTURES.glob("*.cmd"))


def fixture(name: str) -> CommandResult:
    def read(ext: str) -> str:
        path = FIXTURES / f"{name}.{ext}"
        return path.read_bytes().decode("utf-8", "surrogateescape") if path.exists() else ""

    exit_text = read("exit").strip()
    return CommandResult(
        command=read("cmd").strip(),
        cwd="/work",
        stdout=read("out"),
        stderr=read("err"),
        exit_code=int(exit_text) if exit_text else 0,
    )


def settings(mode: str = "balanced", passthrough: Optional[int] = 0, dedup: bool = False) -> config.Settings:
    s = config.load(None, mode)
    if passthrough is not None:
        s.data["limits"]["passthroughTokens"] = passthrough
    s.data["dedup"]["enabled"] = dedup
    return s


class TempStore:
    def __enter__(self) -> ArtifactStore:
        self.tmp = tempfile.TemporaryDirectory()
        return ArtifactStore(Path(self.tmp.name))

    def __exit__(self, *exc) -> None:
        self.tmp.cleanup()


def run(result: CommandResult, store: ArtifactStore, mode: str = "balanced", passthrough: Optional[int] = 0, dedup: bool = False, session: str = "t") -> pipeline.Outcome:
    return pipeline.process(result, settings(mode, passthrough, dedup), store, session=session)


def render(name: str, mode: str = "balanced") -> Tuple[str, pipeline.Outcome]:
    with TempStore() as store:
        outcome = run(fixture(name), store, mode)
        text = outcome.text if outcome.text is not None else "(passthrough: " + outcome.reason + ")"
        return ID.sub("art-ID", text), outcome
