#!/usr/bin/env python3
"""core/tests/conformance/m12-heap/derive.py

M12's derivations, on top of m11-proc/derive.py (which is on top of
m10-elf/derive.py).

WHY THIS FILE IMPORTS THE M11 ONE INSTEAD OF COPYING IT.

m10's file already has an ELF64 reader and a page-table walker written
independently of `core/kernel/elf.dart` and `core/kernel/vm.dart`, and m11's
already has the two-address-space isolation check. M12 needs all of it,
unchanged, because "the heap is isolated" is the same claim about page tables
that "the program pages are isolated" was -- made about pages the kernel handed
out at runtime rather than pages a loader placed.

WHAT IS NEW HERE

  * `heap_base_of(elf)` computes, from the ELF FILE ALONE, the address the
    kernel's `heapInit` must have chosen: one past the highest page any PT_LOAD
    touches. That is the number `PROC HEAP .. OLD ..` prints on the first call,
    and comparing the two is the check that the break starts where the program
    ends rather than at a constant somebody typed.

  * `check_window(tables, elf, base, brk)` audits the WHOLE 2MiB window in one
    pass: the mapped set must be exactly the ELF's pages, one stack page and
    [base, brk), with the heap pages user + writable + NX and the guard page
    absent -- so "the heap ends here" is a property of the tables rather than
    of a counter, and a kernel that mapped one page too many fails.

  * `check_heap_absent` is the same walk with the opposite expectation, for the
    BEFORE dump. A milestone that only ever looked at the after-picture would
    pass on a kernel that mapped the whole window at load time.

  * `heap_mark` recomputes prog.c's per-page signature from `progSig` READ OUT
    OF THE ELF, so the bytes the harness looks for in guest RAM come from the
    binary rather than from a constant typed twice.
"""

import importlib.util
import os

_M11_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "m11-proc", "derive.py")
if not os.path.exists(_M11_PATH):
    raise SystemExit("m12-heap/derive.py needs m11-proc/derive.py at %s" % _M11_PATH)
_spec = importlib.util.spec_from_file_location("m11_derive", _M11_PATH)
m11 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m11)

Elf = m11.Elf
Memory = m11.Memory
PageTables = m11.PageTables
parse_registers = m11.parse_registers
parse_xp = m11.parse_xp
check_program_pages = m11.check_program_pages
check_supervisor = m11.check_supervisor
check_isolation = m11.check_isolation
check_kernel_shared = m11.check_kernel_shared

PAGE_BYTES = m11.PAGE_BYTES
PROG_BASE = m11.PROG_BASE
PROG_END = m11.PROG_END
PROG_PAGES = m11.PROG_PAGES
PROG_PD_INDEX = m11.PROG_PD_INDEX
PROG_STACK_PAGE = m11.PROG_STACK_PAGE
PROG_STACK_TOP = m11.PROG_STACK_TOP
PRESENT = m11.PRESENT
WRITABLE = m11.WRITABLE
USER = m11.USER
HUGE = m11.HUGE
NX = m11.NX
ADDR_MASK = m11.ADDR_MASK

PROC_MAX = m11.PROC_MAX
PROC_TABLE_OFFSET = m11.PROC_TABLE_OFFSET
PROC_SLOT_BYTES = m11.PROC_SLOT_BYTES
PROC_FX_OFFSET = m11.PROC_FX_OFFSET

# Must match core/kernel/heap.dart. run.sh asserts every one of these against
# the source rather than trusting the copy -- the same discipline m11-proc's
# harness applies to its nine.
HEAP_TOP = 0x101FE000
HEAP_TOP_INDEX = 510
HEAP_GUARD_PAGE = 0x101FE000
HEAP_GUARD_INDEX = 510
HEAP_MAX_INC = 2097152
HEAP_SYS_SBRK_NO = 4
HEAP_RET_FLOOR = 0xFFFFFFFFFFFFF000
HEAP_RET_NOMEM = 0xFFFFFFFFFFFFFFFC
HEAP_RET_NOSPACE = 0xFFFFFFFFFFFFFFFD
HEAP_RET_BADARG = 0xFFFFFFFFFFFFFFFE
HEAP_SLOT_BASE = 16
HEAP_SLOT_BRK = 17
HEAP_SLOT_PAGES = 18
HEAP_SLOT_CALLS = 19

