#!/bin/bash

usage() {
  echo "usage: harness.sh status | check | require [project-dir] | update | pin | project-hook | stamp <source-dir>" >&2
  exit 2
}
die() { echo "harness: $1" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
dest="$(dirname "$here")"
stamp="$dest/donedonedone.version"
manifest="$dest/donedonedone.manifest"
cache="$dest/donedonedone.remote"
update_cmd="$here/ddd update"
day=86400

field() { [ -f "$stamp" ] && sed -n "s/^$1=//p" "$stamp" | head -1; }
short() { printf '%s' "$1" | cut -c1-7; }

installed_files() {
  local src="$1"
  (cd "$src" && find agents scripts skills context-firewall -type f ! -path '*/__pycache__/*' 2>/dev/null) \
    | LC_ALL=C sort | while IFS= read -r f; do [ -f "$dest/$f" ] && printf '%s\n' "$f"; done
}

hashes() {
  local list="$1"
  (cd "$dest" && git hash-object --no-filters --stdin-paths < "$list") | paste -d ' ' - "$list"
}

cmd_stamp() {
  local src="$1" commit="unknown" revision="unknown" origin="" dirty=0 list
  [ -d "$src" ] || die "no source directory at $src"
  src="$(cd "$src" && pwd)"
  if git -C "$src" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    commit=$(git -C "$src" rev-parse HEAD)
    revision=$(TZ=UTC git -C "$src" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ)
    origin=$(git -C "$src" remote get-url origin 2>/dev/null | sed 's#://[^/@]*@#://#')
    [ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ] || dirty=1
  fi
  {
    echo "commit=$commit"
    echo "revision=$revision"
    echo "source=$src"
    echo "origin=$origin"
    echo "dirty=$dirty"
    echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$stamp" || die "could not write $stamp"
  list=$(mktemp) || die "could not create a temp file"
  installed_files "$src" > "$list"
  hashes "$list" > "$manifest"
  rm -f "$list" "$cache"
  echo "$(short "$commit") ($revision)"
}

drifted() {
  local list now
  [ -f "$manifest" ] || return 0
  list=$(mktemp) || return 0
  now=$(mktemp) || { rm -f "$list"; return 0; }
  cut -d ' ' -f 2- "$manifest" | while IFS= read -r f; do
    if [ -f "$dest/$f" ]; then printf '%s\n' "$f"; else printf 'missing %s\n' "$f" >&3; fi
  done > "$list" 3> "$now.missing"
  hashes "$list" > "$now"
  { diff "$manifest" "$now" | sed -n 's/^> [0-9a-f]* //p'; sed -n 's/^missing //p' "$now.missing"; } | LC_ALL=C sort -u
  rm -f "$list" "$now" "$now.missing"
}

with_timeout() {
  local secs="$1" pid killer status
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return
  fi
  "$@" &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid"
  status=$?
  kill "$killer" 2>/dev/null
  return "$status"
}

remote_head() {
  local src="$1" force="$2" now checked head=""
  [ "${DONEDONEDONE_OFFLINE:-0}" = "1" ] && return 0
  now=$(date +%s)
  if [ "$force" -eq 0 ] && [ -f "$cache" ]; then
    checked=$(sed -n 's/^checked=//p' "$cache" | head -1)
    case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
    if [ $((now - checked)) -lt "$day" ]; then
      sed -n 's/^head=//p' "$cache" | head -1
      return 0
    fi
  fi
  head=$(cd "$src" && GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=3" \
    with_timeout 5 git ls-remote origin HEAD </dev/null 2>/dev/null | cut -f1 | head -1)
  printf 'checked=%s\nhead=%s\n' "$now" "$head" > "$cache" 2>/dev/null
  printf '%s\n' "$head"
}

findings() {
  local force="$1" commit revision src local_head head changed n
  [ -f "$stamp" ] || return 0
  commit=$(field commit)
  revision=$(field revision)
  src=$(field source)
  if [ -n "$src" ] && [ "$commit" != "unknown" ] && git -C "$src" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    local_head=$(git -C "$src" rev-parse HEAD)
    if [ "$local_head" != "$commit" ]; then
      if git -C "$src" merge-base --is-ancestor "$commit" "$local_head" 2>/dev/null; then
        echo "outdated: $(short "$commit") ($revision) is installed, and its clone at $src is already at $(short "$local_head") — run: $src/install.sh"
      else
        echo "mismatch: $(short "$commit") ($revision) is installed, and its clone at $src is on a different commit, $(short "$local_head") — run: $src/install.sh"
      fi
    fi
    if [ -n "$(field origin)" ]; then
      head=$(remote_head "$src" "$force")
      if [ -n "$head" ] && [ "$head" != "$commit" ] && [ "$head" != "$local_head" ] \
         && ! git -C "$src" merge-base --is-ancestor "$head" "$local_head" 2>/dev/null; then
        echo "update available: $(field origin) is at $(short "$head"), ahead of the clone at $src — run: $update_cmd"
      fi
    fi
  elif [ "$force" -eq 1 ]; then
    echo "unknown: the clone this was installed from (${src:-not recorded}) is gone or is not a git checkout, so updates can't be checked"
  fi
  changed=$(drifted)
  if [ -n "$changed" ]; then
    n=$(printf '%s\n' "$changed" | grep -c .)
    echo "modified: $n installed file(s) no longer match what install.sh put there (first: $(printf '%s\n' "$changed" | head -1)) — re-run install.sh to restore them"
  fi
}

cmd_check() {
  local found
  found=$(findings 0)
  [ -n "$found" ] || return 0
  echo "--- donedonedone install (tell the human once, before other work; never update it yourself) ---"
  printf '%s\n' "$found" | head -4
}

cmd_status() {
  local found
  if [ ! -f "$stamp" ]; then
    echo "donedonedone: no install recorded in $dest — run install.sh from a clone"
    return 1
  fi
  echo "installed: $(short "$(field commit)") ($(field revision)) on $(field installed_at)$([ "$(field dirty)" = 1 ] && echo ", from a clone with uncommitted changes")"
  echo "source: $(field source)$([ -n "$(field origin)" ] && echo " · $(field origin)")"
  found=$(findings 1)
  if [ -z "$found" ]; then
    echo "status: up to date, files unmodified"
    return 0
  fi
  printf '%s\n' "$found"
  return 1
}

cmd_require() {
  local dir="${1:-.}" want have
  [ -f "$dir/vault/project.md" ] || return 0
  want=$(sed -n 's/^[-*][[:space:]]*harness:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$dir/vault/project.md" | head -1 | tr -d '\r`')
  [ -n "$want" ] || return 0
  have=$(field revision)
  { [ -n "$have" ] && [ "$have" != "unknown" ]; } || return 0
  if [[ "$have" < "$want" ]]; then
    echo "--- donedonedone install (tell the human once, before other work; never update it yourself) ---"
    echo "too old for this project: vault/project.md needs harness $want or newer, $have is installed — run: $update_cmd"
  fi
}

cmd_update() {
  local src before after
  [ -f "$stamp" ] || die "no install recorded in $dest — run install.sh from a clone"
  src=$(field source)
  git -C "$src" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 \
    || die "the clone this was installed from ($src) is gone or is not a git checkout — clone it again and run its install.sh"
  [ -z "$(git -C "$src" status --porcelain)" ] || die "$src has uncommitted changes — commit or stash them, then run this again"
  before=$(git -C "$src" rev-parse HEAD)
  git -C "$src" pull --ff-only || die "could not fast-forward $src — pull it by hand, then run $src/install.sh"
  after=$(git -C "$src" rev-parse HEAD)
  if [ "$before" = "$after" ] && [ "$after" = "$(field commit)" ] && [ -z "$(drifted)" ]; then
    echo "already up to date: $(short "$after") ($(field revision))"
    return 0
  fi
  echo "installing $(short "$after") (was $(short "$(field commit)"))"
  "$src/install.sh"
}

cmd_pin() {
  [ -f "$stamp" ] || die "no install recorded in $dest — run install.sh from a clone"
  [ "$(field revision)" != "unknown" ] || die "the install has no revision (it was not installed from a git clone)"
  echo "- harness: $(field revision) ($(short "$(field commit)"))"
}

cmd_project_hook() {
  local origin
  origin=$(field origin)
  cat <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ -x \"\$HOME/.claude/scripts/harness.sh\" ] || echo 'donedonedone is not installed on this machine and this project (vault/) is built with it. Tell the human before other work: git clone ${origin:-<the donedonedone repository>} && ./install.sh'"
          }
        ]
      }
    ]
  }
}
JSON
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  status|version) [ $# -eq 0 ] || usage; cmd_status ;;
  check) [ $# -eq 0 ] || usage; cmd_check ;;
  require) [ $# -le 1 ] || usage; cmd_require "${1:-.}" ;;
  update) [ $# -eq 0 ] || usage; cmd_update ;;
  pin) [ $# -eq 0 ] || usage; cmd_pin ;;
  project-hook) [ $# -eq 0 ] || usage; cmd_project_hook ;;
  stamp) [ $# -eq 1 ] || usage; cmd_stamp "$1" ;;
  *) usage ;;
esac
