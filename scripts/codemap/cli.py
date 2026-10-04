import os
import sys

from codemap.code_lens import CodeLens
from codemap.facts import Facts
from codemap.graphs import cycle_edge_set, cycle_path, forbidden_edges, load_rules, module_edges, reverse, strongly_connected, closure
from codemap.metrics import coverage_loader
from codemap.model import Analysis
from codemap.render import summarize, write_outputs
from codemap.repo import churn_counts, git, is_test, module_of, short_rev
from codemap.setup_lens import SetupLens, detect_roots


def usage():
    sys.stderr.write(
        "usage: codebase-graph.py build [--rev REV] [--days N] [--coverage FILE] [--rules FILE] [--out DIR]\n"
        "       codebase-graph.py impact [--rev REV] (--base REV | <file>...)\n"
        "       codebase-graph.py check --rules FILE --base REV [--rev REV]\n"
    )
    sys.exit(2)


def build_graph(rev, days, coverage_file, rules_file):
    analysis = Analysis(rev)
    rules = load_rules(rules_file)
    code = CodeLens(analysis, churn_counts(rev, days), coverage_loader(coverage_file), rules, days, os.path.basename(os.getcwd()))
    entities = code.build()
    code.seen.update({"files": len(analysis.texts), "skipped": analysis.skipped})
    lenses = [{"id": "code", "label": "Code", "root": "dir:.", "problems": []}]
    for root in detect_roots(analysis.texts):
        setup = SetupLens(analysis, entities, root)
        problems = setup.build()
        lenses.append({"id": setup.lens, "label": root.rstrip("/") or "repo", "root": setup.lens, "problems": problems})
    medges = module_edges(code.deps)
    return {
        "version": 2,
        "rev": short_rev(rev),
        "churn_days": days,
        "coverage_given": bool(coverage_file),
        "rules": rules,
        "seen": code.seen,
        "facts": Facts(analysis, entities).build(),
        "lenses": lenses,
        "entities": entities,
        "module_cycles": [cycle_path(c, medges) for c in strongly_connected({module_of(p) for p in analysis.texts}, medges)],
        "file_cycles": [cycle_path(c, code.deps) for c in strongly_connected(set(analysis.texts), code.deps)],
    }


def listed(items, limit=4):
    items = sorted(items)
    return (" (" + ", ".join(items[:limit]) + (" …" if len(items) > limit else "") + ")") if items else ""


def owning_components(analysis, changed):
    found = set()
    for root in detect_roots(analysis.texts):
        setup = SetupLens(analysis, {}, root)
        setup.discover()
        found |= {setup.owner[p] for p in changed if p in setup.owner}
    return found


def impact_report(analysis, changed):
    deps = analysis.edges()
    back, mentioned_by = reverse(deps), reverse(analysis.edges(("mention",)))
    known = [p for p in changed if p in analysis.texts]
    direct = set().union(set(), *[back.get(p, set()) for p in known]) - set(known)
    everything = closure(known, back)
    mentions = {m for p in known for m in mentioned_by.get(p, ())}
    tests = {p for p in everything | set(known) | mentions if is_test(p)}
    mods = sorted({module_of(p) for p in changed})
    medges = module_edges(deps)
    return {
        "known": known, "other": len(changed) - len(known), "modules": mods, "direct": direct, "everything": everything,
        "tests": tests, "docs": mentions - tests - set(known),
        "reached": sorted({module_of(p) for p in everything} - set(mods)),
        "api": [p for p in known if any(module_of(i) != module_of(p) for i in back.get(p, ()))],
        "cycles": [c for c in strongly_connected({module_of(p) for p in analysis.texts}, medges) if set(c) & set(mods)],
        "components": owning_components(analysis, known),
    }


def risk_estimate(report):
    production = len([p for p in report["everything"] if not is_test(p)])
    if production >= 20 or report["cycles"] or len(report["reached"]) >= 5:
        return "High"
    return "Medium" if production >= 5 or report["api"] else "Low"


