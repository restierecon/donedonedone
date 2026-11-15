#!/bin/bash
# shellcheck disable=SC2016
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

usage() {
  echo "usage: contract.sh lint <plan.json> | lock <ID> [--revise] | check [ID] [--ref <ref>]" >&2
  exit 2
}
die() { echo "contract: $1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq · winget install jqlang.jq · apt install jq). Failing closed."

LIB='
def nonempty: type == "string" and test("\\S");
def whole: type == "number" and . == floor;
def path_ok: nonempty and (startswith("/") | not) and (test("[*?\\[]") | not)
  and (test("(^|/)\\.\\.?(/|$)") | not);
def shape:
  .contract as $c
  | (if ($c.tests | type) == "array" and ($c.tests | length) > 0 and all($c.tests[]; path_ok) then empty
     else "contract.tests must list the acceptance test files or directories, as plain repo paths (no globs)" end),
    (if ($c.budget | whole) and $c.budget > 0 then empty
     else "contract.budget must be a whole number of changed lines above 0" end);
def problems:
  if has("contract") | not then "missing contract — {tests, budget}, or \"none: <reason>\" when no test can prove the slice"
  elif (.contract | type) == "string" then
    (if (.contract | test("^none: *\\S")) then empty else "contract \(.contract | tojson) must be an object or \"none: <reason>\"" end)
  elif (.contract | type) == "object" then shape
  else "contract must be {tests, budget} or \"none: <reason>\"" end;
'

root="" common="" tree="" project=""
if common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  root=$(dirname "$common")
  tree="$root/vault/task-tree.json"
  project="$root/vault/project.md"
fi
base="${GATE_BASE:-main}"
here="$(cd "$(dirname "$0")" && pwd)"

slice_of() { jq -c --arg id "$1" '[.slices[]? | select(.id == $id)][0] // empty' "$tree" 2>/dev/null; }

hash_at() {
  local dir="$1" ref="$2"
  shift 2
  git -C "$dir" ls-tree -r "$ref" -- "$@" | git hash-object --stdin | cut -c1-12
}

cmd_lint() {
  [ -f "$1" ] || die "no plan at $1"
  jq -r "$LIB"'
    if type != "array" then empty
    else to_entries[] | .key as $i | .value | select(type == "object")
      | (if (.id | nonempty) then .id else "slice[\($i)]" end) as $s | problems | "\($s): \(.)" end' "$1" 2>/dev/null \
    || die "$1 could not be read as JSON"
}

red_check() {
  local id="$1" focus wt
  shift
  focus=$(sed -n 's/^[-*][[:space:]]*gate\.test\.focus:[[:space:]]*//p' "$project" 2>/dev/null | head -1 | tr -d '\r`')
  [ -n "$focus" ] || { echo "unverified (no gate.test.focus)"; return 0; }
  wt=$(git -C "$root" worktree list --porcelain \
    | awk -v b="refs/heads/slice/$id" '/^worktree / { w = substr($0, 10) } $0 == "branch " b { print w }' | head -1)
  [ -n "$wt" ] || { echo "unverified (slice/$id is not checked out)"; return 0; }
  [ -z "$(git -C "$wt" status --porcelain -- "$@")" ] || return 4
  if (cd "$wt" && "$here/gate.sh" test -- "$@") >/dev/null 2>&1; then return 5; fi
  echo confirmed
}

cmd_lock() {
  local id="$1" revise="$2" slice found ref tests=() t literal=() exclude=() changed outside
  local locked revision=0 red status=0 hash sha next verdict=locked
  [ -n "$root" ] || die "not inside a git repo"
  [ -f "$tree" ] || die "no vault/task-tree.json — run /init-codebase"
  slice=$(slice_of "$id")
  [ -n "$slice" ] || die "slice $id is not in vault/task-tree.json"
  jq -e '.contract | type == "object"' <<<"$slice" >/dev/null \
    || die "slice $id has no contract to lock (contract is $(jq -c '.contract // "absent"' <<<"$slice"))"
  found=$(jq -r "$LIB"'shape' <<<"$slice")
  [ -z "$found" ] || die "slice $id: $(echo "$found" | head -1)"
  ref="slice/$id"
  git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null || die "no $ref branch — the tester writes the contract tests there first"
  git -C "$root" rev-parse -q --verify "$base^{commit}" >/dev/null || die "no $base branch to diff against; set GATE_BASE"

  while IFS= read -r t; do
    t="${t%/}"
    tests+=("$t"); literal+=(":(literal)$t"); exclude+=(":(exclude,literal)$t")
  done < <(jq -r '.contract.tests[]' <<<"$slice")
  for t in "${tests[@]}"; do
    [ -n "$(git -C "$root" ls-tree -r "$ref" -- "$t" | head -1)" ] \
      || die "contract test $t is not on $ref — the tester writes it there first"
  done
  changed=$(git -C "$root" diff --name-only "$base...$ref" -- "${literal[@]}")
  [ -n "$changed" ] || die "the contract tests on $ref are unchanged from $base — the tester hasn't written them"

  hash=$(hash_at "$root" "$ref" "${tests[@]}")
  sha=$(git -C "$root" rev-parse --short "$ref")
  locked=$(jq -r '.contract.locked.hash // ""' <<<"$slice")
  red=$(jq -r '.contract.locked.red // ""' <<<"$slice")
  if [ "$revise" -eq 0 ]; then
    if [ -n "$locked" ]; then
      [ "$locked" = "$hash" ] || die "the contract of $id is locked at $locked and its tests have changed — a revision after a CONTRACT-DISPUTE is: contract.sh lock $id --revise"
      echo "CONTRACT: LOCKED $id hash=$hash (already locked)"
      return 0
    fi
    outside=$(git -C "$root" diff --name-only "$base...$ref" -- . ':(exclude)vault' "${exclude[@]}")
    [ -z "$outside" ] || die "$ref already changes files outside the contract tests ($(echo "$outside" | head -3 | tr '\n' ' ')) — the contract locks before any build"
    red=$(red_check "$id" "${tests[@]}") || status=$?
    case "$status" in
      4) die "uncommitted changes in the contract tests of slice/$id — commit them first" ;;
      5) die "the contract tests already pass on $ref — they don't test behavior that is still missing" ;;
    esac
  else
    [ -n "$locked" ] || die "the contract of $id was never locked — nothing to revise"
    [ "$locked" != "$hash" ] || die "the contract tests of $id are unchanged since the lock — nothing to revise"
    revision=$(( $(jq -r '.contract.locked.revision // 0' <<<"$slice") + 1 ))
    [ "$revision" -le 1 ] || die "the contract of $id was already revised once — a second dispute is a human decision: escalate it (pending-review.md) and re-grill"
    verdict=revised
  fi

  next=$(mktemp "$tree.XXXXXX") || die "could not write next to vault/task-tree.json"
  if ! jq --arg id "$id" --arg hash "$hash" --arg sha "$sha" --arg red "$red" --argjson revision "$revision" \
      '(.slices[] | select(.id == $id) | .contract.locked) = {hash: $hash, sha: $sha, red: $red, revision: $revision}' "$tree" > "$next"; then
    rm -f "$next"
    die "could not update vault/task-tree.json"
  fi
  if ! (cd "$root" && "$here/log-event.sh" "$id" contract "$verdict" --sha "$sha" --hash "$hash" \
        --signal "tests: ${tests[*]}" --signal "red: $red"); then
    rm -f "$next"
    die "log-event.sh refused the entry; nothing was locked"
  fi
  cat "$next" > "$tree" && rm -f "$next"
  if ! { git -C "$root" add -- vault/task-tree.json vault/log.jsonl \
    && git -C "$root" commit -q -m "chore(vault): contract $verdict ($id)" -- vault/task-tree.json vault/log.jsonl; }; then
    die "locked in task-tree.json and log.jsonl but the commit failed — commit both files before the builder starts"
  fi
  echo "CONTRACT: LOCKED $id hash=$hash sha=$sha tests=${#tests[@]} budget=$(jq -r '.contract.budget' <<<"$slice") red=$red revision=$revision"
}

