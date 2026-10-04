#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRAPH="$ROOT/scripts/codebase-graph.py"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 && "$PY" -c pass >/dev/null 2>&1 || PY=python

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1 ($2)"; }

new_repo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@test
  git -C "$d" config user.name test
  echo "$d"
}
commit() { git -C "$1" add -A && git -C "$1" commit -q -m "${2:-change}"; }
build() { (cd "$1" && "$PY" "$GRAPH" build "${@:2}" 2>&1); }
imports_of() { "$PY" -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["files"][sys.argv[2]]["imports"]))' "$1/.gate/graph.json" "$2"; }
field() { "$PY" -c 'import json,sys; g=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"g": g}))' "$1/.gate/graph.json" "$2"; }
expect() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$3', got '$2'"; fi
}

echo "== codebase-graph.py — import resolution per language =="
repo=$(new_repo)
mkdir -p "$repo/src/shop/pricing" "$repo/tests/fixtures/app" "$repo/web/lib" "$repo/go/internal/tax" "$repo/go/cmd" "$repo/java/src/main/java/shop/core"
touch "$repo/src/shop/__init__.py"
printf 'import json\nimport shop.pricing.rules\nfrom shop.pricing import rules as r\nfrom . import util\n' > "$repo/src/shop/pricing/__init__.py"
printf 'def rule():\n    return 1\n' > "$repo/src/shop/pricing/rules.py"
printf 'from .rules import rule\n' > "$repo/src/shop/pricing/util.py"
printf 'def json():\n    return 1\n' > "$repo/src/shop/pricing/json.py"
printf 'def shop():\n    return 1\n' > "$repo/tests/fixtures/app/shop.py"
printf '"""\nfrom shop.pricing import util\n"""\nfrom shop.pricing.rules import rule\ndef test_rule():\n    assert rule() == 1\n' > "$repo/tests/test_rules.py"
printf "import { add } from './lib/math'\nimport React from 'react'\nexport * from './lib'\n/* import x from './ghost' */\nconst y = require('./lib/math.js')\n" > "$repo/web/app.ts"
printf 'export const add = (a, b) => a + b\n' > "$repo/web/lib/math.js"
printf "export { add } from './math'\n" > "$repo/web/lib/index.ts"
printf 'module example.com/shop\n' > "$repo/go.mod"
printf 'package tax\nfunc Rate() int { return 1 }\n' > "$repo/go/internal/tax/tax.go"
printf 'package tax\nimport "testing"\nfunc TestRate(t *testing.T) {}\n' > "$repo/go/internal/tax/tax_test.go"
printf 'package main\nimport (\n  "fmt"\n  "example.com/shop/go/internal/tax"\n)\nfunc main() { fmt.Println(tax.Rate()) }\n' > "$repo/go/cmd/main.go"
printf 'package shop.core;\npublic class Money {}\n' > "$repo/java/src/main/java/shop/core/Money.java"
printf 'package shop;\nimport shop.core.Money;\nimport java.util.List;\npublic class Cart {}\n' > "$repo/java/src/main/java/shop/Cart.java"
commit "$repo" init
out=$(build "$repo")
if echo "$out" | grep -q "^GRAPH @ " && [ -f "$repo/.gate/graph.json" ] && [ -f "$repo/.gate/graph.html" ]; then ok "build writes graph.json and graph.html and prints a summary"; else bad "build writes graph.json and graph.html and prints a summary" "$out"; fi
expect "python: absolute, aliased and relative imports resolve; stdlib json stays external though a json.py sits inside a package" \
  "$(imports_of "$repo" src/shop/pricing/__init__.py)" "src/shop/pricing/rules.py src/shop/pricing/util.py"
expect "python: imports inside a docstring are ignored" "$(imports_of "$repo" tests/test_rules.py)" "src/shop/pricing/rules.py"
expect "python: a package resolves from its root, not a deeper same-named fixture" \
  "$(field "$repo" 'g["files"]["tests/fixtures/app/shop.py"]["imported_by"]')" "[]"
expect "js/ts: relative imports resolve with extensions and index files; comments and packages don't" \
  "$(imports_of "$repo" web/app.ts)" "web/lib/index.ts web/lib/math.js"
expect "js/ts: packages are recorded as externals" "$(field "$repo" 'g["files"]["web/app.ts"]["externals"]')" "['react']"
expect "go: an import under the go.mod module path reaches the package's non-test files" "$(imports_of "$repo" go/cmd/main.go)" "go/internal/tax/tax.go"
expect "go: _test.go files in the package count as its tests" "$(field "$repo" 'g["files"]["go/internal/tax/tax.go"]["tested_by"]')" "['go/internal/tax/tax_test.go']"
expect "java: a class import resolves by package path" "$(imports_of "$repo" java/src/main/java/shop/Cart.java)" "java/src/main/java/shop/core/Money.java"
expect "test files are marked as tests" "$(field "$repo" '[p for p, n in sorted(g["files"].items()) if n["test"]]')" "['go/internal/tax/tax_test.go', 'tests/fixtures/app/shop.py', 'tests/test_rules.py']"
rm -rf "$repo"

