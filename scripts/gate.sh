#!/bin/bash

EXCERPT_LINES="${GATE_EXCERPT_LINES:-30}"

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gate.sh: not inside a git repo" >&2; exit 1; }

project="$top/vault/project.md"
if [ ! -f "$project" ]; then
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$common" ] && project="$(dirname "$common")/vault/project.md"
fi
[ -f "$project" ] || { echo "gate.sh: no vault/project.md — run /init-vault and add gate.* commands" >&2; exit 1; }

setting() {
  local value
  value=$(sed -n "s/^[-*][[:space:]]*gate\.$1:[[:space:]]*//p" "$project" | head -1 | tr -d '\r')
  value="${value#\`}"
  printf '%s\n' "${value%\`}"
}

known="lint types test build markers comments"
steps=() targets=() focused=0
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then
    focused=1; shift; targets=("$@"); break
  fi
  steps+=("$1"); shift
done
if [ "$focused" -eq 1 ]; then
  [ "${steps[*]}" = "test" ] || { echo "gate.sh: test targets go with the test step alone: gate.sh test -- <targets>" >&2; exit 1; }
  [ ${#targets[@]} -gt 0 ] || { echo "gate.sh: no test targets after --" >&2; exit 1; }
  focus=$(setting 'test\.focus')
  [ -n "$focus" ] || { echo "gate.sh: no gate.test.focus in vault/project.md — add one (e.g. - gate.test.focus: pytest -q {}), or run gate.sh test for the full suite" >&2; exit 1; }
fi
[ ${#steps[@]} -eq 0 ] && read -ra steps <<< "$known"
for step in "${steps[@]}"; do
  case " $known " in
    *" $step "*) ;;
    *) echo "gate.sh: unknown step '$step' (one of: $known)" >&2; exit 1 ;;
  esac
done

budget=""
if [ "$focused" -eq 0 ]; then
  budget=$(setting 'test\.budget')
  case "$budget" in
    *[!0-9]*) echo "gate.sh: gate.test.budget must be whole seconds, not '$budget'" >&2; exit 1 ;;
  esac
fi

dirty=""
[ "$focused" -eq 0 ] && dirty=$(git -C "$top" status --porcelain -- . ':(exclude)vault' ':(exclude).gate')
if [ -n "$dirty" ] && [ "${GATE_ALLOW_DIRTY:-}" != "1" ]; then
  echo "GATE: FAIL (uncommitted changes outside vault/ — commit first so the result describes a SHA):" >&2
  echo "$dirty" | head -"$EXCERPT_LINES" | while IFS= read -r line; do echo "  $line" >&2; done
  exit 1
fi

common_root=$(dirname "$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")
base="${GATE_BASE:-main}"
if [ "$focused" -eq 0 ] && [ "$common_root" != "$top" ] && git -C "$top" rev-parse -q --verify "$base^{commit}" >/dev/null; then
  touched=$(git -C "$top" diff --name-only "$base...HEAD" -- vault/task-tree.json vault/log.jsonl vault/memory/session.md)
  if [ -n "$touched" ]; then
    echo "GATE: FAIL (this worktree's branch changes Director-only files, which a squash-merge would carry into main):" >&2
    echo "$touched" | while IFS= read -r line; do echo "  $line" >&2; done
    exit 1
  fi
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

with_targets() {
  local quoted
  quoted=$(printf '%q ' "${targets[@]}")
  quoted="${quoted% }"
  case "$1" in
    *'{}'*) printf '%s\n' "${1%%\{\}*}$quoted${1#*\{\}}" ;;
    *) printf '%s\n' "$1 $quoted" ;;
  esac
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
  if [ "$focused" -eq 1 ]; then
    cmd=$(with_targets "$focus")
  else
    cmd=$(setting "$step")
  fi
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
  if [ "$status" -eq 0 ] && [ "$step" = "test" ] && [ -n "$budget" ] && [ "$secs" -gt "$budget" ]; then
    echo "$step PASS (${secs}s) — over gate.test.budget (${budget}s)"
  elif [ "$status" -eq 0 ]; then
    echo "$step PASS (${secs}s)"
  else
    failed+=("$step")
    echo "$step FAIL (exit $status, ${secs}s) — full log: .gate/$step.log"
    excerpt=$(grep -nE -i 'error|fail|assert|exception|traceback|✗|✕' "$log" | head -"$EXCERPT_LINES")
    [ -z "$excerpt" ] && excerpt=$(tail -"$EXCERPT_LINES" "$log")
    while IFS= read -r line; do echo "  $line"; done <<< "$excerpt"
  fi
done

if [ "$focused" -eq 1 ]; then
  if [ ${#failed[@]} -eq 0 ]; then
    echo "FOCUSED: PASS — the named tests only, not a gate verdict"
    exit 0
  fi
  echo "FOCUSED: FAIL — the named tests only, not a gate verdict"
  exit 1
fi

sha=$(git rev-parse --short HEAD 2>/dev/null)
if [ ${#failed[@]} -eq 0 ]; then
  echo "GATE: PASS @ $sha"
  exit 0
fi
echo "GATE: FAIL (${failed[*]}) @ $sha"
exit 1
