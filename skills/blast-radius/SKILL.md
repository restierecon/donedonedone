---
name: blast-radius
description: Use during slice review to answer "what does this change break outside its diff". Finds callers and consumers of changed symbols, config, schemas and CLI flags beyond the diff, and proves any suspected breakage by running code before it is reported as a defect. Read-only; reviewer use.
---

# Blast radius

Adapted from [pstack `skills/blast-radius`](https://github.com/backnotprop/pstack/tree/main/skills/blast-radius)
(MIT, Copyright (c) 2026 Lauren Tan — see LICENSE in this directory).

The diff shows what changed. This finds what the change breaks somewhere else.
Listing callers is the cheap part; the job is the breakage a grep won't show you.

## Proof ladder
For each suspected breakage (and the one fact the change is safe because of), get as
far down this list as is cheap, and say where it stopped:
1. Asserted — worthless on its own.
2. Pointed — a real `file:line`, or the dependency's own source.
3. Traced — walked the failure step by step; it does / doesn't reach.
4. Ran — a test or one-off command calls the real code and fails loud if you're wrong.
5. Reproduced — in the running app.

Only rung 4+ turns a suspicion into a REJECTED item. Anything stuck at 1–3 is FYI,
labelled unproven. Never invent a caller or an API; a search that finds nothing is an answer.

## Steps
1. **Read the change.** `git diff main...slice/<ID>` — list every symbol, config key,
   env var, schema/column, route, CLI flag or file format it adds, changes or deletes,
   including behavior the diff doesn't spell out (new default, reordered side effect).
2. **Find consumers outside the diff.** Start with
   `python3 ~/.claude/scripts/codebase-graph.py impact --base main` (codebase-map
   skill): direct and indirect importers, tests in reach, cycles the change touches.
   It sees static imports only, so then, for each item, Grep the repo for references in
   files the diff does NOT touch: imports, call sites, string keys, docs, scripts, CI,
   tests. `git log -S'<symbol>'` and `git blame` show why a shape exists before you
   call a change to it safe.
3. **Look where grep stops.** Dynamic dispatch, string-built names, serialized output
   (JSON, DB columns, wire formats) read by another process or language, feature flags,
   pinned dependency source, ordering/teardown timing.
4. **Find the one fact it's safe because of.** Most risky-looking changes are safe
   because of a single fact ("every caller passes the new arg"). Spend time proving that.
5. **Prove by running.** Run the existing suite via `~/.claude/scripts/gate.sh test`
   (or the project's test command it wraps), or a one-off read-only command —
   `python -c`, `node -e`, invoking the CLI with the old flag — against the slice's
   checkout. Don't write files into the repo; scratch scripts go in a temp dir.
   Paste the command and its decisive output line.

## Hand back (≤ 5 lines, into the reviewer's BLAST RADIUS section)
- Consumers checked: what outside the diff depends on the change (count + key paths;
  the impact block's direct/indirect counts and its risk estimate, labelled an estimate).
- Safety fact: stated, with its rung.
- Each breakage: `file:line` — how it breaks — rung. Rung 4+ → CRITICAL in CRITIQUE;
  below → FYI, unproven.
- Nothing found: say "none outside diff" and what you searched.
