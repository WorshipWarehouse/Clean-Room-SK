#!/usr/bin/env python3
"""Recover Swift type metadata from a Mach-O image.

Reads __swift5_types, __swift5_fieldmd and __swift5_proto and emits a JSON
document of types (module, name, kind, stored property names) plus protocol
conformances with their witness table addresses.

Usage:
    python3 tools/swift_metadata.py /tmp/sundaykeys-arm64 --json types.json

Swift 5 ABI layout used here:

  context descriptor   flags u32, parent i32, name i32, access i32,
                       fields i32 (struct/enum) or superclass i32 (class)
  field descriptor     mangled i32, superclass i32, kind u16,
                       record size u16, count u32, records at +16
  field record         name i32, mangled i32 (record size is normally 8)

Relative pointers are computed from the address of the pointer itself. A low
bit set marks an indirect pointer, whose target is another relative pointer.
"""

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from macho import MachO

KINDS = {16: "class", 17: "struct", 18: "enum"}


def is_identifier(text):
    if not text or len(text) > 200:
        return False
    for char in text:
        if not (char.isalnum() or char in "_.$"):
            return False
    return text[0].isalpha() or text[0] == "_"


class SwiftMetadata:
    def __init__(self, image):
        self.image = image
        self.types = []
        self.by_addr = {}
        self.conformances = []

    def _type_entries(self):
        entries = []
        for addr, size in self.image.sections.get("__swift5_types", []):
            for step in range(0, size, 4):
                field = addr + step
                target = self.image.relative(field)
                if target:
                    entries.append(target)
        return entries

    def _parent_of(self, descriptor):
        """Return the immediate parent type name for a context descriptor."""
        parent = self.image.relative(descriptor + 4)
        if not parent:
            return None
        name_offset = self.image.read_i32(parent + 8)
        if name_offset is None:
            return None
        return self.image.read_cstring(parent + 8 + name_offset)

    def read_types(self):
        for descriptor in self._type_entries():
            flags = self.image.read_u32(descriptor)
            if flags is None:
                continue
            kind = flags & 0x1F
            if kind not in KINDS:
                continue
            # The name field is a plain relative pointer, not an indirectable one.
            name_offset = self.image.read_i32(descriptor + 8)
            name = (
                self.image.read_cstring(descriptor + 8 + name_offset)
                if name_offset is not None
                else None
            )
            if not is_identifier(name):
                continue
            parent = self._parent_of(descriptor)
            fields = []
            if kind in (17, 18):
                field_descriptor = self.image.relative(descriptor + 16)
                fields = self._field_names(field_descriptor)
            record = {
                "addr": descriptor,
                "kind": KINDS[kind],
                "module": parent or "",
                "name": name,
                "fields": fields,
            }
            self.types.append(record)
            self.by_addr[descriptor] = record
        return self.types

    def _field_names(self, descriptor):
        if not descriptor:
            return []
        descriptor_offset = self.image.addr_to_offset(descriptor)
        if descriptor_offset is None:
            return []
        record_size = struct.unpack_from("<H", self.image.data, descriptor_offset + 10)[0]
        count = self.image.read_u32(descriptor + 12) or 0
        names = []
        base = descriptor + 16
        # This build reports a 12-byte field record; the field name lives at
        # record + 8 and is a plain relative pointer, never an indirect one.
        stride = record_size if record_size >= 8 else 12
        for index in range(min(count, 512)):
            record = base + index * stride
            name = None
            for delta in (8, 0, 4):
                offset = self.image.read_i32(record + delta)
                if offset is None:
                    continue
                candidate = self.image.read_cstring(record + delta + offset)
                if is_identifier(candidate):
                    name = candidate
                    break
            if name:
                names.append(name)
        return names

    def read_conformances(self):
        for addr, size in self.image.sections.get("__swift5_proto", []):
            for step in range(0, size, 4):
                field = addr + step
                descriptor = self.image.relative(field)
                if not descriptor:
                    continue
                # ProtocolConformanceDescriptor: protocol +0, type +4, witnesses +8
                type_ref = self.image.relative(descriptor + 4)
                witnesses = self.image.relative(descriptor + 8)
                if type_ref not in self.by_addr:
                    continue
                self.conformances.append(
                    {
                        "type_addr": type_ref,
                        "wt": witnesses,
                    }
                )
        return self.conformances

    def document(self):
        return {"types": self.types, "conformances": self.conformances}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", help="thin arm64 Mach-O slice")
    parser.add_argument("--json", dest="json_path", help="write the full document here")
    parser.add_argument("--module", help="only report types from this module")
    parser.add_argument("--limit", type=int, default=25, help="types to print")
    args = parser.parse_args(argv)

    image = MachO(args.binary)
    metadata = SwiftMetadata(image)
    metadata.read_types()
    metadata.read_conformances()

    print("types %d  conformances %d" % (len(metadata.types), len(metadata.conformances)))
    modules = {}
    for record in metadata.types:
        modules[record["module"]] = modules.get(record["module"], 0) + 1
    for module, count in sorted(modules.items(), key=lambda item: -item[1])[:12]:
        print("  %-24s %d" % (module or "<none>", count))

    shown = [r for r in metadata.types if not args.module or r["module"] == args.module]
    for record in shown[: args.limit]:
        print("  %-14s %-34s %s" % (record["module"], record["name"], ",".join(record["fields"][:8])))

    if args.json_path:
        with open(args.json_path, "w", encoding="utf-8") as handle:
            json.dump(metadata.document(), handle)
        print("wrote %s" % args.json_path)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
