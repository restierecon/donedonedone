#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/guard.sh"
LINT="$ROOT/scripts/lint.sh"
CHECKPOINT="$ROOT/scripts/checkpoint.sh"
GATE="$ROOT/scripts/gate.sh"
SESSION_START="$ROOT/scripts/session-start.sh"
GENERATE="$ROOT/scripts/generate-agents.sh"
AGENTS_MD="$ROOT/scripts/agents-md.sh"
LOG_EVENT="$ROOT/scripts/log-event.sh"
FIND_COMMENTS="$ROOT/scripts/find-comments.sh"
INSTALL="$ROOT/install.sh"

pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1 ($2)"; }

guard_bash() {
  local extra='{}'
  [ -n "$2" ] && extra=$(jq -n --arg t "$2" '{agent_id: "agent-test-1", agent_type: $t}')
  jq -n --arg cmd "$1" --argjson x "$extra" \
    '{tool_name: "Bash", tool_input: {command: $cmd}} + $x' | "$GUARD" 2>/dev/null
}

guard_file() {
  local extra='{}'
  [ -n "$3" ] && extra=$(jq -n --arg t "$3" '{agent_id: "agent-test-1", agent_type: $t}')
  jq -n --arg tool "$1" --arg fp "$2" --argjson x "$extra" \
    '{tool_name: $tool, tool_input: {file_path: $fp}} + $x' | "$GUARD" 2>/dev/null
}

expect_allow() {
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else bad "$desc" "blocked, expected allow"; fi
}

