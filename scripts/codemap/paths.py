import posixpath

from codemap.repo import module_of


def shared_dirs(a, b):
    count = 0
    for x, y in zip(a.split("/")[:-1], b.split("/")[:-1]):
        if x != y:
            break
        count += 1
    return count


class PathIndex:
    def __init__(self, paths):
        self.files = set(paths)
        self.by_dir = {}
        self.by_suffix = {}
        for path in paths:
            self.by_dir.setdefault(module_of(path), []).append(path)
            parts = path.split("/")
            for cut in range(len(parts)):
                self.by_suffix.setdefault("/".join(parts[cut:]), []).append(path)

    def suffix(self, *rels, near="", root_ok=lambda prefix: True):
        hits = [(-shared_dirs(near, p), len(p) - len(rel), p) for rel in rels for p in self.by_suffix.get(rel, ()) if root_ok(p[:len(p) - len(rel)])]
        return min(hits)[2] if hits else None

    def mention(self, token, near):
        if token.startswith(("./", "../")):
            target = posixpath.normpath(posixpath.join(module_of(near), token))
            if target in self.files:
                return target
        segments = [s for s in token.split("/") if s not in ("", ".", "..", "~")]
        for keep in range(len(segments), 0, -1):
            rel = "/".join(segments[-keep:])
            hits = self.by_suffix.get(rel, ())
            if keep == 1 and len(hits) != 1:
                return None
            if hits:
                return self.suffix(rel, near=near)
        return None
