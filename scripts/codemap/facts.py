import json
import posixpath
import re

from codemap.imports import PY_STRING_BLOCK
from codemap.repo import is_doc, is_test

try:
    import tomllib
except ImportError:
    tomllib = None

LANGUAGES = {".py": "Python", ".ts": "TypeScript", ".tsx": "TypeScript", ".js": "JavaScript", ".jsx": "JavaScript", ".mjs": "JavaScript",
             ".cjs": "JavaScript", ".go": "Go", ".java": "Java", ".kt": "Kotlin", ".rs": "Rust", ".rb": "Ruby", ".php": "PHP", ".cs": "C#",
             ".c": "C", ".h": "C", ".cc": "C++", ".cpp": "C++", ".hpp": "C++", ".swift": "Swift", ".scala": "Scala", ".ex": "Elixir",
             ".exs": "Elixir", ".lua": "Lua", ".sh": "Shell", ".bash": "Shell", ".zsh": "Shell", ".ps1": "PowerShell", ".dart": "Dart",
             ".sql": "SQL", ".vue": "Vue", ".svelte": "Svelte", ".hs": "Haskell", ".clj": "Clojure", ".r": "R", ".jl": "Julia"}
MANIFESTS = {"package.json", "pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "go.mod", "Cargo.toml", "Gemfile", "composer.json",
             "pom.xml", "build.gradle", "build.gradle.kts", "mix.exs", "pubspec.yaml", "Package.swift", "build.sbt", "deno.json",
             "CMakeLists.txt", "stack.yaml", "Project.toml", "DESCRIPTION"}
MANIFEST_SUFFIXES = (".csproj", ".gemspec", ".cabal", ".nimble")
MONOREPO_TOOLS = {"pnpm-workspace.yaml", "lerna.json", "nx.json", "turbo.json", "rush.json"}
CI = {".gitlab-ci.yml": "GitLab CI", "Jenkinsfile": "Jenkins", ".circleci/config.yml": "CircleCI", ".travis.yml": "Travis CI",
      "azure-pipelines.yml": "Azure Pipelines", "bitbucket-pipelines.yml": "Bitbucket Pipelines", ".drone.yml": "Drone CI"}
SECURITY = {"SECURITY.md", ".github/dependabot.yml", ".github/dependabot.yaml", "renovate.json", ".snyk", ".gitleaks.toml",
            "CODEOWNERS", ".github/CODEOWNERS"}
LINT = {".eslintrc", ".eslintrc.json", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.yml", "eslint.config.js", "eslint.config.mjs",
        ".prettierrc", ".prettierrc.json", "prettier.config.js", ".editorconfig", "tsconfig.json", ".golangci.yml", ".golangci.yaml",
        ".flake8", ".pylintrc", "mypy.ini", "ruff.toml", ".ruff.toml", ".rubocop.yml", "phpstan.neon", "biome.json", ".shellcheckrc",
        ".markdownlint.json", ".stylelintrc", "rustfmt.toml", "clippy.toml"}
ENV_TEMPLATES = {".env.example", ".env.template", ".env.sample", ".env.defaults", ".env.local.example"}
INTENT = re.compile(r"(^|/)(README|PRD|TRD|SPEC|DESIGN|ROADMAP|ARCHITECTURE|CONTRIBUTING)[^/]*\.(md|rst|txt|adoc)$|(^|/)(adr|decisions)/[^/]+\.md$", re.I)
ENV_READ = re.compile(r"""os\.environ(?:\.get)?\s*[\[(]\s*['"]([A-Z][A-Z0-9_]+)|os\.getenv\(\s*['"]([A-Z][A-Z0-9_]+)|process\.env\.([A-Z][A-Z0-9_]+)"""
                      r"""|process\.env\[\s*['"]([A-Z][A-Z0-9_]+)|import\.meta\.env\.([A-Z][A-Z0-9_]+)|os\.(?:Getenv|LookupEnv)\(\s*"([A-Z][A-Z0-9_]+)"""
                      r"""|ENV(?:\.fetch\()?\s*\[?\s*['"]([A-Z][A-Z0-9_]+)|System\.getenv\(\s*"([A-Z][A-Z0-9_]+)|env::var\(\s*"([A-Z][A-Z0-9_]+)"""
                      r"""|getenv\(\s*['"]([A-Z][A-Z0-9_]+)|\$_ENV\[\s*['"]([A-Z][A-Z0-9_]+)""")
