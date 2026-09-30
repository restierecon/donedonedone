#!/bin/bash

usage() {
  echo "usage: $(basename "$0") --base <ref> | <file>..." >&2
  exit 2
}

directives='^(!|-\*-|noqa|type: *ignore|pyright:|mypy:|pylint:|ruff:|fmt: *(off|on|skip)|isort:|pragma|nosec|eslint|prettier-ignore|@ts-|istanbul |c8 |v8 |biome-ignore|jshint|global |shellcheck |rubocop:|nolint|NOLINT|\+build|SPDX-License-Identifier|Copyright|clang-format|swiftlint:|@formatter:|ktlint|detekt|nosemgrep|gitleaks:allow|syntax=|escape=|check=|#?region|#?endregion|@flow|@jsx|@refresh|webpackChunkName|@vite-ignore|sourceMappingURL|/ *<reference|[#@]__PURE__|__NO_SIDE_EFFECTS__|fallthrough|FALLTHROUGH|cspell:|codespell:|yamllint|hadolint|tflint|checkov|NOSONAR|@generated|Code generated .* DO NOT EDIT)'

top=$(git rev-parse --show-toplevel 2>/dev/null)
project="$top/vault/project.md"
if [ -n "$top" ] && [ ! -f "$project" ]; then
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$common" ] && project="$(dirname "$common")/vault/project.md"
fi
setting() {
  [ -f "$project" ] && sed -n "s/^[-*][[:space:]]*gate\.comments\.$1:[[:space:]]*//p" "$project" | head -1 | sed "s/^\`//; s/\`\$//"
}
extra=$(setting directives)
[ -n "$extra" ] && directives="$directives|$extra"
skip_prefixes=$(setting skip)

language_of() {
  local path="$1" first="$2" base ext
  base=$(basename "$path")
  case "$base" in
    Dockerfile|Dockerfile.*|Makefile|GNUmakefile|*.mk) echo hashword; return ;;
  esac
  ext="${base##*.}"
  [ "$ext" = "$base" ] && ext=""
  case "$ext" in
    py|pyi) echo python ;;
    sh|bash|zsh|ksh|bats) echo shell ;;
    rb|rake|gemspec) echo ruby ;;
    pl|pm|r|R|ex|exs|jl) echo hashany ;;
    yaml|yml|toml|cmake|nix) echo hashword ;;
    tf|tfvars|hcl) echo hcl ;;
    js|jsx|mjs|cjs|ts|tsx|mts|cts|go) echo backtick ;;
    rs) echo rust ;;
    c|h|cc|cpp|cxx|hpp|hh|m|mm|cs|zig|proto) echo cfamily ;;
    java|kt|kts|swift|scala|groovy|gradle|dart) echo textblock ;;
    php) echo php ;;
    css) echo css ;;
    scss|sass|less) echo scss ;;
    sql|lua) echo dash ;;
    hs|elm) echo haskell ;;
    html|htm|xhtml|xml|svg|vue|svelte) echo markup ;;
    "")
      case "$first" in
        '#!'*python*) echo python ;;
        '#!'*ruby*) echo ruby ;;
        '#!'*sh*) echo shell ;;
      esac ;;
  esac
}

