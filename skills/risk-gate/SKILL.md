---
name: risk-gate
description: Scores every slice's change risk 0-100 before any builder starts, maps the class (low/moderate/elevated/high/critical) to the controls and autonomy it gets, and holds the slice at spawn and at merge until those controls are done. Use when drafting a slice's risk assessment (planner), recording or reassessing one (Director), acting on a SCOPE-EXPANSION, a `scope` gate FAIL or a risk-gate BLOCK, or asking a human for an approval.
---

# Risk Gate

Risk decides autonomy. Every slice carries a `risk` assessment from the plan onward;
`~/.claude/scripts/risk-gate.sh` turns it into a score, a class and the controls that
class requires, the same way every time. Hooks enforce the result: guard.sh refuses a
builder spawn and any git command that would land `slice/<ID>` on main until
`risk-gate.sh check` passes; gate.sh's `scope` step fails a diff that leaves the
approved scope. The autonomy dial can add oversight, never remove it.

Where it sits: grill → planner (drafts `risk`) → check-plan.sh (validates it, prints
the risk table) → Director copies the slice and runs `risk-gate.sh assess <ID>` →
builder (spawn checked) → gate.sh (`scope` step) → reviewer → auditor → merge (checked).

## The assessment (`risk` on each slice)
```json
"risk": {
  "dimensions": {"blast_radius": 1, "reversibility": 1, "security": 2, "complexity": 1, "uncertainty": 1},
  "rationale": "one module; follows the cart's existing storage pattern",
  "hazards": [],
  "ruled_out": {"data-loss": "removing a line from the cart is undoable in the UI"},
  "scope": {
    "change": "the smallest change that solves the task, one line",
    "files": ["src/cart/*", "tests/cart/*"],
    "unchanged": ["checkout totals", "guest carts"],
    "regressions": ["cart badge count"]
  },
  "rollback": "revert the squash commit; nothing persisted server-side",
  "safeguards": []
}
```
Never write `score` or `class`: they are computed, and check-plan.sh rejects a
hand-set value that disagrees. `scope.files` are shell patterns (`*` crosses `/`);
list the tests the slice adds too. `vault/` never counts toward scope.

## Rating the five dimensions (0-4 each)
| Dimension | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| blast_radius | one private function | one module | several modules of one component | a shared contract, many users | system-wide, every user, shared infra |
| reversibility | revert the commit | revert + redeploy | revert + config or data cleanup | data migration with a tested down | cannot be undone (data gone, message sent) |
| security | no trust boundary | reads non-sensitive input | user input, an outbound call | data access, sessions, files, deps | auth, authz, secrets, sensitive data |
| complexity | trivial | one path | several paths or states | concurrency, state machines | distributed, novel algorithm |
| uncertainty | the codebase already does this | minor unknowns | a pattern new to the codebase | unfamiliar tech, unclear root cause | speculative |

Score = round((25·blast + 25·reversibility + 25·security + 10·complexity + 15·uncertainty) / 4),
0-100. Weights and thresholds live in `vault/risk-policy.json` when a human sets them.

## Classes and what each one requires
| Score | Class | Controls (cumulative) | Autonomy |
|---|---|---|---|
| 0-20 | low | gate PASS, reviewer APPROVED | autonomous |
| 21-40 | moderate | + reviewer evidence `unit-test-verified` or `live-verified` | autonomous with verification |
| 41-60 | elevated | + deep tests (`gate.mutation` in the full gate, or `live-verified`, else a human merge approval); builder on the session model | reviewer-gated |
| 61-80 | high | + auditor CLEARED, + human merge approval bound to the patch-id | human approves the merge |
| 81-100 | critical | + human authorization before any build, bound to the assessment and its safeguards | stopped until authorized |
Any non-empty `auditor_triggers` adds the auditor at every class, as before. The
reviewer gate is never dropped: low keeps it.

## Policy (`vault/risk-policy.json`, human-only, optional)
```json
{"thresholds": {"moderate": 21, "elevated": 41, "high": 61, "critical": 81},
 "weights": {"blast_radius": 25, "reversibility": 25, "security": 25, "complexity": 10, "uncertainty": 15}}
```
Each value is the lowest score of its class. Omitted keys keep the defaults above.
Thresholds must rise (1 ≤ moderate < elevated < high < critical ≤ 100) and weights must
be whole numbers summing to 100, or every risk-gate.sh call fails closed. The floors
below aren't configurable. A human edits this file between tool calls and commits it.
guard.sh and vault-guard.sh keep agents out, and gate.sh fails a slice branch that
changes it.

