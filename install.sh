#!/bin/bash
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$SRC/scripts/jq-text.sh" ] && . "$SRC/scripts/jq-text.sh"
DEST="$HOME/.tbv"
CLAUDE="$HOME/.claude"
TS=$(date +%Y%m%d-%H%M%S)

if [ -n "${TBV_TOOLS:-}" ]; then
  TOOLS=" $(printf '%s' "$TBV_TOOLS" | tr ',' ' ') "
  for t in $TOOLS; do
    case "$t" in claude|copilot|cursor) ;; *) echo "install.sh: unknown tool '$t' in TBV_TOOLS (claude, copilot, cursor)" >&2; exit 1 ;; esac
  done
else
  TOOLS=" copilot "
  if [ -d "$CLAUDE" ] || command -v claude >/dev/null 2>&1; then TOOLS="$TOOLS claude "; fi
  if [ -d "$HOME/.cursor" ] || command -v cursor >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1 || [ "${CURSOR:-}" = "1" ]; then TOOLS="$TOOLS cursor "; fi
fi
want() { case "$TOOLS" in *" $1 "*) return 0 ;; esac; return 1; }

echo "Installing tbv → $DEST"
mkdir -p "$DEST"/{agents,scripts,skills,bin}

legacy=""
if [ -f "$CLAUDE/tbv.version" ] || { [ -f "$CLAUDE/scripts/guard.sh" ] && [ ! -L "$CLAUDE/scripts/guard.sh" ]; }; then
  legacy="$CLAUDE/tbv-legacy.bak-$TS"
  mkdir -p "$legacy/scripts"
  for f in "$SRC"/scripts/*; do
    old="$CLAUDE/scripts/$(basename "$f")"
    if [ -e "$old" ] && [ ! -L "$old" ]; then mv "$old" "$legacy/scripts/"; fi
  done
  for old in context-firewall tbv.version tbv.manifest tbv.remote; do
    if [ -e "$CLAUDE/$old" ] && [ ! -L "$CLAUDE/$old" ]; then mv "$CLAUDE/$old" "$legacy/$old"; fi
  done
  for old in "$CLAUDE"/bin/jq "$CLAUDE"/bin/jq.exe; do
    if [ -f "$old" ]; then mv "$old" "$DEST/bin/"; fi
  done
  echo "  moved the install from ~/.claude to ~/.tbv (the old scripts and version record → ~/.claude/tbv-legacy.bak-$TS)"
fi
if [ -f "$CLAUDE/scripts/generate-copilot-agents.sh" ]; then
  rm -f "$CLAUDE/scripts/generate-copilot-agents.sh"
fi

cp "$SRC/PROTOCOL.md" "$DEST/PROTOCOL.md"
rm -f "$DEST"/agents/*.md
cp "$SRC"/agents/*.md "$DEST/agents/"
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

if [ -n "$legacy" ]; then
  probe=$(mktemp -d)
  ln -s "$DEST/scripts/gate.sh" "$probe/link" 2>/dev/null || true
  if [ -L "$probe/link" ]; then
    mkdir -p "$CLAUDE/scripts"
    for f in "$DEST"/scripts/*; do
      old="$CLAUDE/scripts/$(basename "$f")"
      [ -e "$old" ] || [ -L "$old" ] || ln -s "$f" "$old"
    done
    echo "  ~/.claude/scripts/<script> now links to ~/.tbv/scripts/<script>, so gate lines and project hooks written before the move keep working"
  else
    echo "  !! this system can't link the old script paths: change ~/.claude/scripts to ~/.tbv/scripts in each project's vault/project.md and .claude/settings.json"
  fi
  rm -f "$probe/link"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq not found — fetching jq from github.com/jqlang/jq (checksum-pinned) into $DEST/bin"
  if fetched=$("$SRC/scripts/fetch-jq.sh" "$DEST/bin"); then
    echo "  jq → $fetched (the hook scripts find it there; no admin rights or PATH change needed)"
    # shellcheck source=/dev/null
    . "$SRC/scripts/jq-text.sh"
  fi
fi

retire() {
  if [ -e "$1" ]; then
    mv "$1" "$2.bak-$TS"
    echo "  retired $1 ($3) → $2.bak-$TS"
  fi
}

install_skills() {
  mkdir -p "$1"
  cp -R "$SRC"/skills/* "$1/"
}

merge_settings() {
  jq -s '
    def union($a; $b): reduce ($a + $b)[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    def commands: [.[]?.hooks[]?.command];
    def moved: if type == "string" then sub("^(~|\\$HOME)/\\.claude/scripts/(?<rest>(session-start|guard|vault-guard|lint|checkpoint)\\.sh$|tbv )"; "~/.tbv/scripts/\(.rest)") else . end;
    def relocate: if type == "array" then map(if type == "object" and (.hooks | type) == "array" then .hooks |= map(if type == "object" and has("command") then .command |= moved else . end) else . end) else . end;
    .[0] as $mine | .[1] as $ours
    | if ($mine | type) != "object" then error("not an object") else $mine end
    | if (.hooks | type) == "object" then .hooks |= map_values(relocate) else . end
    | .env = (($ours.env // {}) + (.env // {}))
    | .permissions = ((.permissions // {})
        | .deny = union(.deny // []; $ours.permissions.deny // [])
        | .ask = union(.ask // []; $ours.permissions.ask // []))
    | .hooks = reduce ($ours.hooks | to_entries[]) as $e (.hooks // {};
        (.[$e.key] // []) as $have
        | .[$e.key] = $have + [$e.value[] | select(. as $g | any($have | commands[]; . == $g.hooks[0].command) | not)])
  ' "$1" "$2"
}

claude_status="not set up (no ~/.claude and no claude on PATH; TBV_TOOLS=claude,copilot sets it up anyway)"
if want claude; then
  mkdir -p "$CLAUDE"/{agents,skills}
  if [ -f "$CLAUDE/CLAUDE.md" ] && ! cmp -s "$SRC/PROTOCOL.md" "$CLAUDE/CLAUDE.md"; then
    cp "$CLAUDE/CLAUDE.md" "$CLAUDE/CLAUDE.md.bak-$TS"
    echo "  backed up existing CLAUDE.md → CLAUDE.md.bak-$TS"
  fi
  cp "$SRC/PROTOCOL.md" "$CLAUDE/CLAUDE.md"

  if [ -f "$CLAUDE/settings.json" ] && ! cmp -s "$SRC/settings.json" "$CLAUDE/settings.json"; then
    merged=$(mktemp)
    if command -v jq >/dev/null 2>&1 && merge_settings "$CLAUDE/settings.json" "$SRC/settings.json" > "$merged" 2>/dev/null; then
      if [ "$(jq -S . "$merged")" != "$(jq -S . "$CLAUDE/settings.json")" ]; then
        cp "$CLAUDE/settings.json" "$CLAUDE/settings.json.bak-$TS"
        cat "$merged" > "$CLAUDE/settings.json"
        echo "  merged this setup's hooks and permissions into your settings.json (yours kept; backup → settings.json.bak-$TS)"
      fi
    else
      cp "$SRC/settings.json" "$CLAUDE/settings.json.new-$TS"
      echo "  !! existing settings.json kept (it could not be merged: jq missing or the file is not valid JSON). Merge permissions+hooks from settings.json.new-$TS manually."
    fi
    rm -f "$merged"
  else
    cp "$SRC/settings.json" "$CLAUDE/settings.json"
  fi

  for old in init-vault harvest; do
    if [ -f "$CLAUDE/commands/$old.md" ]; then
      mv "$CLAUDE/commands/$old.md" "$CLAUDE/commands/$old.md.bak-$TS"
      echo "  retired commands/$old.md (now the $old skill) → $old.md.bak-$TS"
    fi
  done
  if [ -d "$CLAUDE/skills/init-vault" ]; then
    mv "$CLAUDE/skills/init-vault" "$CLAUDE/init-vault-skill.bak-$TS"
    echo "  retired skills/init-vault (renamed /init-codebase) → init-vault-skill.bak-$TS"
  fi
  retire "$CLAUDE/agents/scribe.md" "$CLAUDE/scribe-agent.md" "vault memory layer dropped"
  retire "$CLAUDE/skills/compaction" "$CLAUDE/compaction-skill" "vault memory layer dropped"
  "$DEST/scripts/generate-agents.sh" claude "$CLAUDE/agents" >/dev/null
  install_skills "$CLAUDE/skills"
  claude_status="protocol → ~/.claude/CLAUDE.md, agents → ~/.claude/agents/, skills → ~/.claude/skills/, hooks and permissions → ~/.claude/settings.json"
fi

copilot_status="not selected (TBV_TOOLS leaves it out)"
if want copilot; then
  retire "$HOME/.copilot/agents/scribe.agent.md" "$HOME/.copilot/scribe-agent.md" "vault memory layer dropped"
  "$DEST/scripts/generate-agents.sh" copilot >/dev/null
  install_skills "$HOME/.copilot/skills"
  copilot_status="agents → ~/.copilot/agents/, skills → ~/.copilot/skills/, hooks SKIPPED (install jq, re-run)"
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
        + (if $b == "" then {} else ("& " + $q + $b + $q + " " + $q + $p + "/" + $name + $q + "; exit $LASTEXITCODE") as $ps | {windows: $ps, powershell: $ps} end);
      {
        version: 1,
        hooks: {
          SessionStart: [hook("session-start.sh")],
          PreToolUse:   [hook("guard.sh"), hook("vault-guard.sh")],
          PostToolUse:  [hook("lint.sh"), hook("vault-guard.sh")],
          SubagentStop: [hook("vault-guard.sh")],
          Stop:         [hook("checkpoint.sh")]
        }
      }' > "$hooks_tmp"
    copilot_hooks="$HOME/.copilot/hooks/tbv.json"
    if [ -f "$copilot_hooks" ] && grep -qF '/.claude/scripts/' "$copilot_hooks" && ! grep -qF '/.tbv/scripts/' "$copilot_hooks"; then
      mv "$copilot_hooks" "$copilot_hooks.bak-$TS"
      echo "  replaced ~/.copilot/hooks/tbv.json, which still ran the scripts from ~/.claude (old file → tbv.json.bak-$TS)"
    fi
    if [ -f "$copilot_hooks" ] && ! cmp -s "$hooks_tmp" "$copilot_hooks"; then
      mv "$hooks_tmp" "$copilot_hooks.new-$TS"
      echo "  !! existing ~/.copilot/hooks/tbv.json kept. Merge hooks from tbv.json.new-$TS manually."
    else
      mv "$hooks_tmp" "$copilot_hooks"
    fi
    copilot_status="agents → ~/.copilot/agents/, skills → ~/.copilot/skills/, hooks → ~/.copilot/hooks/tbv.json (VS Code and the Copilot CLI both read it; leave chat.useClaudeHooks off, or every hook runs twice)"
  fi
fi

cursor_status="not detected (re-run with CURSOR=1 to set it up anyway)"
if want cursor; then
  retire "$HOME/.cursor/agents/scribe.md" "$HOME/.cursor/scribe-agent.md" "vault memory layer dropped"
  "$DEST/scripts/generate-agents.sh" cursor >/dev/null
  install_skills "$HOME/.cursor/skills"
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
    cursor_hooks="$HOME/.cursor/hooks.json"
    if [ -f "$cursor_hooks" ] \
       && jq -e --arg old "$CLAUDE/scripts/" '[.hooks[]?[]?.command] | length > 0 and all(.[]; type == "string" and startswith($old))' "$cursor_hooks" >/dev/null 2>&1; then
      mv "$cursor_hooks" "$cursor_hooks.bak-$TS"
      echo "  replaced ~/.cursor/hooks.json, which still ran the scripts from ~/.claude (old file → hooks.json.bak-$TS)"
    fi
    if [ -f "$cursor_hooks" ] && ! cmp -s "$hooks_tmp" "$cursor_hooks"; then
      mv "$hooks_tmp" "$cursor_hooks.new-$TS"
      echo "  !! existing ~/.cursor/hooks.json kept. Merge hooks from hooks.json.new-$TS manually."
    else
      mv "$hooks_tmp" "$cursor_hooks"
    fi
    cursor_status="agents → ~/.cursor/agents/, skills → ~/.cursor/skills/, hooks → ~/.cursor/hooks.json"
  else
    cursor_status="agents → ~/.cursor/agents/, skills → ~/.cursor/skills/; hooks SKIPPED (install jq, re-run)"
  fi
fi

echo ""
n_agents=$(find "$SRC/agents" -name '*.md' | wc -l | tr -d ' ')
n_skills=$(find "$SRC/skills" -name SKILL.md | wc -l | tr -d ' ')
n_scripts=$(find "$SRC/scripts" -name '*.sh' | wc -l | tr -d ' ')
echo "Installed in ~/.tbv: $n_agents agents · $n_skills skills (incl. /init-codebase, /harvest) · $n_scripts scripts · PROTOCOL.md"
echo "Claude Code: $claude_status"
echo "GitHub Copilot (VS Code and CLI): $copilot_status"
echo "Cursor: $cursor_status"
echo ""
if "$DEST/scripts/tbv" config >/dev/null 2>&1; then
  if want claude; then
    echo "Context firewall: Claude Code's PreToolUse/PostToolUse hooks compact noisy shell output; in Cursor and Copilot the agents run noisy commands through '~/.tbv/scripts/tbv run --' (see ~/.tbv/context-firewall/README.md)"
  else
    echo "Context firewall: the agents run noisy commands through '~/.tbv/scripts/tbv run --'; ~/.tbv/scripts/tbv retrieves what it kept (see ~/.tbv/context-firewall/README.md)"
  fi
else
  echo "Context firewall: installed but inactive — needs Python 3.8+ on PATH (python3, python or py -3). Shell output passes through unchanged."
fi
if version=$("$DEST/scripts/harness.sh" stamp "$SRC" 2>/dev/null); then
  echo "Version: $version — '~/.tbv/scripts/tbv version' shows whether it is current; '~/.tbv/scripts/tbv update' pulls and reinstalls. Sessions are told when it falls behind."
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
echo "Next: open any project in Claude Code, Cursor or Copilot and run the init-codebase skill (/init-codebase)."
echo "Copilot cloud agent: run ~/.tbv/scripts/cloud-agent.sh in the project and commit what it writes."
echo "First feature: run /grill before decomposing. Dial starts at supervised — earn semi via evals/."
