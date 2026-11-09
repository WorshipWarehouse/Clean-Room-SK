#!/usr/bin/env python3
"""Build a caller to callee graph from a decompiled corpus.

Reads the chunk format produced by tools/decompile_all.sh, where every body is
introduced by a header line such as:

    ### 1000026a8 -> FUN_1000026a8 @ 1000026a8

A callee is counted when the body names it as a call target and that name is
present in the supplied name table, so unnamed addresses and indirect calls are
reported as unresolved rather than silently dropped. Repeated calls from one
body are counted once per occurrence.

This is the analysis half of the step described in section 20 of the analysis
document: run it against a corpus decompiled from the renamed project and the
edges carry real names, which is what makes caller to callee direction visible
across modules.

Usage:

    python3 tools/callgraph.py --corpus /tmp/sk-named \\
        --names /tmp/sk-full/functions-named.tsv --out /tmp/callgraph.tsv

Output is a two column TSV of caller and callee names, plus a JSON summary on
stdout.
"""

import argparse
import collections
import glob
import json
import os
import re
import sys

HEADER = re.compile(r"^###\s+\S+\s+->\s+(\S+)\s+@\s+(\S+)\s*$")
CALL = re.compile(r"([A-Za-z_$][A-Za-z0-9_$]{2,})\s*\(")


def load_names(path):
    """Read the address, name, size table and keep the real symbols only."""
    names = set()
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            name = parts[1]
            if name.startswith(("FUN_", "thunk_FUN_")):
                continue
            names.add(name)
    return names


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, help="directory of chunk .c files")
    parser.add_argument("--names", required=True, help="TSV of address, name, size")
    parser.add_argument("--out", required=True, help="edge list to write")
    args = parser.parse_args(argv)

    names = load_names(args.names)
    chunks = sorted(glob.glob(os.path.join(args.corpus, "*.c")))
    if not chunks:
        print("no chunk files under %s" % args.corpus, file=sys.stderr)
        return 2

    bodies = 0
    edges = 0
    bodies_with_calls = 0
    unresolved = 0
    callees = collections.Counter()

    with open(args.out, "w", encoding="utf-8") as out:
        for path in chunks:
            caller = None
            pending = []

            def emit(current, items):
                nonlocal edges, bodies_with_calls
                for callee in items:
                    out.write("%s\t%s\n" % (current, callee))
                    callees[callee] += 1
                edges += len(items)
                if items:
                    bodies_with_calls += 1

            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    header = HEADER.match(line)
                    if header:
                        if caller is not None:
                            emit(caller, pending)
                        caller = header.group(1)
                        pending = []
                        bodies += 1
                        continue
                    if caller is None:
                        continue
                    for token in CALL.findall(line):
                        if token in names and token != caller:
                            pending.append(token)
                        else:
                            unresolved += 1
            if caller is not None:
                emit(caller, pending)

    summary = {
        "chunks": len(chunks),
        "bodies": bodies,
        "edges": edges,
        "bodies_with_named_calls": bodies_with_calls,
        "unresolved_call_tokens": unresolved,
        "distinct_callees": len(callees),
    }
    json.dump(summary, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
