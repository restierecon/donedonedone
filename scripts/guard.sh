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

read_only_shell() {
  case "$1" in *\>*|*\$\(*|*\`*|*\<\(*) return 1 ;; esac
  local seg words
  while IFS= read -r seg; do
    read -ra words <<< "$seg"
    [ ${#words[@]} -eq 0 ] && continue
    case "${words[0]}" in
      cat|head|tail|less|grep|egrep|rg|jq|wc|ls|stat|file|diff|test|'[') ;;
      git)
        case "${words[1]:-}" in
          log|show|diff|status|blame|grep) ;;
          *) return 1 ;;
        esac ;;
      *) return 1 ;;
    esac
  done < <(printf '%s\n' "$1" | tr ';&|' '\n')
  return 0
}

protected_hit() {
  case "$tool" in
    Write) echo "$file_path" | grep -q "$1" ;;
    Bash) echo "$cmd" | grep -q "$1" && ! read_only_shell "$cmd" ;;
    *) return 1 ;;
  esac
}

if [ -n "$agent_id" ]; then
  if protected_hit 'task-tree\.json'; then
    block "BLOCKED: task-tree.json is written by the Director only. Return your verdict as text."
  fi
  if protected_hit 'log\.jsonl' || { [ "$tool" = "Bash" ] && echo "$cmd" | grep -q 'log-event\.sh'; }; then
    block "BLOCKED: vault/log.jsonl is written by the Director only (log-event.sh). Return your verdict as text."
  fi
  if [ "$agent_type" != "scribe" ] && protected_hit 'memory/session\.md'; then
    block "BLOCKED: session.md is written by the Director or the scribe only."
  fi
fi

rm_catastrophic() {
  local seg words w in_rm r
  while IFS= read -r seg; do
    read -ra words <<< "$seg"
    in_rm=0 r=0
    for w in "${words[@]}"; do
      if [ "$in_rm" -eq 0 ]; then
        [ "$w" = rm ] && in_rm=1
        continue
      fi
      case "$w" in
        --recursive) r=1 ;;
        --*) ;;
        -*) [[ $w == *[rR]* ]] && r=1 ;;
        *)
          w="${w//\"/}"; w="${w//\'/}"
          case "$w" in
            /|/*|\~|\~/*|\$HOME|\$HOME/*|\$\{HOME\}|\$\{HOME\}/*|.|./|..|../*|\*) [ "$r" -eq 1 ] && return 0 ;;
          esac ;;
      esac
    done
  done < <(printf '%s\n' "$1" | tr ';&|' '\n')
  return 1
}

[ "$tool" = "Bash" ] || allow
[ -z "$cmd" ] && allow

deny_patterns=(
  ':[[:space:]]*>[[:space:]]*/'
  'mkfs'
  'dd[[:space:]]+if='
  '>[[:space:]]*/dev/sd'
  'git[[:space:]]+push.*--force'
  'git[[:space:]]+push.*[[:space:]]-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)'
  'git[[:space:]]+push.*[[:space:]]\+[^[:space:]]'
  'git[[:space:]]+reset[[:space:]]+(.*[[:space:]])?--hard'
  'git[[:space:]]+clean[[:space:]]+(.*[[:space:]])?-[a-zA-Z]*f'
  'git[[:space:]]+(checkout|restore)[[:space:]]+(.*[[:space:]])?\.([[:space:]]|$)'
  'git[[:space:]]+branch[[:space:]]+(.*[[:space:]])?(-D|--delete[[:space:]]+--force|-d[[:space:]]+--force)[[:space:]]+(main|master)([[:space:]]|$)'
  '(^|[;&|][[:space:]]*)sudo[[:space:]]'
  '(curl|wget)[[:space:]].*\|[[:space:]]*(ba|z)?sh([[:space:]]|$)'
  'chmod[[:space:]]+-R[[:space:]]+777'
  '--no-verify'
  'history[[:space:]]+-c'
  '(^|[;&|][[:space:]]*)(shutdown|reboot)([[:space:]]|$)'
)

deny_patterns_nocase=(
  'drop[[:space:]]+(table|database)'
  'truncate[[:space:]]+table'
)

if rm_catastrophic "$cmd"; then
  block "BLOCKED by guardrail (recursive rm of /, ~, \$HOME, . or ..). Delete a named subdirectory instead."
fi

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
