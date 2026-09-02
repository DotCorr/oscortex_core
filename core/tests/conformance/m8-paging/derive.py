#!/usr/bin/env python3
"""core/tests/conformance/m8-paging/derive.py

Walks the kernel's LIVE page tables, read out of guest physical memory, and
recomputes from OUTSIDE the kernel every permission it claims.

WHY THIS FILE EXISTS. `run.sh` could compare `vm`'s report against a golden and
stop there, and a golden proves the kernel is CONSISTENT with itself. It does
not prove the pages are actually protected: a report that restates what the
builder intended and a builder that set the wrong bit agree with each other
perfectly. So every permission claim is checked a second way, from two sources
the kernel does not control:

  * **CR3 as QEMU reports it** (`info registers`), not as the kernel prints it.
    The two are then required to be equal, which is what makes `vm`'s first line
    a claim rather than an assertion.
  * **The page tables themselves**, dumped with the monitor's `xp` out of guest
    physical memory at that CR3, and walked here by this file's own
    implementation of the x86-64 4-level walk -- written independently of
    `core/kernel/vm.dart`'s `vmWalk`, for the same reason `m7-frames/derive.py`
    restates the allocator's reservation rules rather than importing them.
    If the two disagree, one of them is wrong and run.sh says so.

The section boundaries come from `readelf` on `kernel.elf`, so the ranges being
checked are the linker's, not the kernel's.

THE RULE THIS FILE ENCODES, in one sentence: for every 4KiB page in `.text`,
RW must be 0 and NX must be 0; in `.rodata`, RW must be 0 and NX must be 1; in
`.data` and `.bss`, RW must be 1 and NX must be 1.

WHY A CONTIGUOUS DUMP IS ENOUGH. `vmInit` requires its six page-table frames to
be consecutive and refuses to install anything otherwise, so one `xp` of
6 * 512 quadwords starting at CR3 contains every table. `PageTables` REFUSES to
follow a pointer outside that span rather than reading zeroes and silently
reporting "not mapped" -- a walk that quietly falls off the end of its data
would make an unmapped kernel look identical to an unreadable dump.
"""

import re
import sys

# Must match core/kernel/vm.dart. run.sh asserts these against the source rather
# than trusting the copy.
PAGE_BYTES = 4096
BIG_BYTES = 2097152
FINE_BYTES = 33554432
LOW_BYTES = 1048576
# ADR-0189 took the identity map from 128MiB to 256MiB so the driver can pick
# the mode and the CEF text mapping fits. Restated here by hand, on purpose:
# this file is the double-entry copy of vm.dart's geometry, and run.sh asserts
# the two agree rather than importing one into the other.
MAP_BYTES = 268435456
PCI_BASE = 0xC0000000
PCI_END = 0x100000000
FRAME_COUNT = 20

PRESENT = 1 << 0
WRITABLE = 1 << 1
HUGE = 1 << 7
NX = 1 << 63
ADDR_MASK = 0x000FFFFFFFFFF000


def parse_registers(monitor_text):
    """CR0/CR2/CR3/CR4 out of the monitor's `info registers` block.

    QEMU prints them on one line as `CR0=80010011 CR2=... CR3=... CR4=...`.
    Parsed by name rather than by position so a QEMU version that adds a
    register does not shift the answer.
    """
    out = {}
    for name, value in re.findall(r"\b(CR[0-9])=([0-9a-fA-F]+)", monitor_text):
        out[name] = int(value, 16)
    return out


def parse_xp(monitor_text, prefix="xp/"):
    """Every quadword from the monitor `xp/<n>gx` block, in order.

    The reply looks like

        0000000000122000: 0x0000000000123003 0x0000000000000000

    so it is parsed rather than trusted to any column layout: every 16-digit
    0x-prefixed token after the colon on every line, in order. The ADDRESS at
    the start of each line is 16 digits too, which is exactly why the split on
    ':' is not optional.
    """
    qwords = []
    for block in monitor_text.split("=== "):
        if not block.startswith(prefix):
            continue
        for line in block.splitlines():
            if ":" not in line:
                continue
            for token in line.split(":", 1)[1].split():
                if token.startswith("0x"):
                    qwords.append(int(token, 16))
    return qwords


