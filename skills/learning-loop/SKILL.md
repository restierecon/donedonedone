---
name: learning-loop
description: Use with every architecture review (same 5-slice counter), immediately when log-event.sh prints RETRO DUE, or when asked to run /learning-loop or a retro. Dispatches the retro agent over vault/log.jsonl and routes its proposals to the human. Never applies a proposal itself.
---

# Learning Loop

Per-slice capture, batched learning. Every gate verdict, Tier 3 tiebreak, escalation
and human correction is already in vault/log.jsonl (the Director writes it through
`~/.claude/scripts/log-event.sh`). The scribe's compaction discards reasoning trails,
so the log is the only surviving record of what went wrong — this skill turns it into
changes to the setup.

## When
- With every architecture review — dispatch `retro` in the same message as that
  review's explore subagent. Code and process are separate lenses; don't merge them.
- When log-event.sh prints `RETRO DUE` — the same failure category hit two slices.
  Run it before dispatching the next builder, so a third slice doesn't repeat it.
- On request.

## Steps
1. Dispatch the `retro` agent with the trigger and the vault paths. Hand it paths, not
   log contents. Always the `retro` type, never general-purpose: its Read, Grep, Glob
   tools make it read-only by harness, not by prose.
2. For each PROPOSAL, append an entry to vault/flags/pending-review.md with the usual
   3-line summary first (what / what it affects / cost to reverse), then the evidence
   log lines and the proposed change. Tag it `[retro]`.
3. Record the run: `log-event.sh - retro done --signal "<n> proposals"`. This line
   closes the window — the next retro reads only what comes after it.
4. Commit pending-review.md and log.jsonl together:
   `docs(vault): retro — <n> proposals`.

## Routing a proposal once a human accepts it
- **scope: global** — the change lands in the donedonedone setup repo, not this
  project: edit there, re-run `./install.sh` (it regenerates the Cursor and Copilot
  agents too), re-run the eval the proposal names. A manifest change without a fresh
  scorecard doesn't count toward the dial.
- **scope: project** — grilled and planned like any feature (a lint rule or gate step
  in this repo is a slice).
- **Rejected** with a load-bearing reason — offer an ADR so the retro stops proposing it.

## Never
- Apply a proposal, or edit anything under ~/.claude, from inside a project session.
- Skip step 3 — without the retro line, the next run re-reports the same window and
  RETRO DUE keeps firing on patterns already handled.
