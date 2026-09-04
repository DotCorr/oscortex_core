#!/usr/bin/env python3
"""core/tests/conformance/m11-proc/derive.py

M11's derivations, on top of m10-elf/derive.py.

WHY THIS FILE IMPORTS THE M10 ONE INSTEAD OF COPYING IT.

m10-elf/derive.py already contains an ELF64 reader written independently of
`core/kernel/elf.dart`, and a page-table walker that spans several dumped
regions of guest physical memory and REFUSES to follow a pointer outside all of
them. M11 needs both, unchanged, and needs them to mean exactly what they meant
at M10 -- the claim "process A's pages carry the permissions A's own p_flags
asked for" is M10's claim, made twice. Re-typing the walker would produce a
second thing to keep in step and would not make either more true. It is the
same reuse m2-console/qmp-drive.py already gets from nine harnesses.

WHAT IS NEW HERE IS THE PART M10 COULD NOT HAVE HAD: a second address space.

  * `check_isolation` takes TWO `PageTables` and requires that no page of A's
    program window is reachable from B's -- and, for the pages both DO map (the
    two programs are linked to the same virtual addresses, deliberately), that
    the physical frames behind them differ. "Two address spaces" and "two names
    for one" are the same thing to a program until you compare frames.

  * `check_kernel_shared` requires the opposite for kernel memory: the same
    physical frame at the same virtual address in both, still supervisor-only.
    An isolation check that passed because the second address space was empty
    would be worthless, and this is what makes it not that.

  * `check_fx_area` reads a process's 512-byte FXSAVE image out of guest
    memory and reports the x87 control word and MXCSR, so "the save area holds
    a legal image" is read from RAM rather than inferred from the code that
    wrote it.
"""

import importlib.util
import os

# Loaded BY PATH and under a different module name, because m10's file is also
# called `derive.py` and a plain import would find whichever of the two came
# first on sys.path -- silently, and differently depending on who ran it.
_M10_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "m10-elf", "derive.py")
if not os.path.exists(_M10_PATH):
    raise SystemExit("m11-proc/derive.py needs m10-elf/derive.py at %s" % _M10_PATH)
_spec = importlib.util.spec_from_file_location("m10_derive", _M10_PATH)
m10 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m10)

Elf = m10.Elf
Memory = m10.Memory
PageTables = m10.PageTables
parse_registers = m10.parse_registers
parse_xp = m10.parse_xp
check_program_pages = m10.check_program_pages
check_supervisor = m10.check_supervisor

PAGE_BYTES = m10.PAGE_BYTES
PROG_BASE = m10.PROG_BASE
PROG_END = m10.PROG_END
PROG_PAGES = m10.PROG_PAGES
PROG_PD_INDEX = m10.PROG_PD_INDEX
PROG_STACK_PAGE = m10.PROG_STACK_PAGE
PROG_STACK_TOP = m10.PROG_STACK_TOP
PRESENT = m10.PRESENT
WRITABLE = m10.WRITABLE
USER = m10.USER
HUGE = m10.HUGE
NX = m10.NX
ADDR_MASK = m10.ADDR_MASK
MAP_BYTES = m10.MAP_BYTES
LOW_BYTES = m10.LOW_BYTES
BIG_BYTES = m10.BIG_BYTES

# Must match core/kernel/proc.dart. run.sh asserts every one of these against
# the source rather than trusting the copy.
PROC_MAX = 16
PROC_STORE_BYTES = 16512
PROC_HEAD_WORDS = 16
PROC_TABLE_OFFSET = 128
PROC_FX_OFFSET = 8320
PROC_SLOT_BYTES = 512
PROC_SLOT_WORDS = 64
PROC_FX_BYTES = 512
PROC_FRAME_WORDS = 22

# The FXSAVE image, from the SDM. Only the two fields this kernel writes by
# hand are named, because they are the two a wrong value turns into a #GP
# inside a context switch.
FX_CW_OFFSET = 0
FX_MXCSR_OFFSET = 24
FX_CW_INIT = 0x037F
FX_MXCSR_INIT = 0x1F80


def frame_of(tables, va):
    """The PHYSICAL frame backing `va`, or None if it is not mapped."""
    e = tables.leaf(va)
    if e is None:
        return None
    return e & ADDR_MASK


