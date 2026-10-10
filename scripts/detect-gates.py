#!/usr/bin/env python3
import glob
import json
import os
import re
import shutil
import subprocess
import sys

STEPS = ["lint", "types", "test", "test.focus", "test.budget", "build", "a11y", "crap", "crap.max", "mutation", "mutation.min"]
DEFAULTS = {"test.budget": "300", "crap.max": "30", "mutation.min": "80"}
PYTHON = "python" if not shutil.which("python3") and shutil.which("python") else "python3"
SCORER = PYTHON + " ~/.claude/scripts/crap-score.py"
ADAPTER = PYTHON + " ~/.claude/scripts/mutation-report.py"
GATE_LINE = re.compile(r"^[-*][ \t]*gate\.([a-z0-9.]+):[ \t]*(.*)$")


class Repo:
    def __init__(self, root):
        self.root = root

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def exists(self, *parts):
        return os.path.exists(self.path(*parts))

    def isdir(self, *parts):
        return os.path.isdir(self.path(*parts))

    def read(self, *parts):
        try:
            with open(self.path(*parts), encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except OSError:
            return ""

    def first(self, *names):
        for name in names:
            if self.exists(name):
                return name
        return None

    def matches(self, *patterns):
        found = []
        for pattern in patterns:
            found += sorted(glob.glob(self.path(pattern)))
        return [os.path.relpath(f, self.root).replace("\\", "/") for f in found]


class Plan:
    def __init__(self, name, evidence):
        self.name = name
        self.evidence = evidence
        self.steps = {}
        self.ignore = []
        self.coverage_marker = None
        self.test_with_coverage = None

    def ready(self, step, cmd, ignore=()):
        self.steps[step] = {"status": "READY", "cmd": cmd, "why": "", "ignore": list(ignore)}

    def slice(self, step, why, cmd=""):
        self.steps[step] = {"status": "SLICE", "cmd": cmd, "why": why, "ignore": []}

    def tool(self, step, binary, install, cmd, ignore=()):
        status = "READY" if shutil.which(binary) else "TOOL"
        why = "" if status == "READY" else "install " + binary + ": " + install
        self.steps[step] = {"status": status, "cmd": cmd, "why": why, "ignore": list(ignore)}

    def na(self, step, why):
        self.steps[step] = {"status": "N/A", "cmd": "none", "why": why, "ignore": []}


def declared(text, name):
    return re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(name.lower()) + r"(?![A-Za-z0-9_-])", text) is not None


def uses(text, name):
    return declared(text, name) or ("[tool.%s]" % name) in text or ("[tool.%s." % name) in text or ("[%s]" % name) in text


