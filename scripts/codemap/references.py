import re

from codemap.imports import PARSED_EXT
from codemap.repo import extension, is_doc

TOKEN = re.compile(r"[\w.~/@+-]*[\w-]\.[A-Za-z0-9]{1,8}(?![\w-])")


def edge_kind(source):
    if is_doc(source) or extension(source) in PARSED_EXT:
        return "mention"
    return "reference"


def mentions(path, text, index):
    found = {}
    for match in TOKEN.finditer(text):
        token = match.group(0).rstrip(".")
        if "/" not in token and token.count(".") > 2:
            continue
        target = index.mention(token, path)
        if target and target != path and target not in found:
            found[target] = text.count("\n", 0, match.start()) + 1
    return found
