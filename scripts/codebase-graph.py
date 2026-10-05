#!/usr/bin/env python3
import os
import sys

sys.dont_write_bytecode = True
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from codemap.cli import main

if __name__ == "__main__":
    main()