scan() {
  local lang="$1" label="$2" lines="$3"
  FC_DIRECTIVES="$directives" FC_LINES="$lines" awk -v lang="$lang" -v label="$label" '
    BEGIN {
      hash = hashany = slash = block = dash = html = hsb = py = heredocs = 0
      quotes = ""; multi = ""; triples = ""
      if (lang == "python")    { hash = hashany = py = 1; quotes = "\"'\''"; triples = "\"\"\" '\'''\'''\''" }
      if (lang == "shell")     { hash = heredocs = 1; quotes = "\"'\''"; multi = quotes }
      if (lang == "ruby")      { hash = hashany = heredocs = 1; quotes = "\"'\''`" }
      if (lang == "hashany")   { hash = hashany = 1; quotes = "\"'\''" }
      if (lang == "hashword")  { hash = 1; quotes = "\"'\''" }
      if (lang == "hcl")       { hash = slash = block = 1; quotes = "\"" }
      if (lang == "backtick")  { slash = block = 1; quotes = "\"'\''`"; multi = "`" }
      if (lang == "rust")      { slash = block = 1; quotes = "\""; multi = "\"" }
      if (lang == "cfamily")   { slash = block = 1; quotes = "\"'\''" }
      if (lang == "textblock") { slash = block = 1; quotes = "\"'\''"; triples = "\"\"\" '\'''\'''\''" }
      if (lang == "php")       { hash = hashany = slash = block = 1; quotes = "\"'\''" }
      if (lang == "css")       { block = 1; quotes = "\"'\''" }
      if (lang == "scss")      { slash = block = 1; quotes = "\"'\''" }
      if (lang == "dash")      { dash = block = 1; quotes = "\"'\''" }
      if (lang == "haskell")   { dash = hsb = 1; quotes = "\"" }
      if (lang == "markup")    { html = slash = block = 1 }
      directives = ENVIRON["FC_DIRECTIVES"]
      wanted = ENVIRON["FC_LINES"]
      inq = ""; closer = ""; heredoc = ""; depth = 0; prevcode = ""; indoc = 0
    }
    function report(raw,   body) {
      body = raw
      sub(/^(#+|\/\/+|\/\*+|--+|<!--|\{-)[ \t*]*/, "", body)
      if (body ~ directives || raw ~ /^\/\/(go:|export |line |nolint)/) return
      if (wanted != "" && index(wanted, " " FNR " ") == 0) return
      print label ":" FNR ": " $0
      found = 1
    }
    function wordstart(line, i,   p) {
      if (i == 1) return 1
      p = substr(line, i - 1, 1)
      return p == " " || p == "\t" || p == ";" || p == "|" || p == "&" || p == "(" || p == ")"
    }
    function istriple(s,   n, parts, k) {
      n = split(triples, parts, " ")
      for (k = 1; k <= n; k++) if (s == parts[k]) return 1
      return 0
    }
    {
      line = $0
      if (heredoc != "") {
        t = line; sub(/^\t+/, "", t)
        if (t == heredoc) heredoc = ""
        next
      }
      commented = 0; code = ""; pending = ""
      start = 1
      if (closer != "") {
        p = index(line, closer)
        report(line)
        if (p == 0) next
        commented = 1
        start = p + length(closer)
        closer = ""
      }
      if (inq == "" && py && triples != "") {
        t = line; sub(/^[ \t]+/, "", t)
        if (t ~ /^[rRuUbBfF]?[rRuUbBfF]?("""|'\'''\'''\'')/ && depth == 0 && prevcode !~ /(\\|=)$/) indoc = 1
      }
      if (indoc) commented = 1
      for (i = start; i <= length(line); i++) {
        c = substr(line, i, 1); two = substr(line, i, 2); three = substr(line, i, 3)
        if (inq != "") {
          if (length(inq) == 3) {
            if (three == inq) { inq = ""; i += 2; if (indoc) indoc = 2 }
            else if (c == "\\") i++
            continue
          }
          if (c == "\\" && !(lang == "shell" && inq == "'\''")) { i++; continue }
          if (c == inq) inq = ""
          continue
        }
        if (c == "\\") { code = code two; i++; continue }
        if (block && two == "/*") {
          p = index(substr(line, i + 2), "*/")
          report(substr(line, i)); commented = 2
          if (p == 0) { closer = "*/"; break }
          i = i + 1 + p + 1; continue
        }
        if (hsb && two == "{-") {
          p = index(substr(line, i + 2), "-}")
          report(substr(line, i)); commented = 2
          if (p == 0) { closer = "-}"; break }
          i = i + 1 + p + 1; continue
        }
        if (html && substr(line, i, 4) == "<!--") {
          p = index(substr(line, i + 4), "-->")
          report(substr(line, i)); commented = 2
          if (p == 0) { closer = "-->"; break }
          i = i + 3 + p + 2; continue
        }
        if (slash && two == "//" && (i == 1 || substr(line, i - 1, 1) != ":")) { report(substr(line, i)); commented = 2; break }
        if (hash && c == "#" && (hashany || wordstart(line, i))) {
          if (!(FNR == 1 && two == "#!")) report(substr(line, i))
          commented = 2; break
        }
        if (dash && two == "--") { report(substr(line, i)); commented = 2; break }
        if (triples != "" && istriple(three)) { inq = three; code = code three; i += 2; continue }
        if (heredocs && two == "<<" && substr(line, i + 2, 1) != "<") {
          rest = substr(line, i + 2)
          sub(/^[-~]?[ \t]*/, "", rest); sub(/^["'\'']/, "", rest)
          if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) pending = substr(rest, 1, RLENGTH)
        }
        if (quotes != "" && index(quotes, c)) { inq = c; code = code c; continue }
        if (py) { if (c == "(" || c == "[" || c == "{") depth++; else if (c == ")" || c == "]" || c == "}") depth-- }
        code = code c
      }
      if (indoc) { report(line); if (indoc == 2) indoc = 0 }
      if (inq != "" && length(inq) == 1 && index(multi, inq) == 0) inq = ""
      if (pending != "") heredoc = pending
      t = code; gsub(/[ \t]+$/, "", t)
      if (t ~ /[^ \t]/ && commented != 1) prevcode = t
    }
    END { exit found ? 1 : 0 }
  '
}

skipped() {
  local path="$1" prefix
  case "$path" in vault/*) return 0 ;; esac
  for prefix in $skip_prefixes; do
    case "$path" in "$prefix"*) return 0 ;; esac
  done
  return 1
}

status=0
if [ "${1:-}" = "--base" ]; then
  [ -n "${2:-}" ] || usage
  [ -n "$top" ] || { echo "find-comments.sh: not inside a git repo" >&2; exit 2; }
  added=$(git -C "$top" diff -U0 --diff-filter=AMR "$2...HEAD" | awk '
    /^\+\+\+ / { f = substr($0, 7); next }
    /^@@/      { match($0, /\+[0-9]+(,[0-9]+)?/); spec = substr($0, RSTART + 1, RLENGTH - 1)
                 n = split(spec, a, ","); count = (n == 2) ? a[2] : 1
                 for (k = 0; k < count; k++) lines[f] = lines[f] " " (a[1] + k)
                 next }
    END { for (f in lines) print f "\t" lines[f] " " }')
  while IFS=$'\t' read -r path lines; do
    [ -n "$path" ] || continue
    skipped "$path" && continue
    content=$(git -C "$top" show "HEAD:$path" 2>/dev/null) || continue
    lang=$(language_of "$path" "$(printf '%s\n' "$content" | head -1)")
    [ -n "$lang" ] || continue
    printf '%s\n' "$content" | scan "$lang" "$path" "$lines" || status=1
  done <<< "$added"
else
  [ $# -gt 0 ] || usage
  for path in "$@"; do
    [ -f "$path" ] || continue
    lang=$(language_of "$path" "$(head -1 "$path")")
    [ -n "$lang" ] || continue
    label="$path"
    scan "$lang" "$label" "" < "$path" || status=1
  done
fi
exit "$status"
