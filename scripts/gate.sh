#!/bin/bash
# Quiet gate runner — the one way builder, reviewer, and Director run lint/types/tests/build.
# Raw test output is the largest avoidable token cost in a slice: a failing suite can
# dump thousands of lines into the most expensive context, on every red-green iteration.
# This prints one line per step, and on failure only a short excerpt; the full log stays
# on disk at .gate/<step>.log for a targeted Read.
#
# Commands come from vault/project.md, one per line:  - gate.test: pytest -q
# One built-in step needs no command: markers fails if the slice's diff against main
# (GATE_BASE to override) adds a TODO/FIXME/XXX. It turns the builder's "no
# placeholders" self-check from an opinion into a check anyone can re-run.
# Usage: gate.sh [lint|types|test|build|markers ...]   (default: all five, in that order)
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
[ ${#steps[@]} -eq 0 ] && steps=(lint types test build markers)

logdir="$top/.gate"
mkdir -p "$logdir"
failed=()

# Added lines (file:line: text) that carry a work-left-undone marker. vault/ is the
# Director's bookkeeping, not slice code, so it is exempt.
added_markers() { # <base>
  git -C "$top" diff -U0 "$1...HEAD" -- . ':(exclude)vault' | awk '
    /^\+\+\+ /  { f = substr($0, 7); next }
    /^@@/        { match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1); next }
    /^\+/        { t = substr($0, 2)
                   if (t ~ /(^|[^A-Za-z0-9_])(TODO|FIXME|XXX)([^A-Za-z0-9_]|$)/) print f ":" n ": " t
                   n++ }'
}

for step in "${steps[@]}"; do
  if [ "$step" = "markers" ]; then
    base="${GATE_BASE:-main}"
    if ! git -C "$top" rev-parse -q --verify "$base^{commit}" >/dev/null; then
      echo "markers SKIP (no $base branch to diff against; set GATE_BASE)"
      continue
    fi
    found=$(added_markers "$base")
    if [ -z "$found" ]; then
      echo "markers PASS"
    else
      failed+=("markers")
      echo "markers FAIL — the diff against $base adds TODO/FIXME/XXX:"
      echo "$found" | head -"$EXCERPT_LINES" | while IFS= read -r line; do echo "  $line"; done
    fi
    continue
  fi
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
