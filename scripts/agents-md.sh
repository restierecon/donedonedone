#!/bin/bash

SRC="${AGENTS_MD_SRC:-$(cd "$(dirname "$0")/.." && pwd)/PROTOCOL.md}"
PROJECT="${1:-.}"
OUT="$PROJECT/AGENTS.md"
BEGIN='<!-- skeletoncrew:protocol:begin'
END='<!-- skeletoncrew:protocol:end -->'

[ -f "$SRC" ] || { echo "agents-md.sh: $SRC not found — run install.sh first" >&2; exit 1; }

block=$(mktemp); new=$(mktemp)
trap 'rm -f "$block" "$new"' EXIT
{
  echo "$BEGIN (generated from ~/.tbv/PROTOCOL.md by ~/.tbv/scripts/agents-md.sh — edit there, not here) -->"
  echo "Tool notes: Claude Code runs the agents below as subagents from ~/.claude/agents; Cursor"
  echo "from ~/.cursor/agents; Copilot (VS Code, the CLI and the cloud agent) from ~/.copilot/agents or"
  echo "the project's .github/agents, where the \`orchestrator\` agent plays the Director. Skills are"
  echo "in ~/.tbv/skills/<name>/SKILL.md: open that file when your tool has no skill loader."
  echo "Where no hook compacts shell output (Cursor, Copilot), run a noisy command outside gate.sh"
  echo "as \`~/.tbv/scripts/tbv run -- <command>\`."
  echo "Scripts (gate.sh, hooks) live in ~/.tbv/scripts. They are bash: on Windows, run them"
  echo "from Git Bash or WSL; from PowerShell, go through Git Bash:"
  printf '%s\n' "\`& \"\$env:ProgramFiles\\Git\\bin\\bash.exe\" -c '~/.tbv/scripts/gate.sh test -- <targets>'\`"
  echo ""
  cat "$SRC"
  echo "$END"
} > "$block"

if [ ! -f "$OUT" ]; then
  cp "$block" "$new"
elif grep -qF -- "$BEGIN" "$OUT"; then
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
