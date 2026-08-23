#!/bin/bash
# PostToolUse lint — format silently, surface real errors to the model immediately.
# Exit 2 feeds stderr back as corrective input while the file is still in working attention.

input=$(cat)
# VS Code Copilot loads this same settings.json but uses camelCase tool_input keys.
file=$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null)
[ -z "$file" ] || [ ! -f "$file" ] && exit 0

errors=""
case "$file" in
  *.py)
    command -v ruff >/dev/null 2>&1 || exit 0
    ruff format "$file" >/dev/null 2>&1
    errors=$(ruff check --quiet "$file" 2>&1)
    ;;
  *.js|*.jsx|*.ts|*.tsx)
    if [ -f node_modules/.bin/prettier ]; then node_modules/.bin/prettier --write "$file" >/dev/null 2>&1; fi
    if [ -f node_modules/.bin/eslint ]; then errors=$(node_modules/.bin/eslint "$file" 2>&1 | grep -E "error"); fi
    ;;
  *) exit 0 ;;
esac

if [ -n "$errors" ]; then
  echo "LINT ERRORS in $file — fix before continuing:" >&2
  echo "$errors" | head -15 >&2
  exit 2
fi
exit 0
