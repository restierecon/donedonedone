import json
import os

BLIND_SHARE = 0.3


def write_outputs(graph, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "graph.json"), "w", encoding="utf-8") as handle:
        json.dump(graph, handle, indent=1, sort_keys=True)
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(here, "graph-viewer.html"), encoding="utf-8") as handle:
        template = handle.read()
    payload = json.dumps(graph, sort_keys=True).replace("</", "<\\/")
    with open(os.path.join(out_dir, "graph.html"), "w", encoding="utf-8") as handle:
        handle.write(template.replace("__GRAPH_JSON__", payload))


def share(part, whole):
    return "%d%%" % round(100 * part / whole) if whole else "0%"


def seen_lines(seen):
    complexity, edges = seen["complexity"], seen["edges"]
    total = sum(edges.values())
    code = sum(v for k, v in complexity.items() if k not in ("n/a", "other"))
    blind = complexity.get("not measured", 0) + complexity.get("unavailable", 0)
    skipped = ", ".join("%d %s" % (n, k) for k, n in seen["skipped"].items() if n) or "none"
    lines = ["SEEN: %d text files, %d lines — edges: %s imports parsed, %s references scanned · complexity: %s" % (
        seen["files"], total, share(edges.get("imports parsed", 0), total), share(edges.get("references scanned", 0), total),
        ", ".join("%s %s" % (k, share(complexity[k], total)) for k in ("measured", "estimated", "n/a", "other", "not measured", "unavailable") if complexity.get(k))),
        "  skipped files: %s" % skipped]
    if code and blind / code > BLIND_SHARE:
        top = sorted(seen["unmeasured_ext"].items(), key=lambda kv: -kv[1])[:4]
        lines.append("  WARNING: %s of code lines have no complexity measure (%s)%s — their links are name references only" % (
            share(blind, code), ", ".join(k for k, _ in top), "; pip install lizard" if complexity.get("unavailable") else ""))
    return lines


def facts_lines(facts):
    counts = {"todo": 0, "ask": 0}
    for section in facts:
        for entry in section["items"]:
            if entry["level"] in counts:
                counts[entry["level"]] += 1
    head = next((e["fact"] for s in facts if s["section"] == "Stack" for e in s["items"]), "no facts")
    return ["FACTS: %s · %d sections · %d [TODO] · %d [ASK USER]" % (head, len(facts), counts["todo"], counts["ask"])] + \
        ["  " + e["fact"] for s in facts for e in s["items"] if e["level"] == "ask"][:4]


def flagged_lines(entities, limit=8):
    order = {"high": 0, "medium": 1}
    hits = [e for e in entities.values() if e.get("lens") == "code" and e["kind"] in ("dir", "file") and e["flags"]]
    hits.sort(key=lambda e: (order.get(e["risk"], 2), e["id"]))
    return ["  %-6s %s: %s" % (e["risk"], e.get("path"), ", ".join(sorted({f["kind"] for f in e["flags"]}))) for e in hits[:limit] if e["risk"] != "low"]


def lens_line(graph, lens):
    root = graph["entities"][lens["root"]]
    errors = [p for p in lens["problems"] if p["level"] == "error"]
    warnings = len(lens["problems"]) - len(errors)
    counts = ", ".join("%d %s" % (v, k) for k, v in root["metrics"].items() if k != "problems" and v)
    stages = sum(1 for c in root["children"] if c.startswith("stage:"))
    state = "%d problem(s)" % len(errors) if errors else "OK"
    head = "SETUP %s: %s — %s%s · %s" % (lens["label"], root["label"], "%d stages, " % stages if stages else "", counts, state)
    return [head + (", %d warning(s)" % warnings if warnings else "")] + ["  ERROR " + p["message"] for p in errors[:6]]


def setup_lines(graph):
    return [line for lens in graph["lenses"][1:] for line in lens_line(graph, lens)]


def summarize(graph, out_dir):
    entities = graph["entities"]
    count = lambda kind: sum(1 for e in entities.values() if e["kind"] == kind)
    print("GRAPH @ %s: %d dirs, %d files, %d functions, %d module cycles, %d file cycles" % (
        graph["rev"], count("dir"), count("file"), count("function"), len(graph["module_cycles"]), len(graph["file_cycles"])))
    for line in seen_lines(graph["seen"]) + facts_lines(graph.get("facts", [])) + flagged_lines(entities) + setup_lines(graph):
        print(line)
    print("  view: %s · data: %s" % (os.path.join(out_dir, "graph.html"), os.path.join(out_dir, "graph.json")))
