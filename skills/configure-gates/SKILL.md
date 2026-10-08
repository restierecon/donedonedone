---
name: configure-gates
description: Use when gate.sh prints "SKIP (no gate.<step> in vault/project.md)", at /init-codebase, after a tooling slice merges or a human installs a tool the gate needed, or when a human asks to set up or review the gate commands. Detects the stack, writes every gate line the repo already supports, proves each one on main, and routes the rest — missing project tooling through /grill as a slice, machine tools and judgment calls to the human. Never keeps a line it hasn't seen pass on main, never changes a line a human set.
---

# Configure Gates

A step without a `gate.<step>` line reports SKIP, so a check you think runs never
does. Mutation matters most: a slice rated `elevated` needs `gate.mutation` (or
live-verified evidence) or it waits on a human merge approval. This skill sets up every
step the repo can support today and turns the rest into planned work.

Under Cursor or Copilot without a skill loader, read this file from
`~/.claude/skills/configure-gates/SKILL.md`; everything it asks for is scripts and files.

## When
- /init-codebase (it runs the detector before its question round, and this skill after
  its first commit).
- The first time gate.sh prints `SKIP (no gate.<step> in vault/project.md)` in a
  project, unless an open pending-review card already names that step.
- After a tooling slice merges, or the human says a TOOL item is installed.

## 1. Detect — read-only, ≤ 20 lines, run it yourself
`python3 ~/.claude/scripts/detect-gates.py` (`python` on Windows) from the main
checkout. It reads only the repo's manifests and config, plus `PATH` for machine tools:

| Line | Means | You |
|---|---|---|
| `SET` | a human already wrote this line | leave it; a better command is an ASK, never an edit |
| `READY` | the repo declares the tool, so the line should work | `--apply` writes it |
| `N/A` | the stack has no such step (no UI, no build) | `--apply` writes `- gate.<step>: none` |
| `ASK` | a judgment call: two stacks want one line, or a set `gate.test` writes no coverage | ask the human |
| `SLICE` | the project needs a dev dependency, config or test files first | route through /grill |
| `TOOL` | a machine tool is missing; the line says how to install it | ask the human |
| `IGNORE` | what the READY commands write, which must be gitignored | `--apply` adds it |

## 2. Apply, then prove every new line on main
1. On main with a clean tree: `detect-gates.py --apply`. It appends to the Gate
   section of vault/project.md and to .gitignore; it never edits an existing line, and
   a second run changes nothing.
2. Commit vault/project.md and .gitignore alone:
   `chore(gate): configure gate commands`.
3. Run `~/.claude/scripts/gate.sh` once on main, in a background subagent if
   `gate.mutation` was written (a mutation run tests every mutant). Each written step
   must PASS. `crap` and `mutation` pass on main with "the diff touches no ..." —
   that still proves the command runs and prints the format the gate parses.
4. A written step that fails gets its line deleted, so main stays green. What happens
   next depends on why it failed:
   - The command can't run (not found, missing module, wrong report path, "printed no
     ... lines"). Treat it as a TOOL item.
   - It runs and finds real problems on main (lint errors, type errors, red tests).
     Write one pending-review card: "gate.<step> finds N issues on main". If accepted,
     a cleanup slice goes through /grill, then re-run this skill. A red `gate.test` on
     main blocks every slice: escalate that one at once.
   Commit the deletions: `chore(gate): drop gate.<step> until <reason>`.

## 3. Route the rest — one card per kind, every flag-entry rule applies
- **SLICE** items: one card listing each step and what it needs. If accepted, /grill
  it as a tooling feature: "Developer can trust the gate's <steps>". Each new
  dependency gets its one-line ADR. Each step's acceptance criterion is
  "`gate.sh <step>` passes on main with the line detect-gates.py proposes". After it
  merges, re-run this skill; the items now come back READY.
- **TOOL** items: one card with the exact install commands. The human installs them
  on their machine (and in CI, if the gate runs there), then you re-run this skill.
- **ASK** items: one round of questions, each with the detector's proposed line. Write
  the line the human picks, then prove it on main as in step 2.
- **A human declines a step:** write `- gate.<step>: none`. Its SKIP then says so,
  and this skill never asks again.

## Never
- Keep a line that hasn't passed on main, or change a line a human set.
- Install a dependency, or edit the project's config or tests yourself. That is a slice.
- Weaken a command to make it pass: `|| true`, `--exit-zero`, narrowed paths,
  a raised `gate.crap.max` or a lowered `gate.mutation.min`.
