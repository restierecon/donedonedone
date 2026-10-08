#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: guard.sh requires jq and it is not installed (brew install jq · winget install jqlang.jq · apt install jq). Failing closed." >&2
  exit 2
fi

input=$(cat)
here="$(cd "$(dirname "$0")" && pwd)"
if ! echo "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "BLOCKED: guard.sh could not parse the hook payload. Failing closed." >&2
  exit 2
fi

field() { echo "$input" | jq -r "$1 // empty"; }
event="" tool="" agent_id="" cmd="" file_path=""
if ! parsed=$(echo "$input" | jq -r '@sh "event=\(.hook_event_name // "") tool=\(.tool_name // "") agent_id=\(.agent_id // "") cmd=\(.tool_input.command // ([.tool_input.task.command // empty] + (.tool_input.task.args // []) | map(tostring) | join(" "))) file_path=\([.tool_input.file_path, .tool_input.filePath, .tool_input.notebook_path, .tool_input.path, .tool_input.replacements[]?.filePath?, (.tool_input.input | strings | scan("(?m)^\\*\\*\\* (?:(?:Add|Update|Delete) File|Move to): (.+)$") | .[0])] | map(strings) | unique | join("\n"))"' 2>/dev/null); then
  echo "BLOCKED: guard.sh could not read the hook payload's fields. Failing closed." >&2
  exit 2
fi
eval "$parsed"

cursor=0
case "$event" in
  beforeShellExecution) cursor=1; tool="Bash"; cmd=$(field '.command') ;;
  beforeReadFile) cursor=1; tool="Read"; file_path=$(field '.file_path') ;;
  preToolUse) cursor=1 ;;
esac

block() {
  echo "$1" >&2
  [ "$cursor" -eq 1 ] && jq -cn --arg m "$1" '{permission: "deny", agent_message: $m, user_message: $m, agentMessage: $m, userMessage: $m}'
  exit 2
}
allow() {
  [ "$cursor" -eq 1 ] && echo '{"permission":"allow"}'
  exit 0
}

case "$tool" in
  Bash|Shell|runTerminalCommand|run_in_terminal|send_to_terminal|create_and_run_task) tool="Bash" ;;
  Agent|Task|runSubagent) tool="Agent" ;;
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
    -e 'ta' \
    -e ':b' -e 's#/\.?/#/#g' -e 'tb'
}

segments() { printf '%s\n' "$1" | tr ';&|()`' '\n'; }

