#!/usr/bin/env python3
"""Derive provisional names for Swift code addresses from metadata.

Two structures point straight at code:

  * the context descriptor access function (descriptor + 12), which materialises
    the metadata for a struct or enum
  * protocol witness table entries, where slot k implements a requirement of a
    protocol that the type conforms to

Witness tables are encoded differently across builds, so both a four-byte
relative form and an eight-byte absolute form are probed and whichever lands
more entries inside __text is kept for that table.

Protocol names do not survive the conformance descriptor with the current
parser, so witness entries are labelled by the conforming type and their slot
index, which is still enough to navigate from a type to its bodies.

Usage:
    python3 tools/swift_names.py /tmp/sundaykeys-arm64 /tmp/swift-meta.json \
        --out swift-names.tsv
"""

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from macho import MachO

ALLOWED = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$")


def sanitise(text):
    name = "".join(char if char in ALLOWED else "_" for char in text)
    if not name:
        return "T_"
    return name if name[0] not in "0123456789" else "T_" + name


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("metadata")
    parser.add_argument("--out", default="swift-names.tsv")
    parser.add_argument("--max-witness", type=int, default=48)
    args = parser.parse_args(argv)

    image = MachO(args.binary)
    meta = json.load(open(args.metadata, encoding="utf-8"))
    text_addr, text_size = image.text()
    text_end = text_addr + text_size

    def in_text(addr):
        return addr is not None and text_addr <= addr < text_end

    types = {record["addr"]: record for record in meta["types"]}
    names = {}
    accessors = 0
    witnesses = 0

    for record in meta["types"]:
        descriptor = record["addr"]
        offset = image.read_i32(descriptor + 12)
        if offset is None:
            continue
        target = descriptor + 12 + offset
        if in_text(target):
            names.setdefault(
                target,
                sanitise("%s_%s_accessor" % (record["module"] or "M", record["name"])),
            )
            accessors += 1

    def relative_entries(table):
        entries = []
        for index in range(1, args.max_witness + 1):
            offset = image.read_i32(table + index * 4)
            if offset is None:
                break
            entries.append((index, table + index * 4 + offset))
        return entries

    def absolute_entries(table):
        entries = []
        for index in range(1, args.max_witness + 1):
            offset = image.addr_to_offset(table + index * 8)
            if offset is None:
                break
            value = struct.unpack_from("<Q", image.data, offset)[0]
            value &= ~0x8000000000000000
            entries.append((index, value))
        return entries

    for conformance in meta["conformances"]:
        table = conformance.get("wt")
        record = types.get(conformance["type_addr"])
        if not table or not record:
            continue
        prefix = sanitise("%s_%s" % (record["module"] or "M", record["name"]))
        relative = relative_entries(table)
        absolute = absolute_entries(table)
        relative_hits = sum(1 for _i, target in relative if in_text(target))
        absolute_hits = sum(1 for _i, target in absolute if in_text(target))
        chosen = relative if relative_hits >= absolute_hits else absolute
        for index, target in chosen:
            if in_text(target):
                names.setdefault(target, "%s_witness%d" % (prefix, index))
                witnesses += 1

    with open(args.out, "w", encoding="utf-8") as handle:
        for address, name in sorted(names.items()):
            handle.write("%s\t%s\n" % (hex(address), name))

    unique_accessor = sum(1 for name in names.values() if name.endswith("_accessor"))
    unique_witness = len(names) - unique_accessor
    print(
        "named %d addresses (accessor %d, witness %d)"
        % (len(names), unique_accessor, unique_witness)
    )
    print("wrote %s" % args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
