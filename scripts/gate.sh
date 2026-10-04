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

known="lint types test build crap markers comments"
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

crap_max=30
if [ "$focused" -eq 0 ]; then
  crap_max=$(setting 'crap\.max')
  [ -z "$crap_max" ] && crap_max=30
  case "$crap_max" in
    *[!0-9.]*|*.*.*|.*|*.) echo "gate.sh: gate.crap.max must be a number, not '$crap_max'" >&2; exit 1 ;;
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

added_lines() {
  git -C "$top" diff -U0 "$1...HEAD" -- . ':(exclude)vault' | awk '
    /^\+\+\+ / { f = substr($0, 7); next }
    /^@@/       { match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1); next }
    /^\+/       { print f ":" n; n++ }'
}

crap_touched() {
  awk -v max="$1" '
    FILENAME == ARGV[1] { touched[$0] = 1; files[substr($0, 1, index($0, ":") - 1)] = 1; next }
    {
      sub(/\r$/, "")
      if (NF < 3 || $2 !~ /^[0-9]+(\.[0-9]+)?$/) next
      loc = $1
      gsub(/\\/, "/", loc)
      sub(/^\.\//, "", loc)
      if (!match(loc, /:[0-9]+(-[0-9]+)?$/)) next
      path = substr(loc, 1, RSTART - 1)
      range = substr(loc, RSTART + 1)
      parsed++
      name = $3
      for (k = 4; k <= NF; k++) name = name " " $k
      dash = index(range, "-")
      hit = 0
      if (dash) {
        start = substr(range, 1, dash - 1) + 0
        stop = substr(range, dash + 1) + 0
        for (l = start; l <= stop && !hit; l++) if ((path ":" l) in touched) hit = 1
      } else {
        start = range + 0
        if (path in files) hit = 1
      }
      if (!hit) next
      if (!seen || $2 + 0 > best + 0) { best = $2; best_name = name; seen = 1 }
      if ($2 + 0 > max + 0) print "OVER " path ":" start " " name " " $2
    }
    END {
      print "PARSED " parsed + 0
      if (seen) print "TOP " best_name " " best
    }' "$2" "$3"
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
  if [ "$step" = "crap" ]; then
    cmd=$(setting crap)
    if [ -z "$cmd" ]; then
      echo "crap SKIP (no gate.crap in vault/project.md)"
      continue
    fi
    if [ "$cmd" = "none" ]; then
      echo "crap SKIP (gate.crap: none)"
      continue
    fi
    base="${GATE_BASE:-main}"
    if ! git -C "$top" rev-parse -q --verify "$base^{commit}" >/dev/null; then
      echo "crap SKIP (no $base branch to diff against; set GATE_BASE)"
      continue
    fi
    case " ${failed[*]} " in
      *" test "*) echo "crap SKIP (test failed — coverage is stale)"; continue ;;
    esac
    log="$logdir/crap.log"
    start=$(date +%s)
    (cd "$top" && bash -c "$cmd") >"$log" 2>&1
    status=$?
    secs=$(( $(date +%s) - start ))
    if [ "$status" -ne 0 ]; then
      failed+=("crap")
      echo "crap FAIL (exit $status, ${secs}s) — full log: .gate/crap.log"
      tail -"$EXCERPT_LINES" "$log" | while IFS= read -r line; do echo "  $line"; done
      continue
    fi
    added_lines "$base" > "$logdir/crap.touched"
    result=$(crap_touched "$crap_max" "$logdir/crap.touched" "$log")
    if [ "$(echo "$result" | sed -n 's/^PARSED //p')" = "0" ]; then
      failed+=("crap")
      echo "crap FAIL (${secs}s) — gate.crap printed no '<path>:<start>-<end> <score> <name>' lines; full log: .gate/crap.log"
      continue
    fi
    over=$(echo "$result" | sed -n 's/^OVER //p')
    if [ -n "$over" ]; then
      failed+=("crap")
      echo "crap FAIL (${secs}s) — functions the diff touches score over gate.crap.max ($crap_max); split them or test their untested branches:"
      echo "$over" | head -"$EXCERPT_LINES" | while IFS= read -r line; do echo "  $line"; done
      continue
    fi
    top_line=$(echo "$result" | sed -n 's/^TOP //p')
    if [ -n "$top_line" ]; then
      echo "crap PASS (${secs}s) — highest touched: $top_line (max $crap_max)"
    else
      echo "crap PASS (${secs}s) — the diff touches no scored function"
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

sha=$(git -C "$top" rev-parse --short HEAD 2>/dev/null)
patch_id=""
if git -C "$top" rev-parse -q --verify "$base^{commit}" >/dev/null; then
  patch_id=$(git -C "$top" diff "$base...HEAD" -- . ':(exclude)vault' | git patch-id --stable | cut -d' ' -f1)
fi
at="sha=$sha patch_id=${patch_id:-none}"
if [ ${#failed[@]} -eq 0 ]; then
  echo "GATE: PASS @ $at"
  exit 0
fi
echo "GATE: FAIL (${failed[*]}) @ $at"
exit 1
