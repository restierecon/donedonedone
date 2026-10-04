import json
import re
import sys

from codemap.repo import module_of


def strongly_connected(nodes, edges):
    index, low, stack, on_stack, result, counter = {}, {}, [], set(), [], [0]

    def visit(node):
        index[node] = low[node] = counter[0]
        counter[0] += 1
        stack.append(node)
        on_stack.add(node)

    for root in sorted(nodes):
        if root in index:
            continue
        visit(root)
        work = [(root, iter(sorted(edges.get(root, ()))))]
        while work:
            node, children = work[-1]
            child = next((c for c in children if c not in index or c in on_stack), None)
            if child is not None and child not in index:
                visit(child)
                work.append((child, iter(sorted(edges.get(child, ())))))
                continue
            if child is not None:
                low[node] = min(low[node], index[child])
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index[node]:
                result.append(pop_component(stack, on_stack, node))
    return [sorted(c) for c in result if len(c) > 1]


def pop_component(stack, on_stack, node):
    component = []
    while True:
        member = stack.pop()
        on_stack.discard(member)
        component.append(member)
        if member == node:
            return component


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


def closure(start, adjacency):
    seen, frontier = set(), set(start)
    while frontier:
        reached = set()
        for node in frontier:
            reached |= adjacency.get(node, set())
        frontier = reached - seen - set(start)
        seen |= frontier
    return seen


def reverse(edges):
    result = {}
    for source, targets in edges.items():
        for target in targets:
            result.setdefault(target, set()).add(source)
    return result


def module_edges(edges):
    result = {}
    for source, targets in edges.items():
        for target in targets:
            a, b = module_of(source), module_of(target)
            if a != b:
                result.setdefault(a, set()).add(b)
    return result


def all_nodes(edges):
    return set(edges) | {t for ts in edges.values() for t in ts}


def cycle_edge_set(medges):
    found = set()
    for component in strongly_connected(all_nodes(medges), medges):
        members = set(component)
        found |= {(s, t) for s in component for t in medges.get(s, ()) if t in members}
    return found


def glob_regex(pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] in "*?":
            out, i = out + ("[^/]*" if pattern[i] == "*" else "[^/]"), i + 1
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
            if source_re.match(source):
                found |= {(source, t, rule["from"], rule["to"], rule.get("why", "")) for t in targets if target_re.match(t) and not (target_re.match(source) and source_re.match(t))}
    return found