read_only_shell() {
  case "$1" in *\>*|*\$\(*|*\`*|*\<\(*|*--output*|*--pre*) return 1 ;; esac
  local seg words git_ok=" log show diff status blame grep ${2:-} "
  while IFS= read -r seg; do
    read -ra words <<< "$seg"
    [ ${#words[@]} -eq 0 ] && continue
    case "${words[0]}" in
      cat|head|tail|less|grep|egrep|rg|jq|wc|ls|stat|file|diff|test|'[') ;;
      git)
        case "$git_ok" in
          *" ${words[1]:-} "*) ;;
          *) return 1 ;;
        esac ;;
      *) return 1 ;;
    esac
  done < <(segments "$1")
  return 0
}

secret_path() {
  printf '%s\n' "$1" | lower | grep -vE '\.env\.(example|sample|template|dist)$' \
    | grep -qE '(^|/)\.env(\.[a-z0-9_.-]+)?$|(^|/)secrets/|\.pem$|\.key$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|_rsa$|(^|/)\.ssh/'
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
      secret_glob "$w" && return 0
    done
  done < <(segments "$1")
  return 1
}

has_glob() { case "$1" in *[*?[]*) return 0 ;; esac; return 1; }

secret_glob() {
  local part name
  has_glob "$1" || return 1
  IFS=/ read -ra parts <<< "$1"
  for part in "${parts[@]}"; do
    has_glob "$part" || continue
    for name in .env .env.local .env.production .env.development .ssh id_rsa id_dsa id_ecdsa id_ed25519 secrets; do
      case "$name:$part" in .*:.*|[!.]*:*[a-z0-9_-]*[a-z0-9_-]*) ;; *) continue ;; esac
      # shellcheck disable=SC2053
      [[ $name == $part ]] && return 0
    done
  done
  return 1
}

protected_name() {
  echo "$1" | lower | grep -qE "$2"
}

vault_project() {
  local dir common
  dir=$(field '.cwd')
  [ -n "$dir" ] && [ -d "$dir" ] || dir=.
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -d "$(dirname "$common")/vault" ]
}

HUMAN_ONLY_MSG="BLOCKED: approvals and the risk policy are human-only. A human runs ~/.claude/scripts/approve-risk.sh or approve-ui.sh in their own terminal, never through an agent, and edits vault/risk-policy.json themselves. Tell the human what needs their decision and continue with other work."

human_only_path() {
  echo "$1" | lower | grep -qE '(^|/)vault/risk-policy\.json$|(^|/)\.git/(donedonedone|skeletoncrew-vault-guard)(/|$)'
}

lexical() {
  local part lead="" out=() n
  case "$1" in /*) lead=/ ;; esac
  IFS=/ read -ra parts <<< "$1"
  for part in "${parts[@]}"; do
    n=${#out[@]}
    case "$part" in
      ''|.) ;;
      ..)
        if [ "$n" -gt 0 ] && [ "${out[$((n - 1))]}" != .. ]; then unset "out[$((n - 1))]"; out=("${out[@]}")
        elif [ -z "$lead" ]; then out+=(..)
        fi ;;
      *) out+=("$part") ;;
    esac
  done
  local IFS=/
  printf '%s%s\n' "$lead" "${out[*]}"
}

resolve_file() {
  local p="$1" t d rest="" n=0
  case "$p" in /*) ;; *) p="$(field '.cwd')/$p" ;; esac
  p=$(lexical "$p")
  while [ -L "$p" ] && [ "$n" -lt 16 ]; do
    t=$(readlink "$p") || break
    case "$t" in /*) p=$(lexical "$t") ;; *) p=$(lexical "$(dirname "$p")/$t") ;; esac
    n=$((n + 1))
  done
  d=$(dirname "$p")
  while [ ! -d "$d" ] && [ "$d" != / ] && [ "$d" != . ]; do rest="/$(basename "$d")$rest"; d=$(dirname "$d"); done
  d=$(cd -P "$d" 2>/dev/null && pwd -P) || { printf '%s\n' "$p"; return; }
  printf '%s%s/%s\n' "${d%/}" "$rest" "$(basename "$p")"
}

file_forms() {
  printf '%s\n' "$1"
  case "$1" in *\\*) return ;; esac
  resolve_file "$1"
}

FAKE_HUMAN_MSG="BLOCKED: in a vault project an agent may not allocate a pseudo-terminal or scrub its environment (script, expect, unbuffer, pty, CLAUDECODE, env -i) — those are the means to pass for a human at approve-risk.sh. Tell the human what needs their decision and continue with other work."

fakes_human() {
  local seg words
  printf '%s\n' "$1" | grep -qE 'claudecode|(^|[^[:alnum:]_])(pty\.(spawn|fork|openpty)|forkpty|openpty|import[[:space:]]+pty|from[[:space:]]+pty|pexpect|node-pty|posix_openpt)([^[:alnum:]_]|$)|(^|[^[:alnum:]_-])env[[:space:]]+(-[a-z]*i|--ignore-environment)([[:space:]]|$)' && return 0
  while IFS= read -r seg; do
    read -ra words <<< "$seg"
    case "${words[0]:-}" in script|unbuffer|expect|socat|empty|ptyrun|faketty|winpty) return 0 ;; esac
  done < <(segments "$1")
  return 1
}

repo_dirs() {
  local dir
  dir=$(field '.cwd')
  [ -n "$dir" ] && [ -d "$dir" ] || dir=.
  g_common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  g_common=$(cd -P "$g_common" && pwd -P) || return 1
  g_root=$(dirname "$g_common")
  g_cwd=$(cd -P "$dir" && pwd -P)
}

sensitive_paths() {
  local d f
  for d in "$g_common/donedonedone" "$g_common/skeletoncrew-vault-guard"; do
    printf '%s\n' "$d"
    [ -d "$d" ] && for f in "$d"/* "$d"/.[!.]*; do [ -e "$f" ] && printf '%s\n' "$f"; done
  done
  printf '%s\n' "$g_root/vault/risk-policy.json" "$g_common/donedonedone/approvals.jsonl" "$(cd -P "$here" && pwd -P)/approve-risk.sh" "$(cd -P "$here" && pwd -P)/approve-ui.sh"
  [ "${1:-}" = subagent ] && printf '%s\n' "$g_root/vault" "$g_root/vault/task-tree.json" "$g_root/vault/log.jsonl"
}

component_match() {
  case "$1" in .*) case "$2" in .*) ;; *) return 1 ;; esac ;; esac
  # shellcheck disable=SC2053
  [[ $1 == $2 ]]
}

suffix_match() {
  local s="$1" pat="$2" whole="${3:-}" sp pp i j
  IFS=/ read -ra sp <<< "${s#/}"
  IFS=/ read -ra pp <<< "${pat#/}"
  [ ${#pp[@]} -le ${#sp[@]} ] || return 1
  [ -z "$whole" ] || [ ${#pp[@]} -eq ${#sp[@]} ] || return 1
  i=$((${#sp[@]} - 1)); j=$((${#pp[@]} - 1))
  while [ "$j" -ge 0 ]; do
    case "${pp[$j]}" in ''|.) j=$((j - 1)); continue ;; ..) return 0 ;; esac
    component_match "${sp[$i]}" "${pp[$j]}" || return 1
    i=$((i - 1)); j=$((j - 1))
  done
  return 0
}

physical() {
  local p="$1" head="" rest="" part
  IFS=/ read -ra parts <<< "${p#/}"
  for part in "${parts[@]}"; do
    if [ -z "$rest" ] && ! has_glob "$part" && [ -d "$head/$part" ]; then head="$head/$part"; else rest="$rest/$part"; fi
  done
  [ -n "$head" ] && head=$(cd -P "$head" 2>/dev/null && pwd -P)
  printf '%s%s\n' "$head" "$rest"
}

word_paths() {
  local w="$1"
  w="${w#[0-9]}"; w="${w#&}"; w="${w#>}"; w="${w#>}"; w="${w#<}"
  case "$w" in --*=*) w="${w#*=}" ;; esac
  case "$w" in \~|\~/*) w="$HOME${w#\~}" ;; esac
  [ -n "$w" ] && printf '%s\n' "$w"
}

touches_sensitive() {
  local cmd_raw="$1" who="${2:-}" seg words w path cwd known=1 sens
  printf '%s\n' "$cmd_raw" | grep -qE '[*?[]|\.\.|//|/\./|~|(^|[;&|(`[:space:]])(cd|pushd)([[:space:]]|$)' || return 1
  repo_dirs || return 1
  sens=$(sensitive_paths "$who" | lower)
  cwd="$g_cwd"
  while IFS= read -r seg; do
    read -ra words <<< "$seg"
    [ ${#words[@]} -eq 0 ] && continue
    case "${words[0]}" in
      cd|pushd)
        w="${words[1]:-$HOME}"
        case "$w" in \~|\~/*) w="$HOME${w#\~}" ;; esac
        if has_glob "$w" || [ "${w#*\$}" != "$w" ] || [ "$w" = - ]; then known=0
        else case "$w" in /*) cwd=$(lexical "$w") ;; *) cwd=$(lexical "$cwd/$w") ;; esac
        fi
        continue ;;
    esac
    for w in "${words[@]}"; do
      w=$(word_paths "$w") || continue
      case "$w" in */*|*[*?[]*|.*) ;; *) has_glob "$w" || continue ;; esac
      case "$w" in /*) path=$(lexical "$w") ;; *) path=$(lexical "$cwd/$w") ;; esac
      path=$(physical "$path" | lower)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        suffix_match "$s" "$path" whole && return 0
        if [ "$known" -eq 0 ] || [ "${w#*..}" != "$w" ]; then suffix_match "$s" "$(printf '%s' "$w" | lower)" && return 0; fi
      done <<< "$sens"
    done
  done < <(segments "$(printf '%s\n' "$cmd_raw" | tr -d "\"'\\\\")")
  return 1
}

if [ -n "$file_path" ]; then
  forms=$(printf '%s\n' "$file_path" | while IFS= read -r fp; do [ -n "$fp" ] && file_forms "$fp"; done)
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    secret_path "$fp" \
      && block "BLOCKED: $file_path looks like a secret (.env, key, secrets/). Ask the human for the value you need instead."
    [ "$tool" != "Read" ] && human_only_path "$fp" && block "$HUMAN_ONLY_MSG"
  done <<< "$forms"
  file_path="$file_path"$'\n'"$forms"
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
    protected_name "$plain" 'risk-gate' && ! read_only_shell "$plain" && vault_project \
      && block "BLOCKED: risk-gate.sh is the Director's: it records risk assessments and judges merges. If your work needs files outside the approved scope, stop and report SCOPE-EXPANSION."
    if ! read_only_shell "$plain" && vault_project && touches_sensitive "$cmd" subagent; then
      block "BLOCKED: a subagent's shell commands may only read vault/ and may not touch the human-only approvals or risk policy. Use the Write tool for a vault file your manifest names."
    fi
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

require_ui_contract() {
  local tree slice contract root standing verdict
  tree=$(task_tree) || return 0
  slice=$(printf '%s\n' "$1" | sed -n 's/^SLICE:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
  contract=$(jq -r --arg id "$slice" '[.slices[]? | select(.id == $id)][0].ui_contract // empty | strings' "$tree" 2>/dev/null) \
    || block "BLOCKED: vault/task-tree.json is not valid JSON, so the builder brief's UI contract can't be checked. Failing closed."
  [ -n "$contract" ] || return 0
  root=$(dirname "$(dirname "$tree")")
  verdict=$(cd "$root" && "$here/ui-approval.sh" check "$contract" 2>&1) \
    || block "BLOCKED: slice $slice builds to a UI design no human has approved as it stands — ${verdict#UI: }. Put the command in vault/flags/pending-review.md and continue with other work."
  standing=$(printf '%s\n' "$1" | awk '/^[A-Z]+:/ { on = ($0 ~ /^STANDING:/) } on')
  if ! printf '%s\n' "$standing" | grep -q 'frontend-ui-engineering' || ! printf '%s\n' "$standing" | grep -qF "$contract"; then
    block "BLOCKED: slice $slice renders UI, so the builder brief's STANDING must name the frontend-ui-engineering skill and the approved contract $contract (brief-contract skill)."
  fi
}

require_risk() {
  local tree slice dir out status class brief_class model
  tree=$(task_tree) || return 0
  slice=$(printf '%s\n' "$1" | sed -n 's/^SLICE:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
  dir=$(field '.cwd')
  [ -n "$dir" ] && [ -d "$dir" ] || dir=.
  status=0
  out=$(cd "$dir" && "$here/risk-gate.sh" check "$slice" build 2>&1) || status=$?
  [ "$status" -eq 0 ] \
    || block "BLOCKED: the risk gate refuses to start $slice (risk-gate skill):
$(printf '%s\n' "$out" | tail -16)"
  class=$(printf '%s\n' "$out" | sed -n 's/^RISK: PASS build [^ ]* class=\([a-z]*\).*/\1/p' | tail -1)
  [ -n "$class" ] || block "BLOCKED: the risk gate gave no class for $slice. Failing closed."
  brief_class=$(printf '%s\n' "$1" | sed -n 's/^RISK:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1 | lower)
  [ "$brief_class" = "$class" ] \
    || block "BLOCKED: slice $slice is $class risk, so the builder brief needs a line 'RISK: $class — <scope, unchanged behavior, rollback>' (brief-contract skill; got '${brief_class:-none}')."
  model=$(field '.tool_input.model' | lower)
  case "$class:$model" in
    elevated:*sonnet*|elevated:*haiku*|high:*sonnet*|high:*haiku*|critical:*sonnet*|critical:*haiku*)
      block "BLOCKED: slice $slice is $class risk; its builder inherits the session model (drop model: $model)." ;;
  esac
}

