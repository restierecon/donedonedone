#!/bin/bash
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$SRC/scripts/jq-text.sh" ] && . "$SRC/scripts/jq-text.sh"
DEST="$HOME/.claude"
TS=$(date +%Y%m%d-%H%M%S)

echo "Installing autonomous engineering setup → $DEST"
mkdir -p "$DEST"/{agents,scripts,skills}

if [ -f "$DEST/CLAUDE.md" ] && ! cmp -s "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"; then
  cp "$DEST/CLAUDE.md" "$DEST/CLAUDE.md.bak-$TS"
  echo "  backed up existing CLAUDE.md → CLAUDE.md.bak-$TS"
fi
cp "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"

merge_settings() {
  jq -s '
    def union($a; $b): reduce ($a + $b)[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    def commands: [.[]?.hooks[]?.command];
    .[0] as $mine | .[1] as $ours
    | if ($mine | type) != "object" then error("not an object") else $mine end
    | .env = (($ours.env // {}) + (.env // {}))
    | .permissions = ((.permissions // {})
        | .deny = union(.deny // []; $ours.permissions.deny // [])
        | .ask = union(.ask // []; $ours.permissions.ask // []))
    | .hooks = reduce ($ours.hooks | to_entries[]) as $e (.hooks // {};
        (.[$e.key] // []) as $have
        | .[$e.key] = $have + [$e.value[] | select(. as $g | any($have | commands[]; . == $g.hooks[0].command) | not)])
  ' "$1" "$2"
}

if [ -f "$DEST/settings.json" ] && ! cmp -s "$SRC/settings.json" "$DEST/settings.json"; then
  merged=$(mktemp)
  if command -v jq >/dev/null 2>&1 && merge_settings "$DEST/settings.json" "$SRC/settings.json" > "$merged" 2>/dev/null; then
    if [ "$(jq -S . "$merged")" != "$(jq -S . "$DEST/settings.json")" ]; then
      cp "$DEST/settings.json" "$DEST/settings.json.bak-$TS"
      cat "$merged" > "$DEST/settings.json"
      echo "  merged this setup's hooks and permissions into your settings.json (yours kept; backup → settings.json.bak-$TS)"
    fi
  else
    cp "$SRC/settings.json" "$DEST/settings.json.new-$TS"
    echo "  !! existing settings.json kept (it could not be merged: jq missing or the file is not valid JSON). Merge permissions+hooks from settings.json.new-$TS manually."
  fi
  rm -f "$merged"
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
cp "$SRC"/scripts/*.sh "$SRC"/scripts/*.py "$SRC"/scripts/*.html "$SRC"/scripts/tbv "$DEST/scripts/"
rm -rf "$DEST/scripts/codemap"
cp -R "$SRC/scripts/codemap" "$DEST/scripts/codemap"
rm -rf "$DEST/scripts/codemap/__pycache__"
chmod +x "$DEST"/scripts/*.sh "$DEST"/scripts/*.py "$DEST"/scripts/tbv
mkdir -p "$DEST/context-firewall"
rm -rf "$DEST/context-firewall/firewall"
cp -R "$SRC/context-firewall/firewall" "$SRC/context-firewall/tbv.py" "$SRC/context-firewall/tbv.ps1" "$SRC/context-firewall/README.md" "$DEST/context-firewall/"
rm -rf "$DEST/context-firewall/firewall/__pycache__" "$DEST/context-firewall/firewall/adapters/__pycache__"
cp -R "$SRC"/skills/* "$DEST/skills/"

rm -f "$DEST/scripts/generate-copilot-agents.sh"

"$DEST/scripts/generate-agents.sh" copilot >/dev/null

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq not found — fetching jq from github.com/jqlang/jq (checksum-pinned) into $DEST/bin"
  if fetched=$("$SRC/scripts/fetch-jq.sh" "$DEST/bin"); then
    echo "  jq → $fetched (the hook scripts find it there; no admin rights or PATH change needed)"
    # shellcheck source=/dev/null
    . "$SRC/scripts/jq-text.sh"
  fi
fi

vscode_status="hooks SKIPPED (install jq, re-run)"
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$HOME/.copilot/hooks"
  scripts="$DEST/scripts" win_bash="" scripts_ps=""
  git_root=$(cygpath -u "$(cygpath -w / 2>/dev/null)" 2>/dev/null || true)
  if command -v cygpath >/dev/null 2>&1 && [ -x "${git_root%/}/bin/bash.exe" ]; then
    scripts=$(cygpath -m "$DEST/scripts")
    win_bash="$(cygpath -w /)\\bin\\bash.exe"
    win_bash=${win_bash//\'/\'\'}
    scripts_ps=${scripts//\'/\'\'}
  fi
  hooks_tmp=$(mktemp)
  jq -n --arg s "$scripts" --arg b "$win_bash" --arg p "$scripts_ps" --arg q "'" '
    def hook($name): {type: "command", command: ($s + "/" + $name), timeout: 60}
      + (if $b == "" then {} else {windows: ("& " + $q + $b + $q + " " + $q + $p + "/" + $name + $q + "; exit $LASTEXITCODE")} end);
    {
      hooks: {
        SessionStart: [hook("session-start.sh")],
        PreToolUse:   [hook("guard.sh"), hook("vault-guard.sh")],
        PostToolUse:  [hook("lint.sh"), hook("vault-guard.sh")],
        SubagentStop: [hook("vault-guard.sh")],
        Stop:         [hook("checkpoint.sh")]
      }
    }' > "$hooks_tmp"
  vscode_hooks="$HOME/.copilot/hooks/tbv.json"
  if [ -f "$vscode_hooks" ] && ! cmp -s "$hooks_tmp" "$vscode_hooks"; then
    mv "$hooks_tmp" "$vscode_hooks.new-$TS"
    echo "  !! existing ~/.copilot/hooks/tbv.json kept. Merge hooks from tbv.json.new-$TS manually."
  else
    mv "$hooks_tmp" "$vscode_hooks"
  fi
  vscode_status="hooks → ~/.copilot/hooks/tbv.json (leave chat.useClaudeHooks off, or every hook runs twice)"
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
        preToolUse:           [{command: ($s + "/guard.sh"), failClosed: true}, {command: ($s + "/vault-guard.sh")}],
        beforeShellExecution: [{command: ($s + "/guard.sh"), failClosed: true}],
        beforeReadFile:       [{command: ($s + "/guard.sh"), failClosed: true}],
        afterFileEdit:        [{command: ($s + "/lint.sh")}],
        postToolUse:          [{command: ($s + "/lint.sh")}, {command: ($s + "/vault-guard.sh")}],
        postToolUseFailure:   [{command: ($s + "/vault-guard.sh")}],
        subagentStop:         [{command: ($s + "/vault-guard.sh")}],
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
if "$DEST/scripts/tbv" config >/dev/null 2>&1; then
  echo "Context firewall: PreToolUse/PostToolUse hooks compact noisy shell output; ~/.claude/scripts/tbv retrieves it (see ~/.claude/context-firewall/README.md)"
else
  echo "Context firewall: installed but inactive — needs Python 3.8+ on PATH (python3, python or py -3). Shell output passes through unchanged."
fi
if version=$("$DEST/scripts/harness.sh" stamp "$SRC" 2>/dev/null); then
  echo "Version: $version — '~/.claude/scripts/tbv version' shows whether it is current; '~/.claude/scripts/tbv update' pulls and reinstalls. Sessions are told when it falls behind."
else
  echo "Version: not recorded (git is needed to stamp the install); update checks are off."
fi
echo ""
echo "Recommended (optional) tools for full guardrails:"
command -v jq >/dev/null 2>&1       || echo "  jq (required by hook scripts): brew install jq · winget install jqlang.jq · apt install jq · or, without admin rights, save a jq binary as $DEST/bin/jq (jq.exe on Windows) and re-run"
command -v gitleaks >/dev/null 2>&1 || echo "  gitleaks (secret-scan before checkpoints): brew install gitleaks · winget install Gitleaks.Gitleaks"
command -v semgrep >/dev/null 2>&1  || echo "  semgrep (auditor scanner): brew install semgrep · pip install semgrep"
command -v ruff >/dev/null 2>&1     || echo "  ruff (python lint loop): pip install ruff"
echo ""
echo "Next: cd into any project, run 'claude', then '/init-codebase'."
echo "First feature: run /grill before decomposing. Dial starts at supervised — earn semi via evals/."
