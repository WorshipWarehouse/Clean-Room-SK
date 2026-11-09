#!/usr/bin/env python3
"""Summarise decompiled chunk output.

Usage:
    python3 tools/inventory.py <outdir>

Reports how much of the chunked decompilation is done, how many functions carry
meaningful symbol names versus Ghidra generated ones, and where the largest
functions are, which is where the interesting behaviour usually lives.
"""

import argparse
import re
import sys
from pathlib import Path

HEADER = re.compile(r"^### (\S+) -> (\S+) @ (\S+)")
BODY = re.compile(r"^Function body|^$")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("outdir")
    parser.add_argument("--top", type=int, default=15)
    args = parser.parse_args(argv)

    root = Path(args.outdir)
    chunks = sorted((root / "chunks").glob("batch-*.c"))
    if not chunks:
        print("no chunk output in %s" % (root / "chunks"))
        return 1

    functions = 0
    lines = 0
    named = 0
    unnamed = 0
    largest = []

    for chunk in chunks:
        text = chunk.read_text(encoding="utf-8", errors="replace")
        lines += text.count("\n")
        current = None
        size = 0
        for line in text.splitlines():
            match = HEADER.match(line)
            if match:
                if current:
                    largest.append((size, current))
                current = match.group(2)
                size = 0
                functions += 1
                if current.startswith("FUN_") or current.startswith("thunk_FUN_"):
                    unnamed += 1
                else:
                    named += 1
                continue
            if current:
                size += 1
        if current:
            largest.append((size, current))

    print("chunks %d  functions %d  lines %d" % (len(chunks), functions, lines))
    if functions:
        print("named %d (%.1f%%)  ghidra-generated %d (%.1f%%)"
              % (named, 100.0 * named / functions, unnamed, 100.0 * unnamed / functions))
    print("largest functions:")
    for size, name in sorted(largest, reverse=True)[: args.top]:
        print("  %6d lines  %s" % (size, name))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