def check_isolation(a_tables, b_tables, a_elf, b_elf, a_label="A", b_label="B"):
    """THE ISOLATION CLAIM, READ OUT OF THE TWO PAGE TABLES THEMSELVES.

    Three separate things, because they fail in three different ways:

      1. every page `a_elf` asks for is mapped in A -- otherwise the rest is a
         statement about an address space with nothing in it;
      2. every page A maps that B does NOT ask for is ABSENT from B. This is
         the pages-not-shared half;
      3. every page BOTH map (same virtual address, because both programs are
         linked at the same base) is backed by a DIFFERENT physical frame. This
         is the half that a shared `PML4[0]` would pass item 2 of and fail
         here -- and it is the reason `procSpaceBuild` gives each process its
         own PDPT and page directory rather than sharing the kernel's.
    """
    fails = []
    a_want = set(a_elf.pages()) | {PROG_STACK_PAGE}
    b_want = set(b_elf.pages()) | {PROG_STACK_PAGE}

    a_got = set(a_tables.mapped_pages(PROG_BASE, PROG_END))
    b_got = set(b_tables.mapped_pages(PROG_BASE, PROG_END))
    if a_got != a_want:
        fails.append("%s's window maps %s, its ELF plus a stack page says %s"
                     % (a_label, sorted(hex(x) for x in a_got),
                        sorted(hex(x) for x in a_want)))
    if b_got != b_want:
        fails.append("%s's window maps %s, its ELF plus a stack page says %s"
                     % (b_label, sorted(hex(x) for x in b_got),
                        sorted(hex(x) for x in b_want)))

    private = sorted(a_got - b_want)
    if not private:
        fails.append("%s maps no page %s does not also ask for, so this check "
                     "cannot fail and proves nothing. The two programs must "
                     "differ in size -- see progA.c's crossPage." % (a_label, b_label))
    for va in private:
        if b_tables.effective(va) is not None:
            fails.append("0x%X is mapped in %s's address space and %s did not "
                         "ask for it: the two address spaces are one" % (va, b_label, b_label))

    shared_va = sorted(a_got & b_got)
    if not shared_va:
        fails.append("the two programs map no virtual address in common, so "
                     "'the same address is a different page' is untested")
    for va in shared_va:
        fa = frame_of(a_tables, va)
        fb = frame_of(b_tables, va)
        if fa is None or fb is None:
            fails.append("0x%X lost its leaf between two walks" % va)
        elif fa == fb:
            fails.append("0x%X is backed by frame 0x%X in BOTH address spaces. "
                         "Two page tables pointing at one frame is not isolation."
                         % (va, fa))
    return fails, private, shared_va


def check_kernel_shared(a_tables, b_tables, probes):
    """The kernel's mappings must be the SAME frame in both, and supervisor.

    Without this, `check_isolation` would pass on a kernel whose second address
    space was empty -- which is not isolation, it is a broken address space
    that happens to share nothing.
    """
    fails = []
    for va in probes:
        ea = a_tables.effective(va)
        eb = b_tables.effective(va)
        if ea is None or eb is None:
            fails.append("kernel address 0x%X is not mapped in %s -- the kernel's "
                         "own mappings were not copied into every address space"
                         % (va, "A" if ea is None else "B"))
            continue
        if ea[2] or eb[2]:
            fails.append("kernel address 0x%X is USER-accessible (A: %s, B: %s)"
                         % (va, ea[2], eb[2]))
        fa, fb = frame_of(a_tables, va), frame_of(b_tables, va)
        if fa != fb:
            fails.append("kernel address 0x%X is frame 0x%X in A and 0x%X in B -- "
                         "the kernel is not shared, it was copied" % (va, fa, fb))
    return fails


def check_fx_area(mem, base):
    """Reads one 512-byte FXSAVE image out of guest memory.

    Returns (fails, control_word, mxcsr). A reserved bit set in the MXCSR image
    is a #GP inside `fxrstor`, i.e. inside a context switch, so this is read
    from RAM rather than believed from `procFxInit`'s source.
    """
    fails = []
    if base % 16:
        fails.append("the FXSAVE area at 0x%X is not 16-byte aligned; fxsave "
                     "would #GP" % base)
    w0 = mem.qword(base + FX_CW_OFFSET)
    w3 = mem.qword(base + FX_MXCSR_OFFSET)
    cw = w0 & 0xFFFF
    mxcsr = w3 & 0xFFFFFFFF
    if mxcsr & ~0xFFFF:
        fails.append("MXCSR 0x%08X has bits above 15 set" % mxcsr)
    if mxcsr & 0x0000FFC0 != 0x1F80 & 0x0000FFC0:
        fails.append("MXCSR 0x%08X does not have the six SSE exception masks set"
                     % mxcsr)
    return fails, cw, mxcsr
