#!/bin/bash
# SessionStart hook — hands the Director everything Session Discipline needs in one
# injection, so a resume costs zero tool round-trips: session.md, a one-line-per-slice
# summary of live work (not the whole task-tree.json), git status, and any leftover
# parallel-wave worktrees. Silent outside an initialized project. Always exits 0.

[ -f vault/memory/session.md ] || exit 0

cat vault/memory/session.md

if [ -f vault/task-tree.json ] && command -v jq >/dev/null 2>&1; then
  echo "--- live slices (id · status · mode · depends_on) ---"
  jq -r '.slices[]? | "\(.id) · \(.status) · \(.mode) · [\((.depends_on // []) | join(","))] · \(.title)"' \
    vault/task-tree.json 2>/dev/null | head -40
fi

echo "--- git reality check ---"
git status --short 2>/dev/null | head -20

worktrees=$(git worktree list 2>/dev/null | grep -F '/.worktrees/')
if [ -n "$worktrees" ]; then
  echo "--- leftover worktrees (resume or tear down before new work) ---"
  echo "$worktrees"
fi
exit 0
