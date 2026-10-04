#!/usr/bin/env python3
import importlib.util
import json
import os
import posixpath
import re
import subprocess
import sys

SKIP_DIRS = {"node_modules", "target", "build", "dist", "coverage", ".venv", "venv", ".git", ".gate", "vault", ".worktrees", "vendor", "__pycache__"}
SOURCE_EXT = {".py", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".go", ".java", ".kt", ".rb", ".php", ".cs", ".c", ".h", ".cc", ".cpp", ".hpp", ".rs", ".swift", ".scala", ".lua"}
JS_EXT = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]
COMPLEX_CCN = 15
HOTSPOT_CCN = 10
HOTSPOT_CHURN = 3
HUB_FAN_IN = 5
LOW_COVERAGE = 0.5
PY_STRING_BLOCK = re.compile(r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'')
JS_COMMENT = re.compile(r"/\*[\s\S]*?\*/|^\s*//.*$", re.M)
TEST_FILE = re.compile(r"(^|/)(tests?|__tests__|spec)/|(^|/)test_[^/]*\.py$|_test\.(py|go)$|\.(test|spec)\.[jt]sx?$|Tests?\.(java|kt)$")


def usage():
    sys.stderr.write(
        "usage: codebase-graph.py build [--rev REV] [--days N] [--coverage FILE] [--rules FILE] [--out DIR]\n"
        "       codebase-graph.py impact [--rev REV] (--base REV | <file>...)\n"
        "       codebase-graph.py check --rules FILE --base REV [--rev REV]\n"
    )
    sys.exit(2)


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit("codebase-graph.py: git %s failed: %s" % (" ".join(args), result.stderr.strip()))
    return result.stdout


def is_source(path):
    parts = path.split("/")
    if any(p in SKIP_DIRS for p in parts[:-1]):
        return False
    return posixpath.splitext(path)[1] in SOURCE_EXT


def read_tree(rev):
    paths = [p for p in git("ls-tree", "-r", "--name-only", rev).splitlines() if is_source(p)]
    if not paths:
        return {}
    request = "".join("%s:%s\n" % (rev, p) for p in paths).encode()
    out = subprocess.run(["git", "cat-file", "--batch"], input=request, capture_output=True, check=True).stdout
    files, pos = {}, 0
    for path in paths:
        header_end = out.index(b"\n", pos)
        size = int(out[pos:header_end].split()[2])
        body = out[header_end + 1:header_end + 1 + size]
        pos = header_end + 1 + size + 1
        files[path] = body.decode("utf-8", errors="replace")
    return files


def module_of(path):
    return posixpath.dirname(path) or "."


def shared_dirs(a, b):
    count = 0
    for x, y in zip(a.split("/")[:-1], b.split("/")[:-1]):
        if x != y:
            break
        count += 1
    return count


def is_test(path):
    return bool(TEST_FILE.search(path))


