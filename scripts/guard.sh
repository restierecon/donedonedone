#!/bin/bash
# PreToolUse guard — blocks destructive bash patterns the static deny list can't express.
# Exit 2 blocks the tool call and feeds stderr back to the model as corrective input.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

deny_patterns=(
  'rm[[:space:]]+-[a-z]*r[a-z]*f?[[:space:]]+(/|~)'   # recursive delete at root/home
  ':[[:space:]]*>[[:space:]]*/'                        # truncating system files
  'mkfs'
  'dd[[:space:]]+if='
  '>[[:space:]]*/dev/sd'
  'git[[:space:]]+push.*--force'
  'git[[:space:]]+push.*-f([[:space:]]|$)'
  '--no-verify'                                        # never bypass our own hooks
  'history[[:space:]]+-c'
  '(^|[;&|][[:space:]]*)shutdown|reboot'
)

for p in "${deny_patterns[@]}"; do
  if echo "$cmd" | grep -qE -- "$p"; then
    echo "BLOCKED by guardrail (pattern: $p). Use a reversible approach instead." >&2
    exit 2
  fi
done

# Vault integrity: subagents must not write gate state directly (Director-only files)
if echo "$cmd" | grep -qE '(>|>>|tee).*(task-tree\.json|memory/session\.md)'; then
  echo "BLOCKED: task-tree.json and session.md are written by the Director/Scribe protocol only." >&2
  exit 2
fi

exit 0