repo=$(new_repo)
for proj in alpha beta-project; do
  mkdir -p "$repo/fixtures/$proj/src/shop" "$repo/fixtures/$proj/tests"
  printf 'def add(a, b):\n    return a + b\n' > "$repo/fixtures/$proj/src/shop/__init__.py"
  printf 'from shop import add\n' > "$repo/fixtures/$proj/tests/test_shop.py"
done
commit "$repo" init
build "$repo" >/dev/null
expect "python: sibling projects with the same package name each resolve to their own copy" \
  "$(imports_of "$repo" fixtures/beta-project/tests/test_shop.py)" "fixtures/beta-project/src/shop/__init__.py"
rm -rf "$repo"

echo "== codebase-graph.py — cycles, hubs and why they're flagged =="
repo=$(new_repo)
mkdir -p "$repo/core" "$repo/db"
printf 'from db import store\ndef load():\n    return store.get()\n' > "$repo/core/model.py"
printf 'from core import model\ndef get():\n    return model\n' > "$repo/db/store.py"
for i in 1 2 3 4 5; do
  mkdir -p "$repo/f$i"
  printf 'from core.model import load\n' > "$repo/f$i/use.py"
done
commit "$repo" init
build "$repo" >/dev/null
expect "a module cycle is found and its path printed" "$(field "$repo" 'g["module_cycles"]')" "[['core', 'db', 'core']]"
expect "a file in a cycle says which import loop it is in" \
  "$(field "$repo" '[f["why"] for f in g["files"]["db/store.py"]["flags"] if f["kind"] == "cycle"]')" "['import cycle: core/model.py → db/store.py → core/model.py']"
expect "five or more non-test dependents make a hub, with the reason" \
  "$(field "$repo" '[f["why"] for f in g["modules"]["core"]["flags"] if f["kind"] == "hub"]')" "['6 non-test modules depend on it — a change here ripples to all of them']"
expect "cycle makes a module high risk" "$(field "$repo" 'g["modules"]["db"]["risk"]')" "high"
expect "fan-in, fan-out and instability are recorded" "$(field "$repo" '[g["modules"]["core"][k] for k in ("fan_in", "fan_out", "instability")]')" "[6, 1, 0.14]"
expect "without a coverage report, code no test reaches through imports is flagged untested" \
  "$(field "$repo" '[f["kind"] for f in g["files"]["core/model.py"]["flags"] if f["kind"] == "untested"]')" "['untested']"
mkdir -p "$repo/tests"
printf 'from db import store
def test_get():
    assert store.get()
' > "$repo/tests/test_store.py"
commit "$repo" test
build "$repo" >/dev/null
expect "a test that reaches code only through another module's import clears the flag" \
  "$(field "$repo" '[f["kind"] for f in g["files"]["core/model.py"]["flags"] if f["kind"] == "untested"]')" "[]"

echo "== codebase-graph.py — impact =="
out=$(cd "$repo" && "$PY" "$GRAPH" impact core/model.py)
if echo "$out" | grep -q "^Direct dependents:   6" && echo "$out" | grep -q "^Indirect dependents: 1" && echo "$out" | grep -q "^Tests in reach:      1 (tests/test_store.py)" \
   && echo "$out" | grep -q "^Dependency cycles:   core ↔ db" && echo "$out" | grep -q "^Regression risk:     High (estimate"; then
  ok "impact lists direct dependents, cycles touched and an estimated risk"
else
  bad "impact lists direct dependents, cycles touched and an estimated risk" "$out"
fi
git -C "$repo" checkout -q -b slice
printf 'X = 1\n' > "$repo/f1/extra.py"
commit "$repo" extra
out=$(cd "$repo" && "$PY" "$GRAPH" impact --base main)
if echo "$out" | grep -q "^Files:               1 source" && echo "$out" | grep -q "^Regression risk:     Low"; then
  ok "impact --base takes the changed files from the diff"
else
  bad "impact --base takes the changed files from the diff" "$out"
fi
rm -rf "$repo"

echo "== codebase-graph.py — check: only what the diff introduces fails =="
repo=$(new_repo)
mkdir -p "$repo/src/domain/orders" "$repo/src/infra" "$repo/src/web"
printf 'from src.infra import db\n' > "$repo/src/domain/orders/legacy.py"
printf 'X = 1\n' > "$repo/src/infra/db.py"
printf 'from src.domain.orders import legacy\n' > "$repo/src/web/app.py"
printf '{"forbid": [{"from": "src/domain/**", "to": "src/infra/*.py", "why": "ADR-002"}]}\n' > "$repo/rules.json"
commit "$repo" init
out=$(cd "$repo" && "$PY" "$GRAPH" check --rules rules.json --base HEAD); status=$?
expect "a violation already on the base passes (the slice didn't add it)" "$status:$out" "0:PASS 1 forbid rule(s), no new cycles, nothing new against HEAD"
git -C "$repo" checkout -q -b slice
printf 'from src.infra.db import X\n' > "$repo/src/domain/orders/new.py"
commit "$repo" new
out=$(cd "$repo" && "$PY" "$GRAPH" check --rules rules.json --base main); status=$?
if [ "$status" -eq 1 ] && echo "$out" | grep -q "src/domain/orders/new.py imports src/infra/db.py — src/domain/\*\* must not depend on src/infra/\*.py (ADR-002)" \
   && ! echo "$out" | grep -q legacy.py; then
  ok "a new forbidden import fails, ** crosses directories, the old one isn't re-reported"
