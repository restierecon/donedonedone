import posixpath

from codemap.graphs import closure, cycle_edge_set, cycle_path, forbidden_edges, module_edges, reverse, strongly_connected
from codemap.metrics import functions, ratio
from codemap.model import entity, flag, worst
from codemap.repo import is_test, line_count, module_of

COMPLEX_CCN = 15
HOTSPOT_CCN = 10
HOTSPOT_CHURN = 3
HUB_FAN_IN = 5
LOW_COVERAGE = 0.5


def dir_id(path):
    return "dir:" + path


def ancestors(path):
    parts = path.split("/")[:-1]
    return ["."] + ["/".join(parts[:i]) for i in range(1, len(parts) + 1)]


class CodeLens:
    def __init__(self, analysis, churn, cover, rules, days, repo_name):
        self.a = analysis
        self.churn, self.cover, self.rules, self.days = churn, cover, rules, days
        self.repo_name = repo_name
        self.entities = {}
        self.seen = {"complexity": {}, "edges": {}, "unmeasured_ext": {}}
        self.deps = analysis.edges()
        self.importers = reverse(self.deps)
        self.all_importers = reverse(analysis.edges(("import", "reference", "mention")))
        self.test_reach = closure([p for p in analysis.texts if is_test(p)], self.deps)

    def build(self):
        for path in sorted(self.a.texts):
            self.add_file(path)
        self.add_dirs()
        self.flag_file_cycles()
        self.flag_violations()
        self.add_module_metrics()
        self.aggregate_child_edges()
        self.roll_up_risk(dir_id("."))
        return self.entities

    def tally(self, bucket, key, lines):
        self.seen[bucket][key] = self.seen[bucket].get(key, 0) + lines

    def add_file(self, path):
        text = self.a.texts[path]
        lines = line_count(text)
        how, found = functions(path, text)
        self.tally_seen(path, how, lines)
        covered = self.cover(path) if self.cover else None
        record = entity("file:" + path, "file", posixpath.basename(path), path=path, parent=dir_id(module_of(path)), lens="code")
        record["out"] = self.a.file_edges(path)
        record["meta"] = {"edges": self.edge_source(path), "complexity": how, "test": is_test(path),
                          "tested by": self.tested_by(path), "externals": sorted(self.a.externals[path])}
        record["metrics"] = {"lines": lines, "changes": self.churn.get(path, 0)}
        if covered is not None:
            record["metrics"]["coverage"] = ratio(covered) if covered else 0.0
        self.entities[record["id"]] = record
        for fn in sorted(found, key=lambda f: -f["ccn"]):
            self.add_function(record, fn, how, covered)
        if found:
            record["metrics"]["max complexity"] = max(f["ccn"] for f in found)
        self.flag_untested(record, path, bool(found) or (how in ("unavailable", "not measured") and lines > 0))

    def edge_source(self, path):
        return "imports parsed" if self.a.parsed(path) else "references scanned"

    def tally_seen(self, path, how, lines):
        self.tally("complexity", how, lines)
        self.tally("edges", self.edge_source(path), lines)
        if how in ("not measured", "unavailable"):
            self.tally("unmeasured_ext", posixpath.splitext(path)[1] or posixpath.basename(path), lines)

    def tested_by(self, path):
        found = sorted(t for t in self.all_importers.get(path, ()) if is_test(t) and t != path)
        if path.endswith(".go") and not path.endswith("_test.go"):
            found += sorted(p for p in self.a.texts if p.endswith("_test.go") and module_of(p) == module_of(path))
        return found

    def add_function(self, file_record, fn, how, covered):
        fid = "fn:%s#%s@%d" % (file_record["path"], fn["name"], fn["start"])
        record = entity(fid, "function", fn["name"], path=file_record["path"], parent=file_record["id"], lens="code")
        record["metrics"] = {"complexity": fn["ccn"], "code lines": fn["nloc"], "lines": "%d-%d" % (fn["start"], fn["end"])}
        record["meta"] = {"complexity": how}
        if covered:
            record["metrics"]["coverage"] = ratio(covered, fn["start"], fn["end"])
        churn = file_record["metrics"]["changes"]
        estimate = " (estimated)" if how == "estimated" else ""
        if not file_record["meta"]["test"] and fn["ccn"] >= HOTSPOT_CCN and churn >= HOTSPOT_CHURN:
            flag(record, "hotspot", "%s() has complexity %d%s and the file changed %d times in %d days — complex code that keeps changing is where regressions come from" % (fn["name"], fn["ccn"], estimate, churn, self.days))
        elif not file_record["meta"]["test"] and fn["ccn"] >= COMPLEX_CCN:
            flag(record, "complex", "%s() has complexity %d%s (≥ %d): many paths to understand and test" % (fn["name"], fn["ccn"], estimate, COMPLEX_CCN))
        file_record["children"].append(fid)
        self.entities[fid] = record

    def flag_untested(self, record, path, has_code):
        if record["meta"]["test"] or not has_code:
            return
        coverage = record["metrics"].get("coverage")
        if coverage is not None and coverage < LOW_COVERAGE:
            flag(record, "untested", "line coverage %d%% (< %d%%)" % (round(coverage * 100), LOW_COVERAGE * 100))
        elif coverage is None and not record["meta"]["tested by"] and path not in self.test_reach:
            flag(record, "untested", "no test file imports, references or reaches it (no coverage report given — a test may still run it in a way the map can't see)")

    def add_dirs(self):
        for path in sorted(self.a.texts):
            chain = ancestors(path)
            for depth, directory in enumerate(chain):
                did = dir_id(directory)
                if did not in self.entities:
                    label = self.repo_name if directory == "." else posixpath.basename(directory)
                    parent = dir_id(chain[depth - 1]) if depth else None
                    self.entities[did] = entity(did, "dir", label, path=directory, parent=parent, lens="code")
                    if parent:
                        self.entities[parent]["children"].append(did)
            self.entities[dir_id(chain[-1])]["children"].append("file:" + path)
        for record in self.entities.values():
            if record["kind"] == "dir":
                record["children"].sort(key=lambda c: (not c.startswith("dir:"), c))

    def flag_file_cycles(self):
        for component in strongly_connected(set(self.a.texts), self.deps):
            loop = cycle_path(component, self.deps)
            by_import = all(b in self.a.imports[a] for a, b in zip(loop, loop[1:]))
            how = "import cycle" if by_import else "dependency cycle (some links are name references, which may be a message string rather than a call)"
            for path in component:
                flag(self.entities["file:" + path], "cycle", "%s: %s" % (how, " → ".join(loop)), "high" if by_import else "medium")

    def flag_violations(self):
        for source, target, src_glob, dst_glob, why in sorted(forbidden_edges(self.deps, self.rules)):
            flag(self.entities["file:" + source], "violation", "depends on %s, but %s must not depend on %s%s" % (target, src_glob, dst_glob, (" — " + why) if why else ""), "high")

    def add_module_metrics(self):
        medges = module_edges(self.deps)
        dependents = reverse(medges)
        for record in [e for e in self.entities.values() if e["kind"] == "dir"]:
            self.module_metrics(record, sorted(medges.get(record["path"], ())), sorted(dependents.get(record["path"], ())))
        import_cycles = cycle_edge_set(module_edges(self.a.edges(("import",))))
        for component in strongly_connected({module_of(p) for p in self.a.texts}, medges):
            loop = cycle_path(component, medges)
            by_import = all(step in import_cycles for step in zip(loop, loop[1:]))
            why = "module cycle: %s — none of these can change or be tested alone" if by_import else \
                "dependency cycle: %s — some links are name references (possibly message strings), so check before untangling"
            for name in component:
                flag(self.entities[dir_id(name)], "cycle", why % " → ".join(loop), "high" if by_import else "medium")

    def module_metrics(self, record, out_mods, in_mods):
        files = [self.entities[c] for c in record["children"] if c.startswith("file:")]
        record["metrics"].update({"files": len(files), "fan-in": len(in_mods), "fan-out": len(out_mods)})
        if out_mods or in_mods:
            record["metrics"]["instability"] = round(len(out_mods) / (len(out_mods) + len(in_mods)), 2)
        record["meta"].update({"depends on": out_mods, "used by": in_mods,
                               "used from outside": sorted(f["path"] for f in files if any(module_of(i) != record["path"] for i in self.importers.get(f["path"], ())))})
        production = [m for m in in_mods if not self.test_only(m)]
        if len(production) >= HUB_FAN_IN and files and not self.test_only(record["path"]):
            flag(record, "hub", "%d non-test modules depend on it — a change here ripples to all of them" % len(production))

    def test_only(self, directory):
        files = [c for c in self.entities[dir_id(directory)]["children"] if c.startswith("file:")]
        return bool(files) and all(self.entities[f]["meta"]["test"] for f in files)

    def aggregate_child_edges(self):
        tally = {}
        for path in self.a.texts:
            for edge in self.entities["file:" + path]["out"]:
                self.place_edge(tally, path, edge["to"][5:], edge["kind"])
        for (container, source, target), kinds in tally.items():
            self.entities[container].setdefault("child_edges", []).append({"from": source, "to": target, "kinds": kinds})

    def place_edge(self, tally, source, target, kind):
        a, b = ancestors(source), ancestors(target)
        depth = 0
        while depth + 1 < min(len(a), len(b)) and a[depth + 1] == b[depth + 1]:
            depth += 1
        child = lambda chain, path: dir_id(chain[depth + 1]) if depth + 1 < len(chain) else "file:" + path
        key = (dir_id(a[depth]), child(a, source), child(b, target))
        if key[1] != key[2]:
            kinds = tally.setdefault(key, {})
            kinds[kind] = kinds.get(kind, 0) + 1

    def roll_up_risk(self, eid):
        record = self.entities[eid]
        levels = [f["level"] for f in record["flags"]]
        child_risks = [self.roll_up_risk(c) for c in record["children"]]
        kinds = {f["kind"] for f in record["flags"]}
        record["risk"] = worst(levels + [r for r in child_risks if r != "low"])
        if record["kind"] == "dir" and "hub" in kinds and record["risk"] != "low" and len(child_risks) and any(r != "low" for r in child_risks):
            record["risk"] = "high"
        return record["risk"]
