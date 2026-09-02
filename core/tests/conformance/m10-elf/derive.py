#!/usr/bin/env python3
"""core/tests/conformance/m10-elf/derive.py

Two decoders, written independently of `core/kernel/`:

  * an ELF64 reader, so every expectation in run.sh comes OUT OF THE BINARY THE
    HARNESS BUILT rather than out of a literal somebody typed. The entry point,
    the message bytes, the exit status, and the permissions each segment asks
    for are all read from prog.elf; change prog.c and the expectations change
    with it. **This is the difference between testing a loader and testing a
    memory of what a loader once did.**

  * a page-table walker that can span SEVERAL dumped regions of guest physical
    memory. m8's and m9's walkers take one `xp` at CR3 and refuse to follow a
    pointer outside it, deliberately -- at M8 and M9 every table was inside the
    six contiguous frames `vmInit` took. M10 adds a page table that came from
    the allocator at run time and is nowhere near them, so the walker here takes
    a LIST of (base, data) blocks and still refuses to follow a pointer outside
    all of them. Falling off the end of the data must never look like an
    unmapped page.

WHAT THIS FILE ENCODES, in one sentence: a loaded program's pages carry exactly
the permissions its own `p_flags` asked for -- PF_X without PF_W and PF_W
without PF_X -- at exactly the virtual addresses its own `p_vaddr`s named, and
nothing else in the address space becomes reachable from ring 3 while it runs.
"""

import re
import sys

# Must match core/kernel/vm.dart. run.sh asserts these against the source rather
# than trusting the copy. HAND-EDITED, deliberately: this is the second entry in
# a double-entry pair, so deriving it from vm.dart would delete the check. Moved
# for ADR-0189 (the driver picks the mode), which took vmFineBytes 4MiB -> 32MiB,
# vmMapBytes 128MiB -> 256MiB and vmFrameCount 6 -> 20 so a driver-reported mode
# larger than 128MiB of aperture can be mapped.
PAGE_BYTES = 4096
BIG_BYTES = 2097152
FINE_BYTES = 33554432
LOW_BYTES = 1048576
MAP_BYTES = 268435456
PCI_BASE = 0xC0000000
PCI_END = 0x100000000
FRAME_COUNT = 20

PROG_BASE = 0x10000000
PROG_END = 0x10200000
PROG_PAGES = 512
PROG_PD_INDEX = 128
PROG_STACK_PAGE = 0x101FF000
PROG_STACK_TOP = 0x10200000

PRESENT = 1 << 0
WRITABLE = 1 << 1
USER = 1 << 2
HUGE = 1 << 7
NX = 1 << 63
ADDR_MASK = 0x000FFFFFFFFFF000

# ELF64, from the System V gABI. The same offsets core/kernel/elf.dart names as
# constants; run.sh checks the two lists against each other.
ET_EXEC = 2
EM_X86_64 = 0x3E
PT_LOAD = 1
PT_DYNAMIC = 2
PT_INTERP = 3
PF_X = 1
PF_W = 2
PF_R = 4


# ---------------------------------------------------------------------------
# The ELF file.
# ---------------------------------------------------------------------------

