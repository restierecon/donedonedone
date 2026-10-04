from __future__ import annotations

from typing import List, Tuple

from .models import ContextItem
from .tokens import estimate


def select(items: List[ContextItem], budget: int) -> Tuple[List[ContextItem], List[ContextItem]]:
    seen = set()
    chosen: List[ContextItem] = []
    left: List[ContextItem] = []
    remaining = budget
    for item in sorted(items, key=lambda i: (-i.score, i.key)):
        item.tokens = item.tokens or estimate(item.text)
        if item.key and item.key in seen:
            item.reason.append("duplicate of an included item")
            left.append(item)
            continue
        if item.tokens <= remaining:
            chosen.append(item)
            remaining -= item.tokens
            if item.key:
                seen.add(item.key)
        else:
            left.append(item)
    return chosen, left
