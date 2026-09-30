#!/bin/bash

if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: guard.sh requires jq and it is not installed (brew install jq). Failing closed." >&2
  exit 2
fi

input=$(cat)
event=$(echo "$input" | jq -r '.hook_event_name // empty')
tool=$(echo "$input" | jq -r '.tool_name // empty')
agent_id=$(echo "$input" | jq -r '.agent_id // empty')
agent_type=$(echo "$input" | jq -r '.agent_type // empty')
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
file_path=$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.filePath // empty')

cursor=0
if [ "$event" = "beforeShellExecution" ]; then
  cursor=1
  tool="Bash"
  cmd=$(echo "$input" | jq -r '.command // empty')
fi

block() {
  echo "$1" >&2
  [ "$cursor" -eq 1 ] && jq -cn --arg m "$1" '{permission: "deny", agentMessage: $m, userMessage: $m}'
  exit 2
}
allow() {
  [ "$cursor" -eq 1 ] && echo '{"permission":"allow"}'
  exit 0
}

case "$tool" in
  Bash|runTerminalCommand|run_in_terminal) tool="Bash" ;;
  Write|Edit|MultiEdit|create_file|createFile|replace_string_in_file|editFiles|insert_edit_into_file) tool="Write" ;;
esac

if [ -n "$agent_id" ]; then
  case "$tool" in
    Write|Edit|MultiEdit) write_target="$file_path" ;;
    Bash) write_target=$(echo "$cmd" | grep -oE '(>|>>|tee[[:space:]]).*' || true) ;;
    *) write_target="" ;;
  esac
  if echo "$write_target" | grep -q 'task-tree\.json'; then
    block "BLOCKED: task-tree.json is written by the Director only. Return your verdict as text."
  fi
  if echo "$write_target" | grep -q 'log\.jsonl' || { [ "$tool" = "Bash" ] && echo "$cmd" | grep -q 'log-event\.sh'; }; then
    block "BLOCKED: vault/log.jsonl is written by the Director only (log-event.sh). Return your verdict as text."
  fi
  if echo "$write_target" | grep -q 'memory/session\.md' && [ "$agent_type" != "scribe" ]; then
    block "BLOCKED: session.md is written by the Director or the scribe only."
  fi
fi

[ "$tool" = "Bash" ] || allow
[ -z "$cmd" ] && allow

deny_patterns=(
  'rm[[:space:]]+-[a-z]*r[a-z]*f?[[:space:]]+(/|~)'
  ':[[:space:]]*>[[:space:]]*/'
  'mkfs'
  'dd[[:space:]]+if='
  '>[[:space:]]*/dev/sd'
  'git[[:space:]]+push.*--force'
  'git[[:space:]]+push.*-f([[:space:]]|$)'
  '--no-verify'
  'history[[:space:]]+-c'
  '(^|[;&|][[:space:]]*)(shutdown|reboot)([[:space:]]|$)'
)

deny_patterns_nocase=(
  'drop[[:space:]]+(table|database)'
  'truncate[[:space:]]+table'
)

for p in "${deny_patterns[@]}"; do
  if echo "$cmd" | grep -qE -- "$p"; then
    block "BLOCKED by guardrail (pattern: $p). Use a reversible approach instead."
  fi
done

for p in "${deny_patterns_nocase[@]}"; do
  if echo "$cmd" | grep -qiE -- "$p"; then
    block "BLOCKED by guardrail (pattern: $p, any case). Use a reversible approach instead."
  fi
done

allow
