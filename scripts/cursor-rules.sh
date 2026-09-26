#!/bin/bash
# Writes the global protocol into a project as a Cursor rule. Cursor never reads
# CLAUDE.md and has no file-based global rules (User Rules live in its settings UI), so
# each vault project carries .cursor/rules/autonomous-protocol.mdc, applied to every
# request. The file is derived: this script rewrites it only when the source changed,
# and session-start.sh re-runs it on each Cursor session so upgrades propagate.
# Usage: cursor-rules.sh [project-dir]   (default: current directory)

SRC="${CURSOR_RULES_SRC:-$HOME/.claude/CLAUDE.md}"
PROJECT="${1:-.}"
OUT="$PROJECT/.cursor/rules/autonomous-protocol.mdc"

[ -f "$SRC" ] || { echo "cursor-rules.sh: $SRC not found — run install.sh first" >&2; exit 1; }

tmp=$(mktemp)
{
  echo "---"
  echo "description: Autonomous Engineering Protocol (generated from ~/.claude/CLAUDE.md by ~/.claude/scripts/cursor-rules.sh — do not edit here)"
  echo "alwaysApply: true"
  echo "---"
  echo ""
  echo "In Cursor: the agents named below are subagents in ~/.cursor/agents; scripts are in ~/.claude/scripts."
  echo ""
  cat "$SRC"
} > "$tmp"

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  rm -f "$tmp"
  exit 0
fi
mkdir -p "$(dirname "$OUT")"
mv "$tmp" "$OUT"
echo "wrote $OUT"