class Elf:
    """Just enough ELF64 to derive what the kernel should have done.

    Deliberately NOT a call to `readelf`: the point is a second implementation
    of the same decode the kernel performs, so that the two agreeing is
    evidence. `readelf` is used elsewhere in run.sh for the things this does not
    do.
    """

    def __init__(self, blob):
        self.blob = blob
        if blob[0:4] != b"\x7fELF":
            raise ValueError("not an ELF file")
        self.ei_class = blob[4]
        self.ei_data = blob[5]
        self.ei_version = blob[6]
        self.e_type = int.from_bytes(blob[16:18], "little")
        self.e_machine = int.from_bytes(blob[18:20], "little")
        self.e_entry = int.from_bytes(blob[24:32], "little")
        self.e_phoff = int.from_bytes(blob[32:40], "little")
        self.e_shoff = int.from_bytes(blob[40:48], "little")
        self.e_phentsize = int.from_bytes(blob[54:56], "little")
        self.e_phnum = int.from_bytes(blob[56:58], "little")
        self.e_shentsize = int.from_bytes(blob[58:60], "little")
        self.e_shnum = int.from_bytes(blob[60:62], "little")
        self.e_shstrndx = int.from_bytes(blob[62:64], "little")
        self.phdrs = []
        for i in range(self.e_phnum):
            o = self.e_phoff + i * self.e_phentsize
            p = blob[o:o + self.e_phentsize]
            self.phdrs.append({
                "type": int.from_bytes(p[0:4], "little"),
                "flags": int.from_bytes(p[4:8], "little"),
                "offset": int.from_bytes(p[8:16], "little"),
                "vaddr": int.from_bytes(p[16:24], "little"),
                "filesz": int.from_bytes(p[32:40], "little"),
                "memsz": int.from_bytes(p[40:48], "little"),
                "align": int.from_bytes(p[48:56], "little"),
            })
        self._symbols = None

    @property
    def loads(self):
        return [p for p in self.phdrs if p["type"] == PT_LOAD]

    def pages(self):
        """{virtual page -> (writable, executable)} for every page a correct
        loader must map, derived from p_vaddr, p_memsz and p_flags alone."""
        out = {}
        for p in self.loads:
            lo = p["vaddr"] & ~(PAGE_BYTES - 1)
            hi = (p["vaddr"] + p["memsz"] + PAGE_BYTES - 1) & ~(PAGE_BYTES - 1)
            for a in range(lo, hi, PAGE_BYTES):
                out[a] = (bool(p["flags"] & PF_W), bool(p["flags"] & PF_X))
        return out

    def file_offset(self, vaddr):
        for p in self.loads:
            if p["vaddr"] <= vaddr < p["vaddr"] + p["filesz"]:
                return p["offset"] + (vaddr - p["vaddr"])
        return None

    def read(self, vaddr, n):
        """`n` bytes at `vaddr`, out of the FILE image -- what the loader must
        have put in memory there."""
        off = self.file_offset(vaddr)
        if off is None:
            return None
        return self.blob[off:off + n]

    # --- the symbol table, so run.sh names a symbol instead of an address ----

    def _sections(self):
        out = []
        for i in range(self.e_shnum):
            o = self.e_shoff + i * self.e_shentsize
            s = self.blob[o:o + self.e_shentsize]
            out.append({
                "name": int.from_bytes(s[0:4], "little"),
                "type": int.from_bytes(s[4:8], "little"),
                "offset": int.from_bytes(s[24:32], "little"),
                "size": int.from_bytes(s[32:40], "little"),
                "link": int.from_bytes(s[40:44], "little"),
                "entsize": int.from_bytes(s[56:64], "little"),
            })
        return out

    def symbols(self):
        if self._symbols is not None:
            return self._symbols
        self._symbols = {}
        secs = self._sections()
        for s in secs:
            if s["type"] != 2:          # SHT_SYMTAB
                continue
            strtab = secs[s["link"]]
            sd = self.blob[strtab["offset"]:strtab["offset"] + strtab["size"]]
            n = s["size"] // s["entsize"]
            for i in range(n):
                o = s["offset"] + i * s["entsize"]
                e = self.blob[o:o + s["entsize"]]
                nameoff = int.from_bytes(e[0:4], "little")
                end = sd.index(b"\0", nameoff)
                name = sd[nameoff:end].decode("ascii", "replace")
                if name:
                    self._symbols[name] = (
                        int.from_bytes(e[8:16], "little"),   # st_value
                        int.from_bytes(e[16:24], "little"),  # st_size
                    )
        return self._symbols

    def sym(self, name):
        v = self.symbols().get(name)
        if v is None:
            raise KeyError("prog.elf has no symbol %r" % name)
        return v

    def sym_bytes(self, name):
        value, size = self.sym(name)
        return self.read(value, size)

    def sym_u64(self, name):
        b = self.sym_bytes(name)
        if b is None or len(b) < 8:
            raise ValueError("%s is not eight readable bytes in the file" % name)
        return int.from_bytes(b[0:8], "little")

    def sym_cstr(self, name):
        b = self.sym_bytes(name)
        if b is None:
            raise ValueError("%s has no file-backed bytes" % name)
        i = b.find(b"\0")
        return b if i < 0 else b[:i]


