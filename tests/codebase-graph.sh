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
imports_of() { field "$1" '" ".join(e["to"][5:] for e in F(sys.argv[3])["out"] if e["kind"] == "import")' "$2"; }
field() {
  "$PY" -c 'import json,sys
g = json.load(open(sys.argv[1]))
E = g["entities"]
F = lambda p: E["file:" + p]
D = lambda d: E["dir:" + d]
fn = lambda p, i=0: E[F(p)["children"][i]]
importers = lambda p: sorted(i for i, e in E.items() for o in e["out"] if o["to"] == "file:" + p and o["kind"] == "import")
kinds = lambda r: [f["kind"] for f in r["flags"]]
print(eval(sys.argv[2]))' "$1/.gate/graph.json" "$2" "${3:-}"
}
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
  "$(field "$repo" 'importers("tests/fixtures/app/shop.py")')" "[]"
expect "js/ts: relative imports resolve with extensions and index files; comments and packages don't" \
  "$(imports_of "$repo" web/app.ts)" "web/lib/index.ts web/lib/math.js"
expect "js/ts: packages are recorded as externals" "$(field "$repo" 'F("web/app.ts")["meta"]["externals"]')" "['react']"
expect "go: an import under the go.mod module path reaches the package's non-test files" "$(imports_of "$repo" go/cmd/main.go)" "go/internal/tax/tax.go"
expect "go: _test.go files in the package count as its tests" "$(field "$repo" 'F("go/internal/tax/tax.go")["meta"]["tested by"]')" "['go/internal/tax/tax_test.go']"
expect "java: a class import resolves by package path" "$(imports_of "$repo" java/src/main/java/shop/Cart.java)" "java/src/main/java/shop/core/Money.java"
expect "test files are marked as tests" "$(field "$repo" 'sorted(e["path"] for e in E.values() if e["kind"] == "file" and e["meta"]["test"])')" "['go/internal/tax/tax_test.go', 'tests/fixtures/app/shop.py', 'tests/test_rules.py']"
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
  "$(field "$repo" '[f["why"] for f in F("db/store.py")["flags"] if f["kind"] == "cycle"]')" "['import cycle: core/model.py → db/store.py → core/model.py']"
expect "five or more non-test dependents make a hub, with the reason" \
  "$(field "$repo" '[f["why"] for f in D("core")["flags"] if f["kind"] == "hub"]')" "['6 non-test modules depend on it — a change here ripples to all of them']"
expect "cycle makes a module high risk" "$(field "$repo" 'D("db")["risk"]')" "high"
expect "fan-in, fan-out and instability are recorded" "$(field "$repo" '[D("core")["metrics"][k] for k in ("fan-in", "fan-out", "instability")]')" "[6, 1, 0.14]"
expect "without a coverage report, code no test reaches through imports is flagged untested" \
  "$(field "$repo" '[k for k in kinds(F("core/model.py")) if k == "untested"]')" "['untested']"
mkdir -p "$repo/tests"
printf 'from db import store
def test_get():
    assert store.get()
' > "$repo/tests/test_store.py"
commit "$repo" test
build "$repo" >/dev/null
expect "a test that reaches code only through another module's import clears the flag" \
  "$(field "$repo" '[k for k in kinds(F("core/model.py")) if k == "untested"]')" "[]"

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
if echo "$out" | grep -q "^Files:               1 mapped" && echo "$out" | grep -q "^Regression risk:     Low"; then
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
if [ "$status" -eq 1 ] && echo "$out" | grep -q "src/domain/orders/new.py depends on src/infra/db.py — src/domain/\*\* must not depend on src/infra/\*.py (ADR-002)" \
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

