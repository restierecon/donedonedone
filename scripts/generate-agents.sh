#!/bin/bash
set -e

SRC="$(cd "$(dirname "$0")/.." && pwd)/agents"
TARGET="${1:-}"
case "$TARGET" in
  claude)  DEST="${2:-$HOME/.claude/agents}" ;;
  copilot) DEST="${2:-$HOME/.copilot/agents}" ;;
  cursor)  DEST="${2:-$HOME/.cursor/agents}" ;;
  *) echo "usage: $(basename "$0") <claude|copilot|cursor> [dest]" >&2; exit 1 ;;
esac
mkdir -p "$DEST"

map_tools() {
  local claude_tools="$1"
  local out=()
  IFS=',' read -ra parts <<< "$claude_tools"
  for t in "${parts[@]}"; do
    t="$(echo "$t" | xargs)"
    case "$t" in
      Read) v="read" ;;
      Write|Edit|MultiEdit) v="edit" ;;
      Grep|Glob) v="search" ;;
      Bash) v="execute" ;;
      mcp__*) continue ;;
      *) v="$t" ;;
    esac
    if [[ " ${out[*]} " != *" $v "* ]]; then
      out+=("$v")
    fi
  done
  (IFS=,; echo "${out[*]}")
}

to_yaml_list() {
  local csv="$1" first=1 result="["
  IFS=',' read -ra items <<< "$csv"
  for i in "${items[@]}"; do
    [ $first -eq 0 ] && result+=", "
    result+="'$i'"
    first=0
  done
  echo "${result}]"
}

# shellcheck disable=SC2016
windows_note() {
  printf '\n%s\n%s\n%s\n%s\n%s\n' \
    'Scripts in ~/.tbv/scripts are bash. On Windows, run them from Git Bash or WSL; from' \
    "PowerShell, go through Git Bash: \`& \"\$env:ProgramFiles\\Git\\bin\\bash.exe\" -c '~/.tbv/scripts/gate.sh test -- <targets>'\`" \
    'No hook compacts shell output in this tool: for a noisy command outside gate.sh (a test' \
    'run, a build, a long diff or search), run it as `~/.tbv/scripts/tbv run -- <command>` and' \
    'fetch omitted parts with `~/.tbv/scripts/tbv artifact <id>`.'
}

claude_model() {
  case "$1" in
    economy) echo sonnet ;;
    *) echo "$1" ;;
  esac
}

generate_claude() {
  local count=0 src_file name
  for src_file in "$SRC"/*.md; do
    [ -e "$src_file" ] || continue
    name=$(basename "$src_file" .md)
    awk -v model="$(claude_model "$(sed -n 's/^model: //p' "$src_file" | head -1)")" '
      /^---$/ { n++ }
      n == 1 && /^model: / { print "model: " model; next }
      { print }
    ' "$src_file" > "$DEST/$name.md"
    count=$((count + 1))
  done
  echo "Generated $count Claude Code subagents -> $DEST"
}

generate_cursor() {
  local count=0 src_file name tools description ro body
  for src_file in "$SRC"/*.md; do
    [ -e "$src_file" ] || continue
    name=$(basename "$src_file" .md)
    tools=$(sed -n 's/^tools: //p' "$src_file")
    description=$(sed -n 's/^description: //p' "$src_file")
    ro=true
    echo "$tools" | grep -qE '(^|[ ,])(Write|Edit|MultiEdit)([ ,]|$)' && ro=false
    body=$(awk '/^---$/{n++; next} n>=2' "$src_file")
    {
      echo "---"
      echo "name: $name"
      echo "description: $description"
      echo "model: inherit"
      echo "readonly: $ro"
      echo "---"
      echo "$body"
      windows_note
    } > "$DEST/$name.md"
    count=$((count + 1))
  done
  echo "Generated $count Cursor subagents -> $DEST"
}

generate_copilot() {
  local count=0 src_file name claude_tools description yaml_tools body names=()
  for src_file in "$SRC"/*.md; do
    [ -e "$src_file" ] || continue
    name=$(basename "$src_file" .md)
    claude_tools=$(sed -n 's/^tools: //p' "$src_file")
    description=$(sed -n 's/^description: //p' "$src_file")
    yaml_tools=$(to_yaml_list "$(map_tools "$claude_tools")")
    body=$(awk '/^---$/{n++; next} n>=2' "$src_file")
    {
      echo "---"
      echo "name: $name"
      echo "description: $description"
      echo "tools: $yaml_tools"
      echo "user-invocable: false"
      echo "---"
      echo "$body"
      windows_note
    } > "$DEST/$name.agent.md"
    names+=("$name")
    count=$((count + 1))
  done
  local roster roster_prose
  roster=$(to_yaml_list "$(IFS=,; echo "${names[*]}")")
  roster_prose=$(IFS=/; echo "${names[*]}")

  cat > "$DEST/orchestrator.agent.md" <<AGENT
---
name: orchestrator
description: Coordinates the ${roster_prose} subagents through the Autonomous Engineering Protocol (in the project's AGENTS.md; the installed copy is ~/.tbv/PROTOCOL.md). Use for any feature or bugfix that should follow that workflow instead of an ad hoc chat edit.
tools: ['agent', 'read', 'edit', 'search', 'execute']
agents: ${roster}
---

You coordinate work through the Autonomous Engineering Protocol described in your
always-on instructions (the protocol block in AGENTS.md; read ~/.tbv/PROTOCOL.md if it is missing). You never write application code
yourself -- dispatch to the ${roster_prose} subagents and follow the
same decomposition, gating, and resolution rules the protocol defines for the
Director role. You do run ~/.tbv/scripts/gate.sh once per slice
yourself (Completion Gates step 2) and act on what it prints, including a test line
over gate.test.budget. A crap or mutation FAIL is a gate FAIL like any other: back to
the builder. For CRAP hotspots or mutation survivors outside a slice's diff
(architecture reviews, adopted codebases), follow ~/.tbv/skills/crap-hotspots/SKILL.md
or ~/.tbv/skills/mutation-survivors/SKILL.md. A builder brief starts with
SLICE: <ID>; when that slice's auditor_triggers is non-empty, its STANDING orders the
builder to follow ~/.tbv/skills/harden-diff/SKILL.md (brief-contract skill). A slice
with a contract gets the tester first, then ~/.tbv/scripts/contract.sh lock <ID>,
before its builder; a locked test is never edited by a builder. Every slice
carries a risk assessment: adopt an approved plan with ~/.tbv/scripts/adopt-plan.sh
(it runs risk-gate.sh assess on each slice), and merge with
~/.tbv/scripts/land-slice.sh <ID> (it runs risk-gate.sh check <ID> merge first); follow
~/.tbv/skills/risk-gate/SKILL.md for the controls each class needs. Human approvals
come only from approve-risk.sh and approve-ui.sh run by a human in their own terminal;
never run them or write their ledger. Record each gate verdict yourself with
~/.tbv/scripts/record-gate.sh <ID> <gate> <verdict> (task-tree.json, log.jsonl and a
commit in one call; other log lines through ~/.tbv/scripts/log-event.sh); subagents
report back as text only, never editing vault files directly.
AGENT
  windows_note >> "$DEST/orchestrator.agent.md"
  count=$((count + 1))

  echo "Generated $count Copilot custom agents -> $DEST"
}

case "$TARGET" in
  claude) generate_claude ;;
  cursor) generate_cursor ;;
  *) generate_copilot ;;
esac
