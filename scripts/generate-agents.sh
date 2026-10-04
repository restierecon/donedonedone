#!/bin/bash
set -e

SRC="$(cd "$(dirname "$0")/.." && pwd)/agents"
TARGET="${1:-}"
case "$TARGET" in
  copilot) DEST="${2:-$HOME/.copilot/agents}" ;;
  cursor)  DEST="${2:-$HOME/.cursor/agents}" ;;
  *) echo "usage: $(basename "$0") <copilot|cursor> [dest]" >&2; exit 1 ;;
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
      Bash) v="runCommands" ;;
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

windows_note() {
  printf '\n%s\n%s\n' \
    'Scripts in ~/.claude/scripts are bash. On Windows, run them from Git Bash or WSL; from' \
    "PowerShell, go through Git Bash: \`& \"\$env:ProgramFiles\\Git\\bin\\bash.exe\" -c '~/.claude/scripts/gate.sh test -- <targets>'\`"
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
description: Coordinates the ${roster_prose} subagents through the Autonomous Engineering Protocol (in the project's AGENTS.md, and in ~/.claude/CLAUDE.md when chat.useClaudeMdFile is on). Use for any feature or bugfix that should follow that workflow instead of an ad hoc chat edit.
tools: ['agent', 'read', 'edit', 'search', 'runCommands']
agents: ${roster}
---

You coordinate work through the Autonomous Engineering Protocol described in your
always-on instructions (the protocol block in AGENTS.md, or ~/.claude/CLAUDE.md). You never write application code
yourself -- dispatch to the ${roster_prose} subagents and follow the
same decomposition, gating, and resolution rules the protocol defines for the
Director role in Claude Code. You do run ~/.claude/scripts/gate.sh once per slice
yourself (Completion Gates step 2) and act on what it prints, including a test line
over gate.test.budget. A crap or mutation FAIL is a gate FAIL like any other: back to
the builder. For CRAP hotspots or mutation survivors outside a slice's diff
(architecture reviews, adopted codebases), follow ~/.claude/skills/crap-hotspots/SKILL.md
or ~/.claude/skills/mutation-survivors/SKILL.md. A builder brief starts with
SLICE: <ID>; when that slice's auditor_triggers is non-empty, its STANDING orders the
builder to follow ~/.claude/skills/harden-diff/SKILL.md (brief-contract skill). Every slice
carries a risk assessment: run ~/.claude/scripts/risk-gate.sh assess <ID> before its
builder and risk-gate.sh check <ID> merge before merging, and follow
~/.claude/skills/risk-gate/SKILL.md for the controls each class needs. Human approvals
come only from approve-risk.sh run by a human in their own terminal; never run it or
write its ledger. Record gate verdicts, vault/task-tree.json updates and
vault/log.jsonl lines (through ~/.claude/scripts/log-event.sh) yourself; subagents
report back as text only, never editing vault files directly.
AGENT
  windows_note >> "$DEST/orchestrator.agent.md"
  count=$((count + 1))

  echo "Generated $count Copilot custom agents -> $DEST"
}

if [ "$TARGET" = "cursor" ]; then generate_cursor; else generate_copilot; fi
