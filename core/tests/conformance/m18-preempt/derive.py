#!/usr/bin/env python3
"""core/tests/conformance/m18-preempt/derive.py

WHAT THIS FILE IS FOR, IN ONE SENTENCE: every number `run.sh` compares against
the serial capture is computed HERE, out of the two ELF files and out of the
kernel's own source constants -- never typed into an expected-output file.

M18 has no byte-exact golden and cannot have one. The interleaving of a
PREEMPTIVE session is not a property of the programs: which instruction a timer
interrupt lands on is a property of the host. What IS reproducible is stated as
arithmetic, and this file is where the arithmetic lives:

  * the number of quantum expiries in a session is EXACTLY the budget typed at
    the shell, because the scheduler ends the session at that count;
  * progD's exit status is its own `.rodata` word plus its own `.data` word
    plus the checksum of the 64 bytes its own compiler-emitted `movups` moved;
  * progD's message is the bytes of its own `msg` symbol;
  * progC's saved R15 must be large and its saved RIP must be inside its own
    R+X segment, both read out of the kernel's process table in guest RAM.

It reuses `m11-proc/derive.py` -- which reuses `m10-elf/derive.py` -- by path
rather than by `import`, for m11's stated reason: three files in this tree are
called `derive.py` and a plain import would find whichever came first on
sys.path, silently and differently depending on who ran it.
"""

import importlib.util
import os

_M11_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "m11-proc", "derive.py")
if not os.path.exists(_M11_PATH):
    raise SystemExit("m18-preempt/derive.py needs m11-proc/derive.py at %s" % _M11_PATH)
_spec = importlib.util.spec_from_file_location("m11_derive", _M11_PATH)
m11 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m11)

Elf = m11.Elf
Memory = m11.Memory
PageTables = m11.PageTables
parse_registers = m11.parse_registers
parse_xp = m11.parse_xp

PROC_MAX = m11.PROC_MAX
PROC_STORE_BYTES = m11.PROC_STORE_BYTES
PROC_HEAD_WORDS = m11.PROC_HEAD_WORDS
PROC_TABLE_OFFSET = m11.PROC_TABLE_OFFSET
PROC_FX_OFFSET = m11.PROC_FX_OFFSET
PROC_SLOT_BYTES = m11.PROC_SLOT_BYTES
PROC_SLOT_WORDS = m11.PROC_SLOT_WORDS
PROC_FRAME_WORDS = m11.PROC_FRAME_WORDS

PROG_BASE = m11.PROG_BASE
PROG_END = m11.PROG_END

MASK64 = (1 << 64) - 1

# ---------------------------------------------------------------------------
# M18's own numbers. `run.sh` asserts every one of these against
# core/kernel/proc.dart rather than trusting this copy.
# ---------------------------------------------------------------------------
PROC_QUANTUM_TICKS = 8
PROC_POLICY_COOP = 0
PROC_POLICY_PREEMPT = 1

# Header word indices.
HEAD_READY = 0
HEAD_CREATED = 1
HEAD_CURRENT = 2
HEAD_SWITCHES = 3
HEAD_SSE = 4
HEAD_LIVE = 5
HEAD_EXITS = 6
HEAD_ERRORS = 7
HEAD_PREEMPTS = 8
HEAD_QUANTA = 9
HEAD_SLICE = 10
HEAD_POLICY = 11
HEAD_KERNTICKS = 12
HEAD_BUDGET = 13

# Slot word indices M18 reads.
SLOT_STATE = 0
SLOT_ENTRY = 6
SLOT_PREEMPTS = 20
SLOT_YIELDS = 21
SLOT_SAVED = 32

# Offsets INSIDE the 22-word saved frame, in words. These are `isr_common`'s
# push order (core/boot/isr.S) read as a data structure: fifteen registers
# pushed R15 first, then the stub's vector and error code, then the five the CPU
# pushed. run.sh derives the last five from user.dart's own byte offsets rather
# than trusting these.
FRAME_R15 = 0
FRAME_RAX = 14
FRAME_RIP = 17
FRAME_CS = 18
FRAME_RFLAGS = 19
FRAME_RSP = 20
FRAME_SS = 21

# The ring-3 selectors, from core/kernel/user.dart. run.sh reads them out of the
# source; they are here so a failure message can say what was expected.
USER_CODE_SEL = 0x23
USER_DATA_SEL = 0x1B

# progD's declared XMM signature, and what `movq %xmm0,%rax` returns after
# `pshufd $0` broadcasts it to all four lanes. run.sh reads the pattern out of
# progD.c so this is not a second place to change it.
XMM_PATTERN_D = 0xD1D2D3D4
XMM_PATTERN_D_64 = (XMM_PATTERN_D << 32) | XMM_PATTERN_D

# How many involuntary switches progD spins for. Read out of progD.c by run.sh.
WANT_PREEMPTS = 3


