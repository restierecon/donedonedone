#!/bin/bash

if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: guard.sh requires jq and it is not installed (brew install jq · winget install jqlang.jq · apt install jq). Failing closed." >&2
  exit 2
fi

input=$(cat)
if ! echo "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "BLOCKED: guard.sh could not parse the hook payload. Failing closed." >&2
  exit 2
fi

field() { echo "$input" | jq -r "$1 // empty"; }
event="" tool="" agent_id="" cmd="" file_path=""
if ! parsed=$(echo "$input" | jq -r '@sh "event=\(.hook_event_name // "") tool=\(.tool_name // "") agent_id=\(.agent_id // "") cmd=\(.tool_input.command // "") file_path=\(.tool_input.file_path // .tool_input.filePath // .tool_input.notebook_path // .tool_input.path // "")"' 2>/dev/null); then
  echo "BLOCKED: guard.sh could not read the hook payload's fields. Failing closed." >&2
  exit 2
fi
eval "$parsed"

cursor=0
case "$event" in
  beforeShellExecution) cursor=1; tool="Bash"; cmd=$(field '.command') ;;
  beforeReadFile) cursor=1; tool="Read"; file_path=$(field '.file_path') ;;
esac

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
  Read|Grep|Glob|LS|NotebookRead|read_file|readFile|list_dir|listDirectory|file_search|grep_search) tool="Read" ;;
  *)
    if [ -n "$cmd" ]; then tool="Bash"
    elif [ -n "$file_path" ]; then tool="Write"
    fi ;;
esac

lower() { tr '[:upper:]' '[:lower:]'; }

# shellcheck disable=SC2016
normalize() {
  printf '%s\n' "$1" | sed -E 's#([A-Za-z]):\\#\1:/#g' | tr -d "\"'\\\\" | lower | sed -E \
    -e 's#(^|[[:space:];&|(`])[a-z]:/#\1/#g' \
    -e 's#(^|[[:space:];&|(`])[a-z]:([[:space:]]|$)#\1/\2#g' \
    -e 's#(^|[[:space:];&|(`/])(rm|git|find|sudo|dd|chmod|eval|shutdown|reboot|halt|poweroff|env|xargs|(ba|z|da|k|fi|c|tc)?sh)\.exe([[:space:]]|$)#\1\2\4#g' \
    -e 's#(^|[[:space:];&|(`])/[^[:space:];&|()`]*/(rm|git|find|sudo|dd|chmod|eval|shutdown|reboot|halt|poweroff|env|xargs|(ba|z|da|k|fi|c|tc)?sh)([[:space:]]|$)#\1\2\4#g' \
    -e ':a' \
    -e 's#(^|[^[:alnum:]_-])git[[:space:]]+(-c[[:space:]]+[^[:space:]]+|--git-dir(=|[[:space:]]+)[^[:space:]]+|--work-tree(=|[[:space:]]+)[^[:space:]]+|--namespace(=|[[:space:]]+)[^[:space:]]+|--no-pager|-p|--paginate|--bare|--no-replace-objects|--literal-pathspecs)([[:space:]]|$)#\1git #' \
    -e 'ta'
}

segments() { printf '%s\n' "$1" | tr ';&|()`' '\n'; }

