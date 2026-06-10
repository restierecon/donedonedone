---
name: slice-planning
description: Use when decomposing a feature, PRD, or grilled spec into tasks. Produces vertical slices (end-to-end behavior, never layers), each tagged afk or hitl, written into vault/task-tree.json.
---

# Slice Planning

Decompose by BEHAVIOR, never by layer. A slice is a tracer bullet: the thinnest
end-to-end path that makes one piece of user-visible behavior real.

## Every slice must satisfy all three
1. Named "Actor can [do something]" — if you can't name it this way, it's not a slice
2. Touches every layer that behavior needs (DB + API + UI + tests as applicable)
3. Testable and demonstrable with NO other slice complete

## Anti-pattern (reject your own plan if you see this)
No horizontal slicing — never "create the tables", then "build the endpoints",
then "build the UI". That illusion of parallel completeness produces fragile,
unintegrated output. One vertical slice at a time.

## Sizing
A slice the Builder can finish inside its budget (≤ 12 invocations including review
rounds). If acceptance criteria exceed ~7 items, split the slice.

## Mode tagging (decide now, not at failure time)
- **afk** — autonomous: requirements unambiguous, no irreversible action, no design
  judgment a human would want. Prefer afk; most CRUD, wiring, and test slices qualify.
- **hitl** — needs a human decision: ambiguous requirements, UX judgment calls,
  schema choices that are expensive to reverse, anything touching money or deletion
  of user data, architecture refactors.

## Ordering
Walking-skeleton first: the earliest slices should produce a deployable end-to-end
spine (one trivial behavior through every layer), then flesh out behavior by value.
Record dependencies explicitly; the Director schedules afk slices in dependency order
and batches hitl slices for human sessions.

## Output
Write slices into vault/task-tree.json:
{ "id": "S00n", "title": "Actor can ...", "mode": "afk|hitl", "status": "todo",
  "depends_on": [], "acceptance_criteria": ["..."], "retry_count": 0,
  "gates": {"self_review": null, "automated": null, "reviewer": null, "auditor": null} }
Then present the plan as a table (id · title · mode · depends on) for confirmation
before any building starts.