cmd_check() {
  local id="$1" ref="$2" top branch slice kind found locked lock lock_sha tests=() t exclude=() now budget used n red note=""
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not inside a git repo"; exit 3; }
  if [ -z "$id" ]; then
    branch=$(git -C "$top" branch --show-current)
    case "$branch" in
      slice/?*) id="${branch#slice/}" ;;
      *) echo "not on a slice/<ID> branch"; exit 3 ;;
    esac
  fi
  [ -f "$tree" ] || { echo "no vault/task-tree.json"; exit 3; }
  jq -e 'type == "object"' "$tree" >/dev/null 2>&1 || { echo "vault/task-tree.json is not valid JSON"; exit 1; }
  slice=$(slice_of "$id")
  [ -n "$slice" ] || { echo "slice $id is not in vault/task-tree.json"; exit 1; }
  kind=$(jq -r 'if has("contract") | not then "absent" else .contract | type end' <<<"$slice")
  case "$kind" in
    absent) echo "slice $id has no contract field"; exit 3 ;;
    string) echo "slice $id — $(jq -r '.contract' <<<"$slice")"; exit 3 ;;
    object) ;;
    *) echo "slice $id: contract must be {tests, budget} or \"none: <reason>\""; exit 1 ;;
  esac
  found=$(jq -r "$LIB"'shape' <<<"$slice")
  [ -z "$found" ] || { echo "slice $id: $(echo "$found" | head -1)"; exit 1; }
  if ! jq -e '.contract.locked.hash | strings' <<<"$slice" >/dev/null; then
    lock=$(git -C "$top" show "$ref:vault/task-tree.json" 2>/dev/null \
      | jq -c --arg id "$id" '[.slices[]? | select(.id == $id)][0].contract.locked // empty' 2>/dev/null)
    [ -z "$lock" ] || slice=$(jq -c --argjson l "$lock" '.contract.locked = $l' <<<"$slice")
  fi
  locked=$(jq -r '.contract.locked.hash // ""' <<<"$slice")
  [ -n "$locked" ] || { echo "the contract of $id is not locked — the Director runs contract.sh lock $id before any builder"; exit 1; }
  git -C "$top" rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "no $base branch to diff against; set GATE_BASE"; exit 3; }
  git -C "$top" rev-parse -q --verify "$ref^{commit}" >/dev/null || { echo "no $ref to check the contract of $id against"; exit 1; }

  while IFS= read -r t; do
    t="${t%/}"
    tests+=("$t"); exclude+=(":(exclude,literal)$t")
  done < <(jq -r '.contract.tests[]' <<<"$slice")
  now=$(hash_at "$top" "$ref" "${tests[@]}")
  if [ "$now" != "$locked" ]; then
    lock_sha=$(jq -r '.contract.locked.sha // ""' <<<"$slice")
    echo "the contract tests changed since they were locked ($locked) — stop and report CONTRACT-DISPUTE; a builder never edits a locked test:"
    git -C "$top" diff --name-status "$lock_sha" "$ref" -- "${tests[@]}" 2>/dev/null | head -8
    exit 1
  fi
  budget=$(jq -r '.contract.budget' <<<"$slice")
  used=$(git -C "$top" diff --numstat "$base...$ref" -- . ':(exclude)vault' "${exclude[@]}" \
    | awk '$1 != "-" { n += $1 + $2 } END { print n + 0 }')
  if [ "$used" -gt "$budget" ]; then
    echo "the diff changes $used lines outside the contract tests, over the contract budget of $budget — stop and report SCOPE-EXPANSION; the Director re-plans or raises the budget"
    exit 1
  fi
  n=$(git -C "$top" ls-tree -r "$ref" -- "${tests[@]}" | grep -c .)
  red=$(jq -r '.contract.locked.red // ""' <<<"$slice")
  case "$red" in unverified*) note=" · red $red" ;; esac
  echo "$n contract test files as locked ($locked) · $used of $budget budget lines$note"
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  lint) [ $# -eq 1 ] || usage; cmd_lint "$1" ;;
  lock)
    [ $# -ge 1 ] || usage
    id="$1" revise=0
    shift
    while [ $# -gt 0 ]; do
      case "$1" in --revise) revise=1 ;; *) usage ;; esac
      shift
    done
    cmd_lock "$id" "$revise" ;;
  check)
    id="" ref=HEAD
    while [ $# -gt 0 ]; do
      case "$1" in
        --ref) [ $# -ge 2 ] || usage; ref="$2"; shift ;;
        -*) usage ;;
        *) [ -z "$id" ] || usage; id="$1" ;;
      esac
      shift
    done
    cmd_check "$id" "$ref" ;;
  *) usage ;;
esac
