import posixpath
import re

from codemap.repo import extension, git, module_of

JS_EXT = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]
PARSED_EXT = {".py", ".go", ".java", ".kt", *JS_EXT}
PY_STRING_BLOCK = re.compile(r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'')
JS_COMMENT = re.compile(r"/\*[\s\S]*?\*/|^\s*//.*$", re.M)
PY_FROM = re.compile(r"\s*from\s+(\.*)([\w.]*)\s+import\s+(.+)")
PY_IMPORT = re.compile(r"\s*import\s+([\w.]+(?:\s+as\s+\w+)?(?:\s*,\s*[\w.]+(?:\s+as\s+\w+)?)*)\s*$")
JS_SPEC = re.compile(r"""(?:import|export)[^'"`;]*?from\s*['"]([^'"]+)['"]|import\s*['"]([^'"]+)['"]|(?:require|import)\s*\(\s*['"]([^'"]+)['"]\s*\)""")


def go_module_name(rev):
    try:
        text = git("show", "%s:go.mod" % rev)
    except SystemExit:
        return ""
    m = re.search(r"^module\s+(\S+)", text, re.M)
    return m.group(1) if m else ""


class Resolver:
    def __init__(self, index, go_module=""):
        self.index = index
        self.go_module = go_module

    def python_root(self, prefix):
        return prefix + "__init__.py" not in self.index.files

    def py_target(self, base, near, exact=False):
        base = base.strip("/")
        if not base:
            return None
        rels = (base + ".py", base + "/__init__.py")
        if exact:
            return next((rel for rel in rels if rel in self.index.files), None)
        return self.index.suffix(*rels, near=near, root_ok=self.python_root)

    def python_from(self, path, dots, name, names):
        base = name.replace(".", "/")
        if dots:
            anchor = module_of(path)
            for _ in range(len(dots) - 1):
                anchor = posixpath.dirname(anchor)
            base = posixpath.normpath(posixpath.join(anchor, base)) if base else anchor
        subs = [n.strip().split(" as ")[0].strip("() ") for n in names.split(",")]
        found = {t for t in (self.py_target(base + "/" + s, path, exact=bool(dots)) for s in subs) if t}
        if not found:
            target = self.py_target(base, path, exact=bool(dots))
            found = {target} if target else set()
        return found

    def python(self, path, text):
        found, externals = set(), set()
        for line in PY_STRING_BLOCK.sub("", text).splitlines():
            m = PY_FROM.match(line)
            if m:
                hits = self.python_from(path, *m.groups())
                found |= hits
                if not hits and not m.group(1) and m.group(2):
                    externals.add(m.group(2).split(".")[0])
                continue
            m = PY_IMPORT.match(line)
            for part in m.group(1).split(",") if m else []:
                name = part.strip().split()[0]
                target = self.py_target(name.replace(".", "/"), path)
                found.add(target) if target else externals.add(name.split(".")[0])
        return found, externals

    def js(self, path, text):
        found, externals = set(), set()
        for groups in JS_SPEC.findall(JS_COMMENT.sub("", text)):
            spec = next(g for g in groups if g)
            if not spec.startswith("."):
                externals.add("/".join(spec.split("/")[:2]) if spec.startswith("@") else spec.split("/")[0])
                continue
            base = posixpath.normpath(posixpath.join(module_of(path), spec))
            candidates = [base] + [base + e for e in JS_EXT] + [base + "/index" + e for e in JS_EXT]
            target = next((c for c in candidates if c in self.index.files), None)
            if target:
                found.add(target)
        return found, externals

    def go(self, path, text):
        found, externals = set(), set()
        specs = re.findall(r'^\s*import\s+(?:\w+\s+)?"([^"]+)"', text, re.M)
        for block in re.findall(r"^\s*import\s*\((.*?)\)", text, re.M | re.S):
            specs += re.findall(r'"([^"]+)"', block)
        for spec in specs:
            if self.go_module and (spec == self.go_module or spec.startswith(self.go_module + "/")):
                directory = spec[len(self.go_module):].strip("/") or "."
                found.update(p for p in self.index.by_dir.get(directory, []) if p.endswith(".go") and not p.endswith("_test.go"))
            else:
                externals.add(spec)
        return found, externals

    def jvm_class(self, spec, path):
        parts = spec.split(".")
        for cut in range(len(parts), 1, -1):
            rel = "/".join(parts[:cut])
            target = self.index.suffix(rel + ".java", rel + ".kt", near=path)
            if target:
                return {target}
        return set()

    def jvm_package(self, spec):
        directory = spec[:-2].replace(".", "/")
        hits = [d for d in self.index.by_dir if d == directory or d.endswith("/" + directory)]
        return set(self.index.by_dir[min(hits, key=len)]) if hits else set()

    def jvm(self, path, text):
        found, externals = set(), set()
        for spec in re.findall(r"^\s*import\s+(?:static\s+)?([\w.]+(?:\.\*)?)\s*;?", text, re.M):
            hits = self.jvm_package(spec) if spec.endswith(".*") else self.jvm_class(spec, path)
            found |= hits
            if not hits:
                externals.add(".".join(spec.split(".")[:2]))
        return found, externals

    def imports(self, path, text):
        ext = extension(path)
        parser = {".py": self.python, ".go": self.go, ".java": self.jvm, ".kt": self.jvm}.get(ext)
        if ext in JS_EXT:
            parser = self.js
        if not parser:
            return set(), set()
        found, externals = parser(path, text)
        found.discard(path)
        return found, externals
