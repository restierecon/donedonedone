#!/bin/bash
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/jq-text.sh" ] && . "$(dirname "$0")/jq-text.sh"

mode="${1:-flags}"
conf="${DDD_NOTIFY_HOME:-$HOME/.claude}"
max_body=1500

destination_url() {
  if [ -n "${DDD_NOTIFY_URL:-}" ]; then
    printf '%s' "$DDD_NOTIFY_URL"
  elif [ -f "$conf/notify-url" ]; then
    head -n 1 "$conf/notify-url" | tr -d '\r[:space:]'
  fi
}

configured() {
  [ -x "$conf/notify-cmd" ] || [ -n "$(destination_url)" ]
}

curl_config() {
  local url=${1//\\/\\\\}
  printf 'url = "%s"\n' "${url//\"/\\\"}"
}

send() {
  local title=${1//[$'\r\n']/ } body=$2 url
  body=${body:0:$max_body}
  if [ -x "$conf/notify-cmd" ]; then
    printf '%s\n' "$body" | "$conf/notify-cmd" "$title" >/dev/null 2>&1
    return
  fi
  url=$(destination_url)
  [ -n "$url" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  case "$url" in
    https://hooks.slack.com/*)
      jq -n --arg t "$title" --arg b "$body" '{text: ("*" + $t + "*\n" + $b)}' |
        curl -fsS --max-time 5 -K <(curl_config "$url") -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 ;;
    https://discord.com/api/webhooks/* | https://discordapp.com/api/webhooks/*)
      jq -n --arg t "$title" --arg b "$body" '{content: ("**" + $t + "**\n" + $b)}' |
        curl -fsS --max-time 5 -K <(curl_config "$url") -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 ;;
    *)
      printf '%s' "$body" |
        curl -fsS --max-time 5 -K <(curl_config "$url") -H "Title: $title" -H 'Tags: robot' --data-binary @- >/dev/null 2>&1 ;;
  esac
}

project_root() {
  local cwd
  cwd=$(printf '%s' "${input:-}" | jq -r '.cwd // .workspace_roots[0]? // empty' 2>/dev/null)
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || return 1; fi
  git rev-parse --show-toplevel 2>/dev/null
}

added_lines() {
  local old=$1 new=$2
  if [ -f "$old" ]; then
    diff "$old" "$new" | sed -n 's/^> //p'
  else
    cat "$new"
  fi | grep -v '^[[:space:]]*$'
}

check_flags() {
  local top store name label file snap added
  top=$(project_root) || return 0
  [ -n "$top" ] && [ -d "$top/vault/flags" ] || return 0
  store="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/ddd-notify" || return 0
  mkdir -p "$store" 2>/dev/null || return 0
  for name in blocked pending-review; do
    file="$top/vault/flags/$name.md"
    snap="$store/$name.md"
    [ -f "$file" ] || continue
    if [ ! -f "$snap" ]; then
      cp "$file" "$snap"
      continue
    fi
    cmp -s "$file" "$snap" && continue
    added=$(added_lines "$snap" "$file")
    cp "$file" "$snap"
    [ -n "$added" ] || continue
    case "$name" in
      blocked) label="BLOCKED (auditor critical)" ;;
      *) label="needs your review" ;;
    esac
    send "$(basename "$top"): $label" "$added"$'\n\n'"vault/flags/$name.md"
  done
}

forward_event() {
  local top message kind
  top=$(project_root)
  message=$(printf '%s' "${input:-}" | jq -r '.message // empty' 2>/dev/null)
  kind=$(printf '%s' "${input:-}" | jq -r '.notification_type // empty' 2>/dev/null)
  [ -n "$message" ] || return 0
  send "${top:+$(basename "$top"): }Claude Code${kind:+ ($kind)}" "$message"
}

case "$mode" in
  test)
    if ! configured; then
      echo "notify: not configured — put a webhook or ntfy URL in $conf/notify-url (chmod 600), set DDD_NOTIFY_URL, or add an executable $conf/notify-cmd" >&2
      exit 1
    fi
    if send "donedonedone: test" "Notifications work. You'll hear from the Director when a slice needs you."; then
      echo "notify: test sent"
    else
      echo "notify: sending failed — check the URL and that curl can reach it" >&2
      exit 1
    fi ;;
  flags | event)
    configured || exit 0
    [ -t 0 ] || input=$(cat)
    if [ "$mode" = flags ]; then check_flags; else forward_event; fi
    exit 0 ;;
  *)
    echo "usage: notify.sh [flags|event|test]" >&2
    exit 2 ;;
esac
