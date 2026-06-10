#!/bin/bash
# Stop hook — checkpoint after every turn. Secret-scan first; never immortalize a credential.
# Only acts inside a git repo that has a vault/ (i.e., an initialized autonomous project).

[ -d .git ] && [ -d vault ] || exit 0

# Nothing to commit?
git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain)" ] && exit 0

git add -A

# Secret scan before commit (skip gracefully if gitleaks absent, but say so once)
if command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks protect --staged --no-banner >/dev/null 2>&1; then
    git reset >/dev/null 2>&1
    echo "CHECKPOINT ABORTED: gitleaks found a potential secret in staged changes. Remove it before continuing." >&2
    exit 2
  fi
fi

branch=$(git branch --show-current)
slice=$(echo "$branch" | grep -oE 'slice/[A-Za-z0-9_-]+' | cut -d/ -f2)
msg="chore(checkpoint): session checkpoint"
[ -n "$slice" ] && msg="chore(checkpoint): $slice progress"

git commit -q -m "$msg" 2>/dev/null
exit 0
