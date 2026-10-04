import importlib.util
import os
import re
import sys

from codemap.repo import extension, is_data, is_doc

SHELL_EXT = {".sh", ".bash", ".zsh", ".ksh"}
UNMEASURED_CODE = {".ps1", ".psm1", ".pl", ".pm", ".r", ".jl", ".hs", ".ex", ".exs", ".clj", ".cljs", ".elm", ".dart", ".vue", ".svelte",
                   ".groovy", ".gradle", ".tf", ".nim", ".ml", ".mli", ".fs", ".fsx", ".vb", ".cr", ".pas", ".asm", ".tcl", ".awk",
                   ".mk", ".cmake", ".bat", ".cmd", ".nix", ".coffee", ".rkt", ".scm", ".lisp", ".el", ".vim", ".fish", ".hx", ".purs"}
LIZARD_EXT = {".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".java", ".cs", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".m", ".mm", ".swift",
              ".py", ".rb", ".php", ".scala", ".go", ".lua", ".rs", ".kt", ".kts", ".erl", ".sql", ".f90", ".f", ".gd", ".sol"}
UNMEASURED_NAMES = {"Makefile", "Dockerfile", "Rakefile", "Justfile", "Jenkinsfile"}
SH_FUNC = re.compile(r"^(\s*)(?:function\s+)?([A-Za-z_][\w:.-]*)\s*\(\s*\)\s*(\{.*)?$")
SH_BRANCH = re.compile(r"\b(?:if|elif|while|until|for)\b|&&|\|\||;;")
SH_CLOSE = re.compile(r"^(\s*)\}\s*;?\s*$")


def lizard_module():
    try:
        import lizard
        import lizard_languages
    except ImportError:
        return None, None
    return lizard, lizard_languages


def is_shell(path, text):
    if extension(path) in SHELL_EXT:
        return True
    first = text.split("\n", 1)[0]
    return first.startswith("#!") and re.search(r"\b(ba|z|k)?sh\b", first) is not None


def complexity_kind(path, text):
    if is_doc(path) or is_data(path):
        return "n/a"
    if is_shell(path, text):
        return "estimated"
    lizard, languages = lizard_module()
    if lizard is not None and languages.get_reader_for(path):
        return "measured"
    if lizard is None and extension(path) in LIZARD_EXT:
        return "unavailable"
    if extension(path) in UNMEASURED_CODE or os.path.basename(path) in UNMEASURED_NAMES or text.startswith("#!"):
        return "not measured"
    return "other"


def functions(path, text):
    kind = complexity_kind(path, text)
    if kind == "estimated":
        return kind, shell_functions(text)
    if kind != "measured":
        return kind, []
    lizard, _ = lizard_module()
    try:
        info = lizard.analyze_file.analyze_source_code(path, text)
    except Exception as error:
        sys.stderr.write("codebase-graph.py: lizard skipped %s: %s\n" % (path, error))
        return "not measured", []
    return kind, [{"name": f.name, "ccn": f.cyclomatic_complexity, "nloc": f.nloc, "start": f.start_line, "end": f.end_line} for f in info.function_list]


def strip_shell_comment(line):
    if line.lstrip().startswith("#"):
        return ""
    return re.sub(r"\s#\s.*$", "", line)


def shell_function_end(code, start, indent, opener):
    if opener.count("{") and opener.count("{") == opener.count("}"):
        return start
    for j in range(start + 1, len(code)):
        m = SH_CLOSE.match(code[j])
        if m and len(m.group(1)) <= indent:
            return j
    return start


def shell_summary(name, code, rows):
    rows = [r for r in rows if code[r].strip()]
    if not rows:
        return None
    ccn = 1 + sum(len(SH_BRANCH.findall(code[r])) for r in rows)
    return {"name": name, "ccn": ccn, "nloc": len(rows), "start": rows[0] + 1, "end": rows[-1] + 1}


def shell_functions(text):
    code = [strip_shell_comment(line) for line in text.splitlines()]
    found, owned, i = [], set(), 0
    while i < len(code):
        m = SH_FUNC.match(code[i])
        if not m:
            i += 1
            continue
        end = shell_function_end(code, i, len(m.group(1)), m.group(3) or "")
        summary = shell_summary(m.group(2), code, range(i, end + 1))
        if summary:
            summary["start"], summary["end"] = i + 1, end + 1
            found.append(summary)
        owned.update(range(i, end + 1))
        i = end + 1
    body = shell_summary("(script body)", code, [r for r in range(len(code)) if r not in owned])
    return found + ([body] if body else [])


def coverage_loader(path):
    if not path:
        return None
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    spec = importlib.util.spec_from_file_location("crap_score", os.path.join(here, "crap-score.py"))
    crap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(crap)
    data = crap.load_coverage(path)
    return lambda file: crap.coverage_for(file, data)


def ratio(lines, start=None, end=None):
    picked = [hit for n, hit in lines.items() if start is None or start <= n <= end]
    return round(sum(picked) / len(picked), 3) if picked else None
