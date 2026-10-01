#!/bin/bash

EXCERPT_LINES="${GATE_EXCERPT_LINES:-30}"

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gate.sh: not inside a git repo" >&2; exit 1; }

project="$top/vault/project.md"
if [ ! -f "$project" ]; then
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$common" ] && project="$(dirname "$common")/vault/project.md"
fi
[ -f "$project" ] || { echo "gate.sh: no vault/project.md — run /init-vault and add gate.* commands" >&2; exit 1; }

known="lint types test build markers comments"
steps=("$@")
[ ${#steps[@]} -eq 0 ] && read -ra steps <<< "$known"
for step in "${steps[@]}"; do
  case " $known " in
    *" $step "*) ;;
    *) echo "gate.sh: unknown step '$step' (one of: $known)" >&2; exit 1 ;;
  esac
done

dirty=$(git -C "$top" status --porcelain -- . ':(exclude)vault' ':(exclude).gate')
if [ -n "$dirty" ] && [ "${GATE_ALLOW_DIRTY:-}" != "1" ]; then
  echo "GATE: FAIL (uncommitted changes outside vault/ — commit first so the result describes a SHA):" >&2
  echo "$dirty" | head -"$EXCERPT_LINES" | while IFS= read -r line; do echo "  $line" >&2; done
  exit 1
fi

logdir="$top/.gate"
mkdir -p "$logdir"
failed=()

added_markers() {
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
  if [ "$step" = "comments" ]; then
    base="${GATE_BASE:-main}"
    if ! git -C "$top" rev-parse -q --verify "$base^{commit}" >/dev/null; then
      echo "comments SKIP (no $base branch to diff against; set GATE_BASE)"
      continue
    fi
    found=$("$(dirname "$0")/find-comments.sh" --base "$base")
    if [ -z "$found" ]; then
      echo "comments PASS"
    else
      failed+=("comments")
      echo "comments FAIL — the diff against $base adds comments (a why the code can't say goes in a test named for it, an ADR, or the commit message):"
      echo "$found" | head -"$EXCERPT_LINES" | while IFS= read -r line; do echo "  $line"; done
    fi
    continue
  fi
  cmd=$(sed -n "s/^[-*][[:space:]]*gate\.${step}:[[:space:]]*//p" "$project" | head -1)
  cmd="${cmd#\`}"; cmd="${cmd%\`}"
  if [ "$cmd" = "none" ]; then
    echo "$step SKIP (gate.$step: none)"
    continue
  fi
  if [ -z "$cmd" ]; then
    if [ "$step" = "test" ]; then
      failed+=("test")
      echo "test FAIL (no gate.test in vault/project.md — add the test command, or gate.test: none for a project with no tests)"
      continue
    fi
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
