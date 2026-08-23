#!/bin/bash
# One-command install into ~/.claude — safe to re-run (backs up, never clobbers blindly).
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
TS=$(date +%Y%m%d-%H%M%S)

echo "Installing autonomous engineering setup → $DEST"
mkdir -p "$DEST"/{agents,commands,scripts,skills}

# Global CLAUDE.md — back up if one exists and differs
if [ -f "$DEST/CLAUDE.md" ] && ! cmp -s "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"; then
  cp "$DEST/CLAUDE.md" "$DEST/CLAUDE.md.bak-$TS"
  echo "  backed up existing CLAUDE.md → CLAUDE.md.bak-$TS"
fi
cp "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"

# settings.json — never overwrite an existing one; drop alongside for manual merge
if [ -f "$DEST/settings.json" ] && ! cmp -s "$SRC/settings.json" "$DEST/settings.json"; then
  cp "$SRC/settings.json" "$DEST/settings.json.new-$TS"
  echo "  !! existing settings.json kept. Merge permissions+hooks from settings.json.new-$TS manually."
else
  cp "$SRC/settings.json" "$DEST/settings.json"
fi

cp "$SRC"/agents/*.md "$DEST/agents/"
cp "$SRC"/commands/*.md "$DEST/commands/"
cp "$SRC"/scripts/*.sh "$DEST/scripts/"
chmod +x "$DEST"/scripts/*.sh
cp -R "$SRC"/skills/* "$DEST/skills/"

# GitHub Copilot in VS Code reads ~/.claude/CLAUDE.md, ~/.claude/skills/, and
# ~/.claude/settings.json (hooks) natively -- nothing extra needed for those. Its
# subagents are workspace-scoped only though, so builder/reviewer/auditor/scribe need
# a generated user-level equivalent at ~/.copilot/agents/.
"$DEST/scripts/generate-copilot-agents.sh" >/dev/null

echo ""
echo "Installed: 4 agents · 5 skills · 3 hook scripts · /init-vault · /harvest · global CLAUDE.md"
echo "Also generated: 5 GitHub Copilot custom agents → ~/.copilot/agents/"
echo ""
echo "Recommended (optional) tools for full guardrails:"
command -v jq >/dev/null 2>&1       || echo "  brew install jq        (required by hook scripts)"
command -v gitleaks >/dev/null 2>&1 || echo "  brew install gitleaks  (secret-scan before checkpoints)"
command -v semgrep >/dev/null 2>&1  || echo "  brew install semgrep   (auditor scanner)"
command -v ruff >/dev/null 2>&1     || echo "  pip install ruff       (python lint loop)"
echo ""
echo "Next: cd into any project, run 'claude', then '/init-vault'."
echo "First feature: run /grill before decomposing. Dial starts at supervised — earn semi via evals/."