class Resolver:
    def __init__(self, files):
        self.files = set(files)
        self.by_dir = {}
        self.by_suffix = {}
        for path in files:
            self.by_dir.setdefault(module_of(path), []).append(path)
            parts = path.split("/")
            for cut in range(len(parts)):
                self.by_suffix.setdefault("/".join(parts[cut:]), []).append(path)
        self.go_module = ""

    def suffix(self, *rels, near="", root_ok=lambda prefix: True):
        hits = [(-shared_dirs(near, p), len(p) - len(rel), p) for rel in rels for p in self.by_suffix.get(rel, ()) if root_ok(p[:len(p) - len(rel)])]
        return min(hits)[2] if hits else None

    def python_root(self, prefix):
        return prefix + "__init__.py" not in self.files

    def python(self, path, text):
        found, externals = set(), set()
        for line in text.splitlines():
            m = re.match(r"\s*from\s+(\.*)([\w.]*)\s+import\s+(.+)", line)
            if m:
                dots, name, names = m.groups()
                base = name.replace(".", "/")
                if dots:
                    anchor = module_of(path)
                    for _ in range(len(dots) - 1):
                        anchor = posixpath.dirname(anchor)
                    base = posixpath.normpath(posixpath.join(anchor, base)) if base else anchor
                subs = [n.strip().split(" as ")[0].strip("() ") for n in names.split(",")]
                hit = False
                for sub in subs:
                    target = self.py_target(base + "/" + sub, path, exact=bool(dots))
                    if target:
                        found.add(target)
                        hit = True
                target = self.py_target(base, path, exact=bool(dots))
                if target and not hit:
                    found.add(target)
                    hit = True
                if not hit and not dots and name:
                    externals.add(name.split(".")[0])
                continue
            m = re.match(r"\s*import\s+([\w.]+(?:\s+as\s+\w+)?(?:\s*,\s*[\w.]+(?:\s+as\s+\w+)?)*)\s*$", line)
            if m:
                for part in m.group(1).split(","):
                    name = part.strip().split()[0]
                    target = self.py_target(name.replace(".", "/"), path)
                    if target:
                        found.add(target)
                    else:
                        externals.add(name.split(".")[0])
        return found, externals

    def py_target(self, base, near, exact=False):
        base = base.strip("/")
        if not base:
            return None
        rels = (base + ".py", base + "/__init__.py")
        if exact:
            return next((rel for rel in rels if rel in self.files), None)
        return self.suffix(*rels, near=near, root_ok=self.python_root)

    def js(self, path, text):
        found, externals = set(), set()
        specs = re.findall(r"""(?:import|export)[^'"`;]*?from\s*['"]([^'"]+)['"]|import\s*['"]([^'"]+)['"]|(?:require|import)\s*\(\s*['"]([^'"]+)['"]\s*\)""", text)
        for groups in specs:
            spec = next(g for g in groups if g)
            if spec.startswith("."):
                base = posixpath.normpath(posixpath.join(module_of(path), spec))
                target = next((c for c in [base] + [base + e for e in JS_EXT] + [base + "/index" + e for e in JS_EXT] if c in self.files), None)
                if target:
                    found.add(target)
            else:
                externals.add("/".join(spec.split("/")[:2]) if spec.startswith("@") else spec.split("/")[0])
        return found, externals

    def go(self, path, text):
        found, externals = set(), set()
        specs = re.findall(r'^\s*import\s+(?:\w+\s+)?"([^"]+)"', text, re.M)
        for block in re.findall(r"^\s*import\s*\((.*?)\)", text, re.M | re.S):
            specs += re.findall(r'"([^"]+)"', block)
        for spec in specs:
            if self.go_module and (spec == self.go_module or spec.startswith(self.go_module + "/")):
                directory = spec[len(self.go_module):].strip("/") or "."
                found.update(p for p in self.by_dir.get(directory, []) if p.endswith(".go") and not p.endswith("_test.go"))
            else:
                externals.add(spec)
        return found, externals

    def jvm(self, path, text):
        found, externals = set(), set()
        for spec in re.findall(r"^\s*import\s+(?:static\s+)?([\w.]+(?:\.\*)?)\s*;?", text, re.M):
            if spec.endswith(".*"):
                directory = spec[:-2].replace(".", "/")
                hits = [d for d in self.by_dir if d == directory or d.endswith("/" + directory)]
                if hits:
                    found.update(self.by_dir[min(hits, key=len)])
                    continue
            else:
                parts = spec.split(".")
                target = None
                for cut in range(len(parts), 1, -1):
                    rel = "/".join(parts[:cut])
                    target = self.suffix(rel + ".java", rel + ".kt", near=path)
                    if target:
                        break
                if target:
                    found.add(target)
                    continue
            externals.add(".".join(spec.split(".")[:2]))
        return found, externals

    def imports(self, path, text):
        ext = posixpath.splitext(path)[1]
        if ext == ".py":
            found, externals = self.python(path, PY_STRING_BLOCK.sub("", text))
        elif ext in JS_EXT:
            found, externals = self.js(path, JS_COMMENT.sub("", text))
        elif ext == ".go":
            found, externals = self.go(path, text)
        elif ext in (".java", ".kt"):
            found, externals = self.jvm(path, text)
        else:
            return set(), set()
        found.discard(path)
        return found, externals


def go_module_name(rev):
    result = subprocess.run(["git", "show", "%s:go.mod" % rev], capture_output=True, text=True)
    m = re.search(r"^module\s+(\S+)", result.stdout, re.M) if result.returncode == 0 else None
    return m.group(1) if m else ""


