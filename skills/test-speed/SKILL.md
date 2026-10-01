---
name: test-speed
description: Use when a project's test suite is slow — gate.sh prints a test line "over gate.test.budget", a human says the suite takes too long, or an adopted codebase arrives with a slow suite. Measures where the time goes, ranks the causes, and routes the fix through /grill as ordinary slices; builders on those slices load it too. Never deletes, skips or weakens a test to get under budget.
---

# Test Speed

Every slice runs the full suite at least twice (builder's full gate, Director's gate),
and so does every slice after it. Fix a slow suite as planned work, as soon as it
shows. Never fix it as a side quest inside an unrelated slice.

## 1. Measure — in a subagent, so a full run's output stays out of your context
Have a subagent that can run commands (Claude Code: general-purpose) run the whole
suite once with per-test timings,
through the focused gate so the log lands in .gate/test.log:
`gate.sh test -- <timing flag> <whole test dir>`. That needs `gate.test.focus` — ask
for it if project.md lacks it — and goes in the background if the run outlasts the
shell tool's timeout. Timing flags: pytest `--durations=25` (splits setup from
call) · rspec `--profile 25` · `go test -v` · jest `--verbose` · cargo nextest prints
per-test times · vitest `--reporter=junit`, or any runner's JUnit XML (`time` per case).
It returns ≤ 20 lines: total time, worker count, the 10 slowest tests and 5 slowest
files, and setup vs call time where the runner splits them.

## 2. Classify — biggest payoff first
| Cause | Signature | Fix |
|---|---|---|
| Per-test expensive setup | setup ≫ call; one fixture behind most slow tests | build once per run (session scope, template DB, one app or browser), reset per test (rollback, truncate) |
| Proven at too high a layer | browser or out-of-process tests checking rules a module test could | prove the rule one layer down; keep one browser test for the path |
| Real waiting | durations sit just above round numbers (1.0s, 2.0s, 5.0s) | inject the clock or fake timers; await the event |
| Serial runner | one worker on a multi-core machine | parallel runner: pytest-xdist, Go `t.Parallel()`, jest/vitest workers (on unless `--runInBand`/single-thread) — a new plugin is a dependency (ADR) |
| Shared state blocks parallelism | tests pass alone, fail together | per-test tmp dirs, ports, rows |
| Real network or services | slow and flaky together | fake at the boundary |
| Redundant proofs | one behavior tested at three layers | keep the lowest that proves it, plus the path test |

## 3. Route
- One pending-review.md card: the 3-line summary (what / what it affects / cost to
  reverse), then the measured numbers and the causes found.
- Accepted → /grill settles the target budget, which browser tests stay, and whether to
  adopt a parallel runner. The planner slices it like any feature: "Developer can run
  the full suite in under 5 minutes, so that a slice gates in minutes".
- When the last of those slices merges, set `gate.test.budget` to the new suite time
  plus headroom, so the next slowdown is flagged when it lands.

## Never
- Delete, skip, quarantine or weaken a test to get under budget. A proof moves down a
  layer only when the new test fails if the criterion breaks.
- Speed up the suite inside an unrelated slice — that is scope creep; it goes to a card.