echo "== codebase-graph.py — any repo: name references, shell estimates, what it saw =="
repo=$(new_repo)
mkdir -p "$repo/bin/lib" "$repo/a" "$repo/b" "$repo/tests" "$repo/.github/workflows"
cat > "$repo/bin/deploy.sh" <<'SH'
#!/bin/bash
source ./lib/log.sh
"$(dirname "$0")/lib/common.sh" --check
pick() {
  if [ "$1" = a ]; then
    echo a
  elif [ "$1" = b ] && [ -n "$2" ]; then
    echo b
  fi
  case "$1" in
    x) echo x ;;
    y) echo y ;;
  esac
}
for t in 1 2; do pick "$t"; done
SH
printf 'log() { echo "$@"; }\n' > "$repo/bin/lib/log.sh"
printf '#!/bin/sh\necho ok\n' > "$repo/bin/lib/common.sh"
printf 'echo a\n' > "$repo/a/util.sh"
printf 'echo b\n' > "$repo/b/util.sh"
printf 'run util.sh then b/util.sh\n' > "$repo/bin/lib/notes.sh"
printf 'jobs:\n  t:\n    steps:\n      - run: bin/deploy.sh\n' > "$repo/.github/workflows/ci.yml"
# shellcheck disable=SC2016
printf 'Run `deploy.sh` to ship.\n' > "$repo/README.md"
printf '#!/bin/bash\n./bin/deploy.sh --dry-run\n' > "$repo/tests/run-tests.sh"
commit "$repo" init
out=$(build "$repo")
edges() { field "$repo" 'sorted((e["to"][5:], e["kind"]) for e in F(sys.argv[3])["out"])' "$1"; }
expect "shell: source, dirname-relative and plain path mentions become reference edges" "$(edges bin/deploy.sh)" "[('bin/lib/common.sh', 'reference'), ('bin/lib/log.sh', 'reference')]"
expect "config: a CI file naming a script references it" "$(edges .github/workflows/ci.yml)" "[('bin/deploy.sh', 'reference')]"
expect "docs: a README naming a file only mentions it" "$(edges README.md)" "[('bin/deploy.sh', 'mention')]"
expect "an ambiguous bare name links nothing; a path that disambiguates links" "$(edges bin/lib/notes.sh)" "[('b/util.sh', 'reference')]"
expect "a test script that runs a script counts as its test" "$(field "$repo" 'F("bin/deploy.sh")["meta"]["tested by"]')" "['tests/run-tests.sh']"
expect "shell complexity is estimated per function, plus the script body" \
  "$(field "$repo" '[(E[c]["label"], E[c]["metrics"]["complexity"], E[c]["meta"]["complexity"]) for c in F("bin/deploy.sh")["children"]]')" "[('pick', 6, 'estimated'), ('(script body)', 2, 'estimated')]"
if echo "$out" | grep -q "^SEEN: 9 text files" && echo "$out" | grep -q "estimated" && ! echo "$out" | grep -q "WARNING"; then
  ok "the summary says how much it saw and how, with no warning when code is covered"
else
  bad "the summary says how much it saw and how, with no warning when code is covered" "$out"
fi
expect "the viewer gets the seen breakdown" "$(field "$repo" 'sorted(g["seen"]["complexity"])')" "['estimated', 'n/a']"
for i in 1 2 3 4 5 6; do for j in 1 2 3 4 5 6 7 8 9 10; do printf 'Write-Host %s\n' "$i$j"; done > "$repo/s$i.ps1"; done
commit "$repo" ps
out=$(build "$repo")
if echo "$out" | grep -q "WARNING: .* of code lines have no complexity measure (.ps1)"; then
  ok "a repo mostly in a language it can't measure says so instead of looking clean"
else
  bad "a repo mostly in a language it can't measure says so instead of looking clean" "$out"
fi
rm -rf "$repo"

echo "== codebase-graph.py — setup lens: agents, skills, hooks, workflow =="
setup_repo() {
  local d
  d=$(new_repo)
  mkdir -p "$d/agents" "$d/skills/clean-diff" "$d/skills/orphan" "$d/skills/grill" "$d/scripts"
  # shellcheck disable=SC2016
  printf -- '---\nname: builder\ndescription: Builds one slice.\ntools: Read, Edit, Bash\nmodel: sonnet\n---\nRun the clean-diff skill, then `~/.claude/scripts/gate.sh`.\n' > "$d/agents/builder.md"
  # shellcheck disable=SC2016
  printf -- '---\nname: reviewer\ndescription: Reviews cold.\ntools: Read\nmodel: sonnet\n---\nRead the `builder` report.\n' > "$d/agents/reviewer.md"
  printf -- '---\nname: clean-diff\ndescription: Strip slop.\n---\nBody.\n' > "$d/skills/clean-diff/SKILL.md"
  printf -- '---\nname: orphan\ndescription: Nobody calls me.\n---\nBody.\n' > "$d/skills/orphan/SKILL.md"
  printf -- '---\nname: grill\ndescription: Ask first.\n---\nBody.\n' > "$d/skills/grill/SKILL.md"
  printf '#!/bin/bash\necho gate\n' > "$d/scripts/gate.sh"
  printf '#!/bin/bash\necho guard\n' > "$d/scripts/guard.sh"
  printf '#!/bin/bash\necho tool\n' > "$d/scripts/tool.sh"
  printf 'Always start with the grill skill.\n' > "$d/CLAUDE.md"
  printf '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/scripts/guard.sh"}]}], "Stop": [{"hooks": [{"type": "command", "command": "npx something"}]}]}}\n' > "$d/settings.json"
  echo "$d"
}
repo=$(setup_repo)
commit "$repo" init
out=$(build "$repo"); status=$?
expect "without workflow.json the lens groups components by kind and reports no problems" \
  "$status:$(field "$repo" '[E[c]["label"] for c in E["setup:"]["children"]]')" "0:['Agents', 'Skills', 'Hooks (always on)', 'CLAUDE.md']"
