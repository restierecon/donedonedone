#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
event="" agent_type="" agent_id="" transcript="" cwd=""
eval "$(printf '%s' "$input" | jq -r '@sh "event=\(.hook_event_name // "") agent_type=\(.agent_type // "") agent_id=\(.agent_id // "") transcript=\(.agent_transcript_path // "") cwd=\(.cwd // "")"' 2>/dev/null)" || exit 0
[ "$event" = "SubagentStop" ] && [ -n "$agent_type" ] || exit 0
case "$transcript" in \~/*) transcript="$HOME/${transcript#\~/}" ;; esac
[ -f "$transcript" ] || exit 0
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || exit 0; fi

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
vault="$(dirname "$common")/vault"
[ -d "$vault" ] || exit 0

record=$(jq -Rcn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg agent "$agent_type" --arg agent_id "$agent_id" --arg cwd "$PWD" '
  def ms: ((.[0:19] + "Z") | fromdate) * 1000
          + ((capture("\\.(?<f>[0-9]+)") | (.f + "00")[0:3] | tonumber) // 0);
  def text: if type == "string" then . elif type == "array" then map(.text? // empty) | join("\n") else "" end;
  def slice_id: (capture("(?m)^SLICE:[ \\t]*(?<id>[A-Za-z0-9_-]+)") | .id)
                // (capture("(?:slice/|\\.worktrees/)(?<id>[A-Za-z0-9_-]+)") | .id);
  [inputs | fromjson? | select(type == "object")] as $all
  | ([$all[] | select(.type == "assistant" and (.message.usage | type) == "object" and .message.model != "<synthetic>")]
     | group_by(.message.id) | map(.[-1])) as $msgs
  | [$all[] | .timestamp? | strings | ms?] as $times
  | ([$all[] | select(.type == "user")][0].message.content | text) as $brief
  | select(($msgs | length) > 0)
  | {ts: $ts,
     slice: (($brief | slice_id) // ($cwd | slice_id) // "-"),
     agent: $agent, agent_id: $agent_id,
     model: ([$msgs[].message.model | strings] | unique | join(",")),
     turns: ($msgs | length),
     input_tokens: ([$msgs[].message.usage.input_tokens // 0] | add),
     cache_write_tokens: ([$msgs[].message.usage.cache_creation_input_tokens // 0] | add),
     cache_read_tokens: ([$msgs[].message.usage.cache_read_input_tokens // 0] | add),
     output_tokens: ([$msgs[].message.usage.output_tokens // 0] | add),
     duration_ms: (if ($times | length) > 1 then ($times | max) - ($times | min) else 0 end)}
' < "$transcript" 2>/dev/null) || exit 0
[ -n "$record" ] && printf '%s\n' "$record" >> "$vault/usage.jsonl"
exit 0