def dependency_edges(rev):
    files = read_tree(rev)
    resolver = Resolver(files)
    resolver.go_module = go_module_name(rev)
    edges, externals = {}, {}
    for path, text in files.items():
        edges[path], externals[path] = resolver.imports(path, text)
    return files, edges, externals


def strongly_connected(nodes, edges):
    index, low, stack, on_stack, result, counter = {}, {}, [], set(), [], [0]
    for root in sorted(nodes):
        if root in index:
            continue
        work = [(root, iter(sorted(edges.get(root, ()))))]
        index[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, children = work[-1]
            advanced = False
            for child in children:
                if child not in index:
                    index[child] = low[child] = counter[0]
                    counter[0] += 1
                    stack.append(child)
                    on_stack.add(child)
                    work.append((child, iter(sorted(edges.get(child, ())))))
                    advanced = True
                    break
                if child in on_stack:
                    low[node] = min(low[node], index[child])
            if advanced:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index[node]:
                component = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                if len(component) > 1:
                    result.append(sorted(component))
    return result


def cycle_path(component, edges):
    members = set(component)
    start = component[0]
    previous, queue = {start: None}, [start]
    while queue:
        node = queue.pop(0)
        for child in sorted(edges.get(node, ())):
            if child == start:
                path = [node]
                while previous[path[-1]] is not None:
                    path.append(previous[path[-1]])
                return list(reversed(path)) + [start]
            if child in members and child not in previous:
                previous[child] = node
                queue.append(child)
    return component + [start]


def module_edges(edges):
    result = {}
    for source, targets in edges.items():
        for target in targets:
            a, b = module_of(source), module_of(target)
            if a != b:
                result.setdefault(a, set()).add(b)
    return result


def cycle_edge_set(medges):
    found = set()
    for component in strongly_connected(set(medges) | {t for ts in medges.values() for t in ts}, medges):
        members = set(component)
        for source in component:
            for target in medges.get(source, ()):
                if target in members:
                    found.add((source, target))
    return found


def glob_regex(pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + "$")


def load_rules(path):
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            rules = json.load(handle)
    except (OSError, ValueError) as error:
        sys.exit("codebase-graph.py: can't read rules %s: %s" % (path, error))
    for rule in rules.get("forbid", []):
        if not rule.get("from") or not rule.get("to"):
            sys.exit("codebase-graph.py: every forbid rule needs 'from' and 'to' globs: %s" % json.dumps(rule))
    return rules


def forbidden_edges(edges, rules):
    found = set()
    for rule in rules.get("forbid", []):
        source_re, target_re = glob_regex(rule["from"]), glob_regex(rule["to"])
        for source, targets in edges.items():
            if not source_re.match(source):
                continue
            for target in targets:
                if target_re.match(target) and not source_re.match(target):
                    found.add((source, target, rule["from"], rule["to"], rule.get("why", "")))
    return found


def churn_counts(rev, days):
    counts = {}
    for line in git("log", "--format=", "--name-only", "--since=%d days ago" % days, rev).splitlines():
        if line:
            counts[line] = counts.get(line, 0) + 1
    return counts


def lizard_functions(path, text):
    try:
        import lizard
    except ImportError:
        return None
    try:
        info = lizard.analyze_file.analyze_source_code(path, text)
    except Exception as error:
        sys.stderr.write("codebase-graph.py: lizard skipped %s: %s\n" % (path, error))
        return []
    return [{"name": f.name, "ccn": f.cyclomatic_complexity, "nloc": f.nloc, "start": f.start_line, "end": f.end_line} for f in info.function_list]


def coverage_loader(path):
    if not path:
        return None, None
    spec = importlib.util.spec_from_file_location("crap_score", os.path.join(os.path.dirname(os.path.abspath(__file__)), "crap-score.py"))
    crap = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(crap)
    data = crap.load_coverage(path)
    return data, lambda file: crap.coverage_for(file, data)


def ratio(lines, start=None, end=None):
    picked = [hit for n, hit in lines.items() if start is None or start <= n <= end]
    return round(sum(picked) / len(picked), 3) if picked else None


def build_graph(rev, days, coverage_file, rules_file):
    files, edges, externals = dependency_edges(rev)
    rules = load_rules(rules_file)
    churn = churn_counts(rev, days)
    coverage, coverage_for = coverage_loader(coverage_file)
    importers = {p: set() for p in files}
    for source, targets in edges.items():
        for target in targets:
            importers[target].add(source)
    test_reach = closure([p for p in files if is_test(p)], edges)
    medges = module_edges(edges)
    module_cycles = strongly_connected(set(module_of(p) for p in files), medges)
    file_cycles = strongly_connected(set(files), edges)
    violations = forbidden_edges(edges, rules)
    lizard_ok = True
    nodes = {}
    for path, text in sorted(files.items()):
        functions = lizard_functions(path, text)
        if functions is None:
            lizard_ok, functions = False, []
        lines = (coverage_for(path) or {}) if coverage is not None else None
        for fn in functions:
            fn["coverage"] = ratio(lines, fn["start"], fn["end"]) if lines else None
        tested_by = sorted(t for t in importers[path] if is_test(t))
        if path.endswith(".go") and not path.endswith("_test.go"):
            tested_by += sorted(p for p in files if p.endswith("_test.go") and module_of(p) == module_of(path))
        nodes[path] = {
            "path": path,
            "module": module_of(path),
            "test": is_test(path),
            "loc": text.count("\n") + (0 if text.endswith("\n") or not text else 1),
            "churn": churn.get(path, 0),
            "imports": sorted(edges[path]),
            "imported_by": sorted(importers[path]),
            "externals": sorted(externals[path]),
            "tested_by": tested_by,
            "coverage": ratio(lines) if lines else (0.0 if lines is not None else None),
            "functions": sorted(functions, key=lambda f: -f["ccn"]),
            "flags": [],
        }
    for component in file_cycles:
        loop = cycle_path(component, edges)
        for path in component:
            nodes[path]["flags"].append({"kind": "cycle", "why": "import cycle: " + " → ".join(loop)})
    for source, target, src_glob, dst_glob, why in sorted(violations):
        nodes[source]["flags"].append({"kind": "violation", "why": "imports %s, but %s must not depend on %s%s" % (target, src_glob, dst_glob, (" — " + why) if why else "")})
    for node in nodes.values():
        if node["test"]:
            continue
        for fn in node["functions"]:
            if fn["ccn"] >= HOTSPOT_CCN and node["churn"] >= HOTSPOT_CHURN:
                node["flags"].append({"kind": "hotspot", "why": "%s() has complexity %d and the file changed %d times in %d days — complex code that keeps changing is where regressions come from" % (fn["name"], fn["ccn"], node["churn"], days)})
            elif fn["ccn"] >= COMPLEX_CCN:
                node["flags"].append({"kind": "complex", "why": "%s() has complexity %d (≥ %d): many paths to understand and test" % (fn["name"], fn["ccn"], COMPLEX_CCN)})
        if node["functions"] or node["imported_by"]:
            if node["coverage"] is not None and node["coverage"] < LOW_COVERAGE:
                node["flags"].append({"kind": "untested", "why": "line coverage %d%% (< %d%%)" % (round(node["coverage"] * 100), LOW_COVERAGE * 100)})
            elif node["coverage"] is None and not node["tested_by"] and node["path"] not in test_reach and node["functions"]:
                node["flags"].append({"kind": "untested", "why": "no test file reaches it through imports (no coverage report given — a test may still reach it at runtime)"})
    modules = {}
    for node in nodes.values():
        mod = modules.setdefault(node["module"], {"name": node["module"], "files": [], "loc": 0, "churn": 0, "max_ccn": 0, "flags": []})
        mod["files"].append(node["path"])
        mod["loc"] += node["loc"]
        mod["churn"] += node["churn"]
        mod["max_ccn"] = max([mod["max_ccn"]] + [f["ccn"] for f in node["functions"]])
    dependents = {}
    for source, targets in medges.items():
        for target in targets:
            dependents.setdefault(target, set()).add(source)
    for name, mod in modules.items():
        out_mods, in_mods = sorted(medges.get(name, ())), sorted(dependents.get(name, ()))
        mod["depends_on"], mod["used_by"] = out_mods, in_mods
        mod["fan_out"], mod["fan_in"] = len(out_mods), len(in_mods)
        mod["instability"] = round(len(out_mods) / (len(out_mods) + len(in_mods)), 2) if out_mods or in_mods else None
        mod["used_from_outside"] = sorted(p for p in mod["files"] if any(module_of(i) != name for i in nodes[p]["imported_by"]))
        mod["externals"] = sorted({e for p in mod["files"] for e in nodes[p]["externals"]})
        mod["test_only"] = all(nodes[p]["test"] for p in mod["files"])
        production_users = [u for u in in_mods if not all(is_test(p) for p in modules[u]["files"])]
        if len(production_users) >= HUB_FAN_IN and not mod["test_only"]:
            mod["flags"].append({"kind": "hub", "why": "%d non-test modules depend on it — a change here ripples to all of them" % len(production_users)})
    for component in module_cycles:
        loop = cycle_path(component, medges)
        for name in component:
            modules[name]["flags"].append({"kind": "cycle", "why": "module cycle: " + " → ".join(loop) + " — none of these can change or be tested alone"})
    for mod in modules.values():
        kinds = {f["kind"] for f in mod["flags"]} | {f["kind"] for p in mod["files"] for f in nodes[p]["flags"]}
        severe = kinds & {"violation", "cycle"} or ("hub" in kinds and kinds & {"hotspot", "untested"})
        mod["risk"] = "high" if severe else ("medium" if kinds else "low")
        mod["flag_kinds"] = sorted(kinds)
    return {
        "rev": git("rev-parse", "--short", rev).strip(),
        "churn_days": days,
        "complexity_measured": lizard_ok,
        "coverage_given": coverage is not None,
        "rules": rules,
        "modules": modules,
        "files": nodes,
        "module_cycles": [cycle_path(c, medges) for c in module_cycles],
        "file_cycles": [cycle_path(c, edges) for c in file_cycles],
    }


def write_outputs(graph, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "graph.json"), "w", encoding="utf-8") as handle:
        json.dump(graph, handle, indent=1, sort_keys=True)
    template_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "graph-viewer.html")
    with open(template_path, encoding="utf-8") as handle:
        template = handle.read()
    payload = json.dumps(graph, sort_keys=True).replace("</", "<\\/")
    with open(os.path.join(out_dir, "graph.html"), "w", encoding="utf-8") as handle:
        handle.write(template.replace("__GRAPH_JSON__", payload))


