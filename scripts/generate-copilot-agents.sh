#!/bin/bash
# Generates VS Code Copilot user-level custom agents (~/.copilot/agents/*.agent.md)
# from this repo's Claude Code subagent definitions (agents/*.md).
#
# Why this exists: VS Code auto-detects Claude-format subagents from a *workspace*
# .claude/agents folder, but not from the user-level ~/.claude/agents this repo
# installs to (see README -> GitHub Copilot / VS Code compatibility). So we translate
# them into VS Code's own .agent.md format and drop them where VS Code looks at the
# user level: ~/.copilot/agents/.
#
# Output is pure derived content (never hand-edited), so this always overwrites --
# unlike install.sh's handling of CLAUDE.md/settings.json, there's nothing here to
# preserve or merge.
set -e

SRC="$(cd "$(dirname "$0")/.." && pwd)/agents"
DEST="${1:-$HOME/.copilot/agents}"
mkdir -p "$DEST"

# Claude tool name -> VS Code tool identifier. VS Code ignores any tool name it
# doesn't recognize (the agent still loads, just without that capability) rather than
# failing, so an imprecise mapping degrades gracefully. The Bash -> runCommands
# mapping in particular is a best-effort guess, not confirmed against VS Code's own
# tool registry -- if a generated agent seems to be missing terminal access, check the
# real identifier via the `#` tools picker in VS Code chat and fix the case below.
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
      *) v="$t" ;;
    esac
    # Several Claude tools collapse onto the same VS Code toolset (e.g. Write/Edit ->
    # edit) -- dedupe so the output list has no repeats.
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

count=0
for src_file in "$SRC"/*.md; do
  [ -e "$src_file" ] || continue
  name=$(basename "$src_file" .md)
  claude_tools=$(sed -n 's/^tools: //p' "$src_file")
  description=$(sed -n 's/^description: //p' "$src_file")
  yaml_tools=$(to_yaml_list "$(map_tools "$claude_tools")")
  # Body = everything after the second '---' frontmatter delimiter.
  body=$(awk '/^---$/{n++; next} n>=2' "$src_file")

  {
    echo "---"
    echo "name: $name"
    echo "description: $description"
    echo "tools: $yaml_tools"
    echo "user-invocable: false"
    echo "---"
    echo "$body"
  } > "$DEST/$name.agent.md"
  count=$((count + 1))
done

# Coordinator agent -- not derived from a source file, dispatches the four worker
# agents above as subagents. Named "orchestrator" rather than "director" to stay
# distinct from CLAUDE.md's own Claude-Code-specific Director terminology, which
# refers to the main Claude Code session, not a VS Code custom agent.
cat > "$DEST/orchestrator.agent.md" <<'EOF'
---
name: orchestrator
description: Coordinates the builder/reviewer/auditor/scribe subagents through the Autonomous Engineering Protocol (see CLAUDE.md, loaded automatically as always-on instructions). Use for any feature or bugfix that should follow that workflow instead of an ad hoc chat edit.
tools: ['agent', 'read', 'edit', 'search', 'runCommands']
agents: ['builder', 'reviewer', 'auditor', 'scribe']
---

You coordinate work through the Autonomous Engineering Protocol described in your
always-on instructions (CLAUDE.md). You never write application code or run gates
yourself -- dispatch to the builder/reviewer/auditor/scribe subagents and follow the
same decomposition, gating, and resolution rules the protocol defines for the
Director role in Claude Code. Record gate verdicts and vault/task-tree.json updates
yourself; subagents report back as text only, never editing vault files directly.
EOF
count=$((count + 1))

echo "Generated $count Copilot custom agents -> $DEST"
