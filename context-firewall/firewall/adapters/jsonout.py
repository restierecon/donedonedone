from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

from ..models import Compressed, Section

DEPTH = {"strict": 5, "balanced": 3, "aggressive": 2}
KEYS = {"strict": 200, "balanced": 20, "aggressive": 10}


def _scalar(value: Any) -> str:
    text = json.dumps(value, ensure_ascii=False)
    return text if len(text) <= 80 else text[:77] + "...\""


def _outline(value: Any, depth: int, max_depth: int, max_keys: int, path: str, out: List[str]) -> None:
    indent = "  " * depth
    if isinstance(value, dict):
        if depth >= max_depth:
            out.append(f"{indent}{path}: {{{len(value)} keys}}")
            return
        out.append(f"{indent}{path}: {{{len(value)} keys}}" if path else f"{indent}{{{len(value)} keys}}")
        for i, (key, item) in enumerate(value.items()):
            if i >= max_keys:
                out.append(f"{indent}  ... {len(value) - max_keys} more keys (--section outline)")
                break
            _outline(item, depth + 1, max_depth, max_keys, json.dumps(key, ensure_ascii=False), out)
    elif isinstance(value, list):
        kinds = sorted({type(v).__name__ for v in value})
        label = f"[{len(value)} items: {', '.join(kinds)}]" if value else "[]"
        out.append(f"{indent}{path}: {label}" if path else f"{indent}{label}")
        if value and depth < max_depth:
            _outline(value[0], depth + 1, max_depth, max_keys, "[0]", out)
    else:
        out.append(f"{indent}{path}: {_scalar(value)}" if path else f"{indent}{_scalar(value)}")


def compress(text: str, ctx: Dict) -> Optional[Compressed]:
    try:
        data = json.loads(text)
    except ValueError:
        return None
    unbounded = ctx.get("unbounded")
    lines: List[str] = []
    _outline(data, 0, 10 ** 6 if unbounded else DEPTH[ctx["mode"]], 10 ** 9 if unbounded else KEYS[ctx["mode"]], "", lines)
    out = Compressed(type="json", parser="json-outline", confidence="high")
    out.headline.append(f"JSON  {type(data).__name__}  {len(text)} chars  (structure outline; values over 80 chars clipped)")
    out.sections.append(Section("outline", lines, priority=10, title=None, verbatim=False, essential=True))
    return out
