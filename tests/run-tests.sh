#!/bin/bash
# Test harness for the hook scripts — mechanisms get tests, not hope.
# Feeds synthetic hook JSON into guard.sh / lint.sh / checkpoint.sh and asserts
# block/allow behavior. Run: tests/run-tests.sh   Exit nonzero on any failure.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/guard.sh"
LINT="$ROOT/scripts/lint.sh"
CHECKPOINT="$ROOT/scripts/checkpoint.sh"
GATE="$ROOT/scripts/gate.sh"
SESSION_START="$ROOT/scripts/session-start.sh"
GENERATE="$ROOT/scripts/generate-agents.sh"
AGENTS_MD="$ROOT/scripts/agents-md.sh"
LOG_EVENT="$ROOT/scripts/log-event.sh"

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
expect_block "subagent cannot Write log.jsonl"           guard_file Write 'vault/log.jsonl' reviewer
expect_block "subagent cannot append to log.jsonl"       guard_bash 'echo "{}" >> vault/log.jsonl' builder
expect_block "subagent cannot run log-event.sh"          guard_bash "$HOME/.claude/scripts/log-event.sh S001 reviewer APPROVED" reviewer
expect_allow "Director may run log-event.sh"             guard_bash "$HOME/.claude/scripts/log-event.sh S001 reviewer APPROVED"

echo "== checkpoint.sh — branch discipline =="
make_repo() { # prints repo dir; creates git repo with vault/ and one commit
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

echo "== gate.sh — quiet gate runner =="
make_gate_repo() { # <project.md gate lines> — prints repo dir
  local d
  d=$(make_repo)
  printf '# Project\n## Gate\n%s\n' "$1" > "$d/vault/project.md"
  echo "$d"
}

# shellcheck disable=SC2016  # literal shell text destined for project.md
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
  ok "prints RETRO DUE when a category recurs across two slices (ignores 'other')"
else
  bad "prints RETRO DUE when a category recurs across two slices (ignores 'other')" "$out"
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
cursor_shell() { # <command> — prints guard.sh stdout, returns its exit code
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