expect "an agent links to the skills and scripts its file names, with file:line evidence" \
  "$(field "$repo" 'sorted((e["to"], e.get("where")) for e in E["agent:builder"]["out"])')" "[('file:scripts/gate.sh', 'agents/builder.md:7'), ('skill:clean-diff', 'agents/builder.md:7')]"
expect "agents named in backticks link agent to agent" "$(field "$repo" '[e["to"] for e in E["agent:reviewer"]["out"]]')" "['agent:builder']"
expect "frontmatter fills model and tools" "$(field "$repo" '[E["agent:builder"]["meta"]["model"], E["agent:builder"]["metrics"]["tools"]]')" "['sonnet', 3]"
expect "a hook resolves its command to the script it runs, and shows its matcher" \
  "$(field "$repo" '[E["hook:PreToolUse#0.0"]["label"], E["hook:PreToolUse#0.0"]["out"][0]["to"]]')" "['guard.sh (Bash)', 'file:scripts/guard.sh']"
expect "a hook command outside the repo is marked unresolved, not an error" "$(field "$repo" 'kinds(E["hook:Stop#0.0"])')" "['unresolved']"
cat > "$repo/workflow.json" <<'JSON'
{"name": "Loop", "stages": [
  {"id": "build", "uses": ["agent:builder", "skill:ghost"], "next": ["review", "nowhere"]},
  {"id": "review", "uses": ["agent:reviewer"], "next": [{"to": "build", "label": "REJECTED"}]}
]}
JSON
commit "$repo" workflow
out=$(build "$repo"); status=$?
if [ "$status" -eq 1 ] && echo "$out" | grep -q "ERROR stage build uses skill:ghost, which doesn't exist" \
   && echo "$out" | grep -q "ERROR stage build goes next to nowhere, which isn't a stage" \
   && echo "$out" | grep -q "ERROR skill:orphan is unreachable" && ! echo "$out" | grep -q "skill:grill is unreachable" \
   && ! echo "$out" | grep -q "skill:clean-diff is unreachable" && echo "$out" | grep -q "3 problem(s), 1 warning(s)"; then
  ok "workflow.json is verified: dangling uses, unknown stages and unreachable skills fail the build"
else
  bad "workflow.json is verified: dangling uses, unknown stages and unreachable skills fail the build" "$status: $out"
fi
expect "reachability follows the protocol and component links (grill via CLAUDE.md, clean-diff via builder)" \
  "$(field "$repo" '[kinds(E["skill:grill"]), kinds(E["skill:clean-diff"]), [k for k in kinds(F("scripts/tool.sh")) if k == "unreachable"]]')" "[[], [], ['unreachable']]"
expect "stages keep their declared order, flow and loop labels" \
  "$(field "$repo" '[E["setup:"]["children"][:2], [(e["to"], e.get("label")) for e in E["stage:review"]["out"] if e["kind"] == "next"]]')" "[['stage:build', 'stage:review'], [('stage:build', 'REJECTED')]]"
cat > "$repo/workflow.json" <<'JSON'
{"name": "Loop", "stages": [
  {"id": "build", "uses": ["agent:builder", "script:gate.sh"], "next": ["review"]},
  {"id": "review", "uses": ["agent:reviewer"], "next": [{"to": "build", "label": "REJECTED"}]}
], "on_demand": ["skill:orphan"]}
JSON
commit "$repo" fixed
out=$(build "$repo"); status=$?
if [ "$status" -eq 0 ] && echo "$out" | grep -q "^SETUP repo: Loop — 2 stages, 2 agents, 3 skills, 2 hooks · OK, 1 warning(s)"; then
  ok "a complete workflow builds clean; an unreached script is a warning, not an error"
else
  bad "a complete workflow builds clean; an unreached script is a warning, not an error" "$status: $out"
