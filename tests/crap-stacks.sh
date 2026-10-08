#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/gate.sh"
SCORER="$ROOT/scripts/crap-score.py"
FIXTURES="$ROOT/tests/fixtures/crap"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1 ($2)"; }

stack_repo() {
  local d
  d=$(mktemp -d)
  (cd "$FIXTURES/$1" && tar cf - --exclude=node_modules --exclude=target --exclude=coverage .) | (cd "$d" && tar xf -)
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@test
  git -C "$d" config user.name test
  mkdir -p "$d/vault"
  printf '# Project\n## Gate\n- gate.test: %s\n- gate.crap: %s\n' "$2" "$3" > "$d/vault/project.md"
  git -C "$d" add -A
  git -C "$d" commit -q -m "sample project"
  echo "$d"
}

branch_with() {
  git -C "$1" checkout -q main
  git -C "$1" checkout -q -b "$2"
  shift 2
  "$@"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m change
}

add_risky() { cp "$FIXTURES/risky/$(basename "$1")" "$repo/$1"; }

swap_multiply() { sed 's/amount \* 0\.9/0.9 * amount/' "$repo/$1" > "$repo/$1.new" && mv "$repo/$1.new" "$repo/$1"; }

check_stack() {
  local stack="$1" price_file="$2" price_name="$3" risky_file="$4"
  branch_with "$repo" slice/good swap_multiply "$price_file"
  status=0; out=$(cd "$repo" && "$GATE" test crap 2>&1) || status=$?
  if [ "$status" -eq 0 ] && echo "$out" | grep -q "^crap PASS.*highest touched: $price_name 3.0"; then
    ok "$stack: a change to tested code passes, scored from real coverage"
  else
    bad "$stack: a change to tested code passes, scored from real coverage" "exit $status: $out"
  fi
  branch_with "$repo" slice/risky add_risky "$risky_file"
  status=0; out=$(cd "$repo" && "$GATE" test crap 2>&1) || status=$?
  if [ "$status" -eq 1 ] && echo "$out" | grep -q "^  $risky_file:[0-9]* .*shipping 42.0$" && echo "$out" | grep -q "^GATE: FAIL (crap)"; then
    ok "$stack: an untested complexity-6 function fails the gate at CRAP 42"
  else
    bad "$stack: an untested complexity-6 function fails the gate at CRAP 42" "exit $status: $out"
  fi
  rm -rf "$repo"
}

echo "== Python: pytest + coverage.py (lcov) + lizard =="
repo=$(stack_repo python \
  "$PY -m coverage run -m pytest -q && $PY -m coverage lcov -q -o coverage.lcov" \
  "$PY $SCORER coverage.lcov src")
check_stack python src/shop/pricing.py price src/shop/shipping.py

install_home=$(mktemp -d)
HOME="$install_home" "$ROOT/install.sh" >/dev/null 2>&1
for variant in coverage pytest-cov; do
  echo "== Python: gate lines written by detect-gates.py ($variant) =="
  repo=$(mktemp -d)
  (cd "$FIXTURES/python" && tar cf - .) | (cd "$repo" && tar xf -)
  printf '\n[project]\nname = "shop"\nversion = "0"\ndependencies = ["pytest", "%s"]\n' "$variant" >> "$repo/pyproject.toml"
  mkdir -p "$repo/vault"
  printf '# Shop\n## Gate\n' > "$repo/vault/project.md"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@test
  git -C "$repo" config user.name test
  HOME="$install_home" "$PY" "$install_home/.claude/scripts/detect-gates.py" --apply "$repo" >/dev/null
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "sample project"
  status=0; out=$(cd "$repo" && HOME="$install_home" "$install_home/.claude/scripts/gate.sh" test crap 2>&1) || status=$?
  if [ "$status" -eq 0 ] && echo "$out" | grep -q "^crap PASS"; then
    ok "python ($variant): the detected gate.test and gate.crap pass on main"
  else
    bad "python ($variant): the detected gate.test and gate.crap pass on main" "exit $status: $out"
  fi
  branch_with "$repo" slice/risky add_risky src/shop/shipping.py
  status=0; out=$(cd "$repo" && HOME="$install_home" "$install_home/.claude/scripts/gate.sh" test crap 2>&1) || status=$?
  if [ "$status" -eq 1 ] && echo "$out" | grep -q "^  src/shop/shipping.py:[0-9]* .*shipping 42.0$" && [ -z "$(git -C "$repo" status --porcelain)" ]; then
    ok "python ($variant): the detected lines fail an untested complexity-6 function at CRAP 42 and leave the tree clean"
  else
    bad "python ($variant): the detected lines fail an untested complexity-6 function at CRAP 42 and leave the tree clean" "exit $status: $out $(git -C "$repo" status --porcelain)"
  fi
  rm -rf "$repo"
done
rm -rf "$install_home"

echo "== React: Vitest + V8 coverage (lcov) + lizard =="
repo=$(stack_repo react "npx vitest run --coverage" "$PY $SCORER coverage/lcov.info -x '*.test.*' src")
(cd "$repo" && npm ci --no-audit --no-fund >/dev/null 2>&1) || bad "react: npm ci" "install failed"
check_stack react src/Price.tsx Price src/Shipping.tsx

echo "== Java: Maven + JUnit 5 + JaCoCo (xml) + lizard =="
repo=$(stack_repo java "mvn -q -B test" "$PY $SCORER target/site/jacoco/jacoco.xml src/main/java")
check_stack java src/main/java/shop/Pricing.java "Pricing::price" src/main/java/shop/Shipping.java

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