## Floors — a low score never hides these
- Hazard `data-loss` or `destructive-op` → critical.
- Hazard `auth`, `secrets`, `sensitive-data`, `money` or `irreversible` → high.
- Hazard `schema-migration`, `external-side-effect` or `new-dependency` → elevated.
- security 4 or reversibility 4 → high.
- `auditor_triggers` raise security: auth, secrets → 4; sessions, data-access,
  file-uploads, llm-tools → 3; user-input, external-calls, dependencies → 2.
- Words in the title, `so_that` or criteria that suggest a hazard (delete, drop,
  migrate, password, token, payment, webhook, …) must appear in `hazards` or in
  `ruled_out` with a reason. check-plan.sh fails the plan otherwise. The keywords force a
  decision; they don't make it.

## Director steps
1. After check-plan.sh passes and the human approves the table, copy the slices into
   task-tree.json and run `risk-gate.sh assess <ID>` for each. It records `risk` in
   log.jsonl (score, class, hash) and prints the assessment (≤ 20 lines).
2. Builder brief: a `RISK: <class> — <scope.change>; unchanged: …; rollback: …` line.
   guard.sh checks the class word against the computed one. Elevated and above: no
   `model: sonnet`.
3. Critical: stop that slice. Add a pending-review.md entry (3-line summary: what,
   the safeguards, cost to reverse) asking the human to run
   `~/.claude/scripts/approve-risk.sh authorize <ID>` in their own terminal. Continue
   with other slices. `risk-gate.sh pending` and the SessionStart hook list held slices.
4. Before merging, run `risk-gate.sh check <ID> merge` yourself. guard.sh runs it again on the
   merge command. High and critical need `approve-risk.sh merge <ID>` from the human after
   the reviewer and auditor pass. Ask once, in pending-review.md, and move on.
5. Log the merge with the check's CONTROLS line as a signal:
   `log-event.sh <ID> merge done --signal "<CONTROLS line>"`.

## Scope expansion → reassessment
A `scope` FAIL in gate.sh, a builder STATUS: SCOPE-EXPANSION, or a reviewer's
"files outside scope" means the approved assessment no longer describes the work.
1. `log-event.sh <ID> scope EXPANDED --category scope-expansion --signal "<files>"`.
2. Re-rate the slice in task-tree.json: widen `scope.files`, raise the dimensions and
   hazards the new files justify, then run `risk-gate.sh assess <ID>`. A class that went up is
   logged as `risk-underestimate` and the learning loop counts it.
3. Every check fails until the new assessment is recorded. A higher class brings its
   controls with it (approvals are tied to the assessment hash, so a critical slice
   needs a new authorization).
4. Lowering a class needs a human: `approve-risk.sh downgrade <ID>`. Until then the
   highest class ever recorded for the slice sets its controls.
Scope that grows past the slice's purpose goes back to /grill, not into a reassessment.

## Human approvals
`approve-risk.sh <authorize|merge|downgrade> <ID>` runs only in an interactive
terminal outside any agent (it refuses when CLAUDECODE is set or stdin isn't a TTY),
shows the assessment (for merge: the diffstat and controls), and records the typed
decision in `.git/donedonedone/approvals.jsonl` with the approver's git email, the
assessment hash and, for merge, the patch-id. A later decision supersedes an earlier
one; a denial blocks. No agent can write that ledger or `vault/risk-policy.json`:
guard.sh refuses it, and vault-guard.sh restores either file if a tool call changes it.
Never ask the human to paste a command into an agent's shell; it will refuse.

## Rollback
Every slice names its rollback before building. After merge, a revert is logged:
`log-event.sh <ID> rollback REVERTED --category risk-underestimate --signal "<why>"`.
`risk-gate.sh calibrate` reads those, scope expansions, auditor blocks and escalations
per class and lists `UNDERESTIMATE?` slices for the retro. It never changes thresholds,
and a streak of clean slices is never a reason to loosen them. Only a human edits
`vault/risk-policy.json`.

## Commands
`lint <plan>` · `table <plan>` · `score [file|-]` · `show <ID>` · `assess <ID>` ·
`check <ID> build|merge` · `scope [ID]` · `pending` · `calibrate` · `audit <ID>`.
