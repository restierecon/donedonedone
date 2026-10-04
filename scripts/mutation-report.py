#!/usr/bin/env python3
import ast
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

SKIP_DIRS = {
    "node_modules",
    "target",
    "build",
    "dist",
    "coverage",
    ".venv",
    "venv",
    ".git",
    ".gate",
    "vault",
    ".worktrees",
    "mutants",
}

SCHEMA_STATUS = {
    "Killed": "killed",
    "Timeout": "timeout",
    "Survived": "survived",
    "NoCoverage": "no-coverage",
}
PIT_STATUS = {
    "KILLED": "killed",
    "MEMORY_ERROR": "killed",
    "TIMED_OUT": "timeout",
    "SURVIVED": "survived",
    "NO_COVERAGE": "no-coverage",
}
CARGO_STATUS = {
    "CaughtMutant": "killed",
    "Timeout": "timeout",
    "MissedMutant": "survived",
}
GREMLINS_STATUS = {
    "KILLED": "killed",
    "TIMED_OUT": "timeout",
    "LIVED": "survived",
    "NOT_COVERED": "no-coverage",
}
MUTMUT_STATUS = {
    "killed": "killed",
    "caught by type check": "killed",
    "segfault": "killed",
    "timeout": "timeout",
    "survived": "survived",
    "suspicious": "survived",
    "no tests": "no-coverage",
}
MUTMUT_LINE = re.compile(r"^\s*(\S+__mutmut_\d+):\s*(.+?)\s*$")


def usage():
    sys.stderr.write(
        "usage: mutation-report.py <report: mutation-testing-report-schema json | PIT mutations.xml | cargo-mutants outcomes.json | gremlins json | - for 'mutmut results --all true' on stdin>\n"
    )
    sys.exit(2)


def norm(path, root=None):
    path = path.replace("\\", "/")
    if root and os.path.isabs(path):
        rel = os.path.relpath(path, root).replace("\\", "/")
        if not rel.startswith("../"):
            path = rel
    while path.startswith("./"):
        path = path[2:]
    return path


def parse_schema(data):
    root = data.get("projectRoot") or os.getcwd()
    for path, entry in data["files"].items():
        for mutant in entry.get("mutants", []):
            status = SCHEMA_STATUS.get(mutant.get("status"))
            if status:
                yield (
                    norm(path, root),
                    mutant["location"]["start"]["line"],
                    status,
                    mutant.get("mutatorName", "") + " " + mutant.get("replacement", ""),
                )


def parse_gremlins(data):
    for entry in data.get("files") or []:
        for mutation in entry.get("mutations", []):
            status = GREMLINS_STATUS.get(mutation.get("status"))
            if status:
                yield (
                    norm(entry["file_name"], os.getcwd()),
                    mutation["line"],
                    status,
                    mutation.get("type", ""),
                )


def parse_cargo(data):
    for outcome in data["outcomes"]:
        scenario = outcome.get("scenario")
        mutant = scenario.get("Mutant") if isinstance(scenario, dict) else None
        status = CARGO_STATUS.get(outcome.get("summary"))
        if mutant and status:
            yield (
                norm(mutant["file"]),
                mutant["span"]["start"]["line"],
                status,
                (mutant.get("name") or mutant.get("replacement", "")),
            )


def source_index():
    index = {}
    for dirpath, dirnames, filenames in os.walk("."):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            index.setdefault(name, []).append(norm(os.path.join(dirpath, name)))
    return index


def parse_pit(root):
    index = None
    for mutation in root.iter("mutation"):
        status = PIT_STATUS.get(mutation.get("status"))
        if not status:
            continue
        if index is None:
            index = source_index()
        source = mutation.findtext("sourceFile")
        package = mutation.findtext("mutatedClass").rpartition(".")[0].replace(".", "/")
        suffix = (package + "/" if package else "") + source
        matches = [
            p for p in index.get(source, []) if p == suffix or p.endswith("/" + suffix)
        ]
        yield (
            (matches[0] if len(matches) == 1 else suffix),
            int(mutation.findtext("lineNumber")),
            status,
            mutation.findtext("description") or "",
        )