def summarize(graph, out_dir):
    modules, files = graph["modules"], graph["files"]
    flagged = [m for m in modules.values() if m["risk"] != "low"]
    print("GRAPH @ %s: %d modules, %d files, %d module cycles, %d file cycles, %d modules flagged" % (
        graph["rev"], len(modules), len(files), len(graph["module_cycles"]), len(graph["file_cycles"]), len(flagged)))
    if not graph["complexity_measured"]:
        print("  complexity not measured — pip install lizard")
    order = {"high": 0, "medium": 1}
    for mod in sorted(flagged, key=lambda m: (order[m["risk"]], -m["fan_in"], m["name"]))[:12]:
        print("  %-6s %s (fan-in %d, fan-out %d): %s" % (mod["risk"], mod["name"], mod["fan_in"], mod["fan_out"], ", ".join(mod["flag_kinds"])))
    print("  view: %s · data: %s" % (os.path.join(out_dir, "graph.html"), os.path.join(out_dir, "graph.json")))


def closure(start, reverse):
    seen, frontier = set(), set(start)
    while frontier:
        nxt = set()
        for node in frontier:
            nxt |= reverse.get(node, set())
        frontier = nxt - seen - set(start)
        seen |= frontier
    return seen


def impact(rev, changed):
    files, edges, _ = dependency_edges(rev)
    reverse = {}
    for source, targets in edges.items():
        for target in targets:
            reverse.setdefault(target, set()).add(source)
    known = [p for p in changed if p in files]
    other = [p for p in changed if p not in files]
    direct = set().union(*[reverse.get(p, set()) for p in known]) - set(known) if known else set()
    everything = closure(known, reverse)
    indirect = everything - direct
    tests = sorted(p for p in everything | set(known) if is_test(p))
    mods = sorted({module_of(p) for p in changed})
    reached = sorted({module_of(p) for p in everything} - set(mods))
    api = sorted(p for p in known if any(module_of(i) != module_of(p) for i in reverse.get(p, ())))
    medges = module_edges(edges)
    cycles = [c for c in strongly_connected(set(module_of(p) for p in files), medges) if set(c) & set(mods)]
    production = len([p for p in everything if not is_test(p)])
    level = "High" if production >= 20 or cycles or len(reached) >= 5 else ("Medium" if production >= 5 or api else "Low")
    print("CHANGE IMPACT @ %s (import graph only — dynamic calls, string keys and other languages need grep)" % git("rev-parse", "--short", rev).strip())
    print("Files:               %d source + %d other" % (len(known), len(other)))
    print("Modules:             %d (%s)" % (len(mods), ", ".join(mods[:6]) + (" …" if len(mods) > 6 else "")))
    print("Used across modules: %d%s" % (len(api), (" (" + ", ".join(api[:4]) + (" …" if len(api) > 4 else "") + ")") if api else ""))
    print("Direct dependents:   %d%s" % (len(direct), (" (" + ", ".join(sorted(direct)[:4]) + (" …" if len(direct) > 4 else "") + ")") if direct else ""))
    print("Indirect dependents: %d" % len(indirect))
    print("Modules reached:     %d%s" % (len(reached), (" (" + ", ".join(reached[:6]) + (" …" if len(reached) > 6 else "") + ")") if reached else ""))
    print("Tests in reach:      %d%s" % (len(tests), (" (" + ", ".join(tests[:4]) + (" …" if len(tests) > 4 else "") + ")") if tests else ""))
    print("Dependency cycles:   %s" % ("; ".join(" ↔ ".join(c) for c in cycles) if cycles else "none touching the change"))
    print("Regression risk:     %s (estimate from reach, not a measurement)" % level)


