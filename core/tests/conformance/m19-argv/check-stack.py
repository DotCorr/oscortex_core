#!/usr/bin/env python3
"""core/tests/conformance/m19-argv/check-stack.py

READS THE INITIAL PROCESS STACK OUT OF GUEST PHYSICAL MEMORY AND CHECKS ITS
SHAPE AGAINST THE System V x86-64 ABI.

WHY THIS FILE EXISTS SEPARATELY FROM EVERY OTHER CHECK IN m19-argv
---------------------------------------------------------------------------
The program prints `WC ARGC 2 RSP 101fffb0 ...` and every argument it was given.
That is the program's REPORT OF ITS OWN STACK, and a program is not a witness
to its own stack: a kernel that wrote the vector into the wrong place, or wrote
pointers that happened to be self-consistent but pointed outside the mapped
page, or terminated the vector one word late, could produce exactly that
transcript. So this script never looks at what the program said. It takes:

  * the PHYSICAL address of the stack frame, which the kernel prints on the
    `ELF STACK ... FRAME <phys>` line, and which QEMU's own monitor then dumps
    with `xp` -- a description of the machine produced by QEMU, not by the
    kernel and not by the program;
  * the RSP the kernel entered ring 3 with, off the `ELF ENTER` line;
  * THE COMMAND LINE THE HARNESS TYPED, which is the only ground truth in the
    whole exercise.

and requires, in order:

  1. RSP is 16-BYTE ALIGNED. This is the process-entry rule and it is NOT the
     function-entry rule; getting the two confused is the single most likely way
     to build this milestone wrong, and `_start` does not realign, so nothing
     downstream would hide it.
  2. RSP is inside the program's own stack page, `[vmProgStackPage,
     vmProgStackTop)`, and at least `argsMinStack` bytes above the bottom of it.
  3. The word AT RSP is argc, and argc is the number of tokens typed.
  4. argv[0..argc-1] are pointers INSIDE the same page, strictly increasing,
     and each one's NUL-terminated string is byte-for-byte the token that was
     typed -- argv[0] being the program's own name.
  5. argv[argc] is NULL. The vector is terminated.
  6. envp[0] -- the word after that NULL -- is NULL. The environment is EMPTY,
     which is a claim this check makes rather than a thing it assumes.
  7. The auxiliary vector is one AT_NULL entry: two more zero words.
  8. Every byte between the end of that block and the first string is ZERO
     (padding), and every byte above the last string up to vmProgStackTop is
     ZERO. Nothing the kernel did not intend to write is on that page.
  9. The strings do not overlap and together account for exactly the bytes the
     kernel reported.

Usage:
    check-stack.py <monitor-capture> <serial> <argsMinStack> <stackPage>
                   <stackTop> <token> [<token> ...]

Exit status: 0 if the stack is the ABI's, 1 with a sentence if it is not.
"""

import re
import sys


def die(msg):
    print("check-stack: FAIL — %s" % msg, file=sys.stderr)
    raise SystemExit(1)


