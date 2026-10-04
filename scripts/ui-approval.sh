#!/bin/bash

usage() {
  echo "usage: ui-approval.sh <hash|check> vault/ui/<feature-slug>/contract.md" >&2
  exit 2
}
die() { echo "ui-approval: $1" >&2; exit 2; }

[ $# -eq 2 ] || usage
mode="$1" contract="$2"
case "$mode" in hash|check) ;; *) usage ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required. Failing closed."
printf '%s\n' "$contract" | grep -qE '^vault/ui/[^/]+/contract\.md$' \
  || die "contract path must be vault/ui/<feature-slug>/contract.md (got: $contract)"

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repo"
root=$(dirname "$common")
ledger="$common/donedonedone/approvals.jsonl"
dir="$root/$(dirname "$contract")"

folder_hash() {
  [ -f "$root/$contract" ] || return 1
  (cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(git hash-object -- "$f")" "$f"
  done) | git hash-object --stdin | cut -c1-12
}

hash=$(folder_hash) || { echo "UI: NOT APPROVED $contract — no such contract; run the ui-prototype skill in /grill"; exit 1; }
if [ "$mode" = hash ]; then
  echo "$hash"
  exit 0
fi

last=""
[ -f "$ledger" ] && last=$(jq -Rc --arg c "$contract" 'fromjson? | select(type == "object" and .kind == "ui" and .contract == $c)' "$ledger" \
  | jq -sc 'sort_by(.ts // "") | last // empty')
ask="a human runs ~/.claude/scripts/approve-ui.sh $contract in their own terminal"
if [ -z "$last" ]; then
  echo "UI: NOT APPROVED $contract hash=$hash — never approved; $ask"
  exit 1
fi
decision=$(jq -r '.decision' <<<"$last")
approved_hash=$(jq -r '.hash' <<<"$last")
by=$(jq -r '.approver' <<<"$last")
if [ "$decision" != approve ]; then
  echo "UI: NOT APPROVED $contract hash=$hash — last decision was '$decision' by $by; revise it and $ask"
  exit 1
fi
if [ "$approved_hash" != "$hash" ]; then
  echo "UI: NOT APPROVED $contract hash=$hash — $by approved hash=$approved_hash, and the folder has changed since; $ask"
  exit 1
fi
echo "UI: APPROVED $contract hash=$hash by $by"
