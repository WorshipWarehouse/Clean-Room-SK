#!/usr/bin/env python3
"""Resolve C-string literals to the code addresses that reference them.

Usage:
    python3 tools/literal_refs.py /tmp/sundaykeys-arm64 --out refs.tsv
    python3 tools/literal_refs.py /tmp/sundaykeys-arm64 --filter 'pusher|channel' --limit 40

The output is a TSV of string<TAB>comma-separated code addresses, which can be
fed straight into tools/decompile.sh to read the surrounding functions.
"""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from macho import MachO


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", help="thin arm64 Mach-O slice")
    parser.add_argument("--out", help="write string<TAB>addresses TSV here")
    parser.add_argument("--filter", help="regex applied to the recovered strings")
    parser.add_argument("--limit", type=int, default=40, help="how many filtered strings to print")
    parser.add_argument("--window", type=int, default=24, help="instructions to scan after each ADRP")
    args = parser.parse_args(argv)

    image = MachO(args.binary)
    strings = image.strings()
    slots = image.literal_slots(strings)
    refs = image.code_string_refs(strings=strings, slots=slots, window=args.window)

    print("strings %d  slots %d  referenced %d" % (len(strings), len(slots), len(refs)))

    if args.filter:
        pattern = re.compile(args.filter, re.IGNORECASE)
        selected = sorted(text for text in refs if pattern.search(text))
        for text in selected[: args.limit]:
            print("  %-52s %s" % (text[:52], ",".join(hex(x) for x in sorted(refs[text])[:3])))
        print("filtered matches %d" % len(selected))

    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            for text, addrs in sorted(refs.items()):
                handle.write("%s\t%s\n" % (text, ",".join(hex(x) for x in sorted(addrs))))
        print("wrote %s" % args.out)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
