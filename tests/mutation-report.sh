#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTER="$ROOT/scripts/mutation-report.py"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 && "$PY" -c pass >/dev/null 2>&1 || PY=python

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1 ($2)"; }

work=$(mktemp -d)
cp -R "$ROOT/tests/fixtures/mutation/." "$work/"
cd "$work" || exit 1

report() { "$PY" "$ADAPTER" "$@" 2>&1 | tr -d '\r'; }
expect_lines() {
  local desc="$1" want="$2"; shift 2
  local got
  got=$(report "$@")
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc" "got: $got"; fi
}

expect_lines "mutation-testing-report-schema JSON (Stryker, Infection, Mull): statuses mapped, invalid mutants dropped, absolute paths made relative to projectRoot" \
'src/math.ts:1 killed ArithmeticOperator a - b
src/math.ts:2 survived UnaryOperator +a
src/io.ts:1 no-coverage StringLiteral ""
src/io.ts:1 timeout ArrowFunction () => undefined' stryker.json

mkdir -p pit/src/main/java/com/acme
touch pit/src/main/java/com/acme/Calc.java
cd pit || exit 1
expect_lines "PIT mutations.xml: package and sourceFile resolved to the repo path, nested classes included, run errors dropped" \
'src/main/java/com/acme/Calc.java:5 killed Replaced integer addition with subtraction
src/main/java/com/acme/Calc.java:9 survived changed conditional boundary
src/main/java/com/acme/Calc.java:13 no-coverage replaced int return with 0
src/main/java/com/acme/Calc.java:17 timeout Changed increment from 1 to -1' mutations.xml
cd .. || exit 1

expect_lines "cargo-mutants outcomes.json: baseline and unviable mutants dropped" \
'src/lib.rs:3 killed src/lib.rs:3:5: replace add -> i32 with 0
src/lib.rs:7 survived src/lib.rs:7:11: replace > with >= in over
src/lib.rs:9 timeout src/lib.rs:9:5: replace spin with ()' cargo-outcomes.json

expect_lines "Gremlins JSON: LIVED is a survivor, NOT_VIABLE dropped" \
'calc.go:4 killed ARITHMETIC_BASE
calc.go:8 survived CONDITIONALS_BOUNDARY
pkg/io.go:12 no-coverage INCREMENT_DECREMENT
pkg/io.go:15 timeout INVERT_LOOPCTRL' gremlins.json

mutmut_want='src/calc/__init__.py:2 killed calc.x_add__mutmut_1
src/calc/__init__.py:6 survived calc.x_clamp__mutmut_1
src/calc/__init__.py:8 survived calc.x_clamp__mutmut_2
src/calc/__init__.py:15 survived calc.xǁMeterǁover__mutmut_1'
got=$(cd mutmut && "$PY" "$ADAPTER" - < results.txt 2>&1 | tr -d '\r')
if [ "$got" = "$mutmut_want" ]; then
  ok "mutmut 3 results on stdin: each mutant traced to the line it changes, class methods included"
else
  bad "mutmut 3 results on stdin: each mutant traced to the line it changes, class methods included" "got: $got"
fi
cd mutmut || exit 1
expect_lines "mutmut results saved to a file are detected without '-'" "$mutmut_want" results.txt
cd .. || exit 1

printf '{"schemaVersion": "2", "thresholds": {}, "files": {}}' > empty.json
expect_lines "a valid report with no mutants prints no-mutants, so the gate can tell it from garbage" "no-mutants" empty.json

printf 'hello\n' > junk.txt
status=0; "$PY" "$ADAPTER" junk.txt >/dev/null 2>&1 || status=$?
if [ "$status" -ne 0 ]; then ok "an unknown format exits non-zero"; else bad "an unknown format exits non-zero" "exit 0"; fi

cd "$ROOT" || exit 1
rm -rf "$work"
echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
