#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DETECT="$ROOT/scripts/detect-gates.py"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 && "$PY" -c pass >/dev/null 2>&1 || PY=python

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1 ($2)"; }

repo() {
  local d f
  d=$(mktemp -d)
  while [ $# -gt 1 ]; do
    f="$d/$1"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$2" > "$f"
    shift 2
  done
  echo "$d"
}

detect() { "$PY" "$DETECT" "$@" 2>&1 | tr -d '\r'; return "${PIPESTATUS[0]}"; }
py_abs=$(command -v "$PY")
PYN=$("$PY" -c 'import shutil; print("python" if not shutil.which("python3") and shutil.which("python") else "python3")' | tr -d '\r')
detect_on_path() { local p="$1"; shift; PATH="$p" "$py_abs" "$DETECT" "$@" 2>&1 | tr -d '\r'; }
fake_tool() { printf '#!/bin/sh\n' > "$1/$2"; printf '@echo off\r\n' > "$1/$2.bat"; chmod +x "$1/$2" "$1/$2.bat"; }

has() {
  local desc="$1" out="$2"; shift 2
  local want
  for want in "$@"; do
    if ! printf '%s\n' "$out" | grep -qxF -- "$want"; then bad "$desc" "missing line: $want
$out"; return; fi
  done
  ok "$desc"
}

matches() {
  local desc="$1" out="$2" pattern="$3"
  if printf '%s\n' "$out" | grep -qE -- "$pattern"; then ok "$desc"; else bad "$desc" "no line matching $pattern
$out"; fi
}

echo "== detect-gates.py — Python =="
d=$(repo pyproject.toml '[project]
name = "shop"
[dependency-groups]
dev = ["pytest>=8", "pytest-cov", "pytest-timeout", "ruff", "mypy", "mutmut", "build"]
[tool.mutmut]
source_paths = ["src/"]' uv.lock '' src/shop/__init__.py '')
out=$(detect "$d")
has "python with uv: every declared tool becomes a ready line, run through uv" "$out" \
  "READY  - gate.lint: uv run python -m ruff check -q ." \
  "READY  - gate.types: uv run python -m mypy src" \
  "READY  - gate.test: COVERAGE_FILE=.gate/.coverage uv run python -m pytest -q --timeout=10 --cov=src --cov-report=lcov:.gate/coverage.lcov" \
  "READY  - gate.test.focus: uv run python -m pytest -q {}" \
  "READY  - gate.build: uv run python -m build" \
  "READY  - gate.crap: $PYN ~/.claude/scripts/crap-score.py .gate/coverage.lcov src" \
  "READY  - gate.crap.max: 30" \
  "READY  - gate.mutation.min: 80" \
  "N/A    gate.a11y — no UI framework in the Python manifests" \
  "IGNORE dist/ mutants/"
rm -rf "$d"

d=$(repo pyproject.toml '[tool.pytest.ini_options]
testpaths = ["tests"]
[tool.coverage.run]
branch = true' requirements-dev.txt 'django>=5' tests/test_app.py '')
out=$(detect "$d")
has "python: config sections count as evidence; coverage.py writes its report into .gate/" "$out" \
  "READY  - gate.test: COVERAGE_FILE=.gate/.coverage $PYN -m coverage run -m pytest -q && COVERAGE_FILE=.gate/.coverage $PYN -m coverage lcov -q -o .gate/coverage.lcov" \
  "READY  - gate.crap: $PYN ~/.claude/scripts/crap-score.py .gate/coverage.lcov -x 'test_*.py' -x '*_test.py' ."
matches "python: a server-rendered UI needs an a11y slice" "$out" '^SLICE  gate\.a11y — server-rendered UI'
matches "python: missing linter and type checker become slice proposals, not silent skips" "$out" '^SLICE  gate\.lint — no linter declared; add ruff'
matches "python: mutmut not yet declared is a slice with the config it needs" "$out" '^SLICE  gate\.mutation — add mutmut 3 .*source_paths = \["\./"\]|^SLICE  gate\.mutation — add mutmut 3'
rm -rf "$d"

echo "== detect-gates.py — JavaScript / TypeScript =="
d=$(repo package.json '{"scripts": {"build": "vite build", "typecheck": "tsc -p ."},
 "dependencies": {"react": "18"},
 "devDependencies": {"vitest": "2", "@vitest/coverage-v8": "2", "typescript": "5", "eslint": "9"}}' \
  pnpm-lock.yaml '' tsconfig.json '{}' vitest.config.ts 'export default { test: { coverage: { provider: "v8", reporter: ["lcov"] } } }' src/App.tsx '')
out=$(detect "$d")
has "vitest with lcov coverage and pnpm: coverage on, crap ready, a11y and stryker proposed" "$out" \
  "READY  - gate.lint: pnpm exec eslint ." \
  "READY  - gate.types: pnpm -s typecheck" \
  "READY  - gate.test: pnpm exec vitest run --coverage" \
  "READY  - gate.test.focus: pnpm exec vitest run {}" \
  "READY  - gate.build: pnpm -s build" \
  "READY  - gate.crap: $PYN ~/.claude/scripts/crap-score.py coverage/lcov.info -x '*.test.*' -x '*.spec.*' src" \
  "IGNORE dist/ coverage/"
matches "react without an accessibility check: a11y is a slice naming the packages" "$out" '^SLICE  gate\.a11y — UI \(react\) .*@axe-core/playwright'
matches "vitest without stryker: mutation slice names the vitest runner plugin" "$out" '^SLICE  gate\.mutation — add @stryker-mutator/core and @stryker-mutator/vitest-runner'
rm -rf "$d"

d=$(repo package.json '{"scripts": {"lint": "eslint . --fix", "test:a11y": "playwright test a11y"},
 "dependencies": {"vue": "3"},
 "devDependencies": {"jest": "29", "eslint": "9", "@stryker-mutator/core": "8"}}')
out=$(detect "$d")
has "jest: coverage goes to .gate/, a fixing lint script is skipped, an a11y script is used" "$out" \
  "READY  - gate.lint: npx eslint ." \
  "READY  - gate.test: npx jest --coverage --coverageReporters=lcov --coverageDirectory=.gate/coverage" \
  "READY  - gate.test.focus: npx jest {}" \
  "READY  - gate.a11y: npm run -s test:a11y" \
  "READY  - gate.crap: $PYN ~/.claude/scripts/crap-score.py .gate/coverage/lcov.info -x '*.test.*' -x '*.spec.*' ." \
  "READY  - gate.mutation: npx stryker run --reporters json && $PYN ~/.claude/scripts/mutation-report.py reports/mutation/mutation.json" \
  "N/A    gate.types — plain JavaScript (no typescript with a tsconfig.json)"
rm -rf "$d"

d=$(repo package.json '{"scripts": {"test": "node --test"}, "dependencies": {"express": "4"}}')
out=$(detect "$d")
has "a node service with no UI: a11y is not applicable; a custom test script runs with CI=true" "$out" \
  "N/A    gate.a11y — no UI framework in package.json" \
  "READY  - gate.test: CI=true npm run -s test"
rm -rf "$d"

d=$(repo package.json '{"scripts": ')
out=$(detect "$d")
matches "a package.json that doesn't parse asks for a fix instead of guessing" "$out" "^SLICE  gate\.test — package\.json doesn't parse"
rm -rf "$d"

echo "== detect-gates.py — JVM =="
d=$(repo pom.xml '<project><build><plugins>
<plugin><artifactId>jacoco-maven-plugin</artifactId><executions><execution><goals><goal>prepare-agent</goal></goals></execution><execution><goals><goal>report</goal></goals></execution></executions></plugin>
<plugin><groupId>org.pitest</groupId><artifactId>pitest-maven</artifactId></plugin>
<plugin><artifactId>maven-checkstyle-plugin</artifactId></plugin>
</plugins></build></project>' mvnw '')
out=$(detect "$d")
has "maven with jacoco, pit and checkstyle through mvnw: all ready" "$out" \
  "READY  - gate.lint: ./mvnw -q -B checkstyle:check" \
  "READY  - gate.test: ./mvnw -q -B test" \
  "READY  - gate.crap: $PYN ~/.claude/scripts/crap-score.py target/site/jacoco/jacoco.xml src/main/java" \
  "READY  - gate.mutation: ./mvnw -q -B test-compile org.pitest:pitest-maven:mutationCoverage -DoutputFormats=XML -DtimestampedReports=false && $PYN ~/.claude/scripts/mutation-report.py target/pit-reports/mutations.xml" \
  "IGNORE target/"
rm -rf "$d"

d=$(repo build.gradle.kts 'plugins { jacoco }
tasks.jacocoTestReport { reports { xml.required = true } }' gradlew '')
out=$(detect "$d")
has "gradle with jacoco xml: the test step produces the report crap reads" "$out" \
  "READY  - gate.test: ./gradlew -q test jacocoTestReport" \
  "READY  - gate.crap: $PYN ~/.claude/scripts/crap-score.py build/reports/jacoco/test/jacocoTestReport.xml src/main/java"
matches "gradle without pitest: mutation is a slice naming the plugin settings" "$out" "^SLICE  gate\.mutation — apply info\.solidsoft\.pitest with outputFormats"
rm -rf "$d"

echo "== detect-gates.py — Go and Rust: machine tools =="
nobin=$(mktemp -d)
d=$(repo go.mod 'module example.com/shop')
out=$(detect_on_path "$nobin" "$d")
has "go: vet, test and build are ready with nothing installed" "$out" \
  "READY  - gate.lint: go vet ./..." \
  "READY  - gate.test: go test ./..." \
  "READY  - gate.build: go build ./..."
matches "go without gremlins: mutation is a TOOL line with the install command" "$out" '^TOOL   gate\.mutation — install gremlins: go install github\.com/go-gremlins/gremlins/cmd/gremlins@latest ⇒'
matches "go without gocover-cobertura: crap says how gate.test changes" "$out" '^TOOL   gate\.crap — .*gate\.test then becomes: go test -coverprofile=\.gate/cover\.out'
fake_tool "$nobin" gremlins; fake_tool "$nobin" gocover-cobertura
out=$(detect_on_path "$nobin" "$d")
has "go with gremlins and gocover-cobertura on PATH: both ready, gate.test writes the coverage" "$out" \
  "READY  - gate.test: go test -coverprofile=.gate/cover.out ./... && gocover-cobertura < .gate/cover.out > .gate/coverage.xml" \
  "READY  - gate.crap: $PYN ~/.claude/scripts/crap-score.py .gate/coverage.xml ." \
  "READY  - gate.mutation: gremlins unleash --diff \"\$GATE_BASE\" --output .gate/gremlins.json && $PYN ~/.claude/scripts/mutation-report.py .gate/gremlins.json"
rm -rf "$d" "$nobin"

nobin=$(mktemp -d)
d=$(repo Cargo.toml '[package]
name = "shop"')
out=$(detect_on_path "$nobin" "$d")
has "rust: clippy, test and build are ready" "$out" \
  "READY  - gate.lint: cargo clippy -q --all-targets -- -D warnings" \
  "READY  - gate.test: cargo test -q" \
  "N/A    gate.types — rustc type-checks during gate.test"
matches "rust without cargo-mutants: TOOL line with its install command" "$out" '^TOOL   gate\.mutation — install cargo-mutants: cargo install cargo-mutants'
rm -rf "$d" "$nobin"

nobin=$(mktemp -d)
fake_tool "$nobin" python
d=$(repo pyproject.toml '[tool.pytest.ini_options]
[tool.coverage.run]')
out=$(detect_on_path "$nobin" "$d")
has "a machine with python but no python3 (Windows): every command names python" "$out" \
  "READY  - gate.test: COVERAGE_FILE=.gate/.coverage python -m coverage run -m pytest -q && COVERAGE_FILE=.gate/.coverage python -m coverage lcov -q -o .gate/coverage.lcov" \
  "READY  - gate.crap: python ~/.claude/scripts/crap-score.py .gate/coverage.lcov -x 'test_*.py' -x '*_test.py' ."
rm -rf "$d" "$nobin"

echo "== detect-gates.py — several stacks, none, and lines a human already set =="
d=$(repo pyproject.toml '[tool.ruff]
[tool.pytest.ini_options]' package.json '{"scripts": {"lint": "eslint ."}, "dependencies": {"react": "18"},
 "devDependencies": {"vitest": "2", "@vitest/coverage-v8": "2"}}' vitest.config.js 'export default { test: { coverage: { reporter: ["lcov"] } } }')
out=$(detect "$d")
has "python + react: lint and test chain both stacks, and only the stack crap follows gets coverage" "$out" \
  "STACK: python (pyproject.toml) + node (package.json)" \
  "READY  - gate.lint: $PYN -m ruff check -q . && npm run -s lint" \
  "READY  - gate.test: $PYN -m pytest -q && npx vitest run --coverage" \
  "READY  - gate.crap: $PYN ~/.claude/scripts/crap-score.py coverage/lcov.info -x '*.test.*' -x '*.spec.*' ."
matches "python + react: two focus commands can't share one line, so it asks" "$out" '^ASK    gate\.test\.focus — one command per step, and python and node each have one'
rm -rf "$d"

d=$(repo README.md 'nothing to build')
out=$(detect "$d")
has "no manifest: says so and asks for every step instead of guessing" "$out" "STACK: none detected"
matches "no manifest: test is an ASK" "$out" '^ASK    gate\.test — no manifest this script knows'
rm -rf "$d"

d=$(repo pyproject.toml '[project]
dependencies = ["pytest", "pytest-cov"]' vault/project.md '# Shop
## Gate
- gate.test: python3 -m pytest -q
- gate.lint: none')
out=$(detect "$d")
has "lines a human set are kept, including a declined step" "$out" \
  "SET    gate.test (kept as is)" \
  "SET    gate.lint (kept as is)" \
  "READY  - gate.test.budget: 300"
matches "a set gate.test that writes no coverage turns crap into a question with the exact switch" "$out" '^ASK    gate\.crap — it reads a coverage report the current gate\.test doesn.t write; switch gate\.test to: COVERAGE_FILE=\.gate/\.coverage python3? -m pytest -q --cov=\. --cov-report=lcov:\.gate/coverage\.lcov'
rm -rf "$d"

d=$(repo pom.xml '<project></project>')
status=0; out=$(PYTHONIOENCODING=cp1252 "$PY" "$DETECT" "$d" 2>&1 | tr -d '\r') || status=$?
if [ "$status" -eq 0 ] && printf '%s\n' "$out" | grep -qxF "N/A    gate.a11y — no UI framework in pom.xml" && printf '%s\n' "$out" | grep -q '⇒'; then
  ok "a cp1252 console (Windows) still gets every line, in UTF-8"
else
  bad "a cp1252 console (Windows) still gets every line, in UTF-8" "exit $status: $out"
fi
rm -rf "$d"

echo "== detect-gates.py --apply =="
d=$(repo pom.xml '<project></project>' .gitignore '.env' vault/project.md '# Shop

## Gate
- gate.lint: none

## Domain Language
| Term | Meaning |')
status=0; out=$(detect --apply "$d") || status=$?
gate_section=$(sed -n '/^## Gate/,/^## Domain/p' "$d/vault/project.md")
want_section='## Gate
- gate.lint: none
- gate.types: none
- gate.test: mvn -q -B test
- gate.test.focus: mvn -q -B test -Dtest={}
- gate.test.budget: 300
- gate.build: mvn -q -B -DskipTests package
- gate.a11y: none

## Domain Language'
if [ "$status" -eq 0 ] && [ "$gate_section" = "$want_section" ]; then
  ok "apply writes ready lines and 'none' for steps that don't apply, inside the Gate section, keeping the human's lines"
else
  bad "apply writes ready lines and 'none' for steps that don't apply, inside the Gate section, keeping the human's lines" "exit $status: $gate_section"
fi
if [ "$(cat "$d/.gitignore")" = "$(printf '.env\ntarget/\n.gate/')" ]; then
  ok "apply gitignores what the new commands write, and .gate/"
else
  bad "apply gitignores what the new commands write, and .gate/" "$(cat "$d/.gitignore")"
fi
if ! grep -q 'gate\.crap\|gate\.mutation' "$d/vault/project.md"; then
  ok "apply never writes a step that still needs a slice"
else
  bad "apply never writes a step that still needs a slice" "$(cat "$d/vault/project.md")"
fi
before=$(cat "$d/vault/project.md" "$d/.gitignore")
out=$(detect --apply "$d")
if [ "$before" = "$(cat "$d/vault/project.md" "$d/.gitignore")" ] && echo "$out" | grep -qx "WROTE vault/project.md: nothing new"; then
  ok "a second apply changes nothing"
else
  bad "a second apply changes nothing" "$out"
fi
rm -rf "$d"

d=$(repo go.mod 'module x')
status=0; out=$(detect --apply "$d") || status=$?
if [ "$status" -ne 0 ] && echo "$out" | grep -q "no vault/project.md"; then
  ok "apply refuses without vault/project.md"
else
  bad "apply refuses without vault/project.md" "exit $status: $out"
fi
rm -rf "$d"

d=$(repo go.mod 'module x' vault/project.md '# Shop')
detect --apply "$d" >/dev/null
if grep -qx '## Gate' "$d/vault/project.md" && grep -qx -- '- gate.test: go test ./...' "$d/vault/project.md"; then
  ok "apply adds a Gate section when project.md has none"
else
  bad "apply adds a Gate section when project.md has none" "$(cat "$d/vault/project.md")"
fi
rm -rf "$d"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
