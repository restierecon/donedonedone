---
description: Harvest merged slices from the task tree into vault/stories.md as user stories, then prune them from the tree
---

Harvest every merged slice out of vault/task-tree.json into vault/stories.md, then
prune it from the tree. Safe to re-run — already-harvested slices are skipped, and a
slice that isn't merged is never pruned. Runs as the Director (only the Director
writes task-tree.json).

1. If vault/ does not exist, stop and offer /init-vault. If vault/stories.md is
   missing, create it with the header "# Shipped Stories" and the line
   "One entry per merged slice, newest last. task-tree.json holds live work only."
2. Read vault/task-tree.json. Candidates are slices whose every applicable gate
   passed (auditor may be null only if its triggers never matched).
3. Confirm each candidate is actually on main: `git tag -l "<ID>-done"`, falling back
   to `git log main --oneline --grep "(<ID>)"`. No evidence of a merge → leave the
   slice in the tree and report it as unmerged. Never prune to tidy up.
4. Skip any ID already present in stories.md (`grep -c "^## <ID> "`). Never rewrite an
   existing entry — stories.md is append-only.
5. Append one entry per remaining candidate, oldest first, in this exact format:

   ```
   ## S002 — Developer can log in with email and password
   As a developer, I want to log in with my email and password so that my work stays
   tied to my own account.
   Shipped 2026-08-19 · afk · reviewer rejections: 0 · tag S002-done
   - Valid credentials set a session cookie; logout clears it
   - Wrong credentials return 401 without revealing which field was wrong
   - Six failures from one IP in a minute lock the account for 15 minutes
   ```

   - Heading: the slice's `id` and `title` verbatim — don't reword it.
   - Story line: `As a <actor>, I want to <capability> so that <so_that>.` Split the
     title at " can " for the actor and the capability, rewrite them into first person,
     and take the ending from the slice's `so_that` field.
     A slice planned before `so_that` existed won't have one: infer it from the
     acceptance criteria, append ` (so_that inferred)` to that entry's meta line, and
     list those IDs in your report so a human can correct them. Never invent a reason
     the criteria don't support — "so that the feature works" means you should ask
     instead of guessing.
   - Meta line: shipped date (`git log -1 --format=%ad --date=short <ID>-done`, else
     the merge commit's date, else today) · `mode` · reviewer rejections
     (count REJECTED verdicts for that ID in vault/log.jsonl; fall back to
     `retry_count`) · the tag name.
   - Bullets: one per acceptance criterion, rewritten as behavior a user can observe.
     Drop implementation detail; keep numbers, limits, and error behavior exact.
6. Delete the harvested slices from task-tree.json. Leave `depends_on` entries that
   name them alone — an ID with no matching slice is satisfied by definition.
7. Commit both files together: `docs(vault): harvest <n> stories, prune task tree`.
8. Report a table — ID · harvested / skipped (already in stories.md) / kept (unmerged)
   — plus the slice count remaining in the tree.
