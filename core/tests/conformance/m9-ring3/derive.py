#!/usr/bin/env python3
"""core/tests/conformance/m9-ring3/derive.py

Reads the PRIVILEGE STATE of a running oscortex_core kernel out of guest
physical memory and recomputes, from outside, every claim the kernel makes
about it.

WHY THIS FILE EXISTS, AND WHY IT IS NOT `m8-paging/derive.py`
---------------------------------------------------------------------------
m8's walker exists to answer "is this page writable, and is it executable". It
combines RW and NX across the four levels and stops there, because at M8 there
was no third permission: every page in the address space was supervisor-only and
the U/S bit had never been set on anything.

M9's whole subject is that third bit. So this file walks the same tables again
and combines U/S as well -- and it decodes three more structures m8 never had to
look at, because until M9 none of them existed or mattered:

  * **the GDT**, at the base QEMU's own GDTR reports. The DPL of the two user
    descriptors is where CPL 3 comes from; nothing else in the machine can
    produce it. The TSS descriptor's TYPE is also read here, and it is the only
    externally visible evidence that `ltr` ever ran: the CPU turns type 9
    (available) into type 11 (busy) when it loads the task register, and nothing
    else in this kernel writes that byte.
  * **the TSS**, at the base that descriptor names. RSP0 is read out of it and
    required to be a real address inside the kernel image -- the field whose
    absence is a triple fault with no diagnostic.
  * **the IDT**, all 256 gates. Exactly one may have DPL 3. A kernel that gave
    every gate DPL 3 would pass every behavioural test in this harness and would
    have handed ring 3 the whole exception table.

THE RULE THIS FILE ENCODES, in one sentence: while a ring-3 payload is running,
exactly two of the 1024 pages in the 4KiB window are user-accessible and they are
that payload's; at every other moment, none of them are; and no page anywhere in
the address space is both user-accessible and part of the kernel.

Written independently of `core/kernel/vm.dart`'s `vmEffective` and of
`m8-paging/derive.py`, for the reason m8's own header gives: two implementations
that agree are evidence, and one implementation that agrees with itself is not.
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

PRESENT = 1 << 0
WRITABLE = 1 << 1
USER = 1 << 2
HUGE = 1 << 7
NX = 1 << 63
ADDR_MASK = 0x000FFFFFFFFFF000

# A 64-bit TSS, from core/boot/boot.S.
TSS_SIZE = 104
TSS_RSP0_OFF = 4
TSS_IOMAP_OFF = 102


# ---------------------------------------------------------------------------
# Monitor parsing.
# ---------------------------------------------------------------------------

def parse_registers(monitor_text):
    """CR0-CR4, CPL, CS and the descriptor-table registers from `info registers`.

    Parsed by NAME rather than by position, so a QEMU version that adds a
    register does not shift the answer. The three lines that matter here look
    like

        RIP=... RFL=00000202 [-------] CPL=3 II=0 A20=1 SMM=0 HLT=0
        CS =0023 0000000000000000 00000000 0020fb00 DPL=3 CS64 [-RA]
        TR =0028 0000000000123010 00000067 00008900 DPL=0 TSS64-avl
        GDT=     0000000000117000 00000037
        IDT=     0000000000128000 00000fff
    """
    out = {}
    for name, value in re.findall(r"\b(CR[0-9])=([0-9a-fA-F]+)", monitor_text):
        out[name] = int(value, 16)
    m = re.search(r"\bCPL=(\d)", monitor_text)
    if m:
        out["CPL"] = int(m.group(1))
    m = re.search(r"^CS =([0-9a-fA-F]{4}) ", monitor_text, re.M)
    if m:
        out["CS"] = int(m.group(1), 16)
    m = re.search(r"^SS =([0-9a-fA-F]{4}) ", monitor_text, re.M)
    if m:
        out["SS"] = int(m.group(1), 16)
    m = re.search(r"^TR =([0-9a-fA-F]{4}) ([0-9a-fA-F]{16}) ([0-9a-fA-F]{8})",
                  monitor_text, re.M)
    if m:
        out["TR"] = int(m.group(1), 16)
        out["TR_BASE"] = int(m.group(2), 16)
        out["TR_LIMIT"] = int(m.group(3), 16)
    for name in ("GDT", "IDT"):
        m = re.search(r"^%s=\s+([0-9a-fA-F]{16}) ([0-9a-fA-F]{8})" % name,
                      monitor_text, re.M)
        if m:
            out[name + "_BASE"] = int(m.group(1), 16)
            out[name + "_LIMIT"] = int(m.group(2), 16)
    return out


def parse_xp(monitor_text, command):
    """Every quadword from ONE `=== <command> ===` block, in order.

    m8's parser takes any block beginning `xp/`, which is enough when there is a
    single dump. This harness takes four in one boot -- the page tables, the GDT,
    the TSS and the IDT -- so the block is selected by its FULL command line. A
    parser that concatenated them would silently walk the GDT as if it were a
    page table and report "not mapped" for everything.
    """
    # The block header carries the command AS SENT, i.e. with `{addr}` already
    # substituted, so it is matched as a PREFIX including the trailing space --
    # `xp/7gx ` must not match `xp/70gx `.
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
# Descriptors.
# ---------------------------------------------------------------------------

class Descriptor:
    """One 8-byte GDT entry, decoded.

    The x86 segment descriptor is a museum: the base and limit are split across
    five non-adjacent fields, and long mode ignores both of them for code and
    data. What it does NOT ignore -- and what this class exists for -- is the
    access byte at bits 47..40 and the L bit at 53.
    """

    def __init__(self, raw):
        self.raw = raw
        self.access = (raw >> 40) & 0xFF
        self.present = bool(raw & (1 << 47))
        self.dpl = (raw >> 45) & 3
        self.system = not (raw & (1 << 44))   # S=0 means a system descriptor
        self.type = (raw >> 40) & 0xF
        self.accessed = bool(raw & (1 << 40))
        self.long_mode = bool(raw & (1 << 53))
        self.executable = bool(raw & (1 << 43))

    def __repr__(self):
        return ("Descriptor(raw=%016X access=%02X dpl=%d system=%s type=%X "
                "L=%s)" % (self.raw, self.access, self.dpl, self.system,
                           self.type, self.long_mode))


def tss_descriptor(lo, hi):
    """(base, limit, type, dpl, present) for a 16-byte system descriptor.

    Long mode widened the TSS descriptor to two GDT entries so it can carry a
    64-bit base. The base arrives in FOUR pieces -- bits 15:0, 23:16, 31:24 and
    63:32 -- which is exactly why `core/boot/boot.S` has to build this
    descriptor with shifts at runtime instead of writing it as a constant.
    """
    limit = (lo & 0xFFFF) | (((lo >> 48) & 0xF) << 16)
    base = ((lo >> 16) & 0xFFFFFF) | (((lo >> 56) & 0xFF) << 24) | ((hi & 0xFFFFFFFF) << 32)
    return base, limit, (lo >> 40) & 0xF, (lo >> 45) & 3, bool(lo & (1 << 47))


def idt_gate(qwords, vector):
    """(offset, selector, ist, type, dpl, present) for one 16-byte IDT gate."""
    lo = qwords[vector * 2]
    hi = qwords[vector * 2 + 1]
    offset = (lo & 0xFFFF) | (((lo >> 48) & 0xFFFF) << 16) | ((hi & 0xFFFFFFFF) << 32)
    selector = (lo >> 16) & 0xFFFF
    ist = (lo >> 32) & 7
    attr = (lo >> 40) & 0xFF
    return offset, selector, ist, attr & 0xF, (attr >> 5) & 3, bool(attr & 0x80)


# ---------------------------------------------------------------------------
# The page tables.
# ---------------------------------------------------------------------------

class PageTables:
    """The six tables, as read out of guest memory, plus an x86-64 walk.

    `vmInit` requires its six page-table frames to be consecutive and refuses to
    install anything otherwise, so one `xp` of 6 * 512 quadwords starting at CR3
    contains every table. Following a pointer outside that span RAISES rather
    than returning zeroes: a walk that quietly fell off the end of its data would
    make an unmapped kernel look identical to an unreadable dump.
    """

    def __init__(self, base, qwords):
        self.base = base
        self.span = len(qwords) * 8
        self.qwords = qwords

    def entry(self, table_phys, index):
        off = table_phys - self.base
        if off < 0 or off + PAGE_BYTES > self.span:
            raise LookupError(
                "page table at 0x%X is outside the dumped span [0x%X, 0x%X)"
                % (table_phys, self.base, self.base + self.span))
        return self.qwords[(off // 8) + index]

    def effective(self, va):
        """(writable, executable, user, page_size) for `va`, or None.

        **The AND of every level.** A directory entry with U/S clear makes
        everything under it supervisor-only whatever the leaf says, so checking
        only the leaf would report a page as user-accessible that the CPU would
        refuse -- and, worse, would report the two payload pages correctly while
        missing an interior entry that had quietly opened a whole gigabyte.

        NX is the one that combines the other way: it is a veto, so any level
        with bit 63 set makes the page non-executable.
        """
        w = True
        u = True
        nx = False
        e4 = self.entry(self.base, (va >> 39) & 511)
        if not e4 & PRESENT:
            return None
        w &= bool(e4 & WRITABLE); u &= bool(e4 & USER); nx |= bool(e4 & NX)
        e3 = self.entry(e4 & ADDR_MASK, (va >> 30) & 511)
        if not e3 & PRESENT:
            return None
        w &= bool(e3 & WRITABLE); u &= bool(e3 & USER); nx |= bool(e3 & NX)
        e2 = self.entry(e3 & ADDR_MASK, (va >> 21) & 511)
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

    def user_pages(self, lo, hi, step=PAGE_BYTES):
        """Every page in `[lo, hi)` whose EFFECTIVE permission includes U/S."""
        found = []
        a = lo
        while a < hi:
            got = self.effective(a)
            if got is not None and got[2]:
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


def check_page(tables, va, want_w, want_x, want_u, label):
    """One page must be present with exactly these three permissions."""
    got = tables.effective(va)
    if got is None:
        return ["%s: 0x%X is not mapped" % (label, va)]
    w, x, u, _ = got
    if (w, x, u) != (want_w, want_x, want_u):
        return ["%s: 0x%X is W=%d X=%d U=%d, expected W=%d X=%d U=%d"
                % (label, va, w, x, u, want_w, want_x, want_u)]
    return []
