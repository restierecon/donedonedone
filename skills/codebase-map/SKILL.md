---
name: codebase-map
description: Use to see or explain a codebase's architecture — module dependency graph, cycles, hubs, complexity hotspots, test reach — or to size a change's surface before planning it. Generates a machine-readable graph (.gate/graph.json) and a drill-down visual map (.gate/graph.html) from git, on demand. Also /codebase-map. Read-only; the architecture-review and blast-radius skills call it.
---

# Codebase map

The graph is regenerated from git whenever it's needed and never committed, so it
can't go stale. Nothing has to keep it in sync.

## Commands (run from anywhere in the repo; Python 3, lizard for complexity)
- `python3 ~/.claude/scripts/codebase-graph.py build [--coverage <report>] [--rules vault/architecture.json] [--days 90]`
  writes `.gate/graph.json` and `.gate/graph.html` for the committed HEAD (`--rev` for
  another revision) and prints at most 15 summary lines: the flagged modules with
  their fan-in, fan-out and signals. `--coverage` takes any report crap-score.py reads
  (lcov, Cobertura, JaCoCo, coverage.py JSON) and replaces the test-reach estimate
  with measured coverage.
- `python3 ~/.claude/scripts/codebase-graph.py impact (--base main | <files>…)` prints a
  CHANGE IMPACT block: files, modules, files used from other modules, direct and
  indirect dependents, modules reached, tests in reach, cycles touched, and an
  estimated regression risk.
- `python3 ~/.claude/scripts/codebase-graph.py check --rules <file> --base main` reports
  the architecture violations HEAD adds compared with the base. gate.sh's `arch`
  step runs this.

## What the graph holds
- **Repository → modules → files → functions.** A module is a directory. Each file
  records its imports, imported_by, tested_by, externals, lines, churn (commits in
  the window), coverage and functions (complexity, lines, coverage).
- **Each module** records depends_on, used_by, fan-in, fan-out, instability
  (fan-out ÷ total), the files used from outside it (its real interface), max
  complexity, churn, risk, and flags.
- **Every flag carries a `why`** sentence with its numbers. Kinds: `violation` (breaks a
  rule), `cycle`, `hub` (5 or more non-test modules depend on it), `hotspot`
  (complexity ≥ 10 in a file changed 3 or more times), `complex` (≥ 15), `untested`
  (no test reaches it through imports, or coverage under 50%).
- **Risk:** high for a violation or cycle, or a hub that is also a hotspot or untested.
  Medium for any other flag. Low otherwise.

## Limits (say them when you report)
- Imports are found by regex for Python, JS/TS (relative paths only), Go (under the
  go.mod module) and Java/Kotlin. Other languages get complexity and churn but no
  edges. Path aliases (`@/…`), dynamic imports, DI containers, reflection and string
  dispatch are invisible.
- Callers are tracked per file, not per function. Before calling a function unused,
  grep for its name.
- Without `--coverage`, "untested" means no test file reaches the code through
  imports. A test can still exercise it at runtime.

## Reading it (signals, not verdicts)
A flag is a reason to look, not a defect. A 40-line function that reads top to bottom
can be fine. A 3-line function that only forwards a call can still be a problem
(apply the deletion test from architecture-review). Before proposing a change, read
the code behind a flag and judge it. Rank by what hurts change most: cycles and
violations, then hubs that are hotspots, then the rest.

## Reporting to a human (≤ 15 lines)
Lead with the summary line. Then, for each high-risk module: name, signals, and the
`why` that matters most. Then a link to the HTML: open it with the Artifact tool or
send the file, and never paste its contents. End with one suggested next step: a card
for architecture-review, or a rule for vault/architecture.json if the human states a
boundary they want held.

## Fitness rules (vault/architecture.json, set by a human in /grill)
```json
{"no_new_cycles": true,
 "forbid": [{"from": "src/domain/**", "to": "src/infra/**", "why": "ADR-004: domain stays free of I/O"}]}
```
In the globs, `**` crosses directories and `*` stays within one. `no_new_cycles`
defaults to true. The gate reads the rules from `main`, so a slice can't loosen them
on its own branch. It also fails only on violations the diff adds, so legacy
violations never block unrelated work; they show in the map as `violation` flags.
Rules change on main only, as a decision the human made.
