#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

usage() {
  echo "usage: approve-risk.sh <authorize|merge|downgrade> <slice-id>" >&2
  echo "  authorize  — let a critical slice start building (binds the assessment and its safeguards)" >&2
  echo "  merge      — approve the finished diff of a high or critical slice (binds its patch-id)" >&2
  echo "  downgrade  — accept a reassessment that lowered a slice's risk class" >&2
  exit 2
}
refuse() { echo "approve-risk.sh: $1" >&2; exit 1; }

under_agent() {
  local pid="$PPID" n=0 comm args
  while [ "${pid:-0}" -gt 1 ] && [ "$n" -lt 64 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    case "${comm##*/}" in claude|claude.exe) return 0 ;; esac
    case "$args" in *@anthropic-ai/claude-code*|*/claude-code/cli.js*) return 0 ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    n=$((n + 1))
  done
  return 1
}

[ $# -eq 2 ] || usage
kind="$1" id="$2"
case "$kind" in authorize|merge|downgrade) ;; *) usage ;; esac

[ -z "${CLAUDECODE:-}" ] || refuse "refusing inside an agent's shell (CLAUDECODE is set). Approval is a human decision: run this yourself in your own terminal."
under_agent && refuse "refusing inside an agent's shell (a Claude Code process started this one). Approval is a human decision: run this yourself in your own terminal."
{ [ -t 0 ] && [ -t 1 ]; } || refuse "needs an interactive terminal. Run it yourself, outside any agent: approval is a human decision."
{ : </dev/tty; } 2>/dev/null || refuse "cannot open /dev/tty. Run it yourself in an interactive terminal."
command -v jq >/dev/null 2>&1 || refuse "jq is required (brew install jq · winget install jqlang.jq · apt install jq)"

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || refuse "not inside a git repo"
root=$(dirname "$common")
ledger="$common/donedonedone/approvals.jsonl"
here="$(cd "$(dirname "$0")" && pwd)"
base="${GATE_BASE:-main}"

show=$("$here/risk-gate.sh" show "$id" 2>&1) || refuse "the risk gate can't show $id:
$show"
head_line=$(printf '%s\n' "$show" | sed -n 's/^RISK: [^ ]* \(class=.*\)/\1/p' | head -1)
class=$(printf '%s\n' "$head_line" | sed -n 's/.*class=\([a-z]*\).*/\1/p')
score=$(printf '%s\n' "$head_line" | sed -n 's/.*score=\([0-9]*\).*/\1/p')
hash=$(printf '%s\n' "$head_line" | sed -n 's/.*hash=\([0-9a-f]*\).*/\1/p')
{ [ -n "$class" ] && [ -n "$score" ] && [ -n "$hash" ]; } || refuse "could not read the assessment of $id"

patch=""
echo "$show"
if [ "$kind" = merge ]; then
  git -C "$root" rev-parse -q --verify "slice/$id^{commit}" >/dev/null || refuse "no slice/$id branch to approve"
  patch=$(git -C "$root" diff "$base...slice/$id" -- . ':(exclude)vault' | git patch-id --stable | cut -d' ' -f1)
  [ -n "$patch" ] || refuse "slice/$id has no changes against $base"
  echo "--- diff of slice/$id against $base (patch_id $patch) ---"
  git -C "$root" diff --stat "$base...slice/$id" -- . ':(exclude)vault' | tail -20
  echo "--- controls ---"
  "$here/risk-gate.sh" check "$id" merge 2>&1 | grep -E '^(CONTROLS|RISK):'
fi

case "$kind" in
  authorize) expect="AUTHORIZE $id" ;;
  merge) expect="$id" ;;
  downgrade) expect="DOWNGRADE $id" ;;
esac
printf '\nType "%s" to approve. Anything else records a denial; an empty line cancels: ' "$expect" >/dev/tty
IFS= read -r answer </dev/tty || refuse "no answer read; nothing recorded"
[ -n "$answer" ] || { echo "cancelled; nothing recorded"; exit 1; }
decision=deny
[ "$answer" = "$expect" ] && decision=approve

approver=$(git -C "$root" config user.email 2>/dev/null)
mkdir -p "$(dirname "$ledger")" || refuse "cannot create $(dirname "$ledger")"
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg slice "$id" --arg kind "$kind" --arg decision "$decision" \
  --arg class "$class" --argjson score "$score" --arg hash "$hash" --arg patch "$patch" \
  --arg approver "${approver:-unknown}" --arg user "${USER:-$(id -un 2>/dev/null)}" \
  '{ts: $ts, slice: $slice, kind: $kind, decision: $decision, class: $class, score: $score, hash: $hash}
   + (if $patch != "" then {patch_id: $patch} else {} end) + {approver: $approver, user: $user}' >> "$ledger" \
  || refuse "could not write $ledger"
"$here/vault-guard.sh" --human-snapshot </dev/null >/dev/null 2>&1
echo "recorded: $kind $decision for $id (class $class, hash $hash${patch:+, patch_id $patch}) in $ledger"
[ "$decision" = approve ] || exit 1
