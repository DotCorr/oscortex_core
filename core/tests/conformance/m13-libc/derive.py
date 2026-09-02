#!/usr/bin/env python3
"""core/tests/conformance/m13-libc/derive.py

M13's derivations, on top of m12-heap/derive.py (which is on top of m11's, which
is on top of m10's).

WHY IT IMPORTS RATHER THAN COPIES. m10's file already has an ELF64 reader
written independently of `core/kernel/elf.dart`; m12's already computes the heap
base the way `heapInit` computes it. M13 needs both unchanged, because the
question it asks -- "did the program's `malloc` put its blocks where the
allocator says it does" -- starts at the same address the kernel's `sbrk` starts
at.

WHAT IS NEW HERE, AND WHERE ITS NUMBERS COME FROM

  * `block_layout(elf)` recomputes THE ADDRESS OF EVERY BLOCK the test program
    allocates, using three things read OUT OF THE ELF: `mallocHdrBytes`,
    `mallocAlign` (both `volatile const` words core/user/libc/malloc.c exports
    for exactly this) and `reqSize`, the array of request sizes prog.c exports.
    Not one of those three is typed in this file. The program prints the offsets
    it actually got and run.sh compares.

    The formula is `hdr + sum over earlier blocks of (roundup(size, align) +
    hdr)`, which is a statement about a SEQUENTIALLY PACKING allocator, and the
    fact that it holds all the way to the sixth block is also a statement about
    coalescing: the fourth allocation is larger than the chunk the allocator had
    left, so it forced a second `sbrk`, and the formula only survives that if
    the new chunk merged with the free tail of the old one. A first-fit
    allocator without coalescing would put block 4 somewhere else, and this
    check would catch it -- which is what makes it a check rather than a copy of
    the implementation.

  * `exit_status(elf, reuse, coal, round2, fails)` recomputes the status the
    program must exit with, from `exitBase` and `dataWord` in the file. The
    three flags are the negative control's whole point: progL must exit with all
    three set and progN with none, and the DIFFERENCE between the two statuses
    is a constant this file computes.

  * `kernel_bytes(elf)` is how many bytes `malloc` must have taken from `sbrk`
    for progL -- the page-rounded footprint of the six blocks -- which is the
    number progN must EXCEED, because a program whose `free` does nothing has to
    ask the kernel for the second round of allocations all over again.
"""

import importlib.util
import os

_M12_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "m12-heap", "derive.py")
if not os.path.exists(_M12_PATH):
    raise SystemExit("m13-libc/derive.py needs m12-heap/derive.py at %s" % _M12_PATH)
_spec = importlib.util.spec_from_file_location("m12_derive", _M12_PATH)
m12 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m12)

Elf = m12.Elf
heap_base_of = m12.heap_base_of
heap_room = m12.heap_room

PAGE_BYTES = m12.PAGE_BYTES
PROG_BASE = m12.PROG_BASE
PROG_END = m12.PROG_END
HEAP_TOP = m12.HEAP_TOP
HEAP_RET_FLOOR = m12.HEAP_RET_FLOOR
HEAP_RET_NOMEM = m12.HEAP_RET_NOMEM
HEAP_RET_NOSPACE = m12.HEAP_RET_NOSPACE
HEAP_RET_BADARG = m12.HEAP_RET_BADARG
HEAP_MAX_INC = m12.HEAP_MAX_INC

# core/kernel/user.dart's `userWriteMax`, and core/user/libc/oslibc.h's
# PRINTF_MAX. run.sh checks the first against user.dart and the second against
# the `printfMax` word in the ELF, so neither is trusted from here.
USER_WRITE_MAX = 128
PRINTF_MAX = 120
OVF_MARK = "%!OVF"

# The five conversions core/user/libc/printf.c implements, and nothing else.
PRINTF_CONVERSIONS = ("s", "d", "x", "c", "%")


