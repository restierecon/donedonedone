#!/bin/bash
# Test harness for the hook scripts — mechanisms get tests, not hope.
# Feeds synthetic hook JSON into guard.sh / lint.sh / checkpoint.sh and asserts
# block/allow behavior. Run: tests/run-tests.sh   Exit nonzero on any failure.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/guard.sh"
LINT="$ROOT/scripts/lint.sh"
CHECKPOINT="$ROOT/scripts/checkpoint.sh"

pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1 ($2)"; }

# --- payload builders -------------------------------------------------------
# guard_bash <command> [agent_type] — runs guard.sh as if Bash were called.
# When agent_type is given, the payload carries agent_id/agent_type (subagent).
guard_bash() {
  local extra='{}'
  [ -n "$2" ] && extra=$(jq -n --arg t "$2" '{agent_id: "agent-test-1", agent_type: $t}')
  jq -n --arg cmd "$1" --argjson x "$extra" \
    '{tool_name: "Bash", tool_input: {command: $cmd}} + $x' | "$GUARD" 2>/dev/null
}

# guard_file <tool> <file_path> [agent_type] — runs guard.sh for Write/Edit calls.
guard_file() {
  local extra='{}'
  [ -n "$3" ] && extra=$(jq -n --arg t "$3" '{agent_id: "agent-test-1", agent_type: $t}')
  jq -n --arg tool "$1" --arg fp "$2" --argjson x "$extra" \
    '{tool_name: $tool, tool_input: {file_path: $fp}} + $x' | "$GUARD" 2>/dev/null
}

expect_allow() { # <desc> <fn> <args...>
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else bad "$desc" "blocked, expected allow"; fi
}

expect_block() { # <desc> <fn> <args...>
  local desc="$1"; shift
  local status=0
  "$@" || status=$?
  if [ "$status" -eq 2 ]; then ok "$desc"; else bad "$desc" "exit $status, expected 2"; fi
}

echo "== guard.sh — destructive bash patterns =="
expect_allow "allows ls -la"                        guard_bash 'ls -la'
expect_allow "allows git status"                    guard_bash 'git status --short'
expect_allow "allows relative rm -rf"               guard_bash 'rm -rf ./build'
expect_block "blocks rm -rf /"                      guard_bash 'rm -rf /'
expect_block "blocks rm -rf on home"                guard_bash 'rm -rf ~/stuff'
expect_block "blocks git push --force"              guard_bash 'git push --force origin main'
expect_block "blocks git push -f"                   guard_bash 'git push -f'
expect_block "blocks --no-verify"                   guard_bash 'git commit --no-verify -m x'
expect_block "blocks mkfs"                          guard_bash 'mkfs.ext4 /dev/sda1'
expect_block "blocks bare reboot"                   guard_bash 'reboot'
expect_block "blocks chained reboot"                guard_bash 'echo done; reboot'
expect_block "blocks shutdown"                      guard_bash 'shutdown -h now'
expect_allow "allows filename containing reboot"    guard_bash 'cat reboot-notes.md'
expect_allow "allows filename containing shutdown"  guard_bash 'grep timeout shutdown_handler.py'
expect_block "blocks DROP TABLE (upper)"            guard_bash 'psql -c "DROP TABLE users;"'
expect_block "blocks drop table (lower)"            guard_bash 'psql -c "drop table users;"'
expect_block "blocks truncate table"                guard_bash 'mysql -e "truncate table logs"'
expect_allow "allows the word droplet"              guard_bash 'doctl compute droplet list'

echo "== guard.sh — fail closed without jq =="
fakebin=$(mktemp -d)
for b in bash sh cat grep mktemp dirname; do
  p=$(command -v "$b") && ln -s "$p" "$fakebin/$b"
done
status=0
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env PATH="$fakebin" bash "$GUARD" 2>/dev/null || status=$?
if [ "$status" -eq 2 ]; then ok "blocks when jq is missing"; else bad "blocks when jq is missing" "exit $status, expected 2"; fi
rm -rf "$fakebin"

