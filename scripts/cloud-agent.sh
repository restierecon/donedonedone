#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

usage() {
  echo "usage: cloud-agent.sh [--with-agents] [--source <git url>] [--ref <commit>] [project-dir]" >&2
  echo "  writes what GitHub Copilot's cloud agent needs into the project, for you to commit:" >&2
  echo "    .github/workflows/copilot-setup-steps.yml  installs tbv on the agent's runner" >&2
  echo "    .github/hooks/tbv.json                     runs the guard, vault-guard, lint and checkpoint hooks there" >&2
  echo "    .github/agents/*.agent.md                  the agents, with --with-agents" >&2
  exit 2
}
die() { echo "cloud-agent.sh: $1" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
stamp="$(dirname "$here")/tbv.version"
field() { [ -f "$stamp" ] && sed -n "s/^$1=//p" "$stamp" | head -1; }

with_agents=0 source="" ref="" project=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-agents) with_agents=1 ;;
    --source) [ $# -ge 2 ] || usage; source="$2"; shift ;;
    --ref) [ $# -ge 2 ] || usage; ref="$2"; shift ;;
    -*) usage ;;
    *) [ -z "$project" ] || usage; project="$1" ;;
  esac
  shift
done
project="${project:-.}"
[ -d "$project" ] || die "no directory at $project"
command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq · winget install jqlang.jq · apt install jq)"

[ -n "$source" ] || source=$(field origin)
[ -n "$ref" ] || ref=$(field commit)
[ -n "$source" ] || die "the install records no origin to clone tbv from — pass --source <git url>"
case "$source" in
  https://*|git@*|ssh://*) ;;
  *) die "the cloud runner can't clone '$source' — pass --source <https url of the tbv repository>" ;;
esac
case "$ref" in
  ''|unknown) die "the install records no commit to pin — pass --ref <commit>" ;;
  *[!0-9A-Za-z._/-]*) die "'$ref' is not a commit, tag or branch name" ;;
esac
case "$source" in *[!0-9A-Za-z._/:@~-]*) die "'$source' has characters a workflow step can't carry safely" ;; esac

workflow="$project/.github/workflows/copilot-setup-steps.yml"
hooks="$project/.github/hooks/tbv.json"
mkdir -p "$project/.github/workflows" "$project/.github/hooks"

place() {
  local new="$1" out="$2" marker="$3"
  if [ -f "$out" ] && cmp -s "$new" "$out"; then
    rm -f "$new"
    return 0
  fi
  if [ -f "$out" ] && ! grep -qF "$marker" "$out"; then
    mv "$new" "$out.tbv-new"
    echo "!! kept your $out — merge the tbv parts from $out.tbv-new by hand, then delete it"
    return 0
  fi
  mv "$new" "$out"
  echo "wrote $out"
}

tmp=$(mktemp)
cat > "$tmp" <<YAML
name: Copilot Setup Steps
on:
  workflow_dispatch:
  push:
    paths:
      - .github/workflows/copilot-setup-steps.yml
  pull_request:
    paths:
      - .github/workflows/copilot-setup-steps.yml
jobs:
  copilot-setup-steps:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v5
      - name: Install tbv
        run: |
          sudo apt-get install -y -q jq >/dev/null 2>&1 || true
          git clone -q $source "\$HOME/tbv-setup"
          git -C "\$HOME/tbv-setup" checkout -q --detach $ref
          TBV_TOOLS=copilot TBV_OFFLINE=1 "\$HOME/tbv-setup/install.sh"
          rm -f "\$HOME/.copilot/hooks/tbv.json"
          echo "TBV_AGENT=1" >> "\$GITHUB_ENV"
YAML
place "$tmp" "$workflow" "Install tbv"

tmp=$(mktemp)
# shellcheck disable=SC2016
jq -n '
  def run($name):
    ("s=\"$HOME/.tbv/scripts/" + $name + "\"; "
      + "if [ -f \"$HOME/.copilot/hooks/tbv.json\" ]; then exit 0; fi; "
      + "if [ -x \"$s\" ]; then exec \"$s\"; fi; "
      + "if [ \"${GITHUB_ACTIONS:-}\" = true ]; then echo \"BLOCKED: tbv is not installed on this runner (did copilot-setup-steps fail?). Failing closed.\" >&2; exit 2; fi") as $sh
    | {type: "command", command: $sh, bash: $sh, windows: "exit 0", powershell: "exit 0", timeout: 60, timeoutSec: 60};
  {
    version: 1,
    hooks: {
      SessionStart: [run("session-start.sh")],
      PreToolUse:   [run("guard.sh"), run("vault-guard.sh")],
      PostToolUse:  [run("lint.sh"), run("vault-guard.sh")],
      SubagentStop: [run("vault-guard.sh")],
      Stop:         [run("checkpoint.sh")]
    }
  }' > "$tmp"
place "$tmp" "$hooks" ".tbv/scripts/guard.sh"

if [ "$with_agents" -eq 1 ]; then
  "$here/generate-agents.sh" copilot "$project/.github/agents" >/dev/null || die "could not generate the agents"
  echo "wrote $project/.github/agents/ (regenerate after every tbv update)"
fi

[ -f "$project/AGENTS.md" ] && grep -qF '<!-- skeletoncrew:protocol:begin' "$project/AGENTS.md" \
  || echo "note: $project/AGENTS.md has no protocol block yet — run $here/agents-md.sh $project so the cloud agent reads the protocol"
echo "Commit these files to the default branch: the cloud agent reads its setup steps and hooks from there."
