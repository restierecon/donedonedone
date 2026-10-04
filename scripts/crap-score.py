#!/usr/bin/env python3
import csv
import io
import json
import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

SKIP_DIRS = ["node_modules", "target", "build", "dist", "coverage", ".venv", "venv", ".git", ".gate", "vault", ".worktrees"]


def usage():
    sys.stderr.write("usage: crap-score.py <coverage file: lcov | cobertura xml | jacoco xml | coverage.py json> [-x <glob>]... [source paths...]\n")
    sys.exit(2)


def norm(path):
    path = path.replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    return path


def parse_lcov(text):
    files, current = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            current = files.setdefault(norm(line[3:]), {})
        elif line.startswith("DA:") and current is not None:
            number, hits = line[3:].split(",")[:2]
            current[int(number)] = current.get(int(number), False) or int(float(hits)) > 0
        elif line == "end_of_record":
            current = None
    return files


def parse_coverage_json(text):
    files = {}
    for path, data in json.loads(text).get("files", {}).items():
        lines = {n: True for n in data.get("executed_lines", [])}
        lines.update({n: False for n in data.get("missing_lines", [])})
        files[norm(path)] = lines
    return files


def parse_cobertura(root):
    sources = [norm(s.text.strip()) for s in root.iter("source") if s.text and s.text.strip()]
    files = {}
    for cls in root.iter("class"):
        filename = norm(cls.get("filename", ""))
        lines = files.setdefault(filename, {})
        for line in cls.iter("line"):
            number = int(line.get("number"))
            lines[number] = lines.get(number, False) or int(line.get("hits", "0")) > 0
        for source in sources:
            files.setdefault(source.rstrip("/") + "/" + filename, lines)
    return files


def parse_jacoco(root):
    files = {}
    for package in root.iter("package"):
        prefix = package.get("name", "")
        for source in package.iter("sourcefile"):
            path = (prefix + "/" if prefix else "") + source.get("name")
            files[path] = {int(l.get("nr")): int(l.get("ci", "0")) > 0 for l in source.iter("line")}
    return files


def load_coverage(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    stripped = text.lstrip()
    if stripped.startswith("{"):
        return parse_coverage_json(text)
    if stripped.startswith("<"):
        root = ET.fromstring(text)
        if root.tag == "report":
            return parse_jacoco(root)
        if root.tag == "coverage":
            return parse_cobertura(root)
        sys.exit("crap-score.py: unknown XML coverage root <%s> in %s" % (root.tag, path))
    if "SF:" in text:
        return parse_lcov(text)
    sys.exit("crap-score.py: can't tell the format of %s (lcov, cobertura, jacoco or coverage.py json)" % path)


def lizard_command():
    try:
        __import__("lizard")
        return [sys.executable, "-m", "lizard"]
    except ImportError:
        found = shutil.which("lizard")
        if found:
            return [found]
    sys.exit("crap-score.py: lizard not found — pip install lizard")


def functions(paths, globs):
    excludes = []
    for pattern in globs:
        excludes += ["-x", pattern, "-x", "*/" + pattern]
    for name in SKIP_DIRS:
        excludes += ["-x", "*/%s/*" % name, "-x", "%s/*" % name]
    result = subprocess.run(lizard_command() + ["--csv"] + excludes + paths, capture_output=True, text=True)
    if result.returncode != 0 and not result.stdout:
        sys.exit("crap-score.py: lizard failed: %s" % result.stderr.strip())
    found = []
    for row in csv.reader(io.StringIO(result.stdout)):
        if len(row) < 11 or not row[1].isdigit():
            continue
        found.append({"file": norm(os.path.relpath(row[6])), "name": row[7], "ccn": int(row[1]), "start": int(row[9]), "end": int(row[10])})
    return found


def coverage_for(path, coverage):
    if path in coverage:
        return coverage[path]
    absolute = norm(os.path.abspath(path))
    if absolute in coverage:
        return coverage[absolute]
    best, best_len = None, 0
    parts = path.split("/")
    for key, lines in coverage.items():
        key_parts = key.split("/")
        shared = 0
        while shared < min(len(parts), len(key_parts)) and parts[-1 - shared] == key_parts[-1 - shared]:
            shared += 1
        if shared == len(key_parts) or shared == len(parts):
            if shared > best_len:
                best, best_len = lines, shared
    return best


def own_lines(fn, siblings):
    first = fn["start"] + 1 if fn["end"] > fn["start"] else fn["start"]
    lines = set(range(first, fn["end"] + 1))
    for other in siblings:
        if other is not fn and fn["start"] <= other["start"] and other["end"] <= fn["end"] and (other["start"], other["end"]) != (fn["start"], fn["end"]):
            lines -= set(range(other["start"], other["end"] + 1))
    return lines


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        usage()
    coverage = load_coverage(sys.argv[1])
    paths, globs, rest = [], [], sys.argv[2:]
    while rest:
        arg = rest.pop(0)
        if arg == "-x":
            if not rest:
                usage()
            globs.append(rest.pop(0))
        else:
            paths.append(arg)
    found = functions(paths or ["."], globs)
    by_file = {}
    for fn in found:
        by_file.setdefault(fn["file"], []).append(fn)
    for path, fns in sorted(by_file.items()):
        lines = coverage_for(path, coverage) or {}
        for fn in fns:
            measured = [lines[n] for n in own_lines(fn, fns) if n in lines]
            if not measured and fn["start"] in lines:
                measured = [lines[fn["start"]]]
            covered = sum(measured) / len(measured) if measured else 0.0
            score = fn["ccn"] ** 2 * (1 - covered) ** 3 + fn["ccn"]
            print("%s:%d-%d %.1f %s" % (path, fn["start"], fn["end"], score, fn["name"]))


if __name__ == "__main__":
    main()
