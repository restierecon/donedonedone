#!/bin/bash
# Appends one structured line to vault/log.jsonl — the Director's record of every gate
# verdict, Tier 3 tiebreak, escalation and human correction. The scribe compacts
# handoffs and discards reasoning trails; this log is never compacted, so it is the only
# place the raw failure signal survives until the retro agent reads it.
#
# Usage: log-event.sh <slice-id|-> <event> <verdict> [--sha S] [--attempt N]
#                     [--category C]... [--signal "text"]...
#   event:    builder gate reviewer auditor merge tier3 escalation correction retro
#   category: one of CATEGORIES below (the retro groups on these; free text can't be grouped)
#   signal:   one CRITICAL critique line, tiebreak, or correction — at most 5, 200 chars each
#
# After appending, prints "RETRO DUE: ..." when one category has recurred across two or
# more slices since the last retro event — dispatch the retro then, not at the next
# 5-slice review. Always writes to the main checkout's vault, even from a worktree.

EVENTS="builder gate reviewer auditor merge tier3 escalation correction retro"
CATEGORIES="criterion-unmet test-quality speculative-abstraction error-handling dead-code duplication scope-creep contract-mismatch dependency security logging gate-failure merge-conflict ambiguous-criteria human-correction other"
MAX_SIGNALS=5
MAX_CHARS=200

usage() { echo "usage: $(basename "$0") <slice-id|-> <event> <verdict> [--sha S] [--attempt N] [--category C]... [--signal TEXT]..." >&2; exit 1; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

command -v jq >/dev/null 2>&1 || { echo "log-event.sh: jq is required (brew install jq)" >&2; exit 1; }
[ $# -ge 3 ] || usage
slice="$1" event="$2" verdict="$3"; shift 3
in_list "$event" "$EVENTS" || { echo "log-event.sh: unknown event '$event' (one of: $EVENTS)" >&2; exit 1; }

sha="" attempt="" categories=() signals=()
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --sha) sha="$2" ;;
    --attempt) attempt="$2" ;;
    --category)
      in_list "$2" "$CATEGORIES" || { echo "log-event.sh: unknown category '$2' (one of: $CATEGORIES)" >&2; exit 1; }
      categories+=("$2") ;;
    --signal)
      [ ${#signals[@]} -lt "$MAX_SIGNALS" ] && signals+=("$(printf '%s' "$2" | tr '\t\r\n' '   ' | cut -c1-"$MAX_CHARS")") ;;
    *) usage ;;
  esac
  shift 2
done

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { echo "log-event.sh: not inside a git repo" >&2; exit 1; }
log="$(dirname "$common")/vault/log.jsonl"
[ -d "$(dirname "$log")" ] || { echo "log-event.sh: no vault/ in the main checkout — run /init-vault" >&2; exit 1; }

jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg slice "$slice" --arg event "$event" \
  --arg verdict "$verdict" --arg sha "$sha" --arg attempt "$attempt" \
  --args '{ts: $ts, slice: $slice, event: $event, verdict: $verdict}
    + (if $sha != "" then {sha: $sha} else {} end)
    + (if $attempt != "" then {attempt: ($attempt | tonumber? // $attempt)} else {} end)
    + {categories: ($ARGS.positional | map(select(startswith("c:")) | .[2:])),
       signals:    ($ARGS.positional | map(select(startswith("s:")) | .[2:]))}' \
  "${categories[@]/#/c:}" "${signals[@]/#/s:}" >> "$log" || exit 1

[ "$event" = "retro" ] && exit 0

# Lines that aren't JSON (hand-written before this script existed) are skipped, not fatal.
jq -Rrn '
  [inputs | fromjson?] as $all
  | ([$all | to_entries[] | select(.value.event == "retro") | .key] | last // -1) as $cut
  | [$all[($cut + 1):][] | .slice as $s | (.categories // [])[] | select(. != "other") | {c: ., s: $s}]
  | group_by(.c)[] | {c: .[0].c, s: (map(.s) | unique)} | select(.s | length >= 2)
  | "RETRO DUE: \(.c) recurred in \(.s | join(", ")) since the last retro — dispatch it now (learning-loop skill)"
' "$log" 2>/dev/null
exit 0
