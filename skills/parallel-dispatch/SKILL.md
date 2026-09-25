---
name: parallel-dispatch
description: Use when the Director is about to build two or more independent slices at once, or when resuming with leftover .worktrees/ from an interrupted wave. Covers git-worktree setup, concurrent builder/reviewer dispatch, where vault bookkeeping commits go, serial squash-merges, and merge-conflict recovery.
---

# Parallel Slice Dispatch (git worktrees)

Gather all slices whose `depends_on` are satisfied (done, or absent from
task-tree.json = shipped). They are independent and safe to run concurrently. Dispatch
up to `max_parallel_slices` (vault/project.md, default 3) at once:

1. For each: `git worktree add .worktrees/<ID> -b slice/<ID>` from main, then run the
   project's dependency-install step inside that worktree (see project CLAUDE.md) — a
   fresh worktree has no installed environment; gates can't run until it does.
2. Fire that many `builder` Agent calls in a single message, one per worktree —
   instruct each to work only inside its assigned worktree path (the Agent tool has no
   enforced working-directory field; this is prompt discipline, not harness isolation).
3. As each builder reports COMPLETE, run `gate.sh` in that worktree, then its reviewer
   (and auditor, if triggered) against the same worktree — dispatched in parallel
   across whichever slices just finished building.
4. Vault bookkeeping stays out of slice branches during a wave: builder/reviewer/
   auditor commits inside a worktree touch application code only. The Director's own
   commits (task-tree.json, log.jsonl, scribe's memory/handoffs edits) land directly on
   main, in the main checkout — never on a slice branch. Slice branches stay vault-free
   so a squash-merge only touches code and sibling bookkeeping never collides. Per-slice
   working notes go in vault/handoffs/active/<ID>.md, indexed from current.md.
5. Process verdicts and squash-merges to main ONE AT A TIME, in whatever order they
   land — the merge stays Director-serial even though build/review was concurrent.
6. Squash-merge conflict (a sibling already changed an overlapping file): re-dispatch
   that builder once, in its worktree, to rebase onto current main, resolve, and re-run
   gates. Second failure → escalate (vault/flags/pending-review.md); don't force it.
7. After merge (or on abandonment): `git worktree remove .worktrees/<ID>` and delete
   the branch.

A crashed wave leaves worktrees behind; the SessionStart hook lists them. Resume each
(re-invoke its builder/reviewer in place) or tear it down before starting new work.