expect_block() {
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

echo "== guard.sh — VS Code Copilot sends its own tool names and ignores the matcher =="
copilot_call() {
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg tool "$1" --argjson input "$2" --argjson x "$extra" '{tool_name: $tool, tool_input: $input} + $x' | "$GUARD" 2>/dev/null
}
expect_block "guard blocks a force push sent as Copilot's run_in_terminal" \
  copilot_call run_in_terminal '{"command":"git push --force origin main"}'
expect_block "guard blocks a force push sent as Copilot's runTerminalCommand" \
  copilot_call runTerminalCommand '{"command":"git push -f"}'
expect_block "guard blocks a subagent's task-tree write sent as Copilot's create_file with camelCase filePath" \
  copilot_call create_file '{"filePath":"vault/task-tree.json"}' '{"agent_id":"a1","agent_type":"builder"}'
expect_allow "guard allows a safe command sent as Copilot's run_in_terminal" \
  copilot_call run_in_terminal '{"command":"ls"}'

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
expect_block "subagent cannot Write log.jsonl"           guard_file Write 'vault/log.jsonl' reviewer
expect_block "subagent cannot append to log.jsonl"       guard_bash 'echo "{}" >> vault/log.jsonl' builder
expect_block "subagent cannot run log-event.sh"          guard_bash "$HOME/.claude/scripts/log-event.sh S001 reviewer APPROVED" reviewer
expect_allow "Director may run log-event.sh"             guard_bash "$HOME/.claude/scripts/log-event.sh S001 reviewer APPROVED"

echo "== checkpoint.sh — branch discipline =="
make_repo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@test
  git -C "$d" config user.name test
  mkdir -p "$d/vault" && touch "$d/vault/log.jsonl"
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

repo=$(make_repo)
git -C "$repo" worktree add -q "$repo/.worktrees/S002" -b slice/S002
echo change > "$repo/.worktrees/S002/file.txt"
before=$(commits "$repo/.worktrees/S002")
(cd "$repo/.worktrees/S002" && "$CHECKPOINT" </dev/null >/dev/null 2>&1)
after=$(commits "$repo/.worktrees/S002")
if [ "$after" -eq $((before + 1)) ]; then ok "commits slice progress inside a git worktree"; else bad "commits slice progress inside a git worktree" "commits $before->$after"; fi
rm -rf "$repo"

echo "== checkpoint.sh — gitleaks versions =="
checkpoint_with_gitleaks() {
  local fakebin repo before result status=0
  fakebin=$(mktemp -d)
  printf '%s\n' '#!/bin/bash' "$1" > "$fakebin/gitleaks"
  chmod +x "$fakebin/gitleaks"
  repo=$(make_repo)
  git -C "$repo" checkout -q -b slice/S030
  echo "secret" > "$repo/file.txt"
  before=$(commits "$repo")
  (cd "$repo" && PATH="$fakebin:$PATH" "$CHECKPOINT" </dev/null >/dev/null 2>&1) || status=$?
  result=1
  [ "$status" -eq 2 ] && [ "$(commits "$repo")" -eq "$before" ] && result=0
  rm -rf "$fakebin" "$repo"
  return $result
}
# shellcheck disable=SC2016
if checkpoint_with_gitleaks '[ "$1" = git ] && { [ "$2" = --help ] && exit 0; exit 1; }; exit 0'; then
  ok "checkpoint scans with 'gitleaks git --staged' on v8.19+, where protect no longer exists"
else
  bad "checkpoint scans with 'gitleaks git --staged' on v8.19+, where protect no longer exists" "committed or wrong exit"
fi
# shellcheck disable=SC2016
if checkpoint_with_gitleaks '[ "$1" = protect ] && exit 1; exit 2'; then
  ok "checkpoint falls back to 'gitleaks protect --staged' before v8.19"
else
  bad "checkpoint falls back to 'gitleaks protect --staged' before v8.19" "committed or wrong exit"
fi

echo "== gate.sh — quiet gate runner =="
make_gate_repo() {
  local d
  d=$(make_repo)
  printf '# Project\n## Gate\n%s\n' "$1" > "$d/vault/project.md"
  echo "$d"
}

# shellcheck disable=SC2016
repo=$(make_gate_repo '- gate.lint: `true`
- gate.test: echo ok')
status=0
out=$(cd "$repo" && "$GATE" 2>&1) || status=$?
if [ "$status" -eq 0 ] && echo "$out" | grep -q "^lint PASS" && echo "$out" | grep -q "^types SKIP" \
   && echo "$out" | grep -q "^GATE: PASS"; then
  ok "passing steps report PASS, unconfigured steps SKIP"
else
  bad "passing steps report PASS, unconfigured steps SKIP" "exit $status: $out"
fi
rm -rf "$repo"

# shellcheck disable=SC2016
repo=$(make_gate_repo '- gate.test: for i in $(seq 1 500); do echo "noise line $i"; done; echo "AssertionError: boom"; exit 3')
status=0
out=$(cd "$repo" && "$GATE" test 2>&1) || status=$?
lines=$(echo "$out" | wc -l)
if [ "$status" -eq 1 ] && echo "$out" | grep -q "AssertionError: boom" && [ "$lines" -lt 40 ] \
   && [ "$(wc -l < "$repo/.gate/test.log")" -gt 500 ]; then
  ok "failing step prints a short excerpt, keeps the full log on disk"
else
  bad "failing step prints a short excerpt, keeps the full log on disk" "exit $status, $lines lines"
fi
rm -rf "$repo"

repo=$(make_gate_repo '- gate.test: seq 1 100; exit 1')
out=$(cd "$repo" && "$GATE" test 2>&1)
if echo "$out" | grep -q "  100$" && ! echo "$out" | grep -q "  1$"; then
  ok "falls back to the log tail when no line names the failure"
else
  bad "falls back to the log tail when no line names the failure" "$out"
fi
rm -rf "$repo"

repo=$(make_repo)
status=0
(cd "$repo" && "$GATE" >/dev/null 2>&1) || status=$?
if [ "$status" -eq 1 ]; then ok "fails without vault/project.md"; else bad "fails without vault/project.md" "exit $status"; fi
rm -rf "$repo"

echo "== gate.sh — built-in markers step =="
repo=$(make_gate_repo '')
git -C "$repo" checkout -q -b slice/S001
printf 'ok = 1\ncard = "XXXX-1234"\n' > "$repo/app.py"
mkdir -p "$repo/vault/memory" && echo "TODO: next slice" > "$repo/vault/memory/hot.md"
git -C "$repo" add -A && git -C "$repo" commit -q -m "feat: clean slice"
status=0; out=$(cd "$repo" && "$GATE" markers 2>&1) || status=$?
if [ "$status" -eq 0 ] && echo "$out" | grep -q "^markers PASS"; then
  ok "markers passes a clean diff (vault/ exempt, XXXX is not a marker)"
else
  bad "markers passes a clean diff (vault/ exempt, XXXX is not a marker)" "exit $status: $out"
fi
printf 'ok = 1\ncard = "XXXX-1234"\nx = 2  # TODO: handle None\n' > "$repo/app.py"
git -C "$repo" commit -q -am "feat: leave a marker"
status=0; out=$(cd "$repo" && "$GATE" markers 2>&1) || status=$?
if [ "$status" -eq 1 ] && echo "$out" | grep -q "app.py:3: x = 2  # TODO" && echo "$out" | grep -q "^GATE: FAIL (markers)"; then
  ok "markers fails on an added TODO and names file:line"
else
  bad "markers fails on an added TODO and names file:line" "exit $status: $out"
fi
out=$(cd "$repo" && GATE_BASE=trunk "$GATE" markers 2>&1)
if echo "$out" | grep -q "^markers SKIP"; then ok "markers skips when the base branch is missing"; else bad "markers skips when the base branch is missing" "$out"; fi
rm -rf "$repo"

echo "== log-event.sh — structured, compaction-proof log =="
repo=$(make_repo)
: > "$repo/vault/log.jsonl"
echo "hand-written line from before the script" >> "$repo/vault/log.jsonl"
out=$(cd "$repo" && "$LOG_EVENT" S001 reviewer REJECTED --sha abc123 --attempt 1 --category error-handling \
  --signal "$(printf 'app.py:3 CRITICAL bare except\nswallows')" 2>&1)
line=$(tail -1 "$repo/vault/log.jsonl")
if [ -z "$out" ] && echo "$line" | jq -e '.slice == "S001" and .event == "reviewer" and .verdict == "REJECTED"
     and .sha == "abc123" and .attempt == 1 and .categories == ["error-handling"]
     and .signals == ["app.py:3 CRITICAL bare except swallows"]' >/dev/null 2>&1; then
  ok "writes one JSON line with verdict, sha, category and a single-line signal"
else
  bad "writes one JSON line with verdict, sha, category and a single-line signal" "$out | $line"
fi
long=$(printf 'x%.0s' $(seq 1 300))
(cd "$repo" && "$LOG_EVENT" S002 reviewer REJECTED --signal a --signal b --signal c --signal d --signal e --signal f --signal "$long" >/dev/null)
if tail -1 "$repo/vault/log.jsonl" | jq -e '(.signals | length) == 5' >/dev/null; then ok "caps signals at five"; else bad "caps signals at five" "$(tail -1 "$repo/vault/log.jsonl")"; fi
(cd "$repo" && "$LOG_EVENT" S002 reviewer REJECTED --signal "$long" >/dev/null)
if tail -1 "$repo/vault/log.jsonl" | jq -e '(.signals[0] | length) == 200' >/dev/null; then ok "truncates a signal to 200 chars"; else bad "truncates a signal to 200 chars" "$(tail -1 "$repo/vault/log.jsonl")"; fi
before=$(wc -l < "$repo/vault/log.jsonl")
s1=0; (cd "$repo" && "$LOG_EVENT" S001 bogus X >/dev/null 2>&1) || s1=$?
s2=0; (cd "$repo" && "$LOG_EVENT" S001 reviewer X --category nope >/dev/null 2>&1) || s2=$?
if [ "$s1" -eq 1 ] && [ "$s2" -eq 1 ] && [ "$(wc -l < "$repo/vault/log.jsonl")" -eq "$before" ]; then
  ok "rejects an unknown event or category and writes nothing"
else
  bad "rejects an unknown event or category and writes nothing" "exits $s1/$s2"
fi
out=$(cd "$repo" && "$LOG_EVENT" S001 reviewer REJECTED --category error-handling 2>&1)
if [ -z "$out" ]; then ok "no RETRO DUE when only one slice has the category"; else bad "no RETRO DUE when only one slice has the category" "$out"; fi
out=$(cd "$repo" && "$LOG_EVENT" S003 reviewer REJECTED --category error-handling --category other 2>&1)
if echo "$out" | grep -q "^RETRO DUE: error-handling recurred in S001, S003" && ! echo "$out" | grep -q "other"; then
  ok "prints RETRO DUE when a category recurs across two slices (ignores 'other' and hand-written non-JSON lines)"
else
  bad "prints RETRO DUE when a category recurs across two slices (ignores 'other' and hand-written non-JSON lines)" "$out"
fi
(cd "$repo" && "$LOG_EVENT" - retro "done" --signal "1 proposal" >/dev/null)
out=$(cd "$repo" && "$LOG_EVENT" S004 reviewer REJECTED --category error-handling 2>&1)
if [ -z "$out" ]; then ok "a retro line closes the window"; else bad "a retro line closes the window" "$out"; fi
git -C "$repo" worktree add -q "$repo/.worktrees/S005" -b slice/S005
(cd "$repo/.worktrees/S005" && "$LOG_EVENT" S005 gate PASS --sha def456 >/dev/null)
if tail -1 "$repo/vault/log.jsonl" | jq -e '.slice == "S005"' >/dev/null && [ ! -s "$repo/.worktrees/S005/vault/log.jsonl" ]; then
  ok "writes to the main checkout's log from inside a worktree"
else
  bad "writes to the main checkout's log from inside a worktree" "$(tail -1 "$repo/vault/log.jsonl")"
fi
rm -rf "$repo/vault"
status=0; (cd "$repo" && "$LOG_EVENT" S001 gate PASS >/dev/null 2>&1) || status=$?
if [ "$status" -eq 1 ]; then ok "fails without a vault"; else bad "fails without a vault" "exit $status"; fi
rm -rf "$repo"

echo "== gate.sh — worktrees =="
repo=$(make_gate_repo '- gate.test: echo ok')
git -C "$repo" worktree add -q "$repo/.worktrees/S010" -b slice/S010
rm -f "$repo/.worktrees/S010/vault/project.md"
out=$(cd "$repo/.worktrees/S010" && "$GATE" test 2>&1)
if echo "$out" | grep -q "^test PASS"; then
  ok "gate reads the main checkout's project.md from a worktree that predates it"
else
  bad "gate reads the main checkout's project.md from a worktree that predates it" "$out"
fi
rm -rf "$repo"

echo "== find-comments.sh — no comments in any codebase =="
fc=$(mktemp -d)
cp "$ROOT"/tests/fixtures/comments/* "$fc/"
out=$("$FIND_COMMENTS" "$fc/sample.py" | sed "s|$fc/||" | cut -d: -f1-2 | tr '\n' ' ')
if [ "$out" = "sample.py:3 sample.py:6 sample.py:8 sample.py:9 sample.py:10 sample.py:14 " ]; then
  ok "python: flags comments and docstrings, not strings, argument strings or directives"
else
  bad "python: flags comments and docstrings, not strings, argument strings or directives" "$out"
fi
out=$("$FIND_COMMENTS" "$fc/sample.sh" | sed "s|$fc/||" | cut -d: -f1-2 | tr '\n' ' ')
if [ "$out" = "sample.sh:2 sample.sh:4 " ]; then
  ok "shell: flags comments, not \$#, \${#}, quoted or escaped #, heredocs or shellcheck directives"
else
  bad "shell: flags comments, not \$#, \${#}, quoted or escaped #, heredocs or shellcheck directives" "$out"
fi
out=$("$FIND_COMMENTS" "$fc/sample.ts" | sed "s|$fc/||" | cut -d: -f1-2 | tr '\n' ' ')
if [ "$out" = "sample.ts:2 sample.ts:6 sample.ts:7 sample.ts:8 sample.ts:9 " ]; then
  ok "typescript: flags line, block and doc comments, not template literals, URLs or directives"
else
  bad "typescript: flags line, block and doc comments, not template literals, URLs or directives" "$out"
fi
out=$("$FIND_COMMENTS" "$fc/sample.go" "$fc/sample.rs" "$fc/sample.yml" "$fc/sample.html" | sed "s|$fc/||" | cut -d: -f1-2 | tr '\n' ' ')
if [ "$out" = "sample.go:2 sample.rs:1 sample.yml:3 sample.html:2 sample.html:3 " ]; then
  ok "go, rust, yaml, html: comments flagged; build tags, raw and multi-line strings, lifetimes left alone"
else
  bad "go, rust, yaml, html: comments flagged; build tags, raw and multi-line strings, lifetimes left alone" "$out"
fi
status=0; "$FIND_COMMENTS" "$fc/clean.py" "$fc/data.json" >/dev/null || status=$?
if [ "$status" -eq 0 ]; then ok "exits 0 on clean files and ignores unknown file types"; else bad "exits 0 on clean files and ignores unknown file types" "exit $status"; fi
rm -rf "$fc"

repo=$(make_gate_repo '- gate.comments.skip: migrations/
- gate.comments.directives: ^keep-me')
printf 'x = 1  # legacy comment stays\n' > "$repo/app.py"
git -C "$repo" add -A && git -C "$repo" commit -q -m "legacy"
git -C "$repo" checkout -q -b slice/S020
printf 'x = 1  # legacy comment stays\ny = 2\n' > "$repo/app.py"
mkdir -p "$repo/migrations" && printf '# Generated by the framework\n' > "$repo/migrations/0001.py"
printf 'z = 3  # keep-me: project directive\n' > "$repo/tool.py"
git -C "$repo" add -A && git -C "$repo" commit -q -m "feat: clean slice"
status=0; out=$(cd "$repo" && "$GATE" comments 2>&1) || status=$?
if [ "$status" -eq 0 ] && echo "$out" | grep -q "^comments PASS"; then
  ok "comments gate checks only added lines, honours gate.comments.skip and gate.comments.directives"
else
  bad "comments gate checks only added lines, honours gate.comments.skip and gate.comments.directives" "exit $status: $out"
fi
printf 'x = 1  # legacy comment stays\ny = 2  # explains y\n' > "$repo/app.py"
git -C "$repo" commit -q -am "feat: add a comment"
status=0; out=$(cd "$repo" && "$GATE" comments 2>&1) || status=$?
if [ "$status" -eq 1 ] && echo "$out" | grep -q "app.py:2: y = 2  # explains y" && ! echo "$out" | grep -q "legacy"; then
  ok "comments gate fails on an added comment and names file:line"
else
  bad "comments gate fails on an added comment and names file:line" "exit $status: $out"
fi
out=$(cd "$repo" && GATE_BASE=trunk "$GATE" comments 2>&1)
if echo "$out" | grep -q "^comments SKIP"; then ok "comments gate skips when the base branch is missing"; else bad "comments gate skips when the base branch is missing" "$out"; fi
rm -rf "$repo"

echo "== session-start.sh — resume context in one injection =="
repo=$(make_repo)
out=$(cd "$repo" && "$SESSION_START" </dev/null 2>&1)
if [ -z "$out" ]; then ok "silent without session.md"; else bad "silent without session.md" "$out"; fi
mkdir -p "$repo/vault/memory"
echo "# Session State" > "$repo/vault/memory/session.md"
echo '{"slices":[{"id":"S003","title":"User can export notes","status":"todo","depends_on":["S001"]}]}' \
  > "$repo/vault/task-tree.json"
git -C "$repo" worktree add -q "$repo/.worktrees/S009" -b slice/S009
out=$(cd "$repo" && "$SESSION_START" </dev/null 2>&1)
if echo "$out" | grep -q "^# Session State" && echo "$out" | grep -q "S003 · todo · \[S001\]" \
   && echo "$out" | grep -q "leftover worktrees" && echo "$out" | grep -q "S009"; then
  ok "prints session.md, live-slice summary, leftover worktrees"
else
  bad "prints session.md, live-slice summary, leftover worktrees" "$out"
fi
rm -rf "$repo"

echo "== Cursor hook payloads =="
cursor_shell() {
  jq -n --arg c "$1" '{hook_event_name: "beforeShellExecution", command: $c, workspace_roots: ["/tmp"]}' \
    | "$GUARD" 2>/dev/null
}
status=0; out=$(cursor_shell 'git push --force origin main') || status=$?
if [ "$status" -eq 2 ] && [ "$(echo "$out" | jq -r .permission)" = "deny" ]; then
  ok "guard denies a Cursor shell command with deny JSON + exit 2"
else
  bad "guard denies a Cursor shell command with deny JSON + exit 2" "exit $status: $out"
fi
status=0; out=$(cursor_shell 'ls -la') || status=$?
if [ "$status" -eq 0 ] && [ "$(echo "$out" | jq -r .permission)" = "allow" ]; then
  ok "guard allows a safe Cursor shell command with allow JSON"
else
  bad "guard allows a safe Cursor shell command with allow JSON" "exit $status: $out"
fi
out=$(guard_bash 'ls -la')
if [ -z "$out" ]; then ok "guard prints nothing for Claude Code payloads"; else bad "guard prints nothing for Claude Code payloads" "$out"; fi

repo=$(make_repo)
git -C "$repo" checkout -q -b slice/S004
echo change > "$repo/file.txt"
before=$(commits "$repo")
(cd /tmp && jq -n --arg r "$repo" '{hook_event_name: "stop", status: "completed", workspace_roots: [$r]}' \
  | "$CHECKPOINT" >/dev/null 2>&1)
after=$(commits "$repo")
if [ "$after" -eq $((before + 1)) ]; then ok "checkpoint finds the project via workspace_roots"; else bad "checkpoint finds the project via workspace_roots" "commits $before->$after"; fi
rm -rf "$repo"

repo=$(make_repo)
mkdir -p "$repo/vault/memory"
echo "# Session State" > "$repo/vault/memory/session.md"
printf '<!-- skeletoncrew:protocol:begin old -->\nstale\n<!-- skeletoncrew:protocol:end -->\n' > "$repo/AGENTS.md"
out=$(cd /tmp && jq -n --arg r "$repo" '{hook_event_name: "sessionStart", workspace_roots: [$r]}' \
  | AGENTS_MD_SRC="$ROOT/CLAUDE.md" "$SESSION_START" 2>/dev/null)
if echo "$out" | jq -e '.additional_context | test("# Session State")' >/dev/null 2>&1 \
   && grep -q "Autonomous Engineering Protocol" "$repo/AGENTS.md" && ! grep -q "^stale$" "$repo/AGENTS.md"; then
  ok "session-start answers Cursor with additional_context JSON and refreshes AGENTS.md"
else
  bad "session-start answers Cursor with additional_context JSON and refreshes AGENTS.md" "$out"
fi
printf '<!-- skeletoncrew:protocol:begin old -->\nstale\n<!-- skeletoncrew:protocol:end -->\n' > "$repo/AGENTS.md"
(cd "$repo" && AGENTS_MD_SRC="$ROOT/CLAUDE.md" "$SESSION_START" </dev/null >/dev/null 2>&1)
if ! grep -q "^stale$" "$repo/AGENTS.md"; then ok "session-start refreshes AGENTS.md under Claude Code too"; else bad "session-start refreshes AGENTS.md under Claude Code too" "still stale"; fi
rm -rf "$repo"

echo "== generate-agents.sh / agents-md.sh =="
gen=$(mktemp -d)
"$GENERATE" copilot "$gen/copilot" >/dev/null
"$GENERATE" cursor "$gen/cursor" >/dev/null
n_src=$(find "$ROOT/agents" -name '*.md' | wc -l)
if [ "$(find "$gen/copilot" -name '*.agent.md' | wc -l)" -eq $((n_src + 1)) ]; then
  ok "copilot target emits every agent plus the orchestrator"
else
  bad "copilot target emits every agent plus the orchestrator" "$(ls "$gen/copilot")"
fi
if grep -q "^readonly: true" "$gen/cursor/reviewer.md" && grep -q "^readonly: true" "$gen/cursor/auditor.md" \
   && grep -q "^readonly: false" "$gen/cursor/builder.md" && grep -q "^model: fast" "$gen/cursor/scribe.md"; then
  ok "cursor target maps write-less agents to readonly, haiku to fast"
else
  bad "cursor target maps write-less agents to readonly, haiku to fast" "$(grep -h '^readonly\|^model' "$gen"/cursor/*.md | tr '\n' ' ')"
fi
roster_ok=1
for f in "$ROOT"/agents/*.md; do
  grep -q "^agents: .*'$(basename "$f" .md)'" "$gen/copilot/orchestrator.agent.md" || roster_ok=0
done
if [ "$roster_ok" -eq 1 ]; then ok "copilot orchestrator may dispatch every agent in agents/"; else bad "copilot orchestrator may dispatch every agent in agents/" "$(grep '^agents:' "$gen/copilot/orchestrator.agent.md")"; fi
if grep -q "^readonly: true" "$gen/cursor/retro.md" && grep -q "^tools: \['read', 'search'\]" "$gen/copilot/retro.agent.md"; then
  ok "retro is read-only under Cursor and Copilot"
else
  bad "retro is read-only under Cursor and Copilot" "$(grep -h '^readonly\|^tools' "$gen/cursor/retro.md" "$gen/copilot/retro.agent.md")"
fi
if grep -q "^tools: \['read', 'edit', 'search', 'runCommands'\]" "$gen/copilot/builder.agent.md"; then
  ok "copilot collapses Write and Edit into one 'edit' toolset"
else
  bad "copilot collapses Write and Edit into one 'edit' toolset" "$(grep '^tools' "$gen/copilot/builder.agent.md")"
fi
status=0; "$GENERATE" bogus >/dev/null 2>&1 || status=$?
if [ "$status" -eq 1 ]; then ok "unknown target exits 1"; else bad "unknown target exits 1" "exit $status"; fi
proj="$gen/proj"; mkdir -p "$proj"
first=$(AGENTS_MD_SRC="$ROOT/CLAUDE.md" "$AGENTS_MD" "$proj")
second=$(AGENTS_MD_SRC="$ROOT/CLAUDE.md" "$AGENTS_MD" "$proj")
if [ -n "$first" ] && [ -z "$second" ] && grep -q "Autonomous Engineering Protocol" "$proj/AGENTS.md"; then
  ok "agents-md creates AGENTS.md once and is a no-op when unchanged"
else
  bad "agents-md creates AGENTS.md once and is a no-op when unchanged" "first=$first second=$second"
fi
printf '# Mine above\n<!-- skeletoncrew:protocol:begin x -->\nstale\n<!-- skeletoncrew:protocol:end -->\n# Mine below\n' > "$proj/AGENTS.md"
AGENTS_MD_SRC="$ROOT/CLAUDE.md" "$AGENTS_MD" "$proj" >/dev/null
if [ "$(head -1 "$proj/AGENTS.md")" = "# Mine above" ] && [ "$(tail -1 "$proj/AGENTS.md")" = "# Mine below" ] \
   && ! grep -q "^stale$" "$proj/AGENTS.md" && [ "$(grep -c 'skeletoncrew:protocol:begin' "$proj/AGENTS.md")" -eq 1 ]; then
  ok "agents-md replaces a stale block in place and keeps the user's own text"
else
  bad "agents-md replaces a stale block in place and keeps the user's own text" "$(head -3 "$proj/AGENTS.md")"
fi
printf '# Existing notes\n' > "$proj/AGENTS.md"
AGENTS_MD_SRC="$ROOT/CLAUDE.md" "$AGENTS_MD" "$proj" >/dev/null
if [ "$(head -1 "$proj/AGENTS.md")" = "# Existing notes" ] && grep -q "skeletoncrew:protocol:end" "$proj/AGENTS.md"; then
  ok "agents-md appends the block to an AGENTS.md that has none"
else
  bad "agents-md appends the block to an AGENTS.md that has none" "$(head -3 "$proj/AGENTS.md")"
fi
rm -rf "$gen"

echo "== lint.sh =="
fakebin=$(mktemp -d)
# shellcheck disable=SC2016
printf '#!/bin/bash\n[ "$1" = check ] && { echo "E999 fake lint error"; exit 1; }\nexit 0\n' > "$fakebin/ruff"
chmod +x "$fakebin/ruff"
tmppy=$(mktemp /tmp/lint-test-XXXX.py)
status=0
jq -n --arg fp "$tmppy" '{tool_input: {filePath: $fp}}' | PATH="$fakebin:$PATH" "$LINT" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then ok "lint reads VS Code Copilot's camelCase filePath"; else bad "lint reads VS Code Copilot's camelCase filePath" "exit $status"; fi
status=0
jq -n --arg fp "$tmppy" '{hook_event_name: "afterFileEdit", file_path: $fp}' | PATH="$fakebin:$PATH" "$LINT" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then ok "lint reads Cursor's top-level file_path"; else bad "lint reads Cursor's top-level file_path" "exit $status"; fi
rm -rf "$fakebin" "$tmppy"
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

echo "== install.sh — never clobbers what the user already has =="
home=$(mktemp -d)
mkdir -p "$home/.claude/commands" "$home/.claude/scripts" "$home/.cursor"
echo '{"mine": true}' > "$home/.claude/settings.json"
echo "# my own global rules" > "$home/.claude/CLAUDE.md"
echo "old" > "$home/.claude/commands/init-vault.md"
echo "old" > "$home/.claude/scripts/generate-copilot-agents.sh"
echo '{"mine": true}' > "$home/.cursor/hooks.json"
HOME="$home" "$INSTALL" >/dev/null 2>&1
if [ "$(jq -r .mine "$home/.claude/settings.json")" = "true" ] && ls "$home"/.claude/settings.json.new-* >/dev/null 2>&1; then
  ok "install keeps an existing settings.json and drops the new one beside it"
else
  bad "install keeps an existing settings.json and drops the new one beside it" "$(ls "$home/.claude")"
fi
if grep -q "my own global rules" "$home"/.claude/CLAUDE.md.bak-* 2>/dev/null && cmp -s "$ROOT/CLAUDE.md" "$home/.claude/CLAUDE.md"; then
  ok "install backs up a differing CLAUDE.md before replacing it"
else
  bad "install backs up a differing CLAUDE.md before replacing it" "$(ls "$home/.claude")"
fi
if [ "$(jq -r .mine "$home/.cursor/hooks.json")" = "true" ] && ls "$home"/.cursor/hooks.json.new-* >/dev/null 2>&1; then
  ok "install keeps an existing Cursor hooks.json and drops the new one beside it"
else
  bad "install keeps an existing Cursor hooks.json and drops the new one beside it" "$(ls "$home/.cursor")"
fi
if [ ! -e "$home/.claude/commands/init-vault.md" ] && ls "$home"/.claude/commands/init-vault.md.bak-* >/dev/null 2>&1 \
   && [ ! -e "$home/.claude/scripts/generate-copilot-agents.sh" ]; then
  ok "install retires the old init-vault command and the renamed agent generator"
else
  bad "install retires the old init-vault command and the renamed agent generator" "$(ls "$home/.claude/commands" "$home/.claude/scripts")"
fi
rm -rf "$home"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
