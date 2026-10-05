from __future__ import annotations

from typing import Any, Dict, List, Optional

from .store import ArtifactStore
from .tokens import fmt


def collect(store: ArtifactStore, session: Optional[str] = None, since: Optional[float] = None) -> Dict[str, Any]:
    data: Dict[str, Any] = {
        "intercepted": 0, "compressed": 0, "passthrough": 0, "duplicates": 0, "raw": 0, "sent": 0,
        "retrievals": 0, "failures": 0, "ms": [], "byType": {}, "outcomes": {},
    }
    for event in store.events():
        if since and event.get("ts", 0) < since:
            continue
        if session and event.get("session") not in (None, session) and event.get("kind") == "intercept":
            continue
        kind = event.get("kind")
        if kind == "intercept":
            data["intercepted"] += 1
            raw, sent = int(event.get("raw", 0)), int(event.get("sent", 0))
            data["raw"] += raw
            data["sent"] += sent
            data["ms"].append(float(event.get("ms", 0)))
            outcome = event.get("outcome", "")
            data["outcomes"][outcome] = data["outcomes"].get(outcome, 0) + 1
            if outcome == "duplicate":
                data["duplicates"] += 1
            elif outcome == "compressed":
                data["compressed"] += 1
            else:
                data["passthrough"] += 1
            bucket = data["byType"].setdefault(event.get("type", "?"), {"count": 0, "raw": 0, "sent": 0})
            bucket["count"] += 1
            bucket["raw"] += raw
            bucket["sent"] += sent
        elif kind == "retrieve":
            data["retrievals"] += 1
        elif kind == "failure":
            data["failures"] += 1
    ms = sorted(data.pop("ms"))
    data["firewallMsP50"] = ms[len(ms) // 2] if ms else 0
    data["firewallMsMax"] = ms[-1] if ms else 0
    data["reduction"] = (1 - data["sent"] / data["raw"]) * 100 if data["raw"] else 0.0
    data["artifacts"] = len(list((store.root / "artifacts").glob("art-*.json"))) if (store.root / "artifacts").is_dir() else 0
    return data


def render(data: Dict[str, Any], root: str) -> str:
    lines: List[str] = [
        "CONTEXT FIREWALL (token counts are estimates: chars/4)",
        f"Store                 {root}",
        f"Commands intercepted  {data['intercepted']}  (compressed {data['compressed']}, passed through {data['passthrough']}, duplicates {data['duplicates']})",
        f"Raw tool output       {fmt(data['raw'])} tokens",
        f"Model context         {fmt(data['sent'])} tokens",
        f"Estimated reduction   {data['reduction']:.1f}%",
        f"Artifacts             {data['artifacts']}",
        f"Retrieval requests    {data['retrievals']}",
        f"Duplicates removed    {data['duplicates']}",
        f"Firewall failures     {data['failures']}  (each fell back to raw output)",
        f"Firewall time         p50 {data['firewallMsP50']:.0f} ms, max {data['firewallMsMax']:.0f} ms",
    ]
    ranked = sorted(data["byType"].items(), key=lambda kv: -(kv[1]["raw"] - kv[1]["sent"]))
    if ranked:
        lines.append("Largest savings:")
        for name, b in ranked[:8]:
            saved = b["raw"] - b["sent"]
            lines.append(f"  {name:<20} {fmt(saved):>7}  ({b['count']} runs, {fmt(b['raw'])} -> {fmt(b['sent'])})")
    return "\n".join(lines)