# core/kernel/proc.dart's slot words this harness reads out of guest RAM.
PROC_SLOT_STATE = 0
PROC_SLOT_PML4 = 2
PROC_SLOT_HI = 13


def heap_base_of(elf):
    """The break the kernel must start this program at, from the FILE.

    `elfMapPage` maps whole pages, and `elfMetaHi` is the maximum of
    `page_up(p_vaddr + p_memsz)` over the PT_LOADs -- so this is the same
    arithmetic `heapInit` is handed, done independently.
    """
    hi = 0
    for s in elf.loads:
        end = s["vaddr"] + s["memsz"]
        hi = max(hi, (end + PAGE_BYTES - 1) & ~(PAGE_BYTES - 1))
    return hi


def heap_room(base):
    """How many pages can ever fit between `base` and the guard page."""
    return (HEAP_TOP - base) // PAGE_BYTES


def heap_mark(sig, page_index, word_index):
    """prog.c's `mark()`, recomputed. `sig` comes out of the ELF."""
    return (sig + (page_index << 20) + word_index) & 0xFFFFFFFFFFFFFFFF


def check_window(tables, elf, base, brk, label):
    """AUDITS THE WHOLE 2MiB WINDOW AT ONCE, AND THE EXACTNESS IS THE POINT.

    The set of mapped pages must be EXACTLY: the pages the ELF's own program
    headers ask for, one stack page, and the pages between the heap base and the
    break. Not a superset, not a subset.

    A check that only looked at the heap would pass on a kernel that mapped the
    entire window and handed out addresses into it -- which is not an allocator.
    A check that only looked at the program pages (m10's `check_program_pages`)
    would now FAIL on a correct kernel, because the heap really is there; the two
    have to be one audit or the second one has to be weakened, and weakening it
    is how a spare mapped page stops being noticed.

    Returns (fails, heap_pages).
    """
    fails = []
    if brk < base:
        fails.append("%s: the break 0x%X is below the heap base 0x%X" % (label, brk, base))
        return fails, []

    want = dict(elf.pages())                      # va -> (writable, executable)
    want[PROG_STACK_PAGE] = (True, False)
    heap = []
    va = base
    while va < brk:
        want[va] = (True, False)                  # user heap: W, NX
        heap.append(va)
        va += PAGE_BYTES

    got = set(tables.mapped_pages(PROG_BASE, PROG_END))
    extra = sorted(got - set(want))
    missing = sorted(set(want) - got)
    if extra:
        fails.append("%s: %d page(s) are mapped that neither the ELF nor the heap asks for, "
                     "first at 0x%X. The window must hold exactly the program, one stack "
                     "page and [0x%X, 0x%X)." % (label, len(extra), extra[0], base, brk))
    if missing:
        fails.append("%s: %d page(s) the ELF or the heap asks for are NOT mapped, first at "
                     "0x%X." % (label, len(missing), missing[0]))

    for va in sorted(set(want) & got):
        w, x, u, size = tables.effective(va)
        ww, wx = want[va]
        if size != PAGE_BYTES:
            fails.append("%s: 0x%X is part of a %d-byte page, expected 4096" % (label, va, size))
        if not u:
            fails.append("%s: 0x%X is NOT user-accessible" % (label, va))
        if (w, x) != (ww, wx):
            kind = "heap" if base <= va < brk else ("stack" if va == PROG_STACK_PAGE else "program")
            fails.append("%s: %s page 0x%X is W=%d X=%d, expected W=%d X=%d"
                         % (label, kind, va, w, x, ww, wx))
        if w and x:
            fails.append("%s: 0x%X is BOTH writable and executable" % (label, va))

    # THE GUARD PAGE, NAMED. It falls out of the set comparison above, but it is
    # the one page whose absence is a design decision rather than an accident of
    # where the break stopped, so it gets its own sentence.
    if tables.effective(HEAP_GUARD_PAGE) is not None:
        fails.append("%s: the guard page 0x%X is MAPPED. It is the only thing between a "
                     "heap grown to its limit and the stack." % (label, HEAP_GUARD_PAGE))
    return fails, heap


