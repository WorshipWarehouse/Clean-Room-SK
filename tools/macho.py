"""Mach-O helpers for the Sunday Keys clean-room analysis.

Only what the analysis needs: segment and section geometry, a virtual-address
to C-string map, and chained-fixup aware resolution of the data slots that hold
string literal pointers.

The chained-fixup part matters. Rebase targets in this binary are stored as
offsets from the image base rather than as absolute addresses, so a scan that
accepts only absolute values finds almost nothing: in the 2.5.2 arm64 slice it
recovers 11 literal slots instead of 32,510.
"""

import struct

LC_SEGMENT_64 = 0x19
TEXT_SECTION = "__text"
CHAINED_FIXUPS_HIGH_BIT = 0x8000000000000000


class MachO:
    """A thin (non-fat) 64-bit little-endian Mach-O image."""

    def __init__(self, path=None, data=None):
        if data is None:
            with open(path, "rb") as handle:
                data = handle.read()
        self.data = data
        magic, _cputype, _cpusubtype, _filetype, ncmds, _sizeofcmds, _flags, _res = struct.unpack_from(
            "<IiiIIIII", data, 0
        )
        if magic != 0xFEEDFACF:
            raise ValueError("expected a thin 64-bit little-endian Mach-O image")
        self.ncmds = ncmds
        self.segments = []
        self.sections = {}
        offset = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, offset)
            if cmd == LC_SEGMENT_64:
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, offset + 24)
                self.segments.append((vmaddr, vmsize, fileoff, filesize))
                nsects = struct.unpack_from("<I", data, offset + 64)[0]
                walker = offset + 72
                for _i in range(nsects):
                    name = data[walker : walker + 16].split(b"\0")[0].decode("ascii", "replace")
                    addr, size = struct.unpack_from("<QQ", data, walker + 32)
                    self.sections.setdefault(name, []).append((addr, size))
                    walker += 80
            offset += cmdsize

    @property
    def image_base(self):
        return min(segment[0] for segment in self.segments)

    def text(self):
        addr, size = self.sections[TEXT_SECTION][0]
        return addr, size

    def addr_to_offset(self, addr):
        for vmaddr, _vmsize, fileoff, filesize in self.segments:
            if vmaddr <= addr < vmaddr + filesize:
                return fileoff + (addr - vmaddr)
        return None

    def read_i32(self, addr):
        offset = self.addr_to_offset(addr)
        if offset is None:
            return None
        return struct.unpack_from("<i", self.data, offset)[0]

    def read_u32(self, addr):
        offset = self.addr_to_offset(addr)
        if offset is None:
            return None
        return struct.unpack_from("<I", self.data, offset)[0]

    def read_cstring(self, addr):
        """Return the C string starting at addr, or None if it is not printable."""
        offset = self.addr_to_offset(addr)
        if offset is None:
            return None
        end = self.data.find(b"\0", offset)
        if end < 0:
            return None
        try:
            text = self.data[offset:end].decode("ascii")
        except UnicodeDecodeError:
            return None
        return text or None

    def relative(self, addr, indirectable=True):
        """Resolve a 32-bit Swift relative pointer stored at addr.

        Swift uses relative pointers whose target is computed from the field
        address. When the low bit is set the pointer is indirect: the field
        points at another 32-bit relative pointer to follow.
        """
        value = self.read_i32(addr)
        if value is None:
            return None
        if indirectable and value & 1:
            inner = addr + (value & ~1)
            value = self.read_i32(inner)
            if value is None:
                return None
            return inner + value
        return addr + value

    def strings(self, min_len=4):
        """Map every printable NUL-terminated run to its virtual address."""
        table = {}
        for vmaddr, _vmsize, fileoff, filesize in self.segments:
            buf = self.data[fileoff : fileoff + filesize]
            index, size = 0, len(buf)
            while index < size:
                end = index
                while end < size and 32 <= buf[end] < 127:
                    end += 1
                if end - index >= min_len and (end >= size or buf[end] == 0):
                    table[vmaddr + index] = buf[index:end].decode("ascii")
                index = end + 1
        return table

    def literal_slots(self, strings=None):
        """Map slot address to the string address it references.

        Accepts absolute pointers, pointers carrying the chained-fixup high bit,
        and image-relative rebase offsets in both 36-bit and 32-bit form.
        """
        strings = self.strings() if strings is None else strings
        base = self.image_base
        text_addr, text_size = self.text()
        slots = {}
        for vmaddr, _vmsize, fileoff, filesize in self.segments:
            buf = self.data[fileoff : fileoff + filesize]
            for offset in range(0, max(0, len(buf) - 8), 8):
                slot_addr = vmaddr + offset
                # Skip code, but keep the rest of __TEXT: the literal pointer
                # tables live in __TEXT,__const and friends.
                if text_addr <= slot_addr < text_addr + text_size:
                    continue
                value = struct.unpack_from("<Q", buf, offset)[0]
                candidates = (
                    value,
                    value & 0xFFFFFFFFF,
                    (value & 0xFFFFFFFFF) + base,
                    value & 0xFFFFFFFF,
                    (value & 0xFFFFFFFF) + base,
                    value & ~CHAINED_FIXUPS_HIGH_BIT,
                )
                for candidate in candidates:
                    if candidate in strings:
                        slots[slot_addr] = candidate
                        break
        return slots

    def code_string_refs(self, strings=None, slots=None, window=24):
        """Map string text to the code addresses that materialise it."""
        strings = self.strings() if strings is None else strings
        slots = self.literal_slots(strings) if slots is None else slots
        text_addr, text_size = self.text()
        text_off = self.addr_to_offset(text_addr)
        words = text_size // 4
        refs = {}
        for index in range(words):
            word = struct.unpack_from("<I", self.data, text_off + index * 4)[0]
            if (word & 0x9F000000) != 0x90000000:
                continue
            imm = (((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 3)
            if imm & (1 << 20):
                imm -= 1 << 21
            page = (text_addr + index * 4) + (imm << 12)
            reg = word & 0x1F
            for step in range(1, window):
                if index + step >= words:
                    break
                follower = struct.unpack_from("<I", self.data, text_off + (index + step) * 4)[0]
                target = None
                if (follower & 0xFFC00000) == 0xF9400000 and ((follower >> 5) & 0x1F) == reg:
                    target = page + ((follower >> 10) & 0xFFF) * 8
                elif (follower & 0xFFC00000) == 0x91000000 and ((follower >> 5) & 0x1F) == reg:
                    delta = (follower >> 10) & 0xFFF
                    if (follower >> 22) & 1:
                        delta <<= 12
                    target = page + delta
                elif (follower & 0x9F000000) == 0x90000000:
                    break
                if target is not None and target in slots:
                    refs.setdefault(strings[slots[target]], set()).add(text_addr + (index + step) * 4)
                    break
        return refs

    def resolve_constant(self, value, strings=None):
        """Resolve a constant seen in decompiled output back to a C string."""
        strings = self.strings() if strings is None else strings
        for candidate in (
            value,
            value & 0xFFFFFFFFF,
            (value & 0xFFFFFFFFF) + self.image_base,
            value & 0xFFFFFFFF,
            (value & 0xFFFFFFFF) + self.image_base,
            value & ~CHAINED_FIXUPS_HIGH_BIT,
        ):
            if candidate in strings:
                return strings[candidate]
        return None
