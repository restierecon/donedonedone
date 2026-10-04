---
name: mutation-survivors
description: Use when mutation testing shows weak tests outside a slice's diff — an architecture review with gate.mutation set, /init-codebase on an existing codebase, or a human asking which tests would miss a bug. Ranks surviving mutants from a full run, classifies each, and routes the fix through /grill as ordinary slices; builders on a slice the mutation step failed load it too. Never adds assertion-free tests, never lowers gate.mutation.min to pass.
---

# Mutation Survivors

A mutation tool makes one small change to the code (`<` to `<=`, `+` to `-`, a return
value to its default) and runs the tests. A failing test **kills** the mutant: the tests
notice that bug. A mutant every test survives is a bug the suite would ship. Coverage
says a line ran; a killed mutant says a test checked what it did.

The gate's `mutation` step blocks a slice only for mutants on lines its diff adds, and
fails under `gate.mutation.min` (default 80%). It always lists the survivors, even on a
pass. Survivors outside the diff are planned work: found here, fixed in their own slices.

Under Cursor or Copilot without a skill loader, read this file from
`~/.claude/skills/mutation-survivors/SKILL.md`; everything it asks for is gate.sh and files.

## 1. Measure — in a subagent, so the full mutant list stays out of your context
Needs `gate.mutation` in vault/project.md (contract: README → Mutation). For a slice:
the survivors are already in the gate output. For the whole codebase: have a subagent
run the `gate.mutation` command by hand with every source file in
`$GATE_MUTATION_FILES`, then rank `.gate/mutation.log`. It returns ≤ 20 lines: the
score per file, the 10 files with the most survivors, and for each of the 10 one example
survivor as `path:line description`.

## 2. Classify — cheapest, most reversible fix first
| Signature | Fix |
|---|---|
| `no-coverage` — no test runs the line | a test that runs it and asserts the result; often the same fix a CRAP hotspot needs |
| `survived` — a test runs it but checks too little | tighten the assertion: the exact value, the boundary (`100` vs `101`), the error raised |
| Survives on a branch nothing should reach | delete the branch (deprecation-and-migration skill), not test it |
| Equivalent mutant: the change can't alter behavior (`x < lo` returning `lo` vs `x <= lo` returning `lo` at `x == lo`) | a test named for why it is equivalent, so the reviewer sees the reasoning; the survivor stays in the count |
| Generated code | exclude it in the `gate.mutation` command itself, recorded as an ADR — never ad hoc |

## 3. Route
- In a slice the step failed: the builder fixes the survivors on its own lines and
  re-runs the gate. Nothing to route.
- Outside a slice: one pending-review.md card with the 3-line summary (what / what it
  affects / cost to reverse), then the ranked list and the class of each.
- Accepted → /grill settles which files to take first. The planner slices it like any
  feature: "Developer can change <module> safely, so that <the feature that keeps
  touching it> ships without regressions".
- Architecture review: survivors join its candidate cards; a file that is also a CRAP
  hotspot is one card, not two.

## Never
- Tests without assertions, or assertions that can't fail — they kill no mutant and
  prove nothing.
- Assertions copied from the current output without checking the output is right — a
  test that pins a bug kills mutants and keeps the bug.
- Lower `gate.mutation.min`, or exclude a path from `gate.mutation`, to get a slice
  through the gate. A threshold change is a grilled decision with an ADR.
- Mark a survivor equivalent without the named test that shows why.
- Fix survivors inside an unrelated slice — that is scope creep; it goes to a card.