def check(rev, base, rules_file):
    rules = load_rules(rules_file)
    _, head_edges, _ = dependency_edges(rev)
    _, base_edges, _ = dependency_edges(base)
    problems = []
    for source, target, src_glob, dst_glob, why in sorted(forbidden_edges(head_edges, rules) - forbidden_edges(base_edges, rules)):
        problems.append("%s imports %s — %s must not depend on %s%s" % (source, target, src_glob, dst_glob, (" (" + why + ")") if why else ""))
    if rules.get("no_new_cycles", True):
        base_medges = module_edges(base_edges)
        existed = {(s, t) for s, ts in base_medges.items() for t in ts}
        for source, target in sorted(cycle_edge_set(module_edges(head_edges)) - cycle_edge_set(base_medges) - existed):
            culprits = sorted(p for p in head_edges if module_of(p) == source and any(module_of(t) == target for t in head_edges[p]))
            problems.append("new module cycle edge %s → %s (via %s)" % (source, target, ", ".join(culprits[:3])))
    rule_count = len(rules.get("forbid", []))
    if problems:
        print("FAIL %d new architecture violation(s) against %s:" % (len(problems), base))
        for line in problems:
            print("  " + line)
        return 1
    print("PASS %d forbid rule(s)%s, nothing new against %s" % (rule_count, ", no new cycles" if rules.get("no_new_cycles", True) else "", base))
    return 0


