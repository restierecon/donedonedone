#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

usage() {
  echo "usage: approve-ui.sh vault/ui/<feature-slug>/contract.md" >&2
  echo "  approves the contract, prototype and screenshots in that folder exactly as they are now" >&2
  exit 2
}
refuse() { echo "approve-ui.sh: $1" >&2; exit 1; }

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

[ $# -eq 1 ] || usage
contract="$1"

[ -z "${CLAUDECODE:-}" ] || refuse "refusing inside an agent's shell (CLAUDECODE is set). Approval is a human decision: run this yourself in your own terminal."
under_agent && refuse "refusing inside an agent's shell (a Claude Code process started this one). Approval is a human decision: run this yourself in your own terminal."
{ [ -t 0 ] && [ -t 1 ]; } || refuse "needs an interactive terminal. Run it yourself, outside any agent: approval is a human decision."
{ : </dev/tty; } 2>/dev/null || refuse "cannot open /dev/tty. Run it yourself in an interactive terminal."
command -v jq >/dev/null 2>&1 || refuse "jq is required (brew install jq · winget install jqlang.jq · apt install jq)"

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || refuse "not inside a git repo"
root=$(dirname "$common")
ledger="$common/donedonedone/approvals.jsonl"
here="$(cd "$(dirname "$0")" && pwd)"

hash=$("$here/ui-approval.sh" hash "$contract" 2>&1) || refuse "$hash"
slug=$(basename "$(dirname "$contract")")
dir="$root/$(dirname "$contract")"

echo "--- $contract (hash $hash) ---"
head -40 "$root/$contract"
echo "--- files approved together ---"
(cd "$dir" && find . -type f | LC_ALL=C sort | sed 's|^\./|  |')
[ -f "$dir/prototype.html" ] && echo "open the prototype: $dir/prototype.html"

expect="APPROVE UI $slug"
printf '\nType "%s" to approve. Anything else records a denial; an empty line cancels: ' "$expect" >/dev/tty
IFS= read -r answer </dev/tty || refuse "no answer read; nothing recorded"
[ -n "$answer" ] || { echo "cancelled; nothing recorded"; exit 1; }
decision=deny
[ "$answer" = "$expect" ] && decision=approve

approver=$(git -C "$root" config user.email 2>/dev/null)
mkdir -p "$(dirname "$ledger")" || refuse "cannot create $(dirname "$ledger")"
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg contract "$contract" --arg decision "$decision" --arg hash "$hash" \
  --arg approver "${approver:-unknown}" --arg user "${USER:-$(id -un 2>/dev/null)}" \
  '{ts: $ts, kind: "ui", contract: $contract, decision: $decision, hash: $hash, approver: $approver, user: $user}' >> "$ledger" \
  || refuse "could not write $ledger"
"$here/vault-guard.sh" --human-snapshot </dev/null >/dev/null 2>&1
echo "recorded: ui $decision for $contract (hash $hash) in $ledger"
[ "$decision" = approve ] || exit 1