echo "== guard.sh — vault integrity (gate files are Director-only) =="
expect_block "subagent cannot Write task-tree.json"      guard_file Write 'vault/task-tree.json' builder
expect_block "subagent cannot Edit task-tree.json"       guard_file Edit 'vault/task-tree.json' builder
expect_block "scribe cannot write task-tree.json"        guard_file Write 'vault/task-tree.json' scribe
expect_block "subagent cannot Edit session.md"           guard_file Edit 'vault/memory/session.md' builder
expect_allow "scribe may write session.md"               guard_file Write 'vault/memory/session.md' scribe
expect_allow "Director may Write task-tree.json"         guard_file Write 'vault/task-tree.json'
expect_allow "Director may Write session.md"             guard_file Write 'vault/memory/session.md'
expect_allow "subagent may write ordinary files"         guard_file Write 'src/app.py' builder
expect_block "subagent cannot redirect into task-tree"   guard_bash 'echo "{}" > vault/task-tree.json' builder
expect_block "subagent cannot tee into session.md"       guard_bash 'cat notes | tee vault/memory/session.md' builder
expect_allow "subagent may read task-tree.json"          guard_bash 'cat vault/task-tree.json' builder
expect_allow "Director may redirect into task-tree"      guard_bash 'echo "{}" > vault/task-tree.json'

echo "== checkpoint.sh — branch discipline =="
make_repo() { # prints repo dir; creates git repo with vault/ and one commit
  local d
  d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@test
  git -C "$d" config user.name test
  mkdir -p "$d/vault"
  echo init > "$d/file.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m "init"
  echo "$d"
}
commits() { git -C "$1" rev-list --count HEAD; }

repo=$(make_repo)
echo change > "$repo/file.txt"
before=$(commits "$repo")
(cd "$repo" && "$CHECKPOINT" </dev/null >/dev/null 2>&1)
after=$(commits "$repo")
if [ "$after" -eq "$before" ]; then ok "does not auto-commit on main"; else bad "does not auto-commit on main" "committed on main"; fi
rm -rf "$repo"

repo=$(make_repo)
git -C "$repo" checkout -q -b slice/S001
echo change > "$repo/file.txt"
before=$(commits "$repo")
(cd "$repo" && "$CHECKPOINT" </dev/null >/dev/null 2>&1)
after=$(commits "$repo")
msg=$(git -C "$repo" log -1 --format=%s)
if [ "$after" -eq $((before + 1)) ] && echo "$msg" | grep -q "S001"; then
  ok "commits slice progress on slice branch"
else
  bad "commits slice progress on slice branch" "commits $before->$after, msg: $msg"
fi
rm -rf "$repo"

repo=$(make_repo)
rm -rf "$repo/vault"
git -C "$repo" checkout -q -b slice/S001
echo change > "$repo/file.txt"
before=$(commits "$repo")
(cd "$repo" && "$CHECKPOINT" </dev/null >/dev/null 2>&1)
after=$(commits "$repo")
if [ "$after" -eq "$before" ]; then ok "no-ops without a vault"; else bad "no-ops without a vault" "committed"; fi
rm -rf "$repo"

repo=$(make_repo)
git -C "$repo" checkout -q -b slice/S001
status=0
(cd "$repo" && "$CHECKPOINT" </dev/null >/dev/null 2>&1) || status=$?
if [ "$status" -eq 0 ]; then ok "clean tree exits 0"; else bad "clean tree exits 0" "exit $status"; fi
rm -rf "$repo"

echo "== lint.sh =="
status=0
jq -n '{tool_input: {file_path: "/nonexistent/nowhere.py"}}' | "$LINT" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 0 ]; then ok "missing file exits 0"; else bad "missing file exits 0" "exit $status"; fi

tmpmd=$(mktemp /tmp/lint-test-XXXX.md)
echo "# doc" > "$tmpmd"
status=0
jq -n --arg fp "$tmpmd" '{tool_input: {file_path: $fp}}' | "$LINT" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 0 ]; then ok "non-code file exits 0"; else bad "non-code file exits 0" "exit $status"; fi
rm -f "$tmpmd"

if command -v ruff >/dev/null 2>&1; then
  tmppy=$(mktemp /tmp/lint-test-XXXX.py)
  printf 'import os\nx=undefined_name\n' > "$tmppy"
  status=0
  jq -n --arg fp "$tmppy" '{tool_input: {file_path: $fp}}' | "$LINT" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 2 ]; then ok "python lint errors exit 2"; else bad "python lint errors exit 2" "exit $status"; fi
  rm -f "$tmppy"
else
  echo "  SKIP  python lint errors exit 2 (ruff not installed)"
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