MARKER = re.compile(r"(?:#|//|/\*|--|<!--|^\s*\*)[ \t]*(TODO|FIXME|HACK|XXX)(?![A-Za-z0-9_])", re.M)
FENCE = re.compile(r"^(```|~~~).*?^\1", re.M | re.S)
ROOT_ENTRY = re.compile(r"(install|setup|bootstrap|run|start)\.(sh|ps1|py|bat)|Makefile|GNUmakefile|justfile|Taskfile\.ya?ml")
DOC_PATH = re.compile(r"(?<![\w:/.-])(?:\./)?[\w.-]+(?:/[\w.-]+)+\.[A-Za-z0-9]{1,8}(?![\w/-])")
DEV_HINT = re.compile(r"dev|test|lint|doc|ci|type", re.I)


def item(fact, evidence=(), level="info"):
    return {"fact": fact, "evidence": sorted(set(evidence))[:8], "level": level}


def where(text, pos, path):
    return "%s:%d" % (path, text.count("\n", 0, pos) + 1)


def base(path):
    return posixpath.basename(path)


class Facts:
    def __init__(self, analysis, entities, days=90):
        self.a, self.entities, self.days = analysis, entities, days
        self.texts = analysis.texts

    def build(self):
        sections = [("Stack", self.stack()), ("Dependencies", self.dependencies()), ("Entry points", self.entry_points()),
                    ("Configuration", self.configuration()), ("Delivery", self.delivery()), ("Tooling", self.tooling()),
                    ("Intent vs reality", self.intent()), ("Concerns", self.concerns())]
        return [{"section": name, "items": items} for name, items in sections if items]

    def stack(self):
        lines = {}
        for path, text in self.texts.items():
            language = LANGUAGES.get(posixpath.splitext(path)[1].lower())
            if language and not is_test(path):
                lines[language] = lines.get(language, 0) + text.count("\n") + 1
        total = sum(lines.values()) or 1
        top = [(k, v) for k, v in sorted(lines.items(), key=lambda kv: -kv[1])[:6] if round(100 * v / total)]
        found = [item("Languages by production lines: " + ", ".join("%s %d%%" % (k, round(100 * v / total)) for k, v in top))] if top else []
        manifests = self.manifests()
        if manifests:
            found.append(item("Dependency manifests: %d" % len(manifests), manifests))
        else:
            found.append(item("[TODO] No dependency manifest found — the stack above comes from file extensions only", level="todo"))
        found += self.monorepo(manifests)
        return found

    def manifests(self):
        return sorted(p for p in self.a.tracked if (base(p) in MANIFESTS or base(p).endswith(MANIFEST_SUFFIXES)) and not is_test(p))

    def monorepo(self, manifests):
        signals = sorted(p for p in self.a.tracked if base(p) in MONOREPO_TOOLS)
        signals += [p for p in manifests if base(p) == "package.json" and '"workspaces"' in self.texts.get(p, "")]
        by_kind = {}
        for path in manifests:
            by_kind.setdefault(base(path), set()).add(posixpath.dirname(path))
        nested = [k for k, dirs in by_kind.items() if len(dirs) > 1]
        if nested:
            signals += [p for p in manifests if base(p) in nested]
        if not signals:
            return []
        return [item("Monorepo signals: map and document each package separately", signals)]

    def dependencies(self):
        found = []
        for path in self.manifests() + sorted(p for p in self.texts if re.fullmatch(r"requirements[^/]*\.txt", base(p))):
            parsed = self.parse_manifest(path)
            if parsed is None:
                continue
            for kind, names in sorted(parsed.items()):
                names = sorted(set(names))
                if names:
                    found.append(item("%s %s (%d): %s" % (path, kind, len(names), ", ".join(sorted(names)[:12]) + (" …" if len(names) > 12 else "")), [path]))
        return found

    def parse_manifest(self, path):
        text = self.texts.get(path)
        if text is None:
            return None
        name = base(path)
        parsers = {"package.json": self.npm, "composer.json": self.composer, "go.mod": self.gomod, "Gemfile": self.gemfile,
                   "pyproject.toml": self.pyproject, "Cargo.toml": self.cargo}
        if name in parsers:
            return parsers[name](text)
        if name.startswith("requirements"):
            return {("dev" if DEV_HINT.search(name) else "runtime"): requirement_names(text)}
        return None

    def npm(self, text):
        data = load_json(text)
        return {"runtime": list(data.get("dependencies", {})), "dev": list(data.get("devDependencies", {})),
                "peer": list(data.get("peerDependencies", {}))}

    def composer(self, text):
        data = load_json(text)
        keep = lambda names: [n for n in names if n != "php" and not n.startswith("ext-")]
        return {"runtime": keep(data.get("require", {})), "dev": keep(data.get("require-dev", {}))}

    def gomod(self, text):
        direct, indirect = [], []
        for m in re.finditer(r"^\s*(?:require\s+)?([\w.-]+\.[\w.-]+/[\w./-]+)\s+v\S+(.*)$", text, re.M):
            (indirect if "indirect" in m.group(2) else direct).append(m.group(1))
        return {"runtime": direct, "indirect": indirect}

    def gemfile(self, text):
        runtime, dev, depth = [], [], 0
        for line in text.splitlines():
            if re.match(r"\s*group\b.*\bdo\b", line):
                depth += 1
            elif re.match(r"\s*end\b", line) and depth:
                depth -= 1
            m = re.match(r"""\s*gem\s+['"]([\w.-]+)""", line)
            if m:
                (dev if depth else runtime).append(m.group(1))
        return {"runtime": runtime, "dev or test": dev}

    def pyproject(self, text):
        data = load_toml(text)
        if data is None:
            return {"[not parsed: needs Python 3.11+]": []}
        project, poetry = data.get("project", {}), data.get("tool", {}).get("poetry", {})
        runtime = requirement_names("\n".join(project.get("dependencies", [])))
        runtime += [n for n in poetry.get("dependencies", {}) if n != "python"]
        optional = [n for group in project.get("optional-dependencies", {}).values() for n in requirement_names("\n".join(group))]
        dev = [n for group in data.get("dependency-groups", {}).values() for n in requirement_names("\n".join(g for g in group if isinstance(g, str)))]
        dev += list(poetry.get("dev-dependencies", {}))
        dev += [n for group in poetry.get("group", {}).values() for n in group.get("dependencies", {})]
        return {"runtime": runtime, "optional": optional, "dev": dev}

    def cargo(self, text):
        data = load_toml(text)
        if data is None:
            return {"[not parsed: needs Python 3.11+]": []}
        return {"runtime": list(data.get("dependencies", {})), "dev": list(data.get("dev-dependencies", {})),
                "build": list(data.get("build-dependencies", {}))}

    def entry_points(self):
        found = [f for path in self.manifests() for f in self.declared_entries(path)]
        conventional = [p for p, t in self.texts.items() if not is_test(p) and is_conventional_entry(p, t)]
        if conventional:
            found.append(item("Conventional entry files: %d" % len(conventional), conventional))
        dockerfiles = [p for p, t in self.texts.items() if base(p).startswith("Dockerfile") and re.search(r"^\s*(CMD|ENTRYPOINT)\b", t, re.M)]
        if dockerfiles:
            found.append(item("Container start commands (CMD/ENTRYPOINT)", dockerfiles))
        return found or [item("[TODO] No declared or conventional entry point — check how the project is started (scripts, hooks, CI)", level="todo")]

    def declared_entries(self, path):
        text = self.texts.get(path, "")
        if base(path) == "pyproject.toml" and "[project.scripts]" in text:
            return [item("%s declares console scripts ([project.scripts])" % path, [path])]
        if base(path) != "package.json":
            return []
        data = load_json(text)
        declared = [k for k in ("main", "module", "bin") if k in data] + ["scripts.%s" % s for s in ("start", "dev", "serve") if s in data.get("scripts", {})]
        return [item("%s declares %s" % (path, ", ".join(declared)), [path])] if declared else []

    def configuration(self):
        templates = {p: set(re.findall(r"^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=", t, re.M)) for p, t in self.texts.items() if base(p) in ENV_TEMPLATES}
        reads = {}
        for path, text in self.texts.items():
            if is_doc(path) or is_test(path):
                continue
            code = PY_STRING_BLOCK.sub(lambda m: "\n" * m.group(0).count("\n"), text) if path.endswith(".py") else text
            for m in ENV_READ.finditer(code):
                reads.setdefault(next(g for g in m.groups() if g), where(code, m.start(), path))
        found = []
        documented = set().union(*templates.values()) if templates else set()
        if templates:
            found.append(item("Env templates list %d variables" % len(documented), templates))
        if reads:
            found.append(item("Code reads %d environment variables: %s" % (len(reads), ", ".join(sorted(reads)[:15])), reads.values()))
        missing = sorted(set(reads) - documented)
        if templates and missing:
            found.append(item("[ASK USER] Read in code but missing from the env template: %s — required, optional or dead?" % ", ".join(missing[:10]),
                              [reads[n] for n in missing], "ask"))
        return found

    def delivery(self):
        workflows = sorted(p for p in self.a.tracked if re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", p))
        found = [item("CI: GitHub Actions (%d workflow files)" % len(workflows), workflows)] if workflows else []
        found += [item("CI: " + name, [p]) for p, name in sorted(CI.items()) if p in self.a.tracked]
        containers = sorted(p for p in self.a.tracked if is_container_config(p))
        if containers:
            found.append(item("Containers and orchestration", containers))
        security = sorted(p for p in self.a.tracked if p in SECURITY or base(p) in ("SECURITY.md", "CODEOWNERS"))
        if security:
            found.append(item("Security and ownership config", security))
        if not any(f["fact"].startswith("CI:") for f in found):
            found.append(item("[TODO] No CI configuration found — confirm how changes are checked before merge", level="todo"))
        return found

    def tooling(self):
        configs = sorted(p for p in self.a.tracked if base(p) in LINT)
        return [item("Lint, format and type configs", configs)] if configs else []

    def intent(self):
        docs = sorted(p for p in self.a.tracked if INTENT.search(p))
        found = [item("Intent documents to read before the code (README, specs, ADRs)", docs)] if docs else \
            [item("[TODO] No README, spec or ADR — intent can only be inferred from code", level="todo")]
        stale = self.stale_doc_paths()
        if stale:
            found.append(item("[ASK USER] Docs name %d paths that don't exist — moved, renamed, or never built?" % len(stale), stale, "ask"))
        return found

    def stale_doc_paths(self):
        tops = {p.split("/", 1)[0] for p in self.a.tracked if "/" in p}
        stale = []
        for path, text in self.texts.items():
            if not is_doc(path):
                continue
            prose = FENCE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
            for m in DOC_PATH.finditer(prose):
                token = m.group(0)
                first = posixpath.normpath(token).split("/", 1)[0]
                beside = posixpath.normpath(posixpath.join(posixpath.dirname(path), token))
                if first in tops and token not in self.a.tracked and beside not in self.a.tracked and not self.anywhere(token):
                    stale.append("%s (%s)" % (where(prose, m.start(), path), token))
        return stale

    def anywhere(self, token):
        return bool(self.a.index.by_suffix.get(posixpath.normpath(token))) or any(p.endswith("/" + posixpath.normpath(token)) for p in self.a.tracked)

    def concerns(self):
        prod, tests = [], []
        for path, text in self.texts.items():
            record = self.entities.get("file:" + path)
            if is_doc(path) or not record or record["meta"]["complexity"] in ("n/a", "other"):
                continue
            hits = [where(text, m.start(), path) for m in MARKER.finditer(text)]
            (tests if is_test(path) else prod).extend(hits)
        found = []
        if prod or tests:
            found.append(item("TODO/FIXME/HACK/XXX markers: %d in production code, %d in tests (test ones are coverage gaps, not debt)" % (len(prod), len(tests)), prod[:6] + tests[:2]))
        churn = sorted(((e["metrics"]["changes"], e["path"]) for e in self.entities.values() if e["kind"] == "file" and e["metrics"].get("changes")), reverse=True)[:5]
        if churn:
            found.append(item("Most-changed files (%d days): " % self.days + ", ".join("%s ×%d" % (p, n) for n, p in churn), [p for _, p in churn]))
        return found


def is_conventional_entry(path, text):
    name = base(path)
    if name in ("__main__.py", "manage.py", "Program.cs", "Procfile") or path.endswith("src/main.rs"):
        return True
    return (name == "main.go" and "package main" in text) or ("/" not in path and bool(ROOT_ENTRY.fullmatch(path)))


def is_container_config(path):
    name = base(path)
    return name.startswith("Dockerfile") or bool(re.fullmatch(r"(docker-)?compose[^/]*\.ya?ml", name)) \
        or name in ("Chart.yaml", "kustomization.yaml", "Vagrantfile") or bool(re.search(r"(^|/)(k8s|kubernetes)/", path))


def load_json(text):
    try:
        data = json.loads(text)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def load_toml(text):
    if tomllib is None:
        return None
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        return {}


def requirement_names(text):
    names = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line and not line.startswith(("-", "git+", "http")):
            names.append(re.split(r"[\s<>=!~;\[@]", line, maxsplit=1)[0])
    return [n for n in names if n]
