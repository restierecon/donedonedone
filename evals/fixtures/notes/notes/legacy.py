import json
import os


def old_export(notes):
    out = []
    for note in notes:
        out.append(note)
    return out


def _never_called():
    return os.sep
