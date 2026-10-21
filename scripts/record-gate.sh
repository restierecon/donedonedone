#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

here="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: record-gate.sh <slice-id> <self_review|automated|reviewer|auditor> <verdict|'skip: <reason>'> [--gate-line 'GATE: PASS @ sha=S patch_id=P'] [log-event.sh options]" >&2
  exit 1
}
die() { echo "record-gate: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq · winget install jqlang.jq · apt install jq)"
[ $# -ge 3 ] || usage
id="$1" gate="$2" verdict="$3"
shift 3

case "$gate" in
  self_review) event=builder allowed="COMPLETE FAILED" ;;
  automated) event=gate allowed="PASS FAIL" ;;
  reviewer) event=reviewer allowed="APPROVED REJECTED BLOCKED" ;;
  auditor) event=auditor allowed="CLEARED CLEARED-WITH-FINDINGS BLOCKED" ;;
  risk) die "the risk gate is recorded by land-slice.sh, which runs the merge check itself" ;;
  *) die "unknown gate '$gate' (one of: self_review automated reviewer auditor)" ;;
esac
case "$verdict" in
  "skip: "?*) ;;
  *) case " $allowed " in
       *" $verdict "*) ;;
       *) die "$gate takes one of: $allowed, or 'skip: <reason>' — not '$verdict'" ;;
     esac ;;
esac

line="" args=()
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --gate-line) line="$2" ;;
    *) args+=("$1" "$2") ;;
  esac
  shift 2
done
if [ -n "$line" ]; then
  sha=$(sed -nE 's/.*[@[:space:]]sha=([^[:space:]]+).*/\1/p' <<<"$line")
  patch=$(sed -nE 's/.*[[:space:]]patch_id=([^[:space:]]+).*/\1/p' <<<"$line")
  [ -n "$sha" ] || die "--gate-line carries no sha=: $line"
  if [ "$gate" = automated ]; then
    said=$(sed -nE 's/^GATE: (PASS|FAIL).*/\1/p' <<<"$line")
    [ "$said" = "$verdict" ] || die "the verdict $verdict disagrees with the gate line ($line)"
  fi
  [ "$patch" = none ] && patch=""
  args=(--sha "$sha" ${patch:+--patch-id "$patch"} "${args[@]}")
fi

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repo"
root=$(dirname "$common")
tree="$root/vault/task-tree.json"
[ -f "$tree" ] || die "no vault/task-tree.json — run /init-codebase"
jq -e --arg id "$id" '[.slices[]? | select(.id == $id)] | length == 1' "$tree" >/dev/null 2>&1 \
  || die "slice $id is not in vault/task-tree.json"

next=$(mktemp "$tree.XXXXXX") || die "could not write next to vault/task-tree.json"
if ! jq --arg id "$id" --arg g "$gate" --arg v "$verdict" '(.slices[] | select(.id == $id) | .gates[$g]) = $v' "$tree" > "$next"; then
  rm -f "$next"
  die "could not update vault/task-tree.json"
fi
if ! (cd "$root" && "$here/log-event.sh" "$id" "$event" "$verdict" "${args[@]}"); then
  rm -f "$next"
  die "log-event.sh refused the entry; nothing was recorded"
fi
cat "$next" > "$tree" && rm -f "$next"

if ! { git -C "$root" add -- vault/task-tree.json vault/log.jsonl \
  && git -C "$root" commit -q -m "chore(vault): record $gate $verdict ($id)" -- vault/task-tree.json vault/log.jsonl; }; then
  die "recorded in task-tree.json and log.jsonl but the commit failed — commit both files before the next gate"
fi
echo "RECORDED: $id $gate $verdict — task-tree.json, log.jsonl, commit $(git -C "$root" rev-parse --short HEAD)"
