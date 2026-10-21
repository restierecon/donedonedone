#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

here="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: land-slice.sh <slice-id> [-m '<type>(<scope>): <subject> (<slice-id>)']" >&2; exit 1; }
die() { echo "land-slice: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq · winget install jqlang.jq · apt install jq)"
[ $# -ge 1 ] || usage
id="$1" message=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -m) [ $# -ge 2 ] || usage; message="$2"; shift 2 ;;
    *) usage ;;
  esac
done

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repo"
root=$(dirname "$common")
tree="$root/vault/task-tree.json"
base="${GATE_BASE:-main}"
branch="slice/$id"
g() { git -C "$root" "$@"; }

[ -f "$tree" ] || die "no vault/task-tree.json — run /init-codebase"
g rev-parse -q --verify "$branch^{commit}" >/dev/null || die "no $branch branch"
g rev-parse -q --verify "refs/tags/$id-done" >/dev/null && die "tag $id-done already exists — $id has landed before"
[ -z "$(g status --porcelain --untracked-files=no)" ] || die "the main checkout has uncommitted changes — commit or stash them first"
current=$(g symbolic-ref --short -q HEAD)
if [ "$current" != "$base" ]; then
  [ "$current" = "$branch" ] || die "the main checkout is on '${current:-a detached HEAD}' — land from $base"
  g checkout -q "$base" || die "could not check out $base"
fi

check=$(cd "$root" && "$here/risk-gate.sh" check "$id" merge 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
  printf '%s\n' "$check" | tail -16
  die "$id can't land until the risk gate passes (risk-gate skill)"
fi
controls=$(printf '%s\n' "$check" | sed -n 's/^CONTROLS: //p' | tail -1)
patch=$(printf '%s\n' "$check" | sed -n 's/^RISK: PASS .*patch_id=\([0-9a-f]*\).*/\1/p' | tail -1)

conflicts=$(g merge-tree --write-tree --name-only --no-messages "$base" "$branch" 2>/dev/null)
case $? in
  1)
    printf '%s\n' "$conflicts" | sed 1d | head -12 | sed 's/^/  conflict: /'
    die "$branch conflicts with $base — re-dispatch its builder once to rebase and resolve (parallel-dispatch skill, step 6), then re-run the gates if the patch_id changed" ;;
esac

if ! g merge --squash -q "$branch" >/dev/null 2>&1; then
  g reset -q --merge
  die "the squash merge of $branch failed and was undone"
fi
if g diff --cached --quiet; then
  die "$branch adds nothing to $base"
fi
if [ -z "$message" ]; then
  title=$(jq -r --arg id "$id" '[.slices[]? | select(.id == $id)][0].title // empty' "$tree")
  message="feat: ${title:-land $branch} ($id)"
fi
g commit -q -m "$message" || { g reset -q --merge; die "the squash commit failed and was undone"; }
merged=$(g rev-parse --short HEAD)
g tag "$id-done" HEAD || die "landed at $merged but could not tag it $id-done"

next=$(mktemp "$tree.XXXXXX") || die "landed at $merged but could not write vault/task-tree.json"
if jq --arg id "$id" '(.slices[] | select(.id == $id)) |= (.gates.risk = "PASS" | .status = "done")' "$tree" > "$next"; then
  cat "$next" > "$tree"
fi
rm -f "$next"
(cd "$root" && "$here/log-event.sh" "$id" merge "done" --sha "$merged" ${patch:+--patch-id "$patch"} --signal "${controls:-no CONTROLS line}") \
  || die "landed at $merged but log-event.sh refused the merge entry"
if ! { g add -- vault/task-tree.json vault/log.jsonl && g commit -q -m "chore(vault): land $id" -- vault/task-tree.json vault/log.jsonl; }; then
  die "landed at $merged but the bookkeeping commit failed — commit vault/task-tree.json and vault/log.jsonl"
fi

cleanup="branch deleted"
worktree=$(g worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree / { w = substr($0, 10) } $0 == "branch " b { print w }')
if [ -n "$worktree" ] && [ "$worktree" != "$root" ] && ! g worktree remove "$worktree" 2>/dev/null; then
  cleanup="kept $worktree and $branch: the worktree has uncommitted changes"
elif ! g branch -q -D "$branch"; then
  cleanup="could not delete $branch"
fi

echo "LANDED: $id at $merged · tag $id-done · $cleanup"
echo "CONTROLS: ${controls:-none reported}"
echo "NEXT: harvest $id (harvest skill) — append its story to vault/stories.md and prune it from task-tree.json"
