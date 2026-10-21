#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

here="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: adopt-plan.sh [<slice-id>...] | adopt-plan.sh --discard" >&2; exit 1; }
die() { echo "adopt-plan: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq · winget install jqlang.jq · apt install jq)"
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repo"
root=$(dirname "$common")
cd "$root" || die "can't enter $root"
draft=vault/plan-draft.json
tree=vault/task-tree.json

drop_draft() {
  if git ls-files --error-unmatch "$draft" >/dev/null 2>&1; then
    git rm -q -- "$draft"
  else
    rm -f "$draft"
  fi
}

if [ "${1:-}" = "--discard" ]; then
  [ $# -eq 1 ] || usage
  [ -f "$draft" ] || die "no $draft to discard"
  drop_draft
  git diff --cached --quiet -- "$draft" 2>/dev/null || git commit -q -m "chore(vault): discard plan draft" -- "$draft"
  echo "DISCARDED: $draft"
  exit 0
fi
case "${1:-}" in -*) usage ;; esac

[ -f "$draft" ] || die "no $draft — dispatch the planner first"
[ -f "$tree" ] || die "no $tree — run /init-codebase"
check=$("$here/check-plan.sh" "$draft" 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
  printf '%s\n' "$check" | tail -20
  die "check-plan.sh failed — send its output back to the planner"
fi

ids=$(jq -cn '$ARGS.positional' --args "$@")
picked=$(jq -c --argjson ids "$ids" 'if ($ids | length) == 0 then . else map(select(.id as $i | $ids | index($i))) end' "$draft")
missing=$(jq -r --argjson ids "$ids" --argjson picked "$picked" '$ids - ($picked | map(.id)) | join(" ")' -n)
[ -z "$missing" ] || die "not in the draft: $missing"
taken=$(jq -r --argjson picked "$picked" '[.slices[]?.id] as $have | $picked | map(.id | select(IN($have[]))) | join(" ")' "$tree")
[ -z "$taken" ] || die "already in $tree: $taken"
shipped=$(sed -n 's/^## \([^ ]*\) .*/\1/p' vault/stories.md 2>/dev/null | jq -R . | jq -sc .)
orphans=$(jq -r --argjson picked "$picked" --argjson shipped "${shipped:-[]}" '
  ([.slices[]?.id] + ($picked | map(.id)) + $shipped) as $known
  | $picked[] | .id as $s | .depends_on[]? | select(IN($known[]) | not) | "\($s) needs \(.)"' "$tree")
[ -z "$orphans" ] || die "a picked slice depends on one left in the draft: $(echo "$orphans" | tr '\n' ' ')— adopt them together"

next=$(mktemp "$tree.XXXXXX") || die "could not write next to $tree"
jq --argjson picked "$picked" '.slices = ((.slices // []) + $picked)' "$tree" > "$next" || { rm -f "$next"; die "could not update $tree"; }
cat "$next" > "$tree" && rm -f "$next"

failed=()
while IFS= read -r id; do
  out=$("$here/risk-gate.sh" assess "$id" 2>&1) || failed+=("$id")
  printf '%s\n' "$out" | grep -E '^RISK: ' | head -1
done < <(jq -r '.[].id' <<<"$picked")
if [ ${#failed[@]} -gt 0 ]; then
  die "the risk gate could not record ${failed[*]} — fix the assessment and run risk-gate.sh assess on each; $tree is updated, $draft kept, nothing committed"
fi

all=$(jq 'length' "$draft")
kept=$(jq 'length' <<<"$picked")
paths=("$tree" vault/log.jsonl)
git ls-files --error-unmatch "$draft" >/dev/null 2>&1 && [ "$kept" -eq "$all" ] && paths+=("$draft")
[ "$kept" -eq "$all" ] && drop_draft
if ! { git add -- "$tree" vault/log.jsonl \
  && git commit -q -m "chore(vault): adopt plan $(jq -r 'map(.id) | join(" ")' <<<"$picked")" -- "${paths[@]}"; }; then
  die "adopted, but the commit failed — commit $tree and vault/log.jsonl"
fi
echo "ADOPTED: $kept of $all slices$([ "$kept" -eq "$all" ] && echo ", draft deleted" || echo ", draft kept for the rest")"
pending=$("$here/risk-gate.sh" pending 2>/dev/null)
[ -n "$pending" ] && printf 'PENDING:\n%s\n' "$pending"
exit 0
