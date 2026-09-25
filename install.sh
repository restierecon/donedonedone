#!/bin/bash
# One-command install into ~/.claude — safe to re-run (backs up, never clobbers blindly).
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
TS=$(date +%Y%m%d-%H%M%S)

echo "Installing autonomous engineering setup → $DEST"
mkdir -p "$DEST"/{agents,scripts,skills}

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
# /init-vault and /harvest used to ship as commands/ duplicates of their skills. Skills are
# slash-invocable themselves, so retire the old copies rather than leave two definitions.
for old in init-vault harvest; do
  if [ -f "$DEST/commands/$old.md" ]; then
    mv "$DEST/commands/$old.md" "$DEST/commands/$old.md.bak-$TS"
    echo "  retired commands/$old.md (now the $old skill) → $old.md.bak-$TS"
  fi
done
cp "$SRC"/scripts/*.sh "$DEST/scripts/"
chmod +x "$DEST"/scripts/*.sh
cp -R "$SRC"/skills/* "$DEST/skills/"

# GitHub Copilot in VS Code reads ~/.claude/CLAUDE.md, ~/.claude/skills/, and
# ~/.claude/settings.json (hooks) natively -- nothing extra needed for those. Its
# subagents are workspace-scoped only though, so the agents in agents/ need
# a generated user-level equivalent at ~/.copilot/agents/.
"$DEST/scripts/generate-copilot-agents.sh" >/dev/null

echo ""
n_agents=$(find "$SRC/agents" -name '*.md' | wc -l | tr -d ' ')
n_skills=$(find "$SRC/skills" -name SKILL.md | wc -l | tr -d ' ')
n_scripts=$(find "$SRC/scripts" -name '*.sh' | wc -l | tr -d ' ')
echo "Installed: $n_agents agents · $n_skills skills (incl. /init-vault, /harvest) · $n_scripts scripts · global CLAUDE.md"
echo "Also generated: $((n_agents + 1)) GitHub Copilot custom agents → ~/.copilot/agents/"
echo ""
echo "Recommended (optional) tools for full guardrails:"
command -v jq >/dev/null 2>&1       || echo "  brew install jq        (required by hook scripts)"
command -v gitleaks >/dev/null 2>&1 || echo "  brew install gitleaks  (secret-scan before checkpoints)"
command -v semgrep >/dev/null 2>&1  || echo "  brew install semgrep   (auditor scanner)"
command -v ruff >/dev/null 2>&1     || echo "  pip install ruff       (python lint loop)"
echo ""
echo "Next: cd into any project, run 'claude', then '/init-vault'."
echo "First feature: run /grill before decomposing. Dial starts at supervised — earn semi via evals/."
