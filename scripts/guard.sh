#!/bin/bash
# PreToolUse guard — blocks destructive bash patterns the static deny list can't express,
# and enforces vault integrity: gate files are Director-only (scribe may update session.md).
# Exit 2 blocks the tool call and feeds stderr back to the model as corrective input.
# Matcher in settings.json: Bash|Write|Edit|MultiEdit

# Fail closed: without jq we can't inspect the call, so we must not wave it through.
if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: guard.sh requires jq and it is not installed (brew install jq). Failing closed." >&2
  exit 2
fi

input=$(cat)
tool=$(echo "$input" | jq -r '.tool_name // empty')
agent_id=$(echo "$input" | jq -r '.agent_id // empty')     # present only inside subagents
agent_type=$(echo "$input" | jq -r '.agent_type // empty')
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# --- Vault integrity: subagents must not write gate state (Director-only files) ---
# task-tree.json: Director only. session.md: Director and scribe only.
if [ -n "$agent_id" ]; then
  case "$tool" in
    Write|Edit|MultiEdit) write_target="$file_path" ;;
    Bash) write_target=$(echo "$cmd" | grep -oE '(>|>>|tee[[:space:]]).*' || true) ;;
    *) write_target="" ;;
  esac
  if echo "$write_target" | grep -q 'task-tree\.json'; then
    echo "BLOCKED: task-tree.json is written by the Director only. Return your verdict as text." >&2
    exit 2
  fi
  if echo "$write_target" | grep -q 'memory/session\.md' && [ "$agent_type" != "scribe" ]; then
    echo "BLOCKED: session.md is written by the Director or the scribe only." >&2
    exit 2
  fi
fi

# --- Destructive bash tripwires (all callers, Director included) ---
[ "$tool" = "Bash" ] || exit 0
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
  '(^|[;&|][[:space:]]*)(shutdown|reboot)([[:space:]]|$)'
)

# Case-insensitive: SQL arrives in any casing (settings.json deny is case-sensitive)
deny_patterns_nocase=(
  'drop[[:space:]]+(table|database)'
  'truncate[[:space:]]+table'
)

for p in "${deny_patterns[@]}"; do
  if echo "$cmd" | grep -qE -- "$p"; then
    echo "BLOCKED by guardrail (pattern: $p). Use a reversible approach instead." >&2
    exit 2
  fi
done

for p in "${deny_patterns_nocase[@]}"; do
  if echo "$cmd" | grep -qiE -- "$p"; then
    echo "BLOCKED by guardrail (pattern: $p, any case). Use a reversible approach instead." >&2
    exit 2
  fi
done

exit 0
