---
name: clean-diff
description: Builder's cleaning pass over its own diff, run once the slice is green and before the final gate run and report. Finds and fixes dead code, unused parameters and imports, reimplemented helpers, speculative abstraction and needless dependencies in the lines the slice adds — the reviewer's slop checklist turned into fix actions. Never touches lines outside the diff.
---

# Clean Diff

The reviewer reads your diff cold against its slop checklist (`agents/reviewer.md` →
Slop Checklist) and REJECTs what it finds. Each REJECT costs a full builder round. This
pass finds the same things first, while fixing them is one edit.

Run it once per slice: after the tests are green and refactored, before the final
`gate.sh` and the report. Under Cursor or Copilot without a skill loader, read this
file from `~/.claude/skills/clean-diff/SKILL.md`.

## 1. List what the diff adds
`git diff main...HEAD --stat -- . ':(exclude)vault'`, then
`git diff main...HEAD -- <file>` per file. Note every new function, class, module,
parameter, import and dependency. Work from the diff, not from memory of what you wrote.

## 2. Check each addition — cheapest check first
| Check | How | Fix |
|---|---|---|
| Unused | grep the new name across the repo: no caller outside its own test | delete it and its test |
| Already exists | grep for the behavior (a key verb, the type it takes) before trusting your version | call the existing one; delete yours |
| Pass-through | the deletion test: inline it mentally — if nothing gets harder, it forwards with no added behavior | inline it |
| One implementation | an interface, base class, factory or config option with a single user | collapse to the concrete thing |
| Dead branch | a guard for a state the types or the caller already rule out | delete it, or crash loudly if the state is truly impossible |
| Unused parameter or import | the linter may miss a parameter every caller passes the same value | remove it |
| Duplicated block | the same 3+ lines twice in the diff, or copied from a prior slice | extract once, in the domain module that owns it |
| New dependency | does stdlib or an installed dependency do it in a few lines? | use that; keep the dependency only with its one-line justification |
| Leftover | debug prints, stubs, renamed-but-kept old code, commented-out code | delete it |

## 3. Re-run and report
After any fix: commit, then run the full `gate.sh`. A fix that turns a test red was not a
cleanup: undo it and leave the code as it was. Add one line to your report:
`CLEANED: <n> fixes — <what, one phrase each>` or `CLEANED: nothing found`.

## Never
- Touch a line the slice didn't add or change. An improvement you spot outside the diff
  goes under FLAG CANDIDATES for vault/flags/, never into the diff.
- Rename, reformat or restructure for taste. This pass removes, it doesn't redesign.
- Delete a test to make a cleanup pass.
