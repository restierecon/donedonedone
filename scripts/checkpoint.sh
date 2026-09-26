#!/bin/bash
# Stop hook — checkpoint after every turn. Secret-scan first; never immortalize a credential.
# Only acts inside a git repo that has a vault/ (i.e., an initialized autonomous project).
# rev-parse, not [ -d .git ]: in a git worktree .git is a file, and the checkpoint must still run.

# Hooks get a JSON payload on stdin. Cursor runs user-level hooks outside the project,
# so move to the workspace it names (Claude Code's payload carries cwd; same effect).
[ -t 0 ] || input=$(cat)
root=$(echo "${input:-}" | jq -r '.cwd // .workspace_roots[0]? // empty' 2>/dev/null)
if [ -n "$root" ] && [ -d "$root" ]; then cd "$root" || exit 0; fi

top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$top" || exit 0
[ -d vault ] || exit 0

# Nothing to commit?
git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain)" ] && exit 0

# Main is always green: checkpoints belong on slice/* branches, never auto-commit to main
branch=$(git branch --show-current)
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  echo "checkpoint skipped: uncommitted changes on $branch — move them to a slice branch." >&2
  exit 0
fi

git add -A

# Secret scan before commit (skip gracefully if gitleaks absent, but say so once)
if command -v gitleaks >/dev/null 2>&1; then
  # v8.19+ replaced 'protect' with 'git --staged'; support both
  if gitleaks git --help >/dev/null 2>&1; then
    scan=(gitleaks git --pre-commit --staged --no-banner)
  else
    scan=(gitleaks protect --staged --no-banner)
  fi
  if ! "${scan[@]}" >/dev/null 2>&1; then
    git reset >/dev/null 2>&1
    echo "CHECKPOINT ABORTED: gitleaks found a potential secret in staged changes. Remove it before continuing." >&2
    exit 2
  fi
fi
slice=$(echo "$branch" | grep -oE 'slice/[A-Za-z0-9_-]+' | cut -d/ -f2)
msg="chore(checkpoint): session checkpoint"
[ -n "$slice" ] && msg="chore(checkpoint): $slice progress"

git commit -q -m "$msg" 2>/dev/null
exit 0
