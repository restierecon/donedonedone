#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCORER="$ROOT/scripts/crap-score.py"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 && "$PY" -c pass >/dev/null 2>&1 || PY=python

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1 ($2)"; }

work=$(mktemp -d)
cp -R "$ROOT/tests/fixtures/crap/score/." "$work/"
cd "$work" || exit 1
abs=$(pwd)

score() { "$PY" "$SCORER" "$@" 2>&1 | tr -d '\r'; }
expect_lines() {
  local desc="$1" want="$2"; shift 2
  local got
  got=$(score "$@")
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc" "got: $got"; fi
}

python_want='app.py:1-4 2.1 a
app.py:7-9 12.0 m'

printf 'SF:app.py\nDA:1,1\nDA:2,1\nDA:3,1\nDA:4,0\nDA:6,1\nDA:7,1\nDA:8,0\nDA:9,0\nend_of_record\n' > rel.lcov
expect_lines "lcov (coverage.py, Vitest): partial coverage scores comp² × (1 − cov)³ + comp, def line left out" "$python_want" rel.lcov app.py

printf 'SF:%s/app.py\nDA:1,1\nDA:2,1\nDA:3,1\nDA:4,0\nDA:6,1\nDA:7,1\nDA:8,0\nDA:9,0\nend_of_record\n' "$abs" > abs.lcov
expect_lines "lcov with absolute SF paths, as Jest writes them" "$python_want" abs.lcov app.py

printf 'SF:C:\\\\work\\\\proj\\\\app.py\r\nDA:1,1\r\nDA:2,1\r\nDA:3,1\r\nDA:4,0\r\nDA:6,1\r\nDA:7,1\r\nDA:8,0\r\nDA:9,0\r\nend_of_record\r\n' > win.lcov
expect_lines "lcov with CRLF and backslash Windows paths" "$python_want" win.lcov app.py

printf '{"meta": {}, "files": {"app.py": {"executed_lines": [1, 2, 3, 6, 7], "missing_lines": [4, 8, 9]}}}' > cov.json
expect_lines "coverage.py JSON" "$python_want" cov.json app.py

cat > cobertura.xml <<XML
<?xml version="1.0" ?>
<coverage version="7"><sources><source>$abs</source></sources><packages><package name="."><classes>
<class name="app.py" filename="app.py"><lines>
<line number="1" hits="1"/><line number="2" hits="1"/><line number="3" hits="1"/><line number="4" hits="0"/>
<line number="6" hits="1"/><line number="7" hits="1"/><line number="8" hits="0"/><line number="9" hits="0"/>
</lines></class></classes></package></packages></coverage>
XML
expect_lines "Cobertura XML (pytest-cov, Jest, Gradle plugins)" "$python_want" cobertura.xml app.py

cat > jacoco.xml <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?><report name="shop"><package name="shop"><sourcefile name="Pricing.java"><line nr="3" mi="0" ci="3"/><line nr="4" mi="2" ci="0"/><line nr="5" mi="1" ci="0"/><line nr="8" mi="0" ci="4"/><line nr="9" mi="2" ci="0"/><line nr="11" mi="0" ci="2"/><line nr="12" mi="4" ci="0"/><line nr="14" mi="2" ci="0"/></sourcefile></package></report>
XML
expect_lines "JaCoCo XML (Maven, Gradle) matched to src/main/java by package path" 'src/main/java/shop/Pricing.java:4-5 2.0 Pricing::Pricing
src/main/java/shop/Pricing.java:7-15 4.9 Pricing::price' jacoco.xml src/main/java

printf 'SF:other.py\nDA:1,1\nend_of_record\n' > none.lcov
expect_lines "a file the coverage report never saw scores as untested" 'app.py:1-4 6.0 a
app.py:7-9 12.0 m' none.lcov app.py

printf 'SF:Nested.tsx\nDA:1,1\nDA:2,1\nDA:3,0\nDA:4,0\nDA:5,1\nDA:6,1\nDA:7,1\nend_of_record\n' > nested.lcov
expect_lines "an inner function's lines count only toward the inner function (React handlers)" 'Nested.tsx:2-5 3.2 onClick
Nested.tsx:1-7 1.0 Outer' nested.lcov Nested.tsx

expect_lines "-x leaves matching files out" 'app.py:1-4 2.1 a
app.py:7-9 12.0 m' rel.lcov -x 'Nested*' -x 'src/*' .

echo 'hello' > junk.txt
status=0; out=$("$PY" "$SCORER" junk.txt app.py 2>&1) || status=$?
if [ "$status" -ne 0 ] && echo "$out" | grep -q "can't tell the format"; then ok "an unknown coverage format is an error, not empty output"; else bad "an unknown coverage format is an error, not empty output" "$out"; fi

cd "$ROOT" || exit 1
rm -rf "$work"
echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
