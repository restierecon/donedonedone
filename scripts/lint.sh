#!/bin/bash

input=$(cat)
event=$(echo "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
case "$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)" in
  Read|Grep|Glob|LS|NotebookRead|read_file|readFile|list_dir|listDirectory|file_search|grep_search|semantic_search) exit 0 ;;
esac
if [ "$event" = "postToolUse" ]; then
  msg=$(printf '%s' "$input" | jq -c 'del(.hook_event_name)' | "$0" 2>&1 >/dev/null) \
    || jq -cn --arg m "$msg" '{additional_context: $m}'
  exit 0
fi
files=$(echo "$input" | jq -r '[.tool_input.file_path, .tool_input.filePath, .tool_input.path, .file_path, .tool_input.replacements[]?.filePath?, (.tool_input.input | strings | scan("(?m)^\\*\\*\\* (?:Add|Update) File: (.+)$") | .[0])] | map(strings) | unique | .[]' 2>/dev/null)

lint_file() {
  local file="$1" errors=""
  [ -f "$file" ] || return 0
  case "$file" in
    *.py)
      command -v ruff >/dev/null 2>&1 || return 0
      ruff format "$file" >/dev/null 2>&1
      errors=$(ruff check --quiet "$file" 2>&1)
      ;;
    *.js|*.jsx|*.ts|*.tsx)
      if [ -f node_modules/.bin/prettier ]; then node_modules/.bin/prettier --write "$file" >/dev/null 2>&1; fi
      if [ -f node_modules/.bin/eslint ]; then errors=$(node_modules/.bin/eslint "$file" 2>&1 | grep -E "error"); fi
      ;;
  esac
  [ -z "$errors" ] && return 0
  echo "LINT ERRORS in $file — fix before continuing:" >&2
  echo "$errors" | head -15 >&2
  return 2
}

status=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  lint_file "$file" || status=2
done <<< "$files"
exit "$status"
