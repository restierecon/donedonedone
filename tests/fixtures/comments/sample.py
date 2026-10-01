#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Module doc."""
import os  # noqa: F401
x = "a # not a comment"
y = 'it' 's'  # trailing
def f(a):
    """Doc
    more doc
    """
    return call(
        """argument string # not a docstring""",
    )
# full line
z = 1  # type: ignore[attr]
s = """
# inside a string
"""
