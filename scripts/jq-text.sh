#!/bin/bash

if ! command -v jq >/dev/null 2>&1 && [ -d "$HOME/.claude/bin" ]; then
  PATH="$PATH:$HOME/.claude/bin"
fi

if command -v jq >/dev/null 2>&1 && [ "$(command jq -rn '"x"' 2>/dev/null | tr '\r' '!')" = "x!" ]; then
  jq() {
    command jq "$@" | tr -d '\r'
    return "${PIPESTATUS[0]}"
  }
fi