else
  bad "a new forbidden import fails, ** crosses directories, the old one isn't re-reported" "$status: $out"
fi
printf '{"forbid": [{"from": "src/domain/*"}]}\n' > "$repo/bad.json"
out=$(cd "$repo" && "$PY" "$GRAPH" check --rules bad.json --base main 2>&1); status=$?
if [ "$status" -ne 0 ] && echo "$out" | grep -q "needs 'from' and 'to'"; then ok "a malformed rule is an error, not a silent pass"; else bad "a malformed rule is an error, not a silent pass" "$status: $out"; fi
printf '{"no_new_cycles": false, "forbid": []}\n' > "$repo/off.json"
printf 'from src.web import app\n' > "$repo/src/domain/orders/cyc.py"
commit "$repo" cyc
out=$(cd "$repo" && "$PY" "$GRAPH" check --rules off.json --base main); status=$?
expect "no_new_cycles: false turns the cycle check off" "$status" "0"
printf '{"forbid": []}\n' > "$repo/on.json"
out=$(cd "$repo" && "$PY" "$GRAPH" check --rules on.json --base main); status=$?
if [ "$status" -eq 1 ] && echo "$out" | grep -q "new module cycle edge src/domain/orders → src/web (via src/domain/orders/cyc.py)" && ! echo "$out" | grep -q "src/web → src/domain"; then
  ok "a new cycle is blamed on the new edge only, not the old one it closes"
else
  bad "a new cycle is blamed on the new edge only, not the old one it closes" "$status: $out"
fi
rm -rf "$repo"

echo "== codebase-graph.py — viewer and options =="
repo=$(new_repo)
printf 'def a():\n    return "</script><script>alert(1)</script>"\n' > "$repo/x.py"
commit "$repo" init
build "$repo" --out out >/dev/null
if [ -f "$repo/out/graph.html" ] && ! grep -q "__GRAPH_JSON__" "$repo/out/graph.html" && ! grep -q '</script><script>alert' "$repo/out/graph.html"; then
  ok "viewer embeds the data, escapes </script>, honours --out"
else
  bad "viewer embeds the data, escapes </script>, honours --out" "$(grep -c alert "$repo/out/graph.html" 2>/dev/null)"
fi
out=$(cd "$repo" && "$PY" "$GRAPH" build --days abc 2>&1); status=$?
expect "a non-numeric --days is a usage error" "$status" "2"
out=$(cd "$repo" && "$PY" "$GRAPH" frobnicate 2>&1); status=$?
expect "an unknown command is a usage error" "$status" "2"
rm -rf "$repo"

if "$PY" -c 'import lizard' >/dev/null 2>&1; then
  echo "== codebase-graph.py — complexity, churn and coverage (lizard present) =="
  repo=$(new_repo)
  body='def route(a, b, c, d, e, f, g, h, i, j):\n'
  for v in a b c d e f g h i j; do body="$body    if $v:\n        return \"$v\"\n"; done
  body="$body    return None\n"
  printf "%b" "$body" > "$repo/hot.py"
  for n in 1 2 3 4; do printf 'x%s = 1\n' "$n" >> "$repo/hot.py"; commit "$repo" "c$n"; done
  printf 'SF:hot.py\nDA:1,1\nDA:2,1\nDA:3,0\nDA:4,0\nend_of_record\n' > "$repo/cov.lcov"
  build "$repo" --coverage cov.lcov >/dev/null
  expect "complexity is measured per function" "$(field "$repo" 'g["files"]["hot.py"]["functions"][0]["ccn"]')" "11"
  expect "churn counts commits touching the file" "$(field "$repo" 'g["files"]["hot.py"]["churn"]')" "4"
  expect "complex + frequently changed is a hotspot, with numbers in the reason" \
    "$(field "$repo" '[f["why"].split(" — ")[0] for f in g["files"]["hot.py"]["flags"] if f["kind"] == "hotspot"]')" "['route() has complexity 11 and the file changed 4 times in 90 days']"
  expect "coverage from an lcov report is attached (reusing crap-score.py's loaders)" "$(field "$repo" 'g["files"]["hot.py"]["coverage"]')" "0.5"
  rm -rf "$repo"
else
  echo "  SKIP  complexity, churn and coverage (pip install lizard)"
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
