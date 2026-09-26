#!/bin/bash
# SessionStart hook — hands the Director everything Session Discipline needs in one
# injection, so a resume costs zero tool round-trips: session.md, a one-line-per-slice
# summary of live work (not the whole task-tree.json), git status, and any leftover
# parallel-wave worktrees. Silent outside an initialized project. Always exits 0.
# Claude Code and VS Code inject plain stdout; Cursor's sessionStart wants JSON
# ({"additional_context": ...}) and runs user-level hooks outside the project.

[ -t 0 ] || input=$(cat)
event=$(echo "${input:-}" | jq -r '.hook_event_name // empty' 2>/dev/null)
root=$(echo "${input:-}" | jq -r '.cwd // .workspace_roots[0]? // empty' 2>/dev/null)
if [ -n "$root" ] && [ -d "$root" ]; then cd "$root" || exit 0; fi

[ -f vault/memory/session.md ] || exit 0

# Keep the project's AGENTS.md copy of the protocol (read by Cursor and Copilot) in step
# with ~/.claude/CLAUDE.md. Only projects that opted in carry the marker.
if [ -f AGENTS.md ] && grep -qF '<!-- skeletoncrew:protocol:begin' AGENTS.md; then
  "$(dirname "$0")/agents-md.sh" . >/dev/null 2>&1
fi

context() {
  cat vault/memory/session.md

  if [ -f vault/task-tree.json ] && command -v jq >/dev/null 2>&1; then
    echo "--- live slices (id · status · depends_on · title) ---"
    jq -r '.slices[]? | "\(.id) · \(.status) · [\((.depends_on // []) | join(","))] · \(.title)"' \
      vault/task-tree.json 2>/dev/null | head -40
  fi

  echo "--- git reality check ---"
  git status --short 2>/dev/null | head -20

  worktrees=$(git worktree list 2>/dev/null | grep -F '/.worktrees/')
  if [ -n "$worktrees" ]; then
    echo "--- leftover worktrees (resume or tear down before new work) ---"
    echo "$worktrees"
  fi
}

if [ "$event" = "sessionStart" ]; then
  context | jq -Rs '{additional_context: .}'
else
  context
fi
exit 0
