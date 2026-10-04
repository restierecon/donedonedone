#!/bin/bash

command -v jq >/dev/null 2>&1 || exit 0

mode="${1:-hook}"
input=""
[ "$mode" = "hook" ] && input=$(cat)
event="" agent_id="" agent_type="" tool="" cmd="" file_path="" cwd=""
if [ -n "$input" ]; then
  eval "$(echo "$input" | jq -r '@sh "event=\(.hook_event_name // "") agent_id=\(.agent_id // "") agent_type=\(.agent_type // "") tool=\(.tool_name // "") cmd=\(.tool_input.command // "") file_path=\(.tool_input.file_path // .tool_input.filePath // .tool_input.notebook_path // .tool_input.path // "") cwd=\(.cwd // "")"' 2>/dev/null)"
fi
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || exit 0; fi

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
main_root=$(dirname "$common")
[ -d "$main_root/vault" ] || exit 0

state="$common/skeletoncrew-vault-guard"
busy="$state/director-busy"
mkdir -p "$state" || exit 0

protected=(vault/task-tree.json vault/log.jsonl)

key() { printf '%s' "$1" | tr '/' '_'; }

snapshot() {
  local f="$1" k
  k=$(key "$f")
  if [ -e "$main_root/$f" ]; then
    cp -p "$main_root/$f" "$state/$k"
    rm -f "$state/$k.absent"
  else
    rm -f "$state/$k"
    touch "$state/$k.absent"
  fi
}

snapshot_all() {
  local f
  for f in "${protected[@]}"; do snapshot "$f"; done
}

has_snapshot() {
  local k
  k=$(key "$1")
  [ -e "$state/$k" ] || [ -e "$state/$k.absent" ]
}

changed() {
  local f="$1" k
  k=$(key "$f")
  if [ -e "$state/$k.absent" ]; then
    [ -e "$main_root/$f" ]
  else
    ! cmp -s "$main_root/$f" "$state/$k"
  fi
}

restore() {
  local f="$1" k
  k=$(key "$f")
  if [ -e "$state/$k.absent" ]; then
    rm -f "$main_root/$f"
  else
    mkdir -p "$(dirname "$main_root/$f")"
    cp -p "$state/$k" "$main_root/$f"
  fi
}

director_may_touch_vault() {
  case "$tool" in
    Bash|runTerminalCommand|run_in_terminal)
      echo "$cmd" | grep -qiE 'vault|task-tree|log\.jsonl|log-event|(^|[^[:alnum:]_-])git[[:space:]]' ;;
    *)
      [ -n "$file_path" ] && echo "$file_path" | grep -qi 'vault' ;;
  esac
}

busy_fresh() {
  [ -n "$(find "$busy" -mmin -10 2>/dev/null)" ]
}

if [ "$mode" = "--snapshot" ]; then
  snapshot_all
  rm -f "$busy"
  exit 0
fi

if [ -z "$agent_id" ]; then
  case "$event" in
    PreToolUse)
      director_may_touch_vault && touch "$busy"
      exit 0 ;;
    PostToolUse|PostToolUseFailure)
      if [ -e "$busy" ]; then
        snapshot_all
        rm -f "$busy"
        exit 0
      fi
      drifted=()
      for f in "${protected[@]}"; do
        if ! has_snapshot "$f"; then snapshot "$f"; continue; fi
        if changed "$f"; then drifted+=("$f"); snapshot "$f"; fi
      done
      if [ ${#drifted[@]} -gt 0 ]; then
        echo "VAULT CHANGED during a call that shouldn't touch it: ${drifted[*]}. If you didn't do this, a subagent did — check 'git diff -- ${drifted[*]}' before trusting it." >&2
        exit 2
      fi
      exit 0 ;;
  esac
  exit 0
fi

case "$event" in
  PostToolUse|PostToolUseFailure|SubagentStop) ;;
  *) exit 0 ;;
esac

busy_fresh && exit 0

restored=()
for f in "${protected[@]}"; do
  if ! has_snapshot "$f"; then snapshot "$f"; continue; fi
  changed "$f" || continue
  restore "$f"
  restored+=("$f")
done

if [ ${#restored[@]} -gt 0 ]; then
  echo "RESTORED: ${restored[*]} — changed by subagent '${agent_type:-unknown}'. These files are the Director's; your change was undone. Return your verdict as text." >&2
  exit 2
fi
exit 0