def python_plan(repo):
    manifests = repo.matches("pyproject.toml", "setup.cfg", "setup.py", "Pipfile", "requirements*.txt", "requirements/*.txt")
    if not manifests:
        return None
    text = "\n".join(repo.read(m) for m in manifests).lower()
    lock = repo.first("uv.lock", "poetry.lock", "pdm.lock")
    py = {"uv.lock": "uv run python", "poetry.lock": "poetry run python", "pdm.lock": "pdm run python"}.get(lock, PYTHON)
    plan = Plan("python", manifests + ([lock] if lock else []))
    src = "src" if repo.isdir("src") else next(
        (d for d in sorted(os.listdir(repo.root)) if repo.exists(d, "__init__.py") and d not in ("tests", "test", "docs")), ".")
    if uses(text, "ruff") or repo.first("ruff.toml", ".ruff.toml"):
        plan.ready("lint", py + " -m ruff check -q .")
    elif uses(text, "flake8") or repo.exists(".flake8"):
        plan.ready("lint", py + " -m flake8 .")
    else:
        plan.slice("lint", "no linter declared; add ruff to the dev dependencies", py + " -m ruff check -q .")
    if uses(text, "mypy") or repo.exists("mypy.ini"):
        plan.ready("types", py + " -m mypy " + src)
    elif uses(text, "pyright") or repo.exists("pyrightconfig.json"):
        plan.ready("types", py + " -m pyright")
    else:
        plan.slice("types", "no type checker declared; add mypy to the dev dependencies", py + " -m mypy " + src)
    pytest = uses(text, "pytest") or bool(repo.first("pytest.ini", "conftest.py", "tests/conftest.py"))
    unittest = not pytest and bool(repo.matches("test_*.py", "tests/test_*.py", "tests/*/test_*.py"))
    if pytest:
        runner = "pytest -q" + (" --timeout=10" if declared(text, "pytest-timeout") else "")
        plan.ready("test.focus", py + " -m pytest -q {}")
    elif unittest:
        runner = "unittest discover -q"
        plan.ready("test.focus", py + " -m unittest -q {}")
    else:
        plan.slice("test", "no test runner declared and no test_*.py files; add pytest and a first test", py + " -m pytest -q")
        runner = None
    if runner:
        plan.ready("test", py + " -m " + runner)
        if pytest and declared(text, "pytest-cov"):
            plan.test_with_coverage = "COVERAGE_FILE=.gate/.coverage %s -m %s --cov=%s --cov-report=lcov:.gate/coverage.lcov" % (py, runner, src)
        elif uses(text, "coverage"):
            plan.test_with_coverage = "COVERAGE_FILE=.gate/.coverage %s -m coverage run -m %s && COVERAGE_FILE=.gate/.coverage %s -m coverage lcov -q -o .gate/coverage.lcov" % (py, runner, py)
    plan.coverage_marker = ".gate/coverage.lcov"
    exclude = "" if src != "." else " -x 'test_*.py' -x '*_test.py'"
    crap = "%s .gate/coverage.lcov%s %s" % (SCORER, exclude, src)
    if plan.test_with_coverage:
        plan.ready("crap", crap)
    elif runner:
        plan.slice("crap", "no coverage tool declared; add coverage (or pytest-cov) to the dev dependencies", crap)
    if declared(text, "build"):
        plan.ready("build", py + " -m build", ["dist/"])
    else:
        plan.na("build", "no build frontend declared (the build package)")
    mutation = "rm -rf mutants && %s -m mutmut run >/dev/null 2>&1 && %s -m mutmut results --all true 2>/dev/null | %s -" % (py, py, ADAPTER)
    if "[tool.mutmut]" in text:
        plan.ready("mutation", mutation, ["mutants/"])
    elif declared(text, "mutmut"):
        plan.slice("mutation", 'mutmut is declared but unconfigured; add [tool.mutmut] source_paths = ["%s/"] to pyproject.toml and set pytest testpaths so it skips mutants/' % src.rstrip("/"), mutation)
    elif runner:
        plan.slice("mutation", 'add mutmut 3 to the dev dependencies, [tool.mutmut] source_paths = ["%s/"] to pyproject.toml, and pytest testpaths so it skips mutants/' % src.rstrip("/"), mutation)
    if any(declared(text, web) for web in ("django", "flask", "jinja2")):
        plan.slice("a11y", "server-rendered UI (django/flask/jinja2); add Playwright + axe tests that open each page and fail on a WCAG 2 AA violation")
    else:
        plan.na("a11y", "no UI framework in the Python manifests")
    return plan


UI_DEPS = ("react", "react-dom", "vue", "svelte", "@angular/core", "next", "nuxt", "solid-js", "preact", "lit", "@remix-run/react", "astro")