fi
rm -rf "$repo"
repo=$(new_repo)
mkdir -p "$repo/.claude/agents" "$repo/src"
printf -- '---\nname: helper\ndescription: Helps.\n---\nUse src/app.py.\n' > "$repo/.claude/agents/helper.md"
printf 'def main():\n    return 1\n' > "$repo/src/app.py"
commit "$repo" init
build "$repo" >/dev/null
expect "a project's own .claude/ setup gets its lens, linked into the code" \
  "$(field "$repo" '[l["id"] for l in g["lenses"]] + [e["to"] for e in E["agent:.claude/helper"]["out"]]')" "['code', 'setup:.claude/', 'file:src/app.py']"
rm -rf "$repo"

echo "== codebase-graph.py — facts: stack, dependencies, config, delivery, intent =="
repo=$(new_repo)
mkdir -p "$repo/src/app" "$repo/web" "$repo/svc" "$repo/tests/fixtures/old" "$repo/.github/workflows" "$repo/docs"
printf '{"name": "web", "main": "index.js", "scripts": {"start": "node index.js"}, "dependencies": {"express": "4"}, "devDependencies": {"vitest": "1"}, "workspaces": ["web"]}\n' > "$repo/package.json"
printf '[project]\nname = "app"\ndependencies = ["requests>=2", "click"]\n[project.optional-dependencies]\nyaml = ["pyyaml"]\n[dependency-groups]\ndev = ["pytest", "ruff"]\n[project.scripts]\napp = "app:main"\n' > "$repo/pyproject.toml"
printf 'pytest==8\n# a comment\nmypy\n' > "$repo/requirements-dev.txt"
printf 'module example.com/svc\nrequire (\n  github.com/pkg/errors v0.9.1\n  golang.org/x/sys v0.1.0 // indirect\n)\n' > "$repo/svc/go.mod"
printf "source 'https://rubygems.org'\ngem 'rails'\ngroup :development, :test do\n  gem 'rspec'\nend\n" > "$repo/Gemfile"
printf '{"dependencies": {"left-pad": "1"}}\n' > "$repo/tests/fixtures/old/package.json"
printf 'DATABASE_URL=\nPORT=8080\n' > "$repo/.env.example"
printf 'import os\n"""\nos.getenv("DOC_ONLY")\n"""\nDB = os.environ["DATABASE_URL"]\nKEY = os.getenv("API_KEY")\n# TODO: retry on timeout\nPATTERN = "TODO|FIXME"\n' > "$repo/src/app/config.py"
printf 'const port = process.env.PORT\n' > "$repo/web/server.js"
printf 'import os\nX = os.getenv("TEST_ONLY")\n# FIXME flaky\n' > "$repo/tests/test_config.py"
printf 'FROM python:3.12\nCMD ["python", "-m", "app"]\n' > "$repo/Dockerfile"
printf 'on: push\n' > "$repo/.github/workflows/ci.yml"
printf 'Report issues privately.\n' > "$repo/SECURITY.md"
printf 'root = true\n' > "$repo/.editorconfig"
# shellcheck disable=SC2016
printf '# App\nSee src/app/config.py and src/app/legacy.py.\n\n```\ncp src/app/example.py here\n```\n' > "$repo/README.md"
printf 'Run docs/setup.sh first.\n' > "$repo/docs/guide.md"
printf 'echo setup\n' > "$repo/docs/setup.sh"
commit "$repo" init
out=$(build "$repo")
fact() { field "$repo" '[i["fact"] for s in g["facts"] for i in s["items"] if s["section"] == sys.argv[3]]' "$1"; }
evidence() { field "$repo" '[i["evidence"] for s in g["facts"] for i in s["items"] if s["section"] == sys.argv[3]]' "$1"; }
expect "manifests are found at any depth, test fixtures left out" "$(evidence Stack | grep -o "tests/fixtures" || echo none)" "none"
deps=$(fact Dependencies)
if echo "$deps" | grep -q "package.json runtime (1): express" && echo "$deps" | grep -q "package.json dev (1): vitest" \
   && echo "$deps" | grep -q "pyproject.toml runtime (2): click, requests" && echo "$deps" | grep -q "pyproject.toml dev (2): pytest, ruff" \
   && echo "$deps" | grep -q "pyproject.toml optional (1): pyyaml" && echo "$deps" | grep -q "requirements-dev.txt dev (2): mypy, pytest" \
   && echo "$deps" | grep -q "svc/go.mod runtime (1): github.com/pkg/errors" && echo "$deps" | grep -q "svc/go.mod indirect (1): golang.org/x/sys" \
   && echo "$deps" | grep -q "Gemfile runtime (1): rails" && echo "$deps" | grep -q "Gemfile dev or test (1): rspec"; then
  ok "dependencies are split runtime / dev / optional / indirect per manifest"