def check_heap_absent(tables, base, label):
    """The BEFORE picture: nothing at all between the program and the stack."""
    fails = []
    va = base
    mapped = []
    while va < PROG_STACK_PAGE:
        if tables.effective(va) is not None:
            mapped.append(va)
        va += PAGE_BYTES
    if mapped:
        fails.append("%s: %d page(s) between the heap base 0x%X and the stack are ALREADY "
                     "mapped before the process has called sbrk once (first: 0x%X). "
                     "'the mapping was created by the syscall' would be unprovable."
                     % (label, len(mapped), base, mapped[0]))
    return fails


def check_heap_contents(mem, tables, sig, base, pages, deep_first=True):
    """Reads the program's pattern back OUT OF THE PHYSICAL FRAMES.

    This is the step that makes "the pages are real" a hardware fact rather than
    a program's own report: the virtual address is translated through the page
    tables the harness walked, and the qword is read from the dumped guest
    physical memory at the frame the leaf names. A kernel that returned addresses
    without mapping frames could still print anything it liked on the serial
    port; it could not put these bytes at that physical address.

    A frame outside the dumped region is SKIPPED AND COUNTED rather than failed:
    the dump is finite and the heap is ~500 pages. The caller requires a minimum
    number actually checked, so "we skipped them all" cannot pass.

    Returns (fails, checked, skipped).
    """
    fails = []
    checked = 0
    skipped = 0
    for i, va in enumerate(pages):
        leaf = tables.leaf(va)
        if leaf is None:
            fails.append("heap page %d at 0x%X has no leaf" % (i, va))
            continue
        phys = leaf & ADDR_MASK
        try:
            first = mem.qword(phys)
            last = mem.qword(phys + PAGE_BYTES - 8)
        except LookupError:
            skipped += 1
            continue
        want_first = heap_mark(sig, i, 0)
        want_last = heap_mark(sig, i, 511)
        if first != want_first:
            fails.append("heap page %d (va 0x%X, frame 0x%X) holds 0x%016X at word 0, "
                         "the program wrote 0x%016X" % (i, va, phys, first, want_first))
        if last != want_last:
            fails.append("heap page %d (va 0x%X, frame 0x%X) holds 0x%016X at word 511, "
                         "the program wrote 0x%016X" % (i, va, phys, last, want_last))
        checked += 1
        if deep_first and i == 0:
            # The first page was written to the last byte, so every one of its
            # 512 words is checked rather than two of them.
            for w in range(512):
                got = mem.qword(phys + w * 8)
                want = heap_mark(sig, 0, w)
                if got != want:
                    fails.append("heap page 0 word %d (frame 0x%X) is 0x%016X, expected "
                                 "0x%016X" % (w, phys, got, want))
                    break
    return fails, checked, skipped


def check_heap_distinct(a_tables, b_tables, a_base, a_brk, b_base, b_brk):
    """Two heaps at the SAME virtual addresses must be different frames.

    The two programs are one source compiled twice, so their heaps start at the
    same address by construction (build-progs.sh asserts it). Every address they
    both map is therefore a place where "two address spaces" and "two names for
    one" differ, and this is where that difference is measured.
    """
    fails = []
    lo = max(a_base, b_base)
    hi = min(a_brk, b_brk)
    shared = []
    va = lo
    while va < hi:
        fa = a_tables.leaf(va)
        fb = b_tables.leaf(va)
        if fa is not None and fb is not None:
            pa, pb = fa & ADDR_MASK, fb & ADDR_MASK
            if pa == pb:
                fails.append("heap address 0x%X is backed by frame 0x%X in BOTH processes. "
                             "Two page tables pointing at one frame is not isolation."
                             % (va, pa))
            shared.append(va)
        va += PAGE_BYTES
    if not shared:
        fails.append("the two heaps share no virtual address, so 'the same address is a "
                     "different page' is untested. The two builds must have identical "
                     "segment geometry -- see build-progs.sh.")
    return fails, shared


def slot_word(mem, store_base, slot, word):
    """One word of one process-table slot, out of guest RAM."""
    return mem.qword(store_base + PROC_TABLE_OFFSET + slot * PROC_SLOT_BYTES + word * 8)
