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

Prior critique still goes in the brief as free text, around these headers. Start
every brief — reviewer and auditor too — with `SLICE: <ID>` on its own line: the
usage hook reads it to charge the agent run to its slice in the usage ledger.

## Builder briefs: SLICE, RISK and harden-diff
A builder brief in a project with vault/task-tree.json also starts with
`SLICE: <ID>`, the slice's id exactly as task-tree.json has it, and carries a
`RISK: <class> — <scope.change>; unchanged: <...>; rollback: <...>` line whose class
is the one `risk-gate.sh assess <ID>` printed. Before the spawn runs, guard.sh runs
`risk-gate.sh check <ID> build`: an unrecorded or changed assessment, a critical slice
without a human authorization, a RISK line naming another class, or `model: sonnet` on
an elevated-or-higher slice refuses the spawn. guard.sh also reads that
slice's `auditor_triggers`:
- `[]` — nothing more to add.
- non-empty — STANDING must name the harden-diff skill, as an order after the pasted
  standing orders: `<n>. Load the harden-diff skill: this slice crosses <triggers>.`
  (`STANDING: none` becomes `STANDING:` followed by that one order.)
- no such slice, or no `auditor_triggers` field — the spawn is refused. Copy the
  approved slice into task-tree.json, or add the field, then dispatch.

A slice whose `ui_contract` is set needs one more STANDING order, naming the skill and
the exact contract path: `<n>. Load the frontend-ui-engineering skill and build to
vault/ui/<feature-slug>/contract.md (prototype and screenshots beside it).` guard.sh
refuses the spawn when the order is missing or `ui-approval.sh check` doesn't find a
human approval of the folder as it is now — an unapproved design goes back to /grill,
not to a builder.

```
SLICE: S021
GOAL: Shopper can share a saved cart
RISK: elevated — share link opening a read-only cart; unchanged: cart ownership; rollback: revert, links stop resolving
...
STANDING:
1. <order 1 from vault/standing-orders.md, verbatim>
2. Load the harden-diff skill: this slice crosses data-access, user-input.
```