else
  bad "dependencies are split runtime / dev / optional / indirect per manifest" "$deps"
fi
expect "monorepo signals come from workspaces" "$(fact Stack | grep -c 'Monorepo signals')" "1"
entries=$(fact "Entry points")
if echo "$entries" | grep -q "package.json declares main, scripts.start" && echo "$entries" | grep -q "console scripts" && echo "$entries" | grep -q "Container start commands"; then
  ok "entry points come from manifests, conventions and container CMDs"
else
  bad "entry points come from manifests, conventions and container CMDs" "$entries"
fi
config=$(fact Configuration)
if echo "$config" | grep -q "Code reads 3 environment variables: API_KEY, DATABASE_URL, PORT" \
   && echo "$config" | grep -q "\[ASK USER\] Read in code but missing from the env template: API_KEY" && ! echo "$config" | grep -q "DOC_ONLY\|TEST_ONLY"; then
  ok "env reads are found in code (not docstrings or tests) and checked against the template"
else
  bad "env reads are found in code (not docstrings or tests) and checked against the template" "$config"
fi
expect "env read evidence points at the real line" "$(evidence Configuration | grep -o 'src/app/config.py:6' | head -1)" "src/app/config.py:6"
delivery=$(fact Delivery)
if echo "$delivery" | grep -q "CI: GitHub Actions (1 workflow files)" && echo "$delivery" | grep -q "Containers and orchestration" && echo "$delivery" | grep -q "Security and ownership config"; then
  ok "CI, containers and security config are reported"
else
  bad "CI, containers and security config are reported" "$delivery"
fi
expect "intent: a doc path that exists nowhere is an [ASK USER]; fenced examples and doc-relative paths aren't" \
  "$(evidence 'Intent vs reality')" "[['README.md'], ['README.md:2 (src/app/legacy.py)']]"
expect "markers count comment TODOs only, production and tests apart" \
  "$(fact Concerns | grep -o '[0-9] in production code, [0-9] in tests')" "1 in production code, 1 in tests"
if echo "$out" | grep -q "^FACTS: Languages by production lines: .* · [0-9] sections · 0 \[TODO\] · 2 \[ASK USER\]"; then
  ok "the summary leads with the stack and counts what needs a human"
else
  bad "the summary leads with the stack and counts what needs a human" "$out"
fi
rm -rf "$repo"
repo=$(new_repo)
printf 'echo hi\n' > "$repo/run.sh"
commit "$repo" init
build "$repo" >/dev/null
expect "a bare repo says what it can't tell instead of guessing" \
  "$(field "$repo" '[i["fact"].split(" —")[0] for s in g["facts"] for i in s["items"] if i["level"] == "todo"]')" "['[TODO] No dependency manifest found', '[TODO] No CI configuration found', '[TODO] No README, spec or ADR']"
rm -rf "$repo"

echo "== codebase-graph.py — this repo's own workflow.json stays in sync =="
out=$(cd "$ROOT" && "$PY" "$GRAPH" build --out "$(mktemp -d)" 2>&1); status=$?
if [ "$status" -eq 0 ] && echo "$out" | grep -q "^SETUP repo: Autonomous engineering loop — .* · OK"; then
  ok "every agent, skill and hook in this setup is reachable from workflow.json, and every name in it exists"
else
  bad "every agent, skill and hook in this setup is reachable from workflow.json, and every name in it exists" "$status: $(echo "$out" | grep -E 'SETUP|ERROR')"
fi

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
  expect "complexity is measured per function" "$(field "$repo" 'fn("hot.py")["metrics"]["complexity"]')" "11"
  expect "churn counts commits touching the file" "$(field "$repo" 'F("hot.py")["metrics"]["changes"]')" "4"
  expect "complex + frequently changed is a hotspot, with numbers in the reason" \
    "$(field "$repo" '[f["why"].split(" — ")[0] for f in fn("hot.py")["flags"] if f["kind"] == "hotspot"]')" "['route() has complexity 11 and the file changed 4 times in 90 days']"
  expect "coverage from an lcov report is attached (reusing crap-score.py's loaders)" "$(field "$repo" 'F("hot.py")["metrics"]["coverage"]')" "0.5"
  rm -rf "$repo"
else
  echo "  SKIP  complexity, churn and coverage (pip install lizard)"
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
