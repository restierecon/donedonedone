#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
event="" agent_type="" agent_id="" sub_transcript="" main_transcript="" cwd="" session=""
eval "$(printf '%s' "$input" | jq -r '@sh "event=\(.hook_event_name // "") agent_type=\(.agent_type // "") agent_id=\(.agent_id // "") sub_transcript=\(.agent_transcript_path // "") main_transcript=\(.transcript_path // "") cwd=\(.cwd // "") session=\(.session_id // "")"' 2>/dev/null)" || exit 0
case "$event" in
  SubagentStop)
    [ -n "$agent_type" ] || exit 0
    agent="$agent_type" transcript="$sub_transcript" ;;
  Stop)
    session=$(printf '%s' "$session" | tr -cd 'A-Za-z0-9_-')
    [ -n "$session" ] || exit 0
    agent="director" agent_id="" transcript="$main_transcript" ;;
  *) exit 0 ;;
esac
case "$transcript" in \~/*) transcript="$HOME/${transcript#\~/}" ;; esac
[ -f "$transcript" ] || exit 0
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || exit 0; fi

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
main_root=$(dirname "$common")
[ -d "$main_root/vault" ] || exit 0
dir="$common/donedonedone"
ledger="$dir/usage.jsonl"
lock="$dir/usage.lock"
cursor_file="$dir/usage-state/$session"
snapshot=""
case "$common" in
  "$main_root"/*) snapshot="$common/skeletoncrew-vault-guard/$(printf '%s' "${common#"$main_root"/}/donedonedone/usage.jsonl" | tr '/' '_')" ;;
esac

skip=0 last_id=""
if [ "$agent" = "director" ] && [ -f "$cursor_file" ]; then
  read -r skip last_id < "$cursor_file"
  case "$skip" in ''|*[!0-9]*) skip=0 ;; esac
fi
branch_slice=""
branch=$(git branch --show-current 2>/dev/null)
case "$branch" in slice/?*) branch_slice="${branch#slice/}" ;; esac

total=$(wc -l < "$transcript" | tr -d ' ')
[ "$skip" -le "$total" ] || skip=0
result=$(head -n "$total" "$transcript" | tail -n +"$((skip + 1))" | jq -Rcn --argjson total "$total" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg agent "$agent" --arg agent_id "$agent_id" \
  --arg cwd "$PWD" --arg branch_slice "$branch_slice" --arg last_id "$last_id" '
  def ms: ((.[0:19] + "Z") | fromdate) * 1000
          + ((capture("\\.(?<f>[0-9]+)") | (.f + "00")[0:3] | tonumber) // 0);
  def text: if type == "string" then . elif type == "array" then map(.text? // empty) | join("\n") else "" end;
  def slice_id: (capture("(?m)^SLICE:[ \\t]*(?<id>[A-Za-z0-9_-]+)") | .id)
                // (capture("(?:slice/|\\.worktrees/)(?<id>[A-Za-z0-9_-]+)") | .id);
  [inputs | fromjson? | select(type == "object" and .isSidechain != true)] as $all
  | ([$all[] | select(.type == "assistant" and (.message.usage | type) == "object" and .message.model != "<synthetic>")]
     | group_by(.message.id) | map(.[-1]) | map(select(.message.id != $last_id or $last_id == ""))) as $msgs
  | [$all[] | .timestamp? | strings | ms?] as $times
  | ([$all[] | select(.type == "user")][0].message.content | text) as $brief
  | {lines: $total,
     last_id: ([$all[] | select(.type == "assistant") | .message.id | strings] | last // $last_id),
     record: (if ($msgs | length) == 0 then null else
       {ts: $ts,
        slice: (if $agent == "director" then (if $branch_slice == "" then "-" else $branch_slice end)
                else (($brief | slice_id) // ($cwd | slice_id) // "-") end),
        agent: $agent, agent_id: $agent_id,
        model: ([$msgs[].message.model | strings] | unique | join(",")),
        turns: ($msgs | length),
        input_tokens: ([$msgs[].message.usage.input_tokens // 0] | add),
        cache_write_tokens: ([$msgs[].message.usage.cache_creation_input_tokens // 0] | add),
        cache_read_tokens: ([$msgs[].message.usage.cache_read_input_tokens // 0] | add),
        output_tokens: ([$msgs[].message.usage.output_tokens // 0] | add),
        duration_ms: (if ($times | length) > 1 then ($times | max) - ($times | min) else 0 end)} end)}
' 2>/dev/null) || exit 0
[ -n "$result" ] || exit 0
record=$(printf '%s' "$result" | jq -c '.record // empty')

mkdir -p "$dir/usage-state" || exit 0
got=0
for _ in $(seq 1 50); do
  if mkdir "$lock" 2>/dev/null; then got=1; break; fi
  [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
  sleep 0.1
done
[ "$got" -eq 1 ] || exit 0
trap 'rmdir "$lock" 2>/dev/null' EXIT

if [ -n "$record" ]; then
  tmp="$ledger.tmp.$$"
  if [ -f "$ledger" ]; then
    cat "$ledger" > "$tmp"
  else
    git -C "$main_root" show HEAD:vault/usage.jsonl > "$tmp" 2>/dev/null || : > "$tmp"
  fi
  printf '%s\n' "$record" >> "$tmp"
  if [ -n "$snapshot" ] && [ -d "$(dirname "$snapshot")" ]; then
    cp "$tmp" "$snapshot.tmp.$$" && mv -f "$snapshot.tmp.$$" "$snapshot"
    rm -f "$snapshot.absent"
  fi
  mv -f "$tmp" "$ledger"
fi
if [ "$agent" = "director" ]; then
  printf '%s\n' "$result" | jq -r '"\(.lines) \(.last_id)"' > "$cursor_file"
fi
exit 0
