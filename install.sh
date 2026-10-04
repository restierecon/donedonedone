#!/bin/bash
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
TS=$(date +%Y%m%d-%H%M%S)

echo "Installing autonomous engineering setup → $DEST"
mkdir -p "$DEST"/{agents,scripts,skills}

if [ -f "$DEST/CLAUDE.md" ] && ! cmp -s "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"; then
  cp "$DEST/CLAUDE.md" "$DEST/CLAUDE.md.bak-$TS"
  echo "  backed up existing CLAUDE.md → CLAUDE.md.bak-$TS"
fi
cp "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"

if [ -f "$DEST/settings.json" ] && ! cmp -s "$SRC/settings.json" "$DEST/settings.json"; then
  cp "$SRC/settings.json" "$DEST/settings.json.new-$TS"
  echo "  !! existing settings.json kept. Merge permissions+hooks from settings.json.new-$TS manually."
else
  cp "$SRC/settings.json" "$DEST/settings.json"
fi

cp "$SRC"/agents/*.md "$DEST/agents/"
for old in init-vault harvest; do
  if [ -f "$DEST/commands/$old.md" ]; then
    mv "$DEST/commands/$old.md" "$DEST/commands/$old.md.bak-$TS"
    echo "  retired commands/$old.md (now the $old skill) → $old.md.bak-$TS"
  fi
done
if [ -d "$DEST/skills/init-vault" ]; then
  mv "$DEST/skills/init-vault" "$DEST/init-vault-skill.bak-$TS"
  echo "  retired skills/init-vault (renamed /init-codebase) → init-vault-skill.bak-$TS"
fi
for old in \
  "$DEST/agents/scribe.md:$DEST/scribe-agent.md" \
  "$DEST/skills/compaction:$DEST/compaction-skill" \
  "$HOME/.copilot/agents/scribe.agent.md:$HOME/.copilot/scribe-agent.md" \
  "$HOME/.cursor/agents/scribe.md:$HOME/.cursor/scribe-agent.md"; do
  if [ -e "${old%%:*}" ]; then
    mv "${old%%:*}" "${old#*:}.bak-$TS"
    echo "  retired ${old%%:*} (vault memory layer dropped) → ${old#*:}.bak-$TS"
  fi
done
cp "$SRC"/scripts/*.sh "$SRC"/scripts/*.py "$DEST/scripts/"
chmod +x "$DEST"/scripts/*.sh "$DEST"/scripts/*.py
cp -R "$SRC"/skills/* "$DEST/skills/"

rm -f "$DEST/scripts/generate-copilot-agents.sh"

"$DEST/scripts/generate-agents.sh" copilot >/dev/null

vscode_status="hooks SKIPPED (install jq, re-run)"
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$HOME/.copilot/hooks"
  scripts="$DEST/scripts" win_bash=""
  if command -v cygpath >/dev/null 2>&1 && [ -x "$(cygpath -u "$(cygpath -w /)")/bin/bash.exe" ]; then
    scripts=$(cygpath -m "$DEST/scripts")
    win_bash="$(cygpath -w /)\\bin\\bash.exe"
  fi
  hooks_tmp=$(mktemp)
  jq -n --arg s "$scripts" --arg b "$win_bash" '
    def hook($name): {type: "command", command: ($s + "/" + $name), timeout: 60}
      + (if $b == "" then {} else {windows: ("\"" + $b + "\" \"" + $s + "/" + $name + "\"")} end);
    {
      hooks: {
        SessionStart: [hook("session-start.sh")],
        PreToolUse:   [hook("guard.sh"), hook("vault-guard.sh")],
        PostToolUse:  [hook("lint.sh"), hook("vault-guard.sh")],
        SubagentStop: [hook("vault-guard.sh")],
        Stop:         [hook("checkpoint.sh")]
      }
    }' > "$hooks_tmp"
  vscode_hooks="$HOME/.copilot/hooks/donedonedone.json"
  if [ -f "$vscode_hooks" ] && ! cmp -s "$hooks_tmp" "$vscode_hooks"; then
    mv "$hooks_tmp" "$vscode_hooks.new-$TS"
    echo "  !! existing ~/.copilot/hooks/donedonedone.json kept. Merge hooks from donedonedone.json.new-$TS manually."
  else
    mv "$hooks_tmp" "$vscode_hooks"
  fi
  vscode_status="hooks → ~/.copilot/hooks/donedonedone.json (leave chat.useClaudeHooks off, or every hook runs twice)"
fi

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
        beforeReadFile:       [{command: ($s + "/guard.sh")}],
        afterFileEdit:        [{command: ($s + "/lint.sh")}],
        stop:                 [{command: ($s + "/checkpoint.sh")}]
      }
    }' > "$hooks_tmp"
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
echo "Installed: $n_agents agents · $n_skills skills (incl. /init-codebase, /harvest) · $n_scripts scripts · global CLAUDE.md"
echo "GitHub Copilot: $((n_agents + 1)) custom agents → ~/.copilot/agents/, $vscode_status"
echo "Cursor: $cursor_status"
echo ""
echo "Recommended (optional) tools for full guardrails:"
command -v jq >/dev/null 2>&1       || echo "  jq (required by hook scripts): brew install jq · winget install jqlang.jq · apt install jq"
command -v gitleaks >/dev/null 2>&1 || echo "  gitleaks (secret-scan before checkpoints): brew install gitleaks · winget install Gitleaks.Gitleaks"
command -v semgrep >/dev/null 2>&1  || echo "  semgrep (auditor scanner): brew install semgrep · pip install semgrep"
command -v ruff >/dev/null 2>&1     || echo "  ruff (python lint loop): pip install ruff"
echo ""
echo "Next: cd into any project, run 'claude', then '/init-codebase'."
echo "First feature: run /grill before decomposing. Dial starts at supervised — earn semi via evals/."
