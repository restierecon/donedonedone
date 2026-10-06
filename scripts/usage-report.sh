#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

command -v jq >/dev/null 2>&1 || { echo "usage-report.sh: jq is required" >&2; exit 1; }
[ $# -le 1 ] || { echo "usage: $(basename "$0") [slice-id]" >&2; exit 1; }
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { echo "usage-report.sh: not inside a git repo" >&2; exit 1; }
vault="$(dirname "$common")/vault"
usage="$vault/usage.jsonl"
[ -s "$usage" ] || { echo "USAGE: no agent runs recorded yet (vault/usage.jsonl is written by the SubagentStop hook)"; exit 0; }
log="$vault/log.jsonl"
[ -f "$log" ] || log=/dev/null

jq -Rrn --arg only "${1:-}" --rawfile log "$log" '
  def k: if . >= 1000000 then "\((. / 100000 | floor) / 10)M" elif . >= 1000 then "\(. / 1000 | floor)k" else "\(.)" end;
  def mins: "\((. / 6000 | floor) / 10)m";
  def fresh: .input_tokens + .cache_write_tokens;
  [inputs | fromjson? | select(type == "object" and (.agent | type) == "string")] as $all
  | [$log | split("\n")[] | fromjson? | select(type == "object")] as $events
  | if $only != "" then
      [$all[] | select(.slice == $only)] as $runs
      | "USAGE \($only): \($runs | length) agent runs · out \([$runs[].output_tokens] | add // 0 | k) · fresh in \([$runs[] | fresh] | add // 0 | k) · cache reads \([$runs[].cache_read_tokens] | add // 0 | k) · \([$runs[].duration_ms] | add // 0 | mins)",
        ($runs[-15:][] | "  \(.ts) \(.agent) \(.model) · \(.turns) turns · out \(.output_tokens | k) · fresh in \(fresh | k) · \(.duration_ms | mins)")
    else
      "USAGE: \($all | length) agent runs · \([$all[].slice | select(. != "-")] | unique | length) slices · \($all[0].ts) → \($all[-1].ts)",
      "by agent · model (runs · out · fresh in · cache reads · avg time):",
      ($all | group_by([.agent, .model])[]
        | "  \(.[0].agent) \(.[0].model): \(length) · \([.[].output_tokens] | add | k) · \([.[] | fresh] | add | k) · \([.[].cache_read_tokens] | add | k) · \(([.[].duration_ms] | add) / length | mins)"),
      "builder model vs outcome (slices · reviewer rejections per slice · out per slice):",
      ([$all[] | select(.agent == "builder" and .slice != "-")] | group_by(.model)[]
        | . as $b | ([$b[].slice] | unique) as $slices
        | ([$events[] | select(.event == "reviewer" and .verdict == "REJECTED" and (.slice | IN($slices[])))] | length) as $rej
        | "  \($b[0].model): \($slices | length) · \(($rej * 100 / ($slices | length) | floor) / 100) · \(([$b[].output_tokens] | add) / ($slices | length) | floor | k)"),
      "costliest slices by output tokens (agent runs · out · time):",
      ([$all[] | select(.slice != "-")] | group_by(.slice) | map({s: .[0].slice, n: length, out: ([.[].output_tokens] | add), ms: ([.[].duration_ms] | add)})
        | sort_by(-.out)[:5][] | "  \(.s): \(.n) · \(.out | k) · \(.ms | mins)")
    end
' "$usage" | head -20