# ---------------------------------------------------------------------------
# Monitor parsing. Same shape as m9's, because the monitor's output is the
# monitor's output; the walker below is what differs.
# ---------------------------------------------------------------------------

def parse_registers(monitor_text):
    out = {}
    for name, value in re.findall(r"\b(CR[0-9])=([0-9a-fA-F]+)", monitor_text):
        out[name] = int(value, 16)
    m = re.search(r"\bCPL=(\d)", monitor_text)
    if m:
        out["CPL"] = int(m.group(1))
    m = re.search(r"^RIP=([0-9a-fA-F]{16}) ", monitor_text, re.M)
    if m:
        out["RIP"] = int(m.group(1), 16)
    for reg in ("CS", "SS"):
        m = re.search(r"^%s =([0-9a-fA-F]{4}) " % reg, monitor_text, re.M)
        if m:
            out[reg] = int(m.group(1), 16)
    m = re.search(r"^TR =([0-9a-fA-F]{4}) ([0-9a-fA-F]{16})", monitor_text, re.M)
    if m:
        out["TR"] = int(m.group(1), 16)
        out["TR_BASE"] = int(m.group(2), 16)
    return out


def parse_xp(monitor_text, command):
    """Every quadword from ONE `=== <command> ===` block, in order."""
    want = "=== %s" % command
    for block in monitor_text.split("=== "):
        if not ("=== " + block).startswith(want):
            continue
        qwords = []
        for line in block.splitlines():
            if ":" not in line:
                continue
            for token in line.split(":", 1)[1].split():
                if token.startswith("0x"):
                    qwords.append(int(token, 16))
        return qwords
    raise LookupError("no `%s` block in the monitor capture -- the dump this "
                      "check needs was never taken" % command)


# ---------------------------------------------------------------------------
# The page tables, over SEVERAL dumped regions.
# ---------------------------------------------------------------------------