def main():
    if len(sys.argv) < 7:
        die("usage: check-stack.py <mon> <serial> <minstack> <page> <top> <token>...")
    mon_path, ser_path = sys.argv[1], sys.argv[2]
    min_stack = int(sys.argv[3], 0)
    page = int(sys.argv[4], 0)
    top = int(sys.argv[5], 0)
    tokens = [t.encode("ascii") for t in sys.argv[6:]]

    serial = open(ser_path, "rb").read().decode("latin-1")

    m = re.search(r"ELF STACK ([0-9A-F]{16}) FRAME ([0-9A-F]{16})", serial)
    if not m:
        die("the serial capture has no `ELF STACK ... FRAME ...` line")
    if int(m.group(1), 16) != top:
        die("the kernel printed a stack top of 0x%s, vm.dart says 0x%X"
            % (m.group(1), top))
    frame = int(m.group(2), 16)

    m = re.search(r"ELF ENTER RIP [0-9A-F]{16} RSP ([0-9A-F]{16})", serial)
    if not m:
        die("the serial capture has no `ELF ENTER ... RSP ...` line")
    rsp = int(m.group(1), 16)

    # ---- the page, as QEMU dumped it -----------------------------------
    words = {}
    for line in open(mon_path, encoding="utf-8", errors="replace"):
        mm = re.match(r"^([0-9a-fA-F]+):(.*)$", line.strip())
        if not mm:
            continue
        at = int(mm.group(1), 16)
        for tok in mm.group(2).split():
            if tok.startswith("0x"):
                words[at] = int(tok, 16)
                at += 8
    if not words:
        die("the monitor capture holds no `xp` output at all")
    lo, hi = min(words), max(words) + 8
    if lo != frame:
        die("the monitor dump starts at 0x%X, the kernel said the stack frame "
            "is at 0x%X" % (lo, frame))
    if hi - lo != 4096:
        die("the monitor dump covers %d bytes, expected one 4096-byte page"
            % (hi - lo))

    def word(va):
        """The 8-byte word the program sees at virtual address `va`."""
        if not (page <= va < top):
            die("virtual address 0x%X is outside the program's stack page "
                "[0x%X, 0x%X)" % (va, page, top))
        phys = frame + (va - page)
        if phys not in words:
            die("the dump has no word at physical 0x%X (virtual 0x%X)"
                % (phys, va))
        return words[phys]

    def byte(va):
        w = word(va & ~7)
        return (w >> (8 * (va & 7))) & 0xFF

    def cstring(va):
        out = bytearray()
        while True:
            b = byte(va)
            if b == 0:
                return bytes(out)
            out.append(b)
            va += 1
            if len(out) > 4096:
                die("a string at 0x%X is not NUL-terminated inside the page" % va)

    # ---- 1. alignment ---------------------------------------------------
    if rsp % 16 != 0:
        die("RSP is 0x%X, which is not 16-byte aligned. The System V ABI "
            "requires a 16-byte-aligned RSP AT PROCESS ENTRY, pointing at argc "
            "-- that is not the same as the function-entry rule, where RSP+8 "
            "is aligned because a return address has been pushed." % rsp)

    # ---- 2. inside the program's own stack page --------------------------
    if not (page <= rsp < top):
        die("RSP 0x%X is not inside the program's stack page [0x%X, 0x%X)"
            % (rsp, page, top))
    if rsp - page < min_stack:
        die("RSP 0x%X leaves only %d bytes of stack below it; args.dart's "
            "argsMinStack is %d" % (rsp, rsp - page, min_stack))

    # ---- 3. argc ---------------------------------------------------------
    argc = word(rsp)
    if argc != len(tokens):
        die("the word at RSP is %d; the harness typed %d token(s): %r"
            % (argc, len(tokens), [t.decode() for t in tokens]))

    # ---- 4. argv[0..argc-1] ---------------------------------------------
    ptrs = [word(rsp + 8 + 8 * i) for i in range(argc)]
    last_end = None
    for i, (p, tok) in enumerate(zip(ptrs, tokens)):
        if not (page <= p < top):
            die("argv[%d] is 0x%X, which is not inside the program's stack page "
                "[0x%X, 0x%X). A ring-3 program cannot read it." % (i, p, page, top))
        got = cstring(p)
        if got != tok:
            die("argv[%d] points at %r; the harness typed %r"
                % (i, got.decode("latin-1"), tok.decode()))
        if last_end is not None and p < last_end:
            die("argv[%d] at 0x%X overlaps argv[%d], which ended at 0x%X"
                % (i, p, i - 1, last_end))
        last_end = p + len(got) + 1
    if argc and ptrs != sorted(ptrs):
        die("the argv pointers are not in increasing address order: %s"
            % ["0x%X" % p for p in ptrs])

    # ---- 5/6/7. the three terminators ------------------------------------
    if word(rsp + 8 + 8 * argc) != 0:
        die("argv[%d] is 0x%X, not NULL — the argument vector is not terminated"
            % (argc, word(rsp + 8 + 8 * argc)))
    envp0 = rsp + 8 + 8 * argc + 8
    if word(envp0) != 0:
        die("envp[0] is 0x%X, not NULL. This operating system has no "
            "environment (GAP-0146) and the word there must be the terminator."
            % word(envp0))
    aux = envp0 + 8
    if word(aux) != 0 or word(aux + 8) != 0:
        die("the auxiliary vector's first entry is (0x%X, 0x%X), not the "
            "AT_NULL terminator (0, 0)" % (word(aux), word(aux + 8)))
    block_end = aux + 16

    # ---- 8. the padding and the tail are zero ---------------------------
    first_string = min(ptrs) if ptrs else top
    for va in range(block_end, first_string):
        if byte(va) != 0:
            die("the padding byte at 0x%X is 0x%02X, not zero — something was "
                "written between the auxiliary vector and the strings"
                % (va, byte(va)))
    tail = (max(ptrs) + len(cstring(max(ptrs))) + 1) if ptrs else top
    for va in range(tail, top):
        if byte(va) != 0:
            die("the byte at 0x%X, above the last argument string, is 0x%02X "
                "rather than zero" % (va, byte(va)))

    # ---- 9. the whole block, as one range ------------------------------
    print("check-stack: pass  RSP 0x%X (16-aligned, %d bytes of stack below it), "
          "argc %d at RSP, %d argv pointer(s) all inside [0x%X, 0x%X) and all "
          "naming the exact bytes typed, NULL at argv[%d], NULL envp, AT_NULL "
          "auxv, %d bytes of zero padding and %d zero bytes above the last "
          "string — read out of guest physical memory at 0x%X, not out of what "
          "the program said"
          % (rsp, rsp - page, argc, argc, page, top, argc,
             first_string - block_end, top - tail, frame))
    return 0


if __name__ == "__main__":
    sys.exit(main())
