#!/bin/bash
# Quiet gate runner — the one way builder, reviewer, and Director run lint/types/tests/build.
# Raw test output is the largest avoidable token cost in a slice: a failing suite can
# dump thousands of lines into the most expensive context, on every red-green iteration.
# This prints one line per step, and on failure only a short excerpt; the full log stays
# on disk at .gate/<step>.log for a targeted Read.
#
# Commands come from vault/project.md, one per line:  - gate.test: pytest -q
# Usage: gate.sh [lint|types|test|build ...]   (default: all four, in that order)
# Exit 0 if every configured step passed, 1 otherwise.

EXCERPT_LINES="${GATE_EXCERPT_LINES:-30}"

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gate.sh: not inside a git repo" >&2; exit 1; }

# A parallel-wave worktree may predate the latest project.md; fall back to the main checkout's.
project="$top/vault/project.md"
if [ ! -f "$project" ]; then
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$common" ] && project="$(dirname "$common")/vault/project.md"
fi
[ -f "$project" ] || { echo "gate.sh: no vault/project.md — run /init-vault and add gate.* commands" >&2; exit 1; }

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(lint types test build)

logdir="$top/.gate"
mkdir -p "$logdir"
failed=()

for step in "${steps[@]}"; do
  cmd=$(sed -n "s/^[-*][[:space:]]*gate\.${step}:[[:space:]]*//p" "$project" | head -1)
  cmd="${cmd#\`}"; cmd="${cmd%\`}"
  if [ -z "$cmd" ]; then
    echo "$step SKIP (no gate.$step in vault/project.md)"
    continue
  fi
  log="$logdir/$step.log"
  start=$(date +%s)
  (cd "$top" && bash -c "$cmd") >"$log" 2>&1
  status=$?
  secs=$(( $(date +%s) - start ))
  if [ "$status" -eq 0 ]; then
    echo "$step PASS (${secs}s)"
  else
    failed+=("$step")
    echo "$step FAIL (exit $status, ${secs}s) — full log: .gate/$step.log"
    # Prefer lines that name the failure; fall back to the tail if nothing matches.
    excerpt=$(grep -nE -i 'error|fail|assert|exception|traceback|✗|✕' "$log" | head -"$EXCERPT_LINES")
    [ -z "$excerpt" ] && excerpt=$(tail -"$EXCERPT_LINES" "$log")
    while IFS= read -r line; do echo "  $line"; done <<< "$excerpt"
  fi
done

sha=$(git rev-parse --short HEAD 2>/dev/null)
if [ ${#failed[@]} -eq 0 ]; then
  echo "GATE: PASS @ $sha"
  exit 0
fi
echo "GATE: FAIL (${failed[*]}) @ $sha"
exit 1