def function_defs(tree):
    defs = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            defs[node.name] = node
        elif isinstance(node, ast.ClassDef):
            for child in node.body:
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    defs[node.name + "." + child.name] = child
    return defs


def original_name(key):
    if "ǁ" in key:
        cls = key[key.index("ǁ") + 1 : key.rindex("ǁ")]
        return cls + "." + key[key.rindex("ǁ") + 1 :]
    return key[2:]


def mutmut_files():
    files = {}
    for dirpath, _, filenames in os.walk("mutants"):
        for name in filenames:
            if not name.endswith(".py.meta"):
                continue
            with open(os.path.join(dirpath, name), encoding="utf-8") as handle:
                keys = json.load(handle).get("exit_code_by_key", {})
            mutated = os.path.join(dirpath, name[:-5])
            for key in keys:
                files[key] = mutated
    return files


def mutant_line(mutated_path, mutant_key, cache):
    if mutated_path not in cache:
        original_path = norm(os.path.relpath(mutated_path, "mutants"))
        with open(mutated_path, encoding="utf-8") as handle:
            mutated_text = handle.read()
        with open(original_path, encoding="utf-8") as handle:
            original_tree = ast.parse(handle.read())
        cache[mutated_path] = (
            original_path,
            mutated_text.splitlines(),
            function_defs(ast.parse(mutated_text)),
            function_defs(original_tree),
        )
    original_path, lines, mutated_defs, original_defs = cache[mutated_path]
    func = mutant_key.rpartition(".")[2]
    base = func.partition("__mutmut_")[0]
    orig = mutated_defs.get(base + "__mutmut_orig") or next(
        (
            n
            for k, n in mutated_defs.items()
            if k.endswith("." + base + "__mutmut_orig")
        ),
        None,
    )
    mutant = mutated_defs.get(func) or next(
        (n for k, n in mutated_defs.items() if k.endswith("." + func)), None
    )
    target = original_defs.get(original_name(base))
    if not (orig and mutant and target):
        return original_path, None
    orig_lines = lines[orig.lineno - 1 : orig.end_lineno]
    mutant_lines = lines[mutant.lineno - 1 : mutant.end_lineno]
    offset = next(
        (
            i
            for i, (a, b) in enumerate(zip(orig_lines[1:], mutant_lines[1:]), 1)
            if a != b
        ),
        0,
    )
    return original_path, target.lineno + offset


def parse_mutmut(text):
    files = mutmut_files()
    cache = {}
    for raw in text.splitlines():
        match = MUTMUT_LINE.match(raw)
        if not match:
            continue
        key, status = match.group(1), MUTMUT_STATUS.get(match.group(2))
        if not status or key not in files:
            continue
        path, line = mutant_line(files[key], key, cache)
        if line is not None:
            yield path, line, status, key


def load(path):
    if path == "-":
        return parse_mutmut(sys.stdin.read())
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    stripped = text.lstrip()
    if stripped.startswith("<"):
        return parse_pit(ET.fromstring(text))
    if stripped.startswith("{"):
        data = json.loads(text)
        if "outcomes" in data:
            return parse_cargo(data)
        if "go_module" in data or isinstance(data.get("files"), list):
            return parse_gremlins(data)
        if isinstance(data.get("files"), dict):
            return parse_schema(data)
    if MUTMUT_LINE.search(text.splitlines()[0] if text else ""):
        return parse_mutmut(text)
    sys.stderr.write(f"mutation-report.py: {path} is not a format this adapter reads\n")
    sys.exit(2)


def main(argv):
    if len(argv) != 1 or argv[0] in ("-h", "--help"):
        usage()
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    rows = list(load(argv[0]))
    if not rows:
        print("no-mutants")
    for path, line, status, description in rows:
        print(f"{path}:{line} {status} {' '.join(description.split())}".rstrip())


if __name__ == "__main__":
    main(sys.argv[1:])
