#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

usage() { echo "usage: $(basename "$0") [slice-id] | verify | export" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "usage-report.sh: jq is required" >&2; exit 2; }
[ $# -le 1 ] || usage
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { echo "usage-report.sh: not inside a git repo" >&2; exit 2; }
main_root=$(dirname "$common")
vault="$main_root/vault"
[ -d "$vault" ] || { echo "usage-report.sh: no vault/ in the main checkout" >&2; exit 2; }
ledger="$common/donedonedone/usage.jsonl"
mirror="$vault/usage.jsonl"

starts_with() {
  local size
  size=$(wc -c < "$2" | tr -d ' ')
  [ "$(wc -c < "$1" | tr -d ' ')" -ge "$size" ] && head -c "$size" "$1" | cmp -s - "$2"
}

verify() {
  local tmp bad="" n committed sha prev="" older
  tmp=$(mktemp -d)
  if [ ! -f "$ledger" ]; then
    if git -C "$main_root" cat-file -e HEAD:vault/usage.jsonl 2>/dev/null; then
      echo "USAGE LEDGER: NOT SEEDED — vault/usage.jsonl is committed; the next agent or Director stop seeds the ledger from it"
    else
      echo "USAGE LEDGER: EMPTY — nothing recorded yet"
    fi
    rm -rf "$tmp"; return 0
  fi
  n=$(jq -Rn '[inputs | fromjson? | select(type == "object" and (.agent | type) == "string" and (.output_tokens | type) == "number")] | length' "$ledger")
  [ "$n" -eq "$(grep -c '' "$ledger")" ] || bad="a line of .git/donedonedone/usage.jsonl is not a usage record"
  committed=0
  if [ -z "$bad" ] && git -C "$main_root" show HEAD:vault/usage.jsonl > "$tmp/head" 2>/dev/null; then
    committed=$(grep -c '' "$tmp/head")
    starts_with "$ledger" "$tmp/head" || bad="the ledger no longer starts with the committed vault/usage.jsonl (tampered, or diverged from another checkout)"
  fi
  if [ -z "$bad" ] && [ -f "$mirror" ] && ! cmp -s "$mirror" "$tmp/head" 2>/dev/null && ! starts_with "$ledger" "$mirror"; then
    bad="vault/usage.jsonl has uncommitted edits the ledger doesn't hold"
  fi
  if [ -z "$bad" ]; then
    while read -r sha; do
      git -C "$main_root" show "$sha:vault/usage.jsonl" > "$tmp/older" 2>/dev/null || : > "$tmp/older"
      if [ -n "$prev" ] && ! starts_with "$tmp/newer" "$tmp/older"; then
        bad="commit $prev rewrote earlier lines of vault/usage.jsonl instead of appending (a revert keeps this evidence; a human clears it by dropping that commit from history)"
        break
      fi
      mv "$tmp/older" "$tmp/newer"
      prev=$(git -C "$main_root" rev-parse --short "$sha")
    done < <(git -C "$main_root" log --format=%H -n 50 HEAD -- vault/usage.jsonl 2>/dev/null)
  fi
  rm -rf "$tmp"
  if [ -n "$bad" ]; then echo "USAGE LEDGER: TAMPERED — $bad"; return 1; fi
  older=""
  [ "$committed" -gt 0 ] && older=", $committed committed"
  echo "USAGE LEDGER: OK — $n records$older"
}

case "${1:-}" in
  verify) verify; exit $? ;;
  export)
    out=$(verify) || { echo "$out"; echo "export refused: fix or explain the ledger first (vault/flags/pending-review.md)" >&2; exit 1; }
    [ -f "$ledger" ] || { echo "$out"; exit 0; }
    cp "$ledger" "$mirror.tmp.$$" && mv -f "$mirror.tmp.$$" "$mirror" || exit 1
    echo "exported $(grep -c '' "$mirror") records → vault/usage.jsonl — commit it"
    exit 0 ;;
  -*) usage ;;
esac

source_file="$ledger"
if [ ! -s "$source_file" ]; then
  source_file=$(mktemp)
  git -C "$main_root" show HEAD:vault/usage.jsonl > "$source_file" 2>/dev/null
  trap 'rm -f "$source_file"' EXIT
fi
[ -s "$source_file" ] || { echo "USAGE: no agent runs recorded yet (usage-log.sh records each subagent and Director stop)"; exit 0; }
status=$(verify)
log="$vault/log.jsonl"
[ -f "$log" ] || log=/dev/null

jq -Rrn --arg only "${1:-}" --arg status "$status" --rawfile log "$log" '
  def k: if . >= 1000000 then "\((. / 100000 | floor) / 10)M" elif . >= 1000 then "\(. / 1000 | floor)k" else "\(.)" end;
  def mins: "\((. / 6000 | floor) / 10)m";
  def fresh: .input_tokens + .cache_write_tokens;
  [inputs | fromjson? | select(type == "object" and (.agent | type) == "string")] as $all
  | [$log | split("\n")[] | fromjson? | select(type == "object")] as $events
  | if $only != "" then
      [$all[] | select(.slice == $only)] as $runs
      | "USAGE \($only): \($runs | length) runs · out \([$runs[].output_tokens] | add // 0 | k) · fresh in \([$runs[] | fresh] | add // 0 | k) · cache reads \([$runs[].cache_read_tokens] | add // 0 | k) · \([$runs[].duration_ms] | add // 0 | mins)",
        ($runs[-14:][] | "  \(.ts) \(.agent) \(.model) · \(.turns) turns · out \(.output_tokens | k) · fresh in \(fresh | k) · \(.duration_ms | mins)"),
        $status
    else
      "USAGE: \($all | length) runs · \([$all[].slice | select(. != "-")] | unique | length) slices · \($all[0].ts) → \($all[-1].ts)",
      $status,
      "by agent · model (runs · out · fresh in · cache reads · avg time):",
      ($all | group_by([.agent, .model])[]
        | "  \(.[0].agent) \(.[0].model): \(length) · \([.[].output_tokens] | add | k) · \([.[] | fresh] | add | k) · \([.[].cache_read_tokens] | add | k) · \(([.[].duration_ms] | add) / length | mins)"),
      "builder model vs outcome (slices · reviewer rejections per slice · out per slice):",
      ([$all[] | select(.agent == "builder" and .slice != "-")] | group_by(.model)[]
        | . as $b | ([$b[].slice] | unique) as $slices
        | ([$events[] | select(.event == "reviewer" and .verdict == "REJECTED" and (.slice | IN($slices[])))] | length) as $rej
        | "  \($b[0].model): \($slices | length) · \(($rej * 100 / ($slices | length) | floor) / 100) · \(([$b[].output_tokens] | add) / ($slices | length) | floor | k)"),
      "costliest slices, Director included (runs · out · time):",
      ([$all[] | select(.slice != "-")] | group_by(.slice) | map({s: .[0].slice, n: length, out: ([.[].output_tokens] | add), ms: ([.[].duration_ms] | add)})
        | sort_by(-.out)[:4][] | "  \(.s): \(.n) · \(.out | k) · \(.ms | mins)")
    end
' "$source_file" | head -20