class ProcTable:
    """The kernel's process table, read out of guest physical memory.

    `head` is the address the kernel PRINTED (`proc sched ... HEAD <addr>`), and
    the kernel image is identity-mapped, so it is also the physical address the
    QEMU monitor's `xp` needs. Nothing in this class is an address the harness
    chose.
    """

    def __init__(self, mem, head):
        self.mem = mem
        self.head = head

    def head_word(self, i):
        return self.mem.qword(self.head + i * 8)

    def slot_word(self, s, w):
        return self.mem.qword(self.head + PROC_TABLE_OFFSET
                              + s * PROC_SLOT_BYTES + w * 8)

    def frame_word(self, s, w):
        return self.slot_word(s, SLOT_SAVED + w)

    def saved_frame(self, s):
        return [self.frame_word(s, w) for w in range(PROC_FRAME_WORDS)]


def expected_exit_status(elf, bad=0):
    """progD's `sys(SYS_EXIT, exitStatus + dataWord + sum + bad, 0)`.

    `sum` is the checksum of the 64 bytes `blobCopy` moved, which is the sum of
    `srcBlob`'s eight words -- read out of the .data the linker wrote, so this
    number cannot be right unless the loader really mapped that segment.
    """
    total = elf.sym_u64("exitStatus") + elf.sym_u64("dataWord") + bad
    blob = elf.sym_bytes("srcBlob")
    for i in range(8):
        total += int.from_bytes(blob[i * 8:(i + 1) * 8], "little")
    return total & MASK64


def expected_message(elf):
    """progD's `msg`, out of its own .rodata."""
    return elf.sym_cstr("msg").decode("ascii")


def expected_xmm_line(pre):
    """The exact 38 bytes progD writes after its spin.

    Derived rather than typed: the program builds the line one character at a
    time out of `hex()`, and this is the same construction in Python. A kernel
    that restored half of XMM0 would print a right-looking top half, which is
    why all sixteen digits are compared and not eight.
    """
    return "D XMM %016X OK PRE %08X" % (XMM_PATTERN_D_64, pre)


def check_saved_frame(table, slot, elf, label, min_r15, want_rax=None):
    """Everything M18 claims about a PREEMPTED process, read out of the kernel's
    own table rather than out of the log the same kernel wrote."""
    fails = []
    fr = table.saved_frame(slot)

    cs = fr[FRAME_CS]
    if cs != USER_CODE_SEL:
        fails.append("%s: the saved CS is 0x%X, not the ring-3 code selector 0x%X. "
                     "This process was not preempted from CPL 3, and CPL 3 is the "
                     "only privilege this scheduler preempts from."
                     % (label, cs, USER_CODE_SEL))
    if fr[FRAME_SS] != USER_DATA_SEL:
        fails.append("%s: the saved SS is 0x%X, not 0x%X"
                     % (label, fr[FRAME_SS], USER_DATA_SEL))
    if not (fr[FRAME_RFLAGS] & 0x200):
        fails.append("%s: the saved RFLAGS 0x%X has IF clear -- the process was "
                     "running with interrupts disabled, which ring 3 cannot do"
                     % (label, fr[FRAME_RFLAGS]))

    rip = fr[FRAME_RIP]
    text = elf.loads[0]
    if not (text["vaddr"] <= rip < text["vaddr"] + text["memsz"]):
        fails.append("%s: the saved RIP 0x%X is not inside this program's own R+X "
                     "segment [0x%X, 0x%X) -- whatever was preempted, it was not "
                     "this program"
                     % (label, rip, text["vaddr"], text["vaddr"] + text["memsz"]))

    rsp = fr[FRAME_RSP]
    if not (PROG_BASE <= rsp <= PROG_END):
        fails.append("%s: the saved RSP 0x%X is outside the program window "
                     "[0x%X, 0x%X]" % (label, rsp, PROG_BASE, PROG_END))

    # THE SAVED RAX IS THE PROGRAM'S OWN REGISTER, NOT A SYSCALL RETURN VALUE.
    #
    # `procYield` overwrites the saved RAX with 1 before switching away, because
    # ITS frame came from an `int $0x80` whose RAX held a syscall number.
    # `procTick`'s frame came from a timer at an arbitrary instruction boundary,
    # so that word is live program state. A mutation that copied `procYield`'s
    # line into the preemption path SURVIVED this harness until progC was given
    # a constant in RAX that nothing ever writes again.
    if want_rax is not None and fr[FRAME_RAX] != want_rax:
        fails.append("%s: the saved RAX is 0x%016X, not the 0x%016X this program "
                     "loaded once and never touched again. Something wrote the "
                     "program's live RAX during the switch -- `procYield` patches that "
                     "word deliberately and `procTick` must not."
                     % (label, fr[FRAME_RAX], want_rax))

    r15 = fr[FRAME_R15]
    if r15 < min_r15:
        fails.append("%s: the saved R15 is %d, and this program's only instruction "
                     "other than a jump is `incq %%r15`. Fewer than %d iterations "
                     "means it barely ran -- 'both programs made progress' is the "
                     "claim, and this is the evidence for it."
                     % (label, r15, min_r15))
    return fails, {"r15": r15, "rip": rip, "cs": cs, "rsp": rsp}
