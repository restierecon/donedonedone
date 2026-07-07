#!/bin/bash
# Validates agents/*.md and skills/*/SKILL.md frontmatter, and cross-checks the
# Agents table in CLAUDE.md against agents/ on disk. As the roster grows, a
# missing field or a renamed/orphaned agent should fail CI, not surface at runtime.
# Run: scripts/validate-manifests.sh   Exit nonzero on any failure.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

err() { echo "FAIL: $1" >&2; fail=1; }

frontmatter() { # <file> -- prints the YAML block between the first two '---' lines
  awk '/^---$/{n++; next} n==1' "$1"
}

field() { # <frontmatter-text> <key> -- prints the value after "key:"
  echo "$1" | sed -n "s/^${2}: *//p" | head -1
}

check_agent() {
  local f="$1" base name fm
  base=$(basename "$f" .md)
  [ "$(head -1 "$f")" = "---" ] || { err "$f: missing frontmatter"; return; }
  fm=$(frontmatter "$f")
  name=$(field "$fm" "name")
  [ -n "$name" ] || err "$f: frontmatter missing 'name'"
  [ "$name" = "$base" ] || err "$f: name '$name' does not match filename '$base'"
  [ -n "$(field "$fm" "description")" ] || err "$f: frontmatter missing 'description'"
  [ -n "$(field "$fm" "tools")" ] || err "$f: frontmatter missing 'tools'"
  [ -n "$(field "$fm" "model")" ] || err "$f: frontmatter missing 'model'"
}

check_skill() {
  local f="$1" dir name fm
  dir=$(basename "$(dirname "$f")")
  [ "$(head -1 "$f")" = "---" ] || { err "$f: missing frontmatter"; return; }
  fm=$(frontmatter "$f")
  name=$(field "$fm" "name")
  [ -n "$name" ] || err "$f: frontmatter missing 'name'"
  [ "$name" = "$dir" ] || err "$f: name '$name' does not match directory '$dir'"
  [ -n "$(field "$fm" "description")" ] || err "$f: frontmatter missing 'description'"
}

for f in "$ROOT"/agents/*.md; do check_agent "$f"; done
for f in "$ROOT"/skills/*/SKILL.md; do check_skill "$f"; done

# Cross-check: every agent named in CLAUDE.md's Agents table must exist on disk,
# and every agents/*.md must appear in that table — no orphans either direction.
table_agents=$(sed -n '/^## Agents$/,/^## /p' "$ROOT/CLAUDE.md" | grep -oE '^\| [a-z]+ ' | tr -d '| ')
disk_agents=$(for f in "$ROOT"/agents/*.md; do basename "$f" .md; done)

for a in $table_agents; do
  echo "$disk_agents" | grep -qx "$a" || err "CLAUDE.md Agents table references '$a' with no agents/$a.md on disk"
done
for a in $disk_agents; do
  echo "$table_agents" | grep -qx "$a" || err "agents/$a.md exists but is not listed in CLAUDE.md's Agents table"
done

if [ "$fail" -eq 0 ]; then
  echo "manifests OK"
else
  echo "" >&2
fi
exit "$fail"