def node_plan(repo):
    if not repo.exists("package.json"):
        return None
    try:
        pkg = json.loads(repo.read("package.json") or "{}")
    except ValueError:
        plan = Plan("node", ["package.json"])
        for step in ("lint", "types", "test", "build", "a11y", "crap", "mutation"):
            plan.slice(step, "package.json doesn't parse as JSON; fix it, then re-run detect-gates.py")
        return plan
    deps = {}
    for key in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        deps.update(pkg.get(key) or {})
    scripts = pkg.get("scripts") or {}
    lock = repo.first("pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "package-lock.json")
    run, x = {"pnpm-lock.yaml": ("pnpm -s", "pnpm exec"), "yarn.lock": ("yarn -s", "yarn"),
              "bun.lockb": ("bun run", "bunx"), "bun.lock": ("bun run", "bunx")}.get(lock, ("npm run -s", "npx"))
    plan = Plan("node", ["package.json"] + ([lock] if lock else []))
    src = "src" if repo.isdir("src") else "."
    if "lint" in scripts and "--fix" not in scripts["lint"]:
        plan.ready("lint", run + " lint")
    elif "eslint" in deps:
        plan.ready("lint", x + " eslint .")
    elif "@biomejs/biome" in deps:
        plan.ready("lint", x + " biome check .")
    else:
        plan.slice("lint", "no linter declared; add eslint", x + " eslint .")
    typecheck = next((s for s in ("typecheck", "type-check", "types", "check-types", "tsc") if s in scripts), None)
    if typecheck:
        plan.ready("types", run + " " + typecheck)
    elif "typescript" in deps and repo.exists("tsconfig.json"):
        plan.ready("types", x + " tsc --noEmit")
    else:
        plan.na("types", "plain JavaScript (no typescript with a tsconfig.json)")
    config = "\n".join(repo.read(c) for c in repo.matches("vitest.config.*", "vite.config.*"))
    crap = "%s %%s -x '*.test.*' -x '*.spec.*' %s" % (SCORER, src)
    if "vitest" in deps:
        plan.ready("test", x + " vitest run")
        plan.ready("test.focus", x + " vitest run {}")
        provider = "@vitest/coverage-v8" in deps or "@vitest/coverage-istanbul" in deps
        lcov = "lcov" in config
        plan.coverage_marker = "--coverage"
        if provider and lcov:
            plan.test_with_coverage = x + " vitest run --coverage"
            plan.ready("crap", crap % "coverage/lcov.info", ["coverage/"])
        else:
            need = "" if provider else "add @vitest/coverage-v8 and "
            plan.slice("crap", need + 'set coverage: { provider: "v8", reporter: ["lcov"], include: ["%s/**"] } in vitest.config' % src, crap % "coverage/lcov.info")
    elif "jest" in deps:
        plan.ready("test", x + " jest")
        plan.ready("test.focus", x + " jest {}")
        plan.coverage_marker = "--coverage"
        plan.test_with_coverage = x + " jest --coverage --coverageReporters=lcov --coverageDirectory=.gate/coverage"
        plan.ready("crap", crap % ".gate/coverage/lcov.info")
    elif scripts.get("test") and "no test specified" not in scripts["test"]:
        plan.ready("test", "CI=true " + run + " test")
        plan.slice("crap", "the test script's runner isn't vitest or jest; have it write an lcov report", crap % "coverage/lcov.info")
    else:
        plan.slice("test", "no test runner declared; add vitest and a first test", x + " vitest run")
    if "build" in scripts:
        plan.ready("build", run + " build", [".next/"] if "next" in deps else ["dist/"])
    else:
        plan.na("build", "no build script in package.json")
    ui = [d for d in UI_DEPS if d in deps]
    a11y_dir = repo.first("tests/a11y", "e2e/a11y", "tests/e2e/a11y")
    a11y_script = next((s for s in ("test:a11y", "a11y") if s in scripts), None)
    if not ui:
        plan.na("a11y", "no UI framework in package.json")
    elif a11y_script:
        plan.ready("a11y", run + " " + a11y_script, ["test-results/", "playwright-report/"])
    elif "@axe-core/playwright" in deps and "@playwright/test" in deps and a11y_dir:
        plan.ready("a11y", "%s playwright test %s --reporter=line" % (x, a11y_dir), ["test-results/", "playwright-report/"])
    else:
        plan.slice("a11y", "UI (%s) without an accessibility check; add @playwright/test and @axe-core/playwright, and tests/a11y with one test per page asserting no wcag2a/wcag2aa violations" % ui[0],
                   x + " playwright test tests/a11y --reporter=line")
    mutation = "%s stryker run --reporters json && %s reports/mutation/mutation.json" % (x, ADAPTER)
    if "@stryker-mutator/core" in deps:
        plan.ready("mutation", mutation, ["reports/", ".stryker-tmp/"])
    elif "test" in plan.steps and plan.steps["test"]["status"] == "READY":
        runner = "vitest-runner" if "vitest" in deps else "jest-runner" if "jest" in deps else "<runner>"
        plan.slice("mutation", "add @stryker-mutator/core and @stryker-mutator/" + runner, mutation)
    return plan


def maven_plan(repo):
    if not repo.exists("pom.xml"):
        return None
    pom = repo.read("pom.xml")
    mvn = ("./mvnw" if repo.exists("mvnw") else "mvn") + " -q -B"
    plan = Plan("java-maven", ["pom.xml"])
    if "maven-checkstyle-plugin" in pom:
        plan.ready("lint", mvn + " checkstyle:check")
    elif "spotless-maven-plugin" in pom:
        plan.ready("lint", mvn + " spotless:check")
    else:
        plan.slice("lint", "no linter plugin in pom.xml; add maven-checkstyle-plugin", mvn + " checkstyle:check")
    plan.na("types", "javac type-checks during gate.test")
    plan.ready("test", mvn + " test", ["target/"])
    plan.ready("test.focus", mvn + " test -Dtest={}")
    plan.ready("build", mvn + " -DskipTests package", ["target/"])
    crap = "%s target/site/jacoco/jacoco.xml src/main/java" % SCORER
    if "jacoco-maven-plugin" in pom and "<goal>report</goal>" in pom:
        plan.ready("crap", crap)
    else:
        plan.slice("crap", "add jacoco-maven-plugin with prepare-agent and report bound to the test phase (tests/fixtures/crap/java/pom.xml)", crap)
    mutation = "%s test-compile org.pitest:pitest-maven:mutationCoverage -DoutputFormats=XML -DtimestampedReports=false && %s target/pit-reports/mutations.xml" % (mvn, ADAPTER)
    if "pitest-maven" in pom:
        plan.ready("mutation", mutation)
    else:
        plan.slice("mutation", "add org.pitest:pitest-maven to pom.xml (with pitest-junit5-plugin for JUnit 5)", mutation)
    if re.search(r"thymeleaf|vaadin|jsf|freemarker", pom):
        plan.slice("a11y", "server-rendered UI in pom.xml; add Playwright + axe tests that open each page and fail on a WCAG 2 AA violation")
    else:
        plan.na("a11y", "no UI framework in pom.xml")
    return plan


def gradle_plan(repo):
    build = repo.first("build.gradle.kts", "build.gradle")
    if not build:
        return None
    text = repo.read(build)
    gradle = ("./gradlew" if repo.exists("gradlew") else "gradle") + " -q"
    plan = Plan("java-gradle", [build])
    if "checkstyle" in text:
        plan.ready("lint", gradle + " checkstyleMain")
    elif "spotless" in text:
        plan.ready("lint", gradle + " spotlessCheck")
    else:
        plan.slice("lint", "no linter plugin in %s; apply checkstyle" % build, gradle + " checkstyleMain")
    plan.na("types", "the compiler type-checks during gate.test")
    plan.ready("test", gradle + " test", ["build/", ".gradle/"])
    plan.ready("test.focus", gradle + " test --tests {}")
    plan.ready("build", gradle + " assemble", ["build/", ".gradle/"])
    plan.coverage_marker = "jacocoTestReport"
    crap = "%s build/reports/jacoco/test/jacocoTestReport.xml src/main/java" % SCORER
    if "jacoco" in text and re.search(r"xml\.(required|enabled)", text):
        plan.test_with_coverage = gradle + " test jacocoTestReport"
        plan.ready("crap", crap)
    else:
        plan.slice("crap", "apply jacoco with jacocoTestReport { reports { xml.required = true } } in " + build, crap)
    mutation = "%s pitest && %s build/reports/pitest/mutations.xml" % (gradle, ADAPTER)
    if "pitest" in text and "XML" in text and "timestampedReports" in text:
        plan.ready("mutation", mutation)
    else:
        plan.slice("mutation", "apply info.solidsoft.pitest with outputFormats = ['XML'] and timestampedReports = false in " + build, mutation)
    plan.na("a11y", "no UI framework in " + build)
    return plan


def coverage_tool(plan, covered):
    if plan.steps["crap"]["status"] == "READY":
        plan.test_with_coverage = covered
    else:
        plan.steps["crap"]["why"] += "; gate.test then becomes: " + covered


def go_plan(repo):
    if not repo.exists("go.mod"):
        return None
    plan = Plan("go", ["go.mod"])
    if repo.first(".golangci.yml", ".golangci.yaml", ".golangci.toml", ".golangci.json"):
        plan.ready("lint", "golangci-lint run")
    else:
        plan.ready("lint", "go vet ./...")
    plan.na("types", "go build type-checks")
    plan.ready("test", "go test ./...")
    plan.ready("test.focus", "go test {}")
    plan.ready("build", "go build ./...")
    plan.coverage_marker = "cover.out"
    covered = "go test -coverprofile=.gate/cover.out ./... && gocover-cobertura < .gate/cover.out > .gate/coverage.xml"
    plan.tool("crap", "gocover-cobertura", "go install github.com/boumenot/gocover-cobertura@latest",
              "%s .gate/coverage.xml ." % SCORER)
    coverage_tool(plan, covered)
    plan.tool("mutation", "gremlins", "go install github.com/go-gremlins/gremlins/cmd/gremlins@latest",
              'gremlins unleash --diff "$GATE_BASE" --output .gate/gremlins.json && %s .gate/gremlins.json' % ADAPTER)
    plan.na("a11y", "no UI framework in go.mod")
    return plan


def rust_plan(repo):
    if not repo.exists("Cargo.toml"):
        return None
    plan = Plan("rust", ["Cargo.toml"])
    plan.ready("lint", "cargo clippy -q --all-targets -- -D warnings", ["target/"])
    plan.na("types", "rustc type-checks during gate.test")
    plan.ready("test", "cargo test -q", ["target/"])
    plan.ready("test.focus", "cargo test -q {}")
    plan.ready("build", "cargo build -q", ["target/"])
    plan.coverage_marker = "llvm-cov"
    plan.tool("crap", "cargo-llvm-cov", "cargo install cargo-llvm-cov", "%s .gate/lcov.info src" % SCORER)
    coverage_tool(plan, "cargo llvm-cov -q --lcov --output-path .gate/lcov.info")
    plan.tool("mutation", "cargo-mutants", "cargo install cargo-mutants",
              'git diff "$GATE_BASE...HEAD" > .gate/diff.patch; cargo mutants --in-diff .gate/diff.patch; case $? in 0|2|3) %s mutants.out/outcomes.json ;; *) exit 1 ;; esac' % ADAPTER,
              ["mutants.out*/"])
    plan.na("a11y", "no UI framework in Cargo.toml")
    return plan


def existing_lines(project_text):
    found = {}
    for line in project_text.splitlines():
        match = GATE_LINE.match(line.rstrip("\r"))
        if match and match.group(1) not in found:
            found[match.group(1)] = match.group(2).strip().strip("`")
    return found


def merge(plans):
    merged = {}
    for step in ("lint", "types", "test", "build"):
        ready = [p.steps[step] for p in plans if p.steps.get(step, {}).get("status") == "READY"]
        if len(ready) > 1:
            merged[step] = {"status": "READY", "cmd": " && ".join(r["cmd"] for r in ready), "why": "",
                            "ignore": sum((r["ignore"] for r in ready), [])}
    for step in STEPS:
        if step in merged:
            continue
        candidates = [(p, p.steps[step]) for p in plans if step in p.steps]
        ready = [c for c in candidates if c[1]["status"] == "READY"]
        if len(ready) > 1 and step in ("test.focus", "crap", "mutation", "a11y"):
            merged[step] = {"status": "ASK", "cmd": ready[0][1]["cmd"], "ignore": ready[0][1]["ignore"],
                            "why": "one command per step, and %s each have one; pick the stack this step should follow" % " and ".join(p.name for p, _ in ready)}
            continue
        order = {"READY": 0, "ASK": 1, "SLICE": 2, "TOOL": 3, "N/A": 4}
        candidates.sort(key=lambda c: order[c[1]["status"]])
        if candidates:
            merged[step] = dict(candidates[0][1])
    return merged


def propose(repo, project_text):
    plans = [p for p in (python_plan(repo), node_plan(repo), maven_plan(repo), gradle_plan(repo), go_plan(repo), rust_plan(repo)) if p]
    have = existing_lines(project_text)
    steps = merge(plans) if plans else {}
    crap_owner = next((p for p in plans if p.steps.get("crap", {}).get("status") == "READY" and p.test_with_coverage), None)
    if crap_owner and steps.get("crap", {}).get("status") != "READY":
        crap_owner = None
    if crap_owner and steps.get("test", {}).get("status") == "READY" and "test" not in have:
        plain = crap_owner.steps["test"]["cmd"]
        steps["test"] = dict(steps["test"], cmd=steps["test"]["cmd"].replace(plain, crap_owner.test_with_coverage, 1))
    if crap_owner and "test" in have:
        marker = crap_owner.coverage_marker
        if marker and marker not in have["test"]:
            steps["crap"] = dict(steps["crap"], status="ASK",
                                 why="it reads a coverage report the current gate.test doesn't write; switch gate.test to: " + crap_owner.test_with_coverage)
    if not plans:
        for step in ("lint", "types", "test", "build", "a11y", "crap", "mutation"):
            steps[step] = {"status": "ASK", "cmd": "", "why": "no manifest this script knows (pyproject.toml, package.json, pom.xml, build.gradle, go.mod, Cargo.toml)", "ignore": []}
    for step, default in DEFAULTS.items():
        parent = step.split(".")[0]
        if steps.get(parent, {}).get("status") == "READY" or (parent in have and have[parent] != "none"):
            steps[step] = {"status": "READY", "cmd": default, "why": "", "ignore": []}
    for step in STEPS:
        if step in have:
            steps[step] = {"status": "SET", "cmd": have[step], "why": "", "ignore": []}
    return plans, steps


def report(plans, steps):
    lines = []
    if plans:
        lines.append("STACK: " + " + ".join("%s (%s)" % (p.name, ", ".join(p.evidence)) for p in plans))
    else:
        lines.append("STACK: none detected")
    for step in STEPS:
        entry = steps.get(step)
        if not entry:
            continue
        status = entry["status"]
        if status == "SET":
            lines.append("SET    gate.%s (kept as is)" % step)
        elif status == "READY":
            lines.append("READY  - gate.%s: %s" % (step, entry["cmd"]))
        elif status == "N/A":
            lines.append("N/A    gate.%s — %s" % (step, entry["why"]))
        else:
            then = " ⇒ - gate.%s: %s" % (step, entry["cmd"]) if entry["cmd"] else ""
            lines.append("%-6s gate.%s — %s%s" % (status, step, entry["why"], then))
    ignore = to_ignore(steps)
    if ignore:
        lines.append("IGNORE " + " ".join(ignore))
    return lines


def to_ignore(steps):
    seen = []
    for step in STEPS:
        entry = steps.get(step)
        if entry and entry["status"] == "READY":
            for pattern in entry["ignore"]:
                if pattern not in seen:
                    seen.append(pattern)
    return seen


def apply(repo, project_path, project_text, steps):
    have = existing_lines(project_text)
    new = []
    for step in STEPS:
        entry = steps.get(step)
        if not entry or step in have:
            continue
        if entry["status"] == "READY":
            new.append("- gate.%s: %s" % (step, entry["cmd"]))
        elif entry["status"] == "N/A":
            new.append("- gate.%s: none" % step)
    if new:
        lines = project_text.splitlines()
        heading = next((i for i, line in enumerate(lines) if re.match(r"^#+[ \t]*Gate\b", line.rstrip("\r"))), None)
        if heading is None:
            lines += ([""] if lines and lines[-1].strip() else []) + ["## Gate"] + new
        else:
            end = heading + 1
            while end < len(lines) and not re.match(r"^#+[ \t]", lines[end]):
                end += 1
            while end > heading + 1 and not lines[end - 1].strip():
                end -= 1
            lines[end:end] = new
        with open(project_path, "w", encoding="utf-8", newline="") as handle:
            handle.write("\n".join(lines) + "\n")
    gitignore = repo.path(".gitignore")
    current = [line.strip().rstrip("\r") for line in repo.read(".gitignore").splitlines()]
    added = [p for p in to_ignore(steps) + [".gate/"] if p not in current and "/" + p not in current]
    if added:
        text = repo.read(".gitignore")
        with open(gitignore, "a", encoding="utf-8", newline="") as handle:
            handle.write(("" if not text or text.endswith("\n") else "\n") + "\n".join(added) + "\n")
    return new, added


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    args = sys.argv[1:]
    write = "--apply" in args
    rest = [a for a in args if a != "--apply"]
    if len(rest) > 1 or any(a.startswith("-") for a in rest):
        sys.exit("usage: detect-gates.py [--apply] [repo root]")
    root = rest[0] if rest else None
    if root is None:
        try:
            root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            root = os.getcwd()
    repo = Repo(root)
    project_path = repo.path("vault", "project.md")
    project_text = repo.read("vault", "project.md")
    if write and not os.path.exists(project_path):
        sys.exit("detect-gates.py: no vault/project.md — run /init-codebase first")
    plans, steps = propose(repo, project_text)
    for line in report(plans, steps):
        print(line)
    if write:
        new, added = apply(repo, project_path, project_text, steps)
        print("WROTE vault/project.md: " + (", ".join(n.split(":")[0][2:] for n in new) if new else "nothing new"))
        print("WROTE .gitignore: " + (" ".join(added) if added else "nothing new"))


if __name__ == "__main__":
    main()
