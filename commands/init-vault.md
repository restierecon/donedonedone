---
description: Initialize this project for the autonomous engineering workflow (vault, project config, git discipline)
---

Initialize this project for the autonomous workflow. Do all of the following:

1. Verify this is a git repo (`git rev-parse`); if not, `git init`.
2. Verify `.env` and `.env.*` are in .gitignore — add them if missing. Never proceed without this.
3. Create directories: vault/handoffs/archive, vault/decisions, vault/findings, vault/flags, vault/memory
4. Create vault/task-tree.json:
   {"project": "", "autonomy_note": "dial lives in project.md", "slices_since_arch_review": 0, "slices": []}
5. Create vault/log.jsonl (empty file).
6. Create vault/memory/session.md with: "# Session State — fresh project, no active slice. Read vault/project.md and task-tree.json to begin."
7. Create vault/memory/hot.md and vault/handoffs/current.md with headers only.
8. Create vault/project.md by asking me (one round of questions max) for:
   - Project name and one-line purpose
   - Stack (suggest from what you see in the repo if it's not empty)
   Then write it with these sections: Purpose · Stack · Domain Language (empty table:
   Term | Meaning — grow it as the project develops) · Autonomy: supervised ·
   Definition of Done (every slice independently testable, no TODO/FIXME, gates green).
9. Create a project-level CLAUDE.md containing ONLY project specifics (stack commands
   for lint/test/build, anything unusual) — the protocol lives globally, don't repeat it.
10. Commit: `git add -A && git commit -m "chore: init autonomous workflow vault"`
11. Confirm to me: vault ready, autonomy dial at `supervised`, and suggest running
    /grill on the first feature before any decomposition.
