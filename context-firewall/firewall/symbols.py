from __future__ import annotations

import ast
import re
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

BRACE_EXT = {"js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "java", "kt", "kts", "cs", "go", "rs", "c", "h", "cc", "cpp", "hpp", "swift", "scala", "php", "dart", "ps1", "psm1"}
CLASS_RE = re.compile(r"^(?P<indent>\s*)(?:export\s+)?(?:default\s+)?(?:public\s+|private\s+|protected\s+|internal\s+|abstract\s+|sealed\s+|static\s+|final\s+|partial\s+|data\s+|open\s+)*(?:class|interface|struct|enum|trait|record|object|impl|type)\s+(?P<name>[A-Za-z_$][\w$]*)")
FUNC_RE = re.compile(r"^(?P<indent>\s*)(?:export\s+)?(?:default\s+)?(?:async\s+)?(?:function\*?|func|fn|def|sub)\s+(?:\([^)]*\)\s*)?(?P<name>[A-Za-z_$][\w$]*)")
ARROW_RE = re.compile(r"^(?P<indent>\s*)(?:export\s+)?(?:const|let|var)\s+(?P<name>[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=>")
METHOD_RE = re.compile(r"^(?P<indent>\s+)(?:(?:public|private|protected|internal|static|async|override|virtual|abstract|final|readonly|get|set|synchronized)\s+)*(?:[\w<>\[\],.?]+\s+)?(?P<name>[A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\([^;]*$")
PS_FUNC = re.compile(r"^(?P<indent>\s*)function\s+(?P<name>[\w-]+)", re.I)
KEYWORDS = {"if", "for", "while", "switch", "catch", "return", "else", "do", "try", "using", "lock", "foreach", "new", "throw", "await", "typeof", "sizeof", "with", "when", "match", "elif"}


@dataclass
class Symbol:
    name: str
    kind: str
    start: int
    end: int
    parent: str = ""

    @property
    def qualified(self) -> str:
        return f"{self.parent}.{self.name}" if self.parent else self.name


def _python(text: str) -> List[Symbol]:
    tree = ast.parse(text)
    out: List[Symbol] = []

    def visit(node: ast.AST, parent: str) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                start = min([child.lineno] + [d.lineno for d in getattr(child, "decorator_list", [])])
                kind = "class" if isinstance(child, ast.ClassDef) else ("method" if parent else "function")
                out.append(Symbol(child.name, kind, start, getattr(child, "end_lineno", child.lineno) or child.lineno, parent))
                visit(child, f"{parent}.{child.name}" if parent else child.name)

    visit(tree, "")
    return out


def _block_end(lines: List[str], start: int) -> int:
    depth = 0
    seen = False
    quote = ""
    for i in range(start, len(lines)):
        line = lines[i]
        j = 0
        while j < len(line):
            ch = line[j]
            if quote:
                if ch == "\\":
                    j += 2
                    continue
                if ch == quote:
                    quote = ""
            elif line.startswith("//", j):
                break
            elif ch in ("'", '"', "`"):
                quote = ch
            elif ch == "{":
                depth += 1
                seen = True
            elif ch == "}":
                depth -= 1
                if seen and depth == 0:
                    return i + 1
            j += 1
        if quote in ("'", '"'):
            quote = ""
        if not seen and i > start + 3 and line.rstrip().endswith(";"):
            return i + 1
    return len(lines) if seen else start + 1


def _brace(text: str, ext: str) -> List[Symbol]:
    lines = text.split("\n")
    out: List[Symbol] = []
    stack: List[Symbol] = []
    for i, line in enumerate(lines):
        while stack and i + 1 > stack[-1].end:
            stack.pop()
        match = CLASS_RE.match(line)
        kind = "class"
        if not match:
            match = FUNC_RE.match(line) or ARROW_RE.match(line) or (PS_FUNC.match(line) if ext in ("ps1", "psm1") else None)
            kind = "function"
        if not match and stack and stack[-1].kind == "class":
            match = METHOD_RE.match(line)
            kind = "method"
            if match and match.group("name") in KEYWORDS:
                match = None
        if not match:
            continue
        end = _block_end(lines, i)
        parent = stack[-1].qualified if stack else ""
        if kind == "function" and parent:
            kind = "method"
        sym = Symbol(match.group("name"), kind, i + 1, end, parent)
        out.append(sym)
        if kind == "class" and end > i + 1:
            stack.append(sym)
    return out


def outline(path: Path) -> List[Symbol]:
    text = path.read_text(encoding="utf-8", errors="replace")
    ext = path.suffix.lower().lstrip(".")
    if ext in ("py", "pyi"):
        try:
            return _python(text)
        except SyntaxError:
            return []
    if ext in BRACE_EXT:
        return _brace(text, ext)
    return []


def find(path: Path, name: str) -> List[Symbol]:
    symbols = outline(path)
    exact = [s for s in symbols if s.qualified == name]
    if exact:
        return exact
    tail = [s for s in symbols if s.qualified.endswith("." + name) or s.name == name]
    return tail


def source(path: Path, symbol: Symbol) -> List[str]:
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    return lines[symbol.start - 1:symbol.end]


def identifiers(lines: List[str]) -> List[str]:
    seen: List[str] = []
    for match in re.finditer(r"\b([A-Z][A-Za-z0-9_]+)(?:\.([a-z_][A-Za-z0-9_]*))?|\b([a-z_][A-Za-z0-9_]*)\s*\(", "\n".join(lines)):
        token = match.group(1) or match.group(3)
        if token and token not in KEYWORDS and token not in seen:
            seen.append(token)
    return seen


def resolve(root: Path, rel: str) -> Optional[Path]:
    candidate = (root / rel).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError:
        return None
    return candidate if candidate.is_file() else None
