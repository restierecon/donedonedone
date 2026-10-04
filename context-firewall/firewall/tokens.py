from __future__ import annotations

CHARS_PER_TOKEN = 4


def estimate(text: str) -> int:
    if not text:
        return 0
    return (len(text) + CHARS_PER_TOKEN - 1) // CHARS_PER_TOKEN


def fmt(tokens: int) -> str:
    if tokens >= 1_000_000:
        return f"{tokens / 1_000_000:.2f}M"
    if tokens >= 10_000:
        return f"{tokens / 1000:.0f}k"
    if tokens >= 1000:
        return f"{tokens / 1000:.1f}k"
    return str(tokens)