def take(args, flag, default=None):
    if flag in args:
        i = args.index(flag)
        if i + 1 >= len(args):
            usage()
        value = args[i + 1]
        del args[i:i + 2]
        return value
    return default


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        usage()
    command = args.pop(0)
    top = git("rev-parse", "--show-toplevel").strip()
    os.chdir(top)
    rev = take(args, "--rev", "HEAD")
    if command == "build":
        days = take(args, "--days", "90")
        if not days.isdigit():
            usage()
        coverage_file = take(args, "--coverage")
        rules_file = take(args, "--rules")
        out_dir = take(args, "--out", ".gate")
        if args:
            usage()
        graph = build_graph(rev, int(days), coverage_file, rules_file)
        write_outputs(graph, out_dir)
        summarize(graph, out_dir)
    elif command == "impact":
        base = take(args, "--base")
        if bool(base) == bool(args):
            usage()
        changed = args or [p for p in git("diff", "--name-only", "%s...%s" % (base, rev)).splitlines() if not p.startswith("vault/")]
        if not changed:
            print("CHANGE IMPACT: no files changed against %s" % base)
            return
        impact(rev, changed)
    elif command == "check":
        rules_file, base = take(args, "--rules"), take(args, "--base")
        if not rules_file or not base or args:
            usage()
        sys.exit(check(rev, base, rules_file))
    else:
        usage()


if __name__ == "__main__":
    main()
