#!/bin/bash

case "$(command -v jq >/dev/null 2>&1 && command jq -rn '"x"' 2>/dev/null | tr '\r' '!')" in
  x!*) jq_writes_cr=1 ;;
  *) jq_writes_cr="" ;;
esac
if [ -n "$jq_writes_cr" ]; then
  if [ "$(command jq -b -rn '"x"' 2>/dev/null | tr '\r' '!')" = "x" ]; then
    jq() {
      command jq -b "$@"
    }
  else
    jq() {
      command jq "$@" | tr -d '\r'
      return "${PIPESTATUS[0]}"
    }
  fi
fi