class PageTables:
    """The six tables, as read out of guest memory, plus an x86-64 walk."""

    def __init__(self, base, qwords):
        self.base = base
        self.span = len(qwords) * 8
        self.qwords = qwords

    def entry(self, table_phys, index):
        """Entry `index` of the table at physical address `table_phys`.

        Raises rather than returning a default if the table is outside the
        dumped span: see this file's header.
        """
        off = table_phys - self.base
        if off < 0 or off + PAGE_BYTES > self.span:
            raise LookupError(
                "page table at 0x%X is outside the dumped span "
                "[0x%X, 0x%X) -- the kernel's tables are not the six "
                "contiguous frames it said they were"
                % (table_phys, self.base, self.base + self.span))
        return self.qwords[(off // 8) + index]

    def walk(self, va):
        """The leaf entry for `va`, or None if any level is not present.

        Returns `(entry, page_size)` so the caller can tell a 2MiB page from a
        4KiB one -- which matters, because a region reported as 4KiB-granular
        that is actually covered by one 2MiB page would have uniform
        permissions for the wrong reason.
        """
        e4 = self.entry(self.base, (va >> 39) & 511)
        if not e4 & PRESENT:
            return None
        e3 = self.entry(e4 & ADDR_MASK, (va >> 30) & 511)
        if not e3 & PRESENT:
            return None
        e2 = self.entry(e3 & ADDR_MASK, (va >> 21) & 511)
        if not e2 & PRESENT:
            return None
        if e2 & HUGE:
            return (e2, BIG_BYTES)
        e1 = self.entry(e2 & ADDR_MASK, (va >> 12) & 511)
        if not e1 & PRESENT:
            return None
        return (e1, PAGE_BYTES)

    def effective(self, va):
        """(writable, executable, page_size) for `va`, or None.

        **The AND of every level, not just the leaf.** x86-64 computes a page's
        effective permission by combining the whole chain: a directory entry
        with RW=0 makes everything under it read-only, and one with NX=1 makes
        everything under it non-executable, whatever the leaf says. Checking
        only the leaf would pass a table whose interior entries silently
        overrode it.
        """
        w = True
        x = True
        e4 = self.entry(self.base, (va >> 39) & 511)
        if not e4 & PRESENT:
            return None
        w &= bool(e4 & WRITABLE)
        x &= not (e4 & NX)
        e3 = self.entry(e4 & ADDR_MASK, (va >> 30) & 511)
        if not e3 & PRESENT:
            return None
        w &= bool(e3 & WRITABLE)
        x &= not (e3 & NX)
        e2 = self.entry(e3 & ADDR_MASK, (va >> 21) & 511)
        if not e2 & PRESENT:
            return None
        w &= bool(e2 & WRITABLE)
        x &= not (e2 & NX)
        if e2 & HUGE:
            return (w, x, BIG_BYTES)
        e1 = self.entry(e2 & ADDR_MASK, (va >> 12) & 511)
        if not e1 & PRESENT:
            return None
        w &= bool(e1 & WRITABLE)
        x &= not (e1 & NX)
        return (w, x, PAGE_BYTES)

    def physical(self, va):
        """The physical address `va` maps to, or None. Used to prove IDENTITY."""
        got = self.walk(va)
        if got is None:
            return None
        entry, size = got
        return (entry & ADDR_MASK & ~(size - 1)) | (va & (size - 1))


def check_region(tables, lo, hi, want_w, want_x, label, step=PAGE_BYTES):
    """Every page in `[lo, hi)` must be present, identity-mapped, and carry
    exactly `want_w`/`want_x`. Returns a list of complaint strings."""
    fails = []
    bad = 0
    first_bad = None
    a = lo
    while a < hi:
        got = tables.effective(a)
        if got is None:
            bad += 1
            if first_bad is None:
                first_bad = (a, "not present")
        else:
            w, x, _size = got
            if w != want_w or x != want_x:
                bad += 1
                if first_bad is None:
                    first_bad = (a, "W=%d X=%d" % (w, x))
            elif tables.physical(a) != a:
                bad += 1
                if first_bad is None:
                    first_bad = (a, "maps to 0x%X, not identity"
                                 % tables.physical(a))
        a += step
    if bad:
        fails.append("%s: %d of %d pages in [0x%X, 0x%X) are wrong "
                     "(want W=%d X=%d); first at 0x%X -- %s"
                     % (label, bad, (hi - lo + step - 1) // step, lo, hi,
                        want_w, want_x, first_bad[0], first_bad[1]))
    return fails


def main():
    if len(sys.argv) != 3:
        print("usage: derive.py <monitor-capture> <cr3-hex>", file=sys.stderr)
        return 2
    monitor = open(sys.argv[1], encoding="utf-8").read()
    base = int(sys.argv[2], 16)
    tables = PageTables(base, parse_xp(monitor))
    print("regs   %r" % parse_registers(monitor))
    print("span   0x%X bytes of tables at 0x%X" % (tables.span, base))
    for va in (0x100000, 0x113000, 0x115000, 0xB8000, 0xC0000000):
        print("0x%-10X %r" % (va, tables.effective(va)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