def impact(rev, changed):
    r = impact_report(Analysis(rev), changed)
    rows = [
        ("Files", "%d mapped + %d other" % (len(r["known"]), r["other"])),
        ("Modules", "%d%s" % (len(r["modules"]), listed(r["modules"], 6))),
        ("Used across modules", "%d%s" % (len(r["api"]), listed(r["api"]))),
        ("Direct dependents", "%d%s" % (len(r["direct"]), listed(r["direct"]))),
        ("Indirect dependents", "%d" % len(r["everything"] - r["direct"])),
        ("Modules reached", "%d%s" % (len(r["reached"]), listed(r["reached"], 6))),
        ("Tests in reach", "%d%s" % (len(r["tests"]), listed(r["tests"]))),
        ("Docs mentioning it", "%d%s" % (len(r["docs"]), listed(r["docs"]))),
    ]
    if r["components"]:
        rows.append(("Setup components", "%d%s" % (len(r["components"]), listed(r["components"], 6))))
    rows.append(("Dependency cycles", "; ".join(" ↔ ".join(c) for c in r["cycles"]) or "none touching the change"))
    rows.append(("Regression risk", "%s (estimate from reach, not a measurement)" % risk_estimate(r)))
    print("CHANGE IMPACT @ %s (imports + name references; dynamic calls and string-built names need grep)" % short_rev(rev))
    for label, value in rows:
        print("%-21s%s" % (label + ":", value))


def check(rev, base, rules_file):
    rules = load_rules(rules_file)
    head, base_analysis = Analysis(rev), Analysis(base)
    head_edges, base_edges = head.edges(), base_analysis.edges()
    problems = ["%s depends on %s — %s must not depend on %s%s" % (s, t, sg, tg, (" (" + why + ")") if why else "")
                for s, t, sg, tg, why in sorted(forbidden_edges(head_edges, rules) - forbidden_edges(base_edges, rules))]
    if rules.get("no_new_cycles", True):
        head_imports, base_imports = head.edges(("import",)), base_analysis.edges(("import",))
        base_medges = module_edges(base_imports)
        existed = {(s, t) for s, ts in base_medges.items() for t in ts}
        for source, target in sorted(cycle_edge_set(module_edges(head_imports)) - cycle_edge_set(base_medges) - existed):
            culprits = sorted(p for p in head_imports if module_of(p) == source and any(module_of(t) == target for t in head_imports[p]))
            problems.append("new module cycle edge %s → %s (via %s)" % (source, target, ", ".join(culprits[:3])))
    if problems:
        print("FAIL %d new architecture violation(s) against %s:" % (len(problems), base))
        for line in problems:
            print("  " + line)
        return 1
    print("PASS %d forbid rule(s)%s, nothing new against %s" % (len(rules.get("forbid", [])), ", no new cycles" if rules.get("no_new_cycles", True) else "", base))
    return 0


def take(args, flag, default=None):
    if flag not in args:
        return default
    i = args.index(flag)
    if i + 1 >= len(args):
        usage()
    value = args[i + 1]
    del args[i:i + 2]
    return value


def run_build(args, rev):
    days = take(args, "--days", "90")
    coverage_file, rules_file, out_dir = take(args, "--coverage"), take(args, "--rules"), take(args, "--out", ".gate")
    if args or not days.isdigit():
        usage()
    graph = build_graph(rev, int(days), coverage_file, rules_file)
    write_outputs(graph, out_dir)
    summarize(graph, out_dir)
    return 1 if any(p["level"] == "error" for lens in graph["lenses"] for p in lens["problems"]) else 0


def run_impact(args, rev):
    base = take(args, "--base")
    if bool(base) == bool(args):
        usage()
    changed = args or [p for p in git("diff", "--name-only", "%s...%s" % (base, rev)).splitlines() if not p.startswith("vault/")]
    if not changed:
        print("CHANGE IMPACT: no files changed against %s" % base)
        return 0
    impact(rev, changed)
    return 0


def run_check(args, rev):
    rules_file, base = take(args, "--rules"), take(args, "--base")
    if not rules_file or not base or args:
        usage()
    return check(rev, base, rules_file)


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        usage()
    command = args.pop(0)
    runner = {"build": run_build, "impact": run_impact, "check": run_check}.get(command)
    if not runner:
        usage()
    os.chdir(git("rev-parse", "--show-toplevel").strip())
    sys.exit(runner(args, take(args, "--rev", "HEAD")))
