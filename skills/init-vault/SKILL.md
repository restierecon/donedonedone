---
name: init-vault
description: Initialize this project for the autonomous engineering workflow (vault, project config, git discipline). Use when setting up a new project for the Autonomous Engineering Protocol, or when asked to run /init-vault.
---

Initialize this project for the autonomous workflow. Do all of the following:

1. Verify this is a git repo (`git rev-parse`); if not, `git init`.
2. Verify `.env` and `.env.*` are in .gitignore — add them if missing. Never proceed
   without this. Also verify `.worktrees/` (parallel-slice git worktrees) and `.gate/`
   (gate.sh logs) are gitignored — add them if missing.
3. Create directories: vault/handoffs/archive, vault/decisions, vault/findings, vault/flags, vault/memory
4. Create vault/task-tree.json:
   {"project": "", "autonomy_note": "dial lives in project.md", "slices_since_arch_review": 0, "slices": []}
5. Create vault/log.jsonl (empty file) and vault/stories.md containing only the
   header "# Shipped Stories" plus the line "One entry per merged slice, newest last.
   task-tree.json holds live work only." — every merged slice is harvested here and
   then pruned from task-tree.json.
6. Create vault/memory/session.md with: "# Session State — fresh project, no active slice. Read vault/project.md and task-tree.json to begin."
7. Create vault/memory/hot.md and vault/handoffs/current.md with headers only.
8. Create vault/project.md by asking me (one round of questions max) for:
   - Project name and one-line purpose
   - Stack (suggest from what you see in the repo if it's not empty)
   - Gate commands (suggest from the repo: package.json scripts, pyproject, Makefile)
   Then write it with these sections: Purpose · Stack · Gate — one line per step, read
   by `~/.claude/scripts/gate.sh`, omit a step the stack doesn't have:
   `- gate.lint: <cmd>` · `- gate.types: <cmd>` · `- gate.test: <cmd>` ·
   `- gate.build: <cmd>` (quiet flags preferred, e.g. `pytest -q`) · Domain Language (empty table:
   Term | Meaning — grow it as the project develops) · Autonomy: supervised ·
   Parallelism: max_parallel_slices: 3 (git-worktree parallel dispatch, see global
   protocol → Parallel Slice Dispatch) · Definition of Done (every slice independently
   testable, no TODO/FIXME, gates green).
9. Create a project-level CLAUDE.md containing ONLY project specifics (dependency
   install step, anything unusual — gate commands live in project.md) — the protocol lives globally, don't repeat it.
10. Cursor has no global rules file and never reads CLAUDE.md: if `~/.cursor/` exists,
    run `~/.claude/scripts/cursor-rules.sh` to write .cursor/rules/autonomous-protocol.mdc
    (the protocol as an always-applied project rule; it refreshes itself on each Cursor
    session).
11. Commit: `git add -A && git commit -m "chore: init autonomous workflow vault"`
12. Confirm to me: vault ready, autonomy dial at `supervised`, and suggest running
    /grill on the first feature before any decomposition.
