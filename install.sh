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

# Renamed to generate-agents.sh (now serves Copilot and Cursor); drop the stale copy.
rm -f "$DEST/scripts/generate-copilot-agents.sh"

# GitHub Copilot in VS Code reads ~/.claude/CLAUDE.md, ~/.claude/skills/, and
# ~/.claude/settings.json (hooks) natively -- nothing extra needed for those. Its
# subagents are workspace-scoped only though, so the agents in agents/ need
# a generated user-level equivalent at ~/.copilot/agents/.
"$DEST/scripts/generate-agents.sh" copilot >/dev/null

# Cursor reads ~/.claude/skills and ~/.claude/agents natively, but not CLAUDE.md or
# settings.json. It gets: read-only-aware agent copies in ~/.cursor/agents, the same
# hook scripts wired through ~/.cursor/hooks.json, and the protocol via each project's
# AGENTS.md (/init-vault runs agents-md.sh). Only when Cursor is present, or CURSOR=1.
cursor_status="not detected (re-run with CURSOR=1 to set it up anyway)"
if [ -d "$HOME/.cursor" ] || command -v cursor >/dev/null 2>&1 || [ "${CURSOR:-}" = "1" ]; then
  "$DEST/scripts/generate-agents.sh" cursor >/dev/null
  if command -v jq >/dev/null 2>&1; then
    hooks_tmp=$(mktemp)
    jq -n --arg s "$DEST/scripts" '{
      version: 1,
      hooks: {
        sessionStart:         [{command: ($s + "/session-start.sh")}],
        beforeShellExecution: [{command: ($s + "/guard.sh")}],
        afterFileEdit:        [{command: ($s + "/lint.sh")}],
        stop:                 [{command: ($s + "/checkpoint.sh")}]
      }
    }' > "$hooks_tmp"
    # Same policy as settings.json: never overwrite a hooks.json the user already has.
    if [ -f "$HOME/.cursor/hooks.json" ] && ! cmp -s "$hooks_tmp" "$HOME/.cursor/hooks.json"; then
      mv "$hooks_tmp" "$HOME/.cursor/hooks.json.new-$TS"
      echo "  !! existing ~/.cursor/hooks.json kept. Merge hooks from hooks.json.new-$TS manually."
    else
      mv "$hooks_tmp" "$HOME/.cursor/hooks.json"
    fi
    cursor_status="agents → ~/.cursor/agents/, hooks → ~/.cursor/hooks.json"
  else
    cursor_status="agents → ~/.cursor/agents/; hooks SKIPPED (install jq, re-run)"
  fi
fi

echo ""
n_agents=$(find "$SRC/agents" -name '*.md' | wc -l | tr -d ' ')
n_skills=$(find "$SRC/skills" -name SKILL.md | wc -l | tr -d ' ')
n_scripts=$(find "$SRC/scripts" -name '*.sh' | wc -l | tr -d ' ')
echo "Installed: $n_agents agents · $n_skills skills (incl. /init-vault, /harvest) · $n_scripts scripts · global CLAUDE.md"
echo "GitHub Copilot: $((n_agents + 1)) custom agents → ~/.copilot/agents/"
echo "Cursor: $cursor_status"
echo ""
echo "Recommended (optional) tools for full guardrails:"
command -v jq >/dev/null 2>&1       || echo "  brew install jq        (required by hook scripts)"
command -v gitleaks >/dev/null 2>&1 || echo "  brew install gitleaks  (secret-scan before checkpoints)"
command -v semgrep >/dev/null 2>&1  || echo "  brew install semgrep   (auditor scanner)"
command -v ruff >/dev/null 2>&1     || echo "  pip install ruff       (python lint loop)"
echo ""
echo "Next: cd into any project, run 'claude', then '/init-vault'."
echo "First feature: run /grill before decomposing. Dial starts at supervised — earn semi via evals/."
