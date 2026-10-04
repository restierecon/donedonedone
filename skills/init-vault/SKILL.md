---
name: init-vault
description: Initialize this project for the autonomous engineering workflow (vault, project config, git discipline). Use when setting up a new project for the Autonomous Engineering Protocol, or when asked to run /init-vault.
---

Initialize this project for the autonomous workflow. Do all of the following:

1. Verify this is a git repo (`git rev-parse`); if not, `git init`.
2. Verify `.env` and `.env.*` are in .gitignore — add them if missing. Never proceed
   without this. Also verify `.worktrees/` (parallel-slice git worktrees), `.gate/`
   (gate.sh logs) and `vault/handoffs/plan-draft.json` (the planner's scratch output,
   never source of truth) are gitignored — add them if missing.
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
   - Gate commands (suggest from the repo: package.json scripts, pyproject, Makefile),
     including how to run only some tests, and a full-suite budget in seconds (default 300)
   Then write it with these sections: Purpose · Stack · Gate — one line per step, read
   by `~/.claude/scripts/gate.sh`, omit a step the stack doesn't have (except
   `gate.test`, which the gate requires — write `- gate.test: none` only if the
   project truly has no tests):
   `- gate.lint: <cmd>` · `- gate.types: <cmd>` · `- gate.test: <cmd>` (with a
   per-test timeout where the runner offers one, e.g. `--timeout=10` with pytest-timeout) ·
   `- gate.build: <cmd>` (quiet flags preferred, e.g. `pytest -q`) ·
   `- gate.test.focus: <cmd>` with `{}` where test files or ids go (`pytest -q {}`,
   `npx vitest run {}`, `go test {}`) — builders run only their own tests mid-loop ·
   `- gate.test.budget: <seconds>` — the gate flags a full suite slower than this ·
   `- gate.crap: <cmd>` printing `<path>:<start>-<end> <score> <name>` per function,
   usually from the coverage file `gate.test` writes (README → CRAP has per-stack
   pointers; skip it if the stack has no per-function coverage) · `- gate.crap.max: 30`; the
   built-in `markers` and `comments` steps need no line, but add
   `- gate.comments.skip: <path prefixes>` for generated code (migrations) and
   `- gate.comments.directives: <regex>` for a tool directive the gate doesn't know ·
   Domain Language (empty table:
   Term | Meaning — grow it as the project develops) · Autonomy: supervised ·
   Parallelism: max_parallel_slices: 3 (git-worktree parallel dispatch, see global
   protocol → Parallel Slice Dispatch) · Definition of Done (every slice independently
   testable, no TODO/FIXME, no comments, gates green).
9. Create a project-level CLAUDE.md containing ONLY project specifics (dependency
   install step, anything unusual — gate commands live in project.md) — the protocol lives globally, don't repeat it.
10. Run `~/.claude/scripts/agents-md.sh` to put the protocol into AGENTS.md — the file
    Cursor and GitHub Copilot read (Claude Code ignores it and reads the global CLAUDE.md).
    It only manages its own marked block, so an existing AGENTS.md keeps its content, and
    the session-start hook keeps the block current after upgrades.
11. Commit: `git add -A && git commit -m "chore: init autonomous workflow vault"`
12. Existing codebase with `gate.crap` set: run the crap-hotspots skill
    (~/.claude/skills/crap-hotspots/SKILL.md) once for a baseline card in
    vault/flags/pending-review.md, then commit it.
13. Confirm to me: vault ready, autonomy dial at `supervised`, and suggest running
    /grill on the first feature before any decomposition.