read_only_shell() {
  case "$1" in *\>*|*\$\(*|*\`*|*\<\(*|*--output*|*--pre*) return 1 ;; esac
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
  done < <(segments "$1")
  return 0
}

secret_path() {
  echo "$1" | lower | grep -qE '(^|/)\.env(\.[a-z0-9_.-]+)?$|(^|/)secrets/|\.pem$|\.key$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|_rsa$|(^|/)\.ssh/' \
    && ! echo "$1" | lower | grep -qE '\.env\.(example|sample|template|dist)$'
}

secret_in_shell() {
  local seg words w
  while IFS= read -r seg; do
    case "$seg" in *.gitignore*) continue ;; esac
    read -ra words <<< "$seg"
    if [ "${words[0]:-}" = cp ] && [ ${#words[@]} -eq 3 ] \
       && echo "${words[1]}" | grep -qE '\.env\.(example|sample|template|dist)$' \
       && echo "${words[2]}" | grep -qE '(^|/)\.env$'; then
      continue
    fi
    for w in "${words[@]}"; do
      secret_path "$w" && return 0
    done
  done < <(segments "$1")
  return 1
}

protected_name() {
  echo "$1" | lower | grep -qE "$2"
}

if [ -n "$file_path" ] && secret_path "$file_path"; then
  block "BLOCKED: $file_path looks like a secret (.env, key, secrets/). Ask the human for the value you need instead."
fi

if [ -n "$agent_id" ]; then
  if [ "$tool" = "Write" ]; then
    protected_name "$file_path" 'task-tree\.json' \
      && block "BLOCKED: task-tree.json is written by the Director only. Return your verdict as text."
    protected_name "$file_path" 'log\.jsonl' \
      && block "BLOCKED: vault/log.jsonl is written by the Director only (log-event.sh). Return your verdict as text."
  fi
  if [ "$tool" = "Bash" ]; then
    plain=$(normalize "$cmd")
    protected_name "$plain" 'log-event' \
      && block "BLOCKED: vault/log.jsonl is written by the Director only (log-event.sh). Return your verdict as text."
    if protected_name "$plain" 'vault|task-tree|log\.jsonl' && ! read_only_shell "$plain"; then
      protected_name "$plain" 'task-tree' \
        && block "BLOCKED: task-tree.json is written by the Director only. Return your verdict as text."
      protected_name "$plain" 'log\.jsonl' \
        && block "BLOCKED: vault/log.jsonl is written by the Director only (log-event.sh). Return your verdict as text."
      block "BLOCKED: a subagent's shell commands may only read vault/ (cat, grep, jq, git diff/log/show, no redirects). Use the Write tool for a vault file your manifest names."
    fi
  fi
fi

task_tree() {
  local dir common
  dir=$(field '.cwd')
  [ -n "$dir" ] && [ -d "$dir" ] || dir=.
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -f "$(dirname "$common")/vault/task-tree.json" ] || return 1
  printf '%s\n' "$(dirname "$common")/vault/task-tree.json"
}

require_hardening() {
  local tree slice triggers
  tree=$(task_tree) || return 0
  slice=$(printf '%s\n' "$1" | sed -n 's/^SLICE:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
  [ -n "$slice" ] \
    || block "BLOCKED: builder brief has no SLICE: <ID> line. guard.sh reads the slice's auditor_triggers from task-tree.json to check the brief names harden-diff."
  triggers=$(jq -r --arg id "$slice" '
    [.slices[]? | select(.id == $id)] as $s
    | if ($s | length) == 0 then "NOSLICE"
      elif ($s[0].auditor_triggers | type) != "array" then "NOFIELD"
      else $s[0].auditor_triggers | join(", ") end' "$tree" 2>/dev/null) \
    || block "BLOCKED: vault/task-tree.json is not valid JSON, so the builder brief's hardening can't be checked. Failing closed."
  case "$triggers" in
    NOSLICE) block "BLOCKED: SLICE $slice is not in vault/task-tree.json. Copy the approved slice in before dispatching its builder." ;;
    NOFIELD) block "BLOCKED: slice $slice in vault/task-tree.json has no auditor_triggers. Add the trust boundaries it crosses, [] for none (slice-planning skill)." ;;
    "") return 0 ;;
  esac
  printf '%s\n' "$1" | awk '/^[A-Z]+:/ { on = ($0 ~ /^STANDING:/) } on' | grep -q 'harden-diff' \
    || block "BLOCKED: slice $slice crosses trust boundaries ($triggers), so the builder brief's STANDING must name the harden-diff skill (brief-contract skill)."
}

if [ "$tool" = "Agent" ] || [ "$tool" = "Task" ]; then
  case "$(field '.tool_input.subagent_type')" in
    builder|reviewer|auditor)
      prompt=$(field '.tool_input.prompt')
      missing=()
      for h in GOAL SCOPE ACCEPTANCE VERIFY FORBIDDEN REPORT STANDING; do
        printf '%s\n' "$prompt" | grep -q "^$h:" || missing+=("$h")
      done
      [ ${#missing[@]} -gt 0 ] \
        && block "BLOCKED: brief is missing required header(s): ${missing[*]}. See the brief-contract skill; STANDING pastes vault/standing-orders.md verbatim."
      [ "$(field '.tool_input.subagent_type')" = "builder" ] && require_hardening "$prompt"
      ;;
  esac
  allow
fi

if [ "$tool" = "mcp__claude-in-chrome__navigate" ] || [ "$tool" = "mcp__claude-in-chrome__tabs_create_mcp" ]; then
  raw_url=$(field '.tool_input.url')
  if [ -z "$raw_url" ]; then
    [ "$tool" = "mcp__claude-in-chrome__tabs_create_mcp" ] && allow
    block "BLOCKED: navigate without a url."
  fi
  case "$raw_url" in *[[:space:][:cntrl:]]*)
    block "BLOCKED: url contains whitespace or control characters." ;;
  esac
  url=$(printf '%s' "$raw_url" | lower)
  case "$url" in back|forward) allow ;; esac
  authority=$(printf '%s\n' "$url" | sed -nE 's#^https?://([^/?#]*).*#\1#p')
  printf '%s\n' "$authority" | LC_ALL=C grep -qE '^(localhost|127\.0\.0\.1|\[::1\]|([a-z0-9-]+\.)+(local|localhost|test))(:[0-9]+)?$' \
    || block "BLOCKED: browser navigation is limited to http(s) on localhost, 127.0.0.1, [::1], *.local, *.localhost, *.test (got: $raw_url)."
  allow
fi

[ "$tool" = "Bash" ] || allow
[ -z "$cmd" ] && allow

plain=$(normalize "$cmd")

if secret_in_shell "$plain"; then
  block "BLOCKED: this command touches a secret (.env, key, secrets/). Ask the human for the value you need instead."
fi

dangerous_target() {
  case "$1" in
    /|/*|\~|\~/*|\~*|\$*|\{*|.|./|..|../*|\*) return 0 ;;
  esac
  return 1
}

rm_catastrophic() {
  local seg words w in_rm r targets t
  while IFS= read -r seg; do
    read -ra words <<< "$seg"
    in_rm=0 r=0 targets=()
    for w in "${words[@]}"; do
      if [ "$in_rm" -eq 0 ]; then
        [ "$w" = rm ] && in_rm=1
        continue
      fi
      case "$w" in
        --recursive) r=1 ;;
        --*) ;;
        -*) [[ $w == *r* ]] && r=1 ;;
        *) targets+=("$w") ;;
      esac
    done
    [ "$r" -eq 1 ] || continue
    for t in "${targets[@]}"; do
      dangerous_target "$t" && return 0
    done
  done < <(segments "$1")
  return 1
}

find_catastrophic() {
  local seg words
  while IFS= read -r seg; do
    read -ra words <<< "$seg"
    [ "${words[0]:-}" = find ] || continue
    dangerous_target "${words[1]:-}" || continue
    case " $seg " in *" -delete "*|*" -exec rm "*|*" -execdir rm "*|*" -ok rm "*) return 0 ;; esac
  done < <(segments "$1")
  return 1
}

if rm_catastrophic "$plain"; then
  block "BLOCKED by guardrail: recursive rm of /, ~, a \$VARIABLE, . or .. — spell out a named subdirectory instead."
fi
if find_catastrophic "$plain"; then
  block "BLOCKED by guardrail: find that deletes under /, ~, a \$VARIABLE, . or .. — spell out a named subdirectory instead."
fi

git_destructive='git[[:space:]]+(reset|clean|push|branch|checkout|restore|switch|stash)([[:space:]]|$)'
deny_patterns=(
  ':[[:space:]]*>[[:space:]]*/'
  'mkfs'
  '(^|[^[:alnum:]_-])dd[[:space:]]+if='
  '>[[:space:]]*/dev/sd'
  'git[[:space:]]+push.*--force'
  'git[[:space:]]+push.*[[:space:]]-[a-z]*f[a-z]*([[:space:]]|$)'
  'git[[:space:]]+push.*[[:space:]]\+[^[:space:]]'
  'git[[:space:]]+push.*[[:space:]](--delete|-d|--mirror|--prune)([[:space:]]|$)'
  'git[[:space:]]+push.*[[:space:]]:[^[:space:]]'
  'git[[:space:]]+reset[[:space:]]+(.*[[:space:]])?(--hard|--merge|--keep)'
  'git[[:space:]]+clean[[:space:]]+(.*[[:space:]])?-[a-z]*f'
  'git[[:space:]]+(checkout|restore)[[:space:]]+(.*[[:space:]])?\.([[:space:]]|$)'
  'git[[:space:]]+(checkout|switch)[[:space:]]+(.*[[:space:]])?(-f|--force|--discard-changes)([[:space:]]|$)'
  'git[[:space:]]+stash[[:space:]]+(drop|clear)'
  'git[[:space:]]+branch[[:space:]]+(.*[[:space:]])?(-d|--delete)[[:space:]]+(.*[[:space:]])?(main|master)([[:space:]]|$)'
  'git[[:space:]]+update-ref[[:space:]]+-d'
  'git[[:space:]]+filter-(branch|repo)'
  '(^|[^[:alnum:]_-])sudo[[:space:]]'
  '\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?(ba|z|da|k|fi|c|tc)?sh([[:space:]]|$)'
  '(^|[;&|(][[:space:]]*)eval[[:space:]]'
  '(^|[;&|][[:space:]]*)(\$\(|`)'
  '(ba|z|da|k)?sh[[:space:]]+-c[[:space:]]+.*(\$\(|`|base64)'
  'chmod[[:space:]]+(-r[[:space:]]+)?[0-7]*777'
  '--no-verify'
  'history[[:space:]]+-c'
  '(^|[;&|][[:space:]]*)(shutdown|reboot|halt|poweroff)([[:space:]]|$)'
  'drop[[:space:]]+(table|database|schema)'
  'truncate[[:space:]]+table'
)

for p in "${deny_patterns[@]}"; do
  if echo "$cmd" | lower | grep -qE -- "$p" || echo "$plain" | grep -qE -- "$p"; then
    block "BLOCKED by guardrail (pattern: $p). Use a reversible approach instead."
  fi
done

while IFS= read -r seg; do
  if echo "$seg" | grep -qE "$git_destructive" && echo "$seg" | grep -q '\$'; then
    block "BLOCKED by guardrail: a destructive git command with a \$variable — the guard can't see what it expands to. Spell the arguments out."
  fi
done < <(segments "$cmd")

allow
