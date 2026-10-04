---
name: brief-contract
description: Required brief format for spawning builder, reviewer, or auditor agents. Use when the Director writes the prompt for one of those three agents.
---

# Brief Contract

Every builder, reviewer, or auditor spawn carries a brief with all seven headers
below. Each header begins its own line, uppercase, followed by a colon.
`scripts/guard.sh` blocks the spawn if any header is missing and names the gaps, so a
brief that skips one never runs.

| Header | Contents |
|---|---|
| GOAL | One sentence: the behavior this slice delivers (or verifies). |
| SCOPE | May write: paths/globs. May NOT write: paths/globs. Working directory, if any. |
| ACCEPTANCE | Numbered criteria, copied from task-tree.json. |
| VERIFY | How done is proven: `gate.sh`, plus SHA and gate result line for reviewer/auditor. |
| FORBIDDEN | Actions out of bounds for this slice (merging, force-push, new deps, ...). |
| REPORT | Shape and size of the reply (e.g. the manifest's output format, ≤ 20 lines). |
| STANDING | The numbered orders from `vault/standing-orders.md`, pasted verbatim. |

STANDING is copied, never summarized or paraphrased. Orders are cross-slice rules
that would otherwise exist only in the Director's head. If the file has no orders
yet, write `STANDING: none`. The header still has to be there.

## Template

```
GOAL: <Actor can ...>
SCOPE: may write <paths>; may NOT write <paths>. Work only inside <worktree>.
ACCEPTANCE:
1. <criterion>
2. <criterion>
VERIFY: ~/.claude/scripts/gate.sh at your final commit; report the SHA.
FORBIDDEN: merging, force-push, editing vault/task-tree.json, new deps without justification.
REPORT: manifest output format, ≤ 20 lines.
STANDING:
1. <order 1 from vault/standing-orders.md, verbatim>
2. <order 2, verbatim>
```

Slice ID, hot-memory path, and prior critique still go in the brief as free text,
around these headers.