class Memory:
    """Guest physical memory, as however many `xp` dumps were taken.

    A read outside every block RAISES. That is the same rule m8's and m9's
    walkers have and it matters more here: this harness dumps two disjoint
    regions, and a walker that returned zeroes for the gap between them would
    report a correctly-mapped program as unmapped -- or, worse, an
    incorrectly-mapped one as fine.
    """

    def __init__(self):
        self.blocks = []

    def add(self, base, qwords):
        self.blocks.append((base, qwords))
        return self

    def qword(self, phys):
        for base, qwords in self.blocks:
            off = phys - base
            if 0 <= off < len(qwords) * 8:
                if off % 8:
                    raise ValueError("unaligned read at 0x%X" % phys)
                return qwords[off // 8]
        raise LookupError(
            "0x%X is outside every dumped region (%s) -- the walk needs memory "
            "this harness never asked QEMU for"
            % (phys, ", ".join("[0x%X, 0x%X)" % (b, b + len(q) * 8)
                               for b, q in self.blocks)))

    @property
    def span(self):
        return sum(len(q) * 8 for _, q in self.blocks)


class PageTables:
    def __init__(self, cr3, memory):
        self.cr3 = cr3
        self.mem = memory

    def entry(self, table_phys, index):
        return self.mem.qword(table_phys + index * 8)

    def effective(self, va):
        """(writable, executable, user, page_size) for `va`, or None.

        The AND of every level for W and U; NX is a veto and combines the other
        way. Written out rather than shared with m8/m9, for their header's
        reason: two implementations that agree are evidence, one that agrees
        with itself is not.
        """
        w = True
        u = True
        nx = False
        e = self.entry(self.cr3, (va >> 39) & 511)
        if not e & PRESENT:
            return None
        w &= bool(e & WRITABLE); u &= bool(e & USER); nx |= bool(e & NX)
        e = self.entry(e & ADDR_MASK, (va >> 30) & 511)
        if not e & PRESENT:
            return None
        w &= bool(e & WRITABLE); u &= bool(e & USER); nx |= bool(e & NX)
        e2 = self.entry(e & ADDR_MASK, (va >> 21) & 511)
        if not e2 & PRESENT:
            return None
        w &= bool(e2 & WRITABLE); u &= bool(e2 & USER); nx |= bool(e2 & NX)
        if e2 & HUGE:
            return (w, not nx, u, BIG_BYTES)
        e1 = self.entry(e2 & ADDR_MASK, (va >> 12) & 511)
        if not e1 & PRESENT:
            return None
        w &= bool(e1 & WRITABLE); u &= bool(e1 & USER); nx |= bool(e1 & NX)
        return (w, not nx, u, PAGE_BYTES)

    def leaf(self, va):
        """The raw leaf entry for `va`, or None. Used for the PHYSICAL address,
        which `effective` deliberately throws away."""
        e = self.entry(self.cr3, (va >> 39) & 511)
        if not e & PRESENT:
            return None
        e = self.entry(e & ADDR_MASK, (va >> 30) & 511)
        if not e & PRESENT:
            return None
        e2 = self.entry(e & ADDR_MASK, (va >> 21) & 511)
        if not e2 & PRESENT:
            return None
        if e2 & HUGE:
            return e2
        e1 = self.entry(e2 & ADDR_MASK, (va >> 12) & 511)
        if not e1 & PRESENT:
            return None
        return e1

    def user_pages(self, lo, hi, step=PAGE_BYTES):
        found = []
        a = lo
        while a < hi:
            got = self.effective(a)
            if got is not None and got[2]:
                found.append(a)
            a += step
        return found

    def mapped_pages(self, lo, hi, step=PAGE_BYTES):
        found = []
        a = lo
        while a < hi:
            if self.effective(a) is not None:
                found.append(a)
            a += step
        return found


def check_supervisor(tables, lo, hi, label, step=PAGE_BYTES):
    """Every page in `[lo, hi)` must be present and NOT user-accessible."""
    fails = []
    bad = []
    a = lo
    while a < hi:
        got = tables.effective(a)
        if got is None:
            fails.append("%s: 0x%X is not mapped at all" % (label, a))
        elif got[2]:
            bad.append(a)
        a += step
    if bad:
        fails.append("%s: %d page(s) are USER-ACCESSIBLE, first at 0x%X. Ring 3 "
                     "can read kernel memory." % (label, len(bad), bad[0]))
    return fails


def check_program_pages(tables, elf, stack_page=PROG_STACK_PAGE):
    """THE CENTRAL CHECK: the live tables match the ELF's own p_flags.

    Every page the file says to map must be present, user-accessible, and carry
    exactly the W and X the segment's p_flags asked for -- PF_X without PF_W and
    PF_W without PF_X, because this kernel refuses W+X. The stack page is
    expected too, and it is expected writable and NOT executable; nothing in the
    ELF asks for it, which is why it is named separately here rather than
    derived.

    Nothing else in the window may be mapped at all: the count is exact, so a
    loader that mapped a spare page would fail this and not merely be untidy.
    """
    fails = []
    want = elf.pages()
    want[stack_page] = (True, False)
    got = set(tables.mapped_pages(PROG_BASE, PROG_END))
    if got != set(want):
        fails.append("the mapped pages of the program window are %s, but the "
                     "ELF's program headers (plus one stack page) say they "
                     "should be %s"
                     % (sorted(hex(a) for a in got), sorted(hex(a) for a in want)))
    for va in sorted(set(want) & got):
        w, x, u, size = tables.effective(va)
        ww, wx = want[va]
        if size != PAGE_BYTES:
            fails.append("0x%X is part of a %d-byte page, expected 4096" % (va, size))
        if not u:
            fails.append("0x%X is NOT user-accessible; ring 3 cannot reach the "
                         "program it is about to run" % va)
        if (w, x) != (ww, wx):
            fails.append("0x%X is W=%d X=%d, but p_flags asks for W=%d X=%d"
                         % (va, w, x, ww, wx))
        if w and x:
            fails.append("0x%X is BOTH writable and executable" % va)
    return fails
