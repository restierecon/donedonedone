#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

[ -t 0 ] || input=$(cat)
here="$(cd "$(dirname "$0")" && pwd)"
event=$(echo "${input:-}" | jq -r '.hook_event_name // empty' 2>/dev/null)
root=$(echo "${input:-}" | jq -r '.cwd // .workspace_roots[0]? // empty' 2>/dev/null)
if [ -n "$root" ] && [ -d "$root" ]; then cd "$root" || exit 0; fi

[ -d vault ] || exit 0

"$(dirname "$0")/vault-guard.sh" --snapshot </dev/null >/dev/null 2>&1

if [ -f AGENTS.md ] && grep -qF '<!-- skeletoncrew:protocol:begin' AGENTS.md; then
  "$(dirname "$0")/agents-md.sh" . >/dev/null 2>&1
fi

context() {
  if [ -d vault/memory ] || [ -d vault/handoffs ]; then
    echo "!! retired memory layer found (vault/memory or vault/handoffs): remove it via the init-codebase migration step (clean tree, git rm, own commit)."
  fi

  if [ -f vault/task-tree.json ] && command -v jq >/dev/null 2>&1; then
    echo "--- live slices (id · status · depends_on · title) ---"
    jq -r '.slices[]? | "\(.id) · \(.status) · [\((.depends_on // []) | join(","))] · \(.title)"' \
      vault/task-tree.json 2>/dev/null | head -40
    held=$("$here/risk-gate.sh" pending 2>&1)
    if [ -n "$held" ]; then
      echo "--- risk gate (slices that can't start yet) ---"
      echo "$held"
    fi
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
elif [ "$event" = "SessionStart" ]; then
  context | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}'
else
  context
fi
exit 0
