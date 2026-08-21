---
name: slice-planning
description: Use when decomposing a feature, PRD, or grilled spec into tasks. Produces vertical slices (end-to-end behavior, never layers), each tagged afk or hitl, written into vault/task-tree.json.
---

# Slice Planning

Decompose by BEHAVIOR, never by layer. A slice is a tracer bullet: the thinnest
end-to-end path that makes one piece of user-visible behavior real.

## Every slice must satisfy all three
1. Named "Actor can [do something]" — if you can't name it this way, it's not a slice.
   Write its `so_that` in the same breath: the reason the actor wants it, in the
   actor's words, never the implementation ("so that I don't lose my draft", not
   "so that we persist to localStorage"). Title plus `so_that` is the user story the
   slice ships as; a slice whose `so_that` you can only state as "so that the system
   works" has no user-visible value and is probably a layer, not a slice.
2. Touches every layer that behavior needs (DB + API + UI + tests as applicable)
3. Testable and demonstrable with NO other slice complete

## Anti-pattern (reject your own plan if you see this)
No horizontal slicing — never "create the tables", then "build the endpoints",
then "build the UI". That illusion of parallel completeness produces fragile,
unintegrated output. One vertical slice at a time.

## Sizing
A slice the Builder can finish inside its budget (≤ 12 invocations including review
rounds). If acceptance criteria exceed ~7 items, split the slice. Other split signals:
the title needs an "and" to describe it (that's two slices); it touches two or more
independent subsystems (e.g. billing and notifications); you can't state its
acceptance criteria in 3 bullets without hand-waving.

## Map dependencies before sizing
Before writing slice boundaries, sketch what depends on what (schema → API → UI is
the common shape, but not the only one). Order slices bottom-up along that graph —
this is what `depends_on` should encode, not just "did it get planned first."

## Instrumentation
If the slice adds a new I/O or external-call path (network, queue, subprocess,
third-party API) that will run in production, add an explicit acceptance criterion
for it: "logs entry/exit with a correlation ID" or equivalent. Observability is not
an afterthought slice — it ships with the behavior it observes.

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

## Classify for parallel dispatch
`depends_on` isn't just "must come after" — it's what makes a slice eligible for
concurrent git-worktree dispatch (see the global protocol's Parallel Slice Dispatch).
For each pair of afk slices, decide:
- **Safe to parallelize** — genuinely independent: different files, no shared schema
  or contract. Leave `depends_on` empty between them.
- **Must be sequential** — one changes shared state the other reads (a migration,
  a schema the other's queries assume). Add the edge to `depends_on`.
- **Needs coordination, not sequencing** — both consume the same API contract or
  schema but could otherwise run concurrently. Don't force a false dependency edge;
  instead plan a contract-defining slice first (types/interfaces/schema only), then
  let the consumers depend on *that*, not on each other.
Getting this wrong either serializes work that could have run concurrently, or lets
two slices race on files neither one's `depends_on` protected.

## Output
Write slices into vault/task-tree.json:
{ "id": "S00n", "title": "Actor can ...", "so_that": "...", "mode": "afk|hitl",
  "status": "todo", "depends_on": [], "acceptance_criteria": ["..."], "retry_count": 0,
  "gates": {"self_review": null, "automated": null, "reviewer": null, "auditor": null} }
A `depends_on` ID that names a slice absent from task-tree.json is satisfied — merged
slices are harvested into vault/stories.md and pruned. Check stories.md before assuming
a missing ID is a typo.
Then present the plan as a table (id · title · mode · depends on) for confirmation
before any building starts.
