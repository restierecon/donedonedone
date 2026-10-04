#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/gate.sh"
ADAPTER="$ROOT/scripts/mutation-report.py"
FIXTURE="$ROOT/tests/fixtures/mutation/python"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1 ($2)"; }

repo=$(mktemp -d)
(cd "$FIXTURE" && tar cf - --exclude=later --exclude=mutants --exclude=__pycache__ .) | (cd "$repo" && tar xf -)
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@test
git -C "$repo" config user.name test
mkdir -p "$repo/vault"
printf '# Project\n## Gate\n- gate.test: %s\n- gate.mutation: %s\n' \
  "$PY -m pytest -q" \
  "rm -rf mutants && $PY -m mutmut run >/dev/null 2>&1 && $PY -m mutmut results --all true 2>/dev/null | $PY \"$ADAPTER\" -" > "$repo/vault/project.md"
git -C "$repo" add -A
git -C "$repo" commit -q -m "sample project"

slice_with_tests() {
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b "$1"
  cp "$FIXTURE/later/discount.py" "$repo/src/shop/discount.py"
  cp "$FIXTURE/later/$2" "$repo/tests/$2"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m change
}

echo "== Python: pytest + mutmut through the real gate =="
slice_with_tests slice/weak test_discount_weak.py
status=0; out=$(cd "$repo" && "$GATE" test mutation 2>&1) || status=$?
if [ "$status" -eq 1 ] && echo "$out" | grep -q "^mutation FAIL.*under gate.mutation.min" \
   && echo "$out" | grep -q "^  survived: src/shop/discount.py:[23] survived" && echo "$out" | grep -q "^GATE: FAIL (mutation)"; then
  ok "python: tests that run the code without asserting fail the gate, survivors named by line"
else
  bad "python: tests that run the code without asserting fail the gate, survivors named by line" "exit $status: $out"
fi

slice_with_tests slice/strong test_discount_strong.py
status=0; out=$(cd "$repo" && "$GATE" test mutation 2>&1) || status=$?
if [ "$status" -eq 0 ] && echo "$out" | grep -q "^mutation PASS.*touched mutants (min 80%)"; then
  ok "python: asserting tests pass the gate"
else
  bad "python: asserting tests pass the gate" "exit $status: $out"
fi

rm -rf "$repo"
echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
