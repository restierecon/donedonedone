---
name: compaction
description: Use when the scribe agent runs, or whenever vault memory files exceed their size targets. The step-by-step procedure for compressing handoffs and checkpointing session state so progress survives session death.
---

# Compaction

The contract: after every compaction, a brand-new session reading only
vault/memory/session.md can resume with zero re-done work and zero lost decisions.

## What survives vs what dies
KEEP: shipped behavior (as a story in stories.md), outcomes, decisions,
acceptance criteria, gate verdicts, file paths,
established patterns, unresolved items.
DISCARD: reasoning trails, intermediate attempts, deliberation, raw tool output,
anything reconstructible from git.

## session.md template (< 150 lines, always)
# Session State
Last updated: [ts]
## Progress
Completed: [slice ids] · Active: [id — title] · Branch: slice/[id]
Active step: [agent] · Last gate passed: [gate] · Next gate: [gate]
## Active Slice Context
[dependencies on prior slices, established patterns, criteria — copied, not referenced]
## Pending Flags / Unresolved
[...]
## Resume Instructions
1. Read task-tree.json → confirm active slice  2. git status — reconcile drift first
3. Read hot.md → continue active step  4. Never re-do gate-approved work

## hot.md (< 100 lines) — active slice working memory only
What we know · Decisions made this slice · Current step summary.
Cleared and re-seeded from task-tree.json when a slice completes.

## current.md compaction (when > 400 lines mid-slice)
Rewrite as three sections: completed steps (one-line outcomes each) ·
active step (FULL detail preserved — never compress the live step) ·
pending (list only). Move newly-learned durable facts to hot.md first.

## Slice-complete sequence
0. Harvest the story first — append to vault/stories.md: `## <ID> — <title>`, then
   `As a <actor>, I want to <capability> so that <so_that>.` (actor and capability
   from either side of " can " in the title, ending from the slice's `so_that`), then
   `Shipped <date> · <mode> · reviewer rejections: <n> · tag <ID>-done`, then one
   bullet per acceptance criterion. Read them out of task-tree.json before the Director
   prunes the slice from it. stories.md is append-only and has no size target: it is
   the permanent record of what the product does, and the streak the autonomy-dial
   promotion rule counts.
1. current.md → 10-15 line outcome summary → handoffs/archive/<ID>.md
2. Reset current.md (next slice header only)
3. Builder DECISIONS → hot.md re-seed; durable patterns → project.md
4. session.md updated; size targets verified (state actual line counts in your report)
