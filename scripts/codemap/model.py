from codemap.imports import Resolver, go_module_name, PARSED_EXT
from codemap.paths import PathIndex
from codemap.references import edge_kind, mentions
from codemap.repo import extension, listing, read_tree

LEVELS = {"high": 2, "medium": 1, "info": 0}
DEPENDENCY_KINDS = ("import", "reference")


def entity(eid, kind, label, **fields):
    record = {"id": eid, "kind": kind, "label": label, "metrics": {}, "flags": [], "meta": {}, "out": [], "children": []}
    record.update(fields)
    return record


def flag(record, kind, why, level="medium"):
    record["flags"].append({"kind": kind, "why": why, "level": level})


def worst(levels):
    best = max((LEVELS[level] for level in levels), default=-1)
    return {2: "high", 1: "medium"}.get(best, "low")


class Analysis:
    def __init__(self, rev):
        self.texts, self.skipped = read_tree(rev)
        self.tracked = {path for path, _ in listing(rev)}
        self.index = PathIndex(self.texts)
        resolver = Resolver(self.index, go_module_name(rev))
        self.imports, self.externals, self.links = {}, {}, {}
        for path, text in self.texts.items():
            self.imports[path], self.externals[path] = resolver.imports(path, text)
            kind = edge_kind(path)
            self.links[path] = {t: (kind, line) for t, line in mentions(path, text, self.index).items() if t not in self.imports[path]}

    def parsed(self, path):
        return extension(path) in PARSED_EXT

    def edges(self, kinds=DEPENDENCY_KINDS):
        result = {}
        for path in self.texts:
            targets = set(self.imports[path]) if "import" in kinds else set()
            targets |= {t for t, (k, _) in self.links[path].items() if k in kinds}
            result[path] = targets
        return result

    def file_edges(self, path):
        out = [{"to": "file:" + t, "kind": "import"} for t in sorted(self.imports[path])]
        out += [{"to": "file:" + t, "kind": k, "where": "%s:%d" % (path, line)} for t, (k, line) in sorted(self.links[path].items())]
        return out
