#!/bin/bash
# Writes the global protocol into a project's AGENTS.md, the one instruction file both
# Cursor and GitHub Copilot read (Copilot's cloud coding agent and CLI too, which never
# see ~/.claude/). Claude Code reads ~/.claude/CLAUDE.md directly and ignores this file.
#
# The protocol lives in a marked block; anything else in AGENTS.md is the user's and is
# never touched. The block is derived: rewritten only when ~/.claude/CLAUDE.md changed,
# and session-start.sh re-runs this each session so upgrades propagate.
# Usage: agents-md.sh [project-dir]   (default: current directory)

SRC="${AGENTS_MD_SRC:-$HOME/.claude/CLAUDE.md}"
PROJECT="${1:-.}"
OUT="$PROJECT/AGENTS.md"
BEGIN='<!-- skeletoncrew:protocol:begin'
END='<!-- skeletoncrew:protocol:end -->'

[ -f "$SRC" ] || { echo "agents-md.sh: $SRC not found — run install.sh first" >&2; exit 1; }

block=$(mktemp); new=$(mktemp)
trap 'rm -f "$block" "$new"' EXIT
{
  echo "$BEGIN (generated from ~/.claude/CLAUDE.md by ~/.claude/scripts/agents-md.sh — edit there, not here) -->"
  echo "Tool notes: Cursor runs the agents below as subagents from ~/.cursor/agents; VS Code"
  echo "Copilot from ~/.copilot/agents, where the \`orchestrator\` agent plays the Director."
  echo "Scripts (gate.sh, hooks) live in ~/.claude/scripts."
  echo ""
  cat "$SRC"
  echo "$END"
} > "$block"

if [ ! -f "$OUT" ]; then
  cp "$block" "$new"
elif grep -qF -- "$BEGIN" "$OUT"; then
  # Replace the existing block in place, keeping the user's text on both sides.
  awk -v begin="$BEGIN" -v end="$END" -v blockfile="$block" '
    index($0, begin) == 1 { while ((getline line < blockfile) > 0) print line; skip = 1; next }
    skip && $0 == end     { skip = 0; next }
    !skip                 { print }
  ' "$OUT" > "$new"
else
  { cat "$OUT"; echo ""; cat "$block"; } > "$new"
fi

if [ -f "$OUT" ] && cmp -s "$new" "$OUT"; then
  exit 0
fi
cp "$new" "$OUT"
echo "wrote $OUT"