if [ "$tool" = "Agent" ]; then
  subagent=$(field '.tool_input.subagent_type // .tool_input.agentName')
  case "$subagent" in
    builder|reviewer|auditor)
      prompt=$(field '.tool_input.prompt')
      missing=()
      for h in GOAL SCOPE ACCEPTANCE VERIFY FORBIDDEN REPORT STANDING; do
        printf '%s\n' "$prompt" | grep -q "^$h:" || missing+=("$h")
      done
      [ ${#missing[@]} -gt 0 ] \
        && block "BLOCKED: brief is missing required header(s): ${missing[*]}. See the brief-contract skill; STANDING pastes vault/standing-orders.md verbatim."
      if [ "$subagent" = "builder" ]; then
        require_hardening "$prompt"
        require_ui_contract "$prompt"
        require_risk "$prompt"
      fi
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

if protected_name "$plain" 'approvals\.jsonl|risk-policy|approve-risk|approve-ui|vault-guard[^[:space:]]*[[:space:]]+--|--human-snapshot|\.git/(donedonedone|skeletoncrew-vault-guard)' \
   && ! read_only_shell "$plain" "add commit" && vault_project; then
  block "$HUMAN_ONLY_MSG"
fi

if vault_project && ! read_only_shell "$plain" "add commit"; then
  fakes_human "$plain" && block "$FAKE_HUMAN_MSG"
  touches_sensitive "$cmd" && block "$HUMAN_ONLY_MSG"
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

rebase_lands() {
  local words=() w i=0 skip="" first=""
  read -ra words <<< "$1"
  while [ "$i" -lt ${#words[@]} ] && [ "${words[$i]}" != rebase ]; do i=$((i + 1)); done
  for w in "${words[@]:$((i + 1))}"; do
    if [ -n "$skip" ]; then
      [ "$skip" = onto ] && case "$w" in slice/*) printf '%s\n' "$w" ;; esac
      skip=""
      continue
    fi
    case "$w" in
      --onto) skip=onto ;;
      --onto=slice/*) printf '%s\n' "${w#--onto=}" ;;
      -s|-x|--strategy|--exec|--strategy-option) skip=value ;;
      -*) ;;
      *) [ -z "$first" ] && first="$w" ;;
    esac
  done
  case "$first" in slice/*) printf '%s\n' "$first" ;; esac
}

landing_slices() {
  local seg plain_seg sub refs
  while IFS= read -r seg; do
    plain_seg=$(normalize "$seg")
    sub=$(printf '%s\n' "$plain_seg" | sed -nE 's/^(.*[^[:alnum:]_-])?git[[:space:]]+([a-z-]+).*/\2/p' | head -1)
    refs=""
    case "$sub" in
      merge|cherry-pick|pull|reset|update-ref)
        refs=$(printf '%s\n' "$plain_seg" | grep -oE 'slice/[a-z0-9._-]+') ;;
      rebase)
        refs=$(rebase_lands "$plain_seg") ;;
      branch|checkout|switch)
        printf '%s\n' "$plain_seg" | grep -qE '[[:space:]](-f|--force|-b|-c)[[:space:]]+(main|master)([[:space:]]|$)' \
          && refs=$(printf '%s\n' "$plain_seg" | grep -oE 'slice/[a-z0-9._-]+') ;;
      push)
        refs=$(printf '%s\n' "$plain_seg" | grep -oE 'slice/[a-z0-9._-]+:(refs/heads/)?(main|master)([[:space:]]|$)' | cut -d: -f1) ;;
    esac
    [ -n "$refs" ] || continue
    printf '%s\n' "$refs" | while IFS= read -r ref; do
      printf '%s\n' "$seg" | grep -oiE "slice/[A-Za-z0-9._-]+" | while IFS= read -r raw; do
        [ "$(printf '%s' "$raw" | lower)" = "$ref" ] && printf '%s\n' "${raw#slice/}"
      done | head -1
    done
  done < <(segments "$cmd") | awk '!seen[$0]++'
}

if task_tree >/dev/null; then
  dir=$(field '.cwd')
  [ -n "$dir" ] && [ -d "$dir" ] || dir=.
  while IFS= read -r slice_id; do
    [ -n "$slice_id" ] || continue
    status=0
    out=$(cd "$dir" && "$here/risk-gate.sh" check "$slice_id" merge 2>&1) || status=$?
    [ "$status" -eq 0 ] || block "BLOCKED: slice/$slice_id can't land on main until the risk gate passes (risk-gate skill):
$(printf '%s\n' "$out" | tail -16)"
  done < <(landing_slices)
fi

allow