def _u64_array(elf, name, n):
    """`n` consecutive u64s starting at symbol `name`, out of the file."""
    value, size = elf.sym(name)
    if size < 8 * n:
        raise ValueError("%s is %d bytes; %d u64s were asked for" % (name, size, n))
    blob = elf.read(value, 8 * n)
    if blob is None:
        raise ValueError("%s has no file-backed bytes" % name)
    return [int.from_bytes(blob[8 * i:8 * i + 8], "little") for i in range(n)]


def req_sizes(elf):
    """prog.c's `reqSize[]`, out of the ELF. The COUNT comes from the symbol's
    own st_size, so adding a seventh allocation to prog.c does not need this
    file edited."""
    _, size = elf.sym("reqSize")
    if size % 8:
        raise ValueError("reqSize is %d bytes, not a whole number of u64s" % size)
    return _u64_array(elf, "reqSize", size // 8)


def alloc_params(elf):
    """(header bytes, alignment, minimum split) as core/user/libc/malloc.c
    exports them."""
    return (elf.sym_u64("mallocHdrBytes"),
            elf.sym_u64("mallocAlign"),
            elf.sym_u64("mallocMinSplit"))


def _round_up(n, a):
    return (n + a - 1) & ~(a - 1)


def block_layout(elf):
    """The offset from the heap base of every block prog.c allocates.

    Derived entirely from the ELF: the request sizes, the header size and the
    alignment. See this file's header for why the fourth entry surviving is a
    statement about coalescing rather than about packing.
    """
    hdr, align, _ = alloc_params(elf)
    out = []
    at = 0
    for s in req_sizes(elf):
        at += hdr
        out.append(at)
        at += _round_up(s, align)
    return out


def kernel_bytes(elf):
    """How many bytes `malloc` must take from `sbrk` for the six blocks.

    THIS ONE IS A SIMULATION, AND IT IS DELIBERATELY A SECOND, DIFFERENT
    DERIVATION FROM `block_layout` ABOVE. The addresses follow from sequential
    packing alone; the total taken from the kernel does not, because `malloc`
    grows by `roundup(hdr + need, 4096)` -- a whole number of PAGES -- only when
    the free list cannot serve the request. The fourth allocation is the one
    that matters: 4096 bytes do not fit in what is left of the first page, so a
    second grow happens and it asks for 8192, not for the 4096 that would have
    "fit". Getting that wrong here and in malloc.c the same way is the failure
    mode this file cannot rule out on its own -- which is why run.sh ALSO checks
    the derived break against the kernel's OWN `PROC HEAP ... NEW` line, and the
    kernel has never heard of this allocator.

    While the whole heap is in use the free list holds at most one block (the
    tail at the top), because every chunk `sbrk` returns abuts the last and
    `insertFree` merges them; that is what makes the model below one variable.

    It is the number progL must report TWICE -- before and after freeing
    everything and allocating it all again -- and the number progN must EXCEED.
    """
    hdr, align, minsplit = alloc_params(elf)
    brk = 0
    tail = None  # payload bytes in the single free block at the top, or None
    for s in req_sizes(elf):
        need = _round_up(s, align)
        if tail is None or tail < need:
            want = _round_up(hdr + need, PAGE_BYTES)
            brk += want
            tail = want - hdr if tail is None else tail + want
        if tail >= need + hdr + minsplit:
            tail -= need + hdr
        else:
            tail = None
    return brk


def exit_status(elf, reuse, coal, round2, fails=0):
    """prog.c's computed exit status, from `exitBase` and `dataWord` in the file.

    prog.c: exitBase + dataWord + (reuse << 20) + (coal << 16) + (round2 << 12)
            + fails
    """
    base = elf.sym_u64("exitBase")
    data = elf.sym_u64("dataWord")
    v = base + data + (reuse << 20) + (coal << 16) + (round2 << 12) + fails
    return v & 0xFFFFFFFFFFFFFFFF


def free_enabled(elf):
    """1 for the library as written, 0 for the negative-control build."""
    return elf.sym_u64("libcFreeEnabled")


def prog_id(elf):
    return elf.sym_u64("progId")
