#!/usr/bin/env python3
"""core/tests/conformance/m13-libc/check-session.py

Every expectation about the m13 session, in one place, so that it can be run
TWICE: once with the truth, and once with a deliberately wrong expectation that
MUST fail.

    check-session.py <serial> <derive.py> <progL.elf> <progN.elf> --reuse-ids 0
    check-session.py <serial> <derive.py> <progL.elf> <progN.elf> --reuse-ids 0,1

The second form asserts that BOTH processes reused memory. progN is progL with
`free()` disabled, so it does not, and the second form must exit non-zero. A
harness whose reuse check passes for a program that cannot reuse is measuring
nothing, and three previous milestones each shipped exactly one check with that
shape before their own harness caught it.

Nothing in this file is a constant typed twice: every address, every size, every
exit status and every teardown count comes out of derive.py, which computes them
from the two ELF files.

Exit status: 0 if every check passed, 1 otherwise (with the reasons on stderr).
"""

import importlib.util
import re
import sys


def main():
    argv = sys.argv[1:]
    args, reuse_ids, i = [], set(), 0
    while i < len(argv):
        if argv[i] == "--reuse-ids":
            reuse_ids = {int(x) for x in argv[i + 1].split(",") if x != ""}
            i += 2
            continue
        args.append(argv[i])
        i += 1
    if len(args) != 4:
        raise SystemExit("usage: check-session.py <serial> <derive.py> <progL.elf> <progN.elf> "
                         "--reuse-ids 0[,1]")
    cap = open(args[0], "rb").read().decode("latin-1")
    spec = importlib.util.spec_from_file_location("m13_derive", args[1])
    D = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(D)
    elfs = {0: D.Elf(open(args[2], "rb").read()), 1: D.Elf(open(args[3], "rb").read())}

    fails = []

    # --- the two builds are the two things they are supposed to be ---------
    if D.free_enabled(elfs[0]) != 1:
        fails.append("progL was built with free() disabled")
    if D.free_enabled(elfs[1]) != 0:
        fails.append("progN was built with free() ENABLED — the negative control is not a control")
    if D.prog_id(elfs[0]) != 0 or D.prog_id(elfs[1]) != 1:
        fails.append("the two builds do not carry progId 0 and 1")

    base = {p: D.heap_base_of(elfs[p]) for p in (0, 1)}
    if base[0] != base[1]:
        fails.append("the two builds have different heap bases (0x%X, 0x%X); their offsets "
                     "cannot be compared" % (base[0], base[1]))

    # --- the kernel's FIRST sbrk(0) is the top of the program's own PT_LOADs -
    k0 = re.search(r"PROC HEAP 00 INC 0{16} OLD ([0-9A-F]{16}) NEW ([0-9A-F]{16}) "
                   r"PAGES ([0-9A-F]{8})", cap)
    if not k0:
        fails.append("the kernel never printed a PROC HEAP line for slot 0's sbrk(0)")
    else:
        if int(k0.group(1), 16) != base[0] or int(k0.group(2), 16) != base[0]:
            fails.append("the kernel's first PROC HEAP line reports OLD/NEW 0x%s/0x%s; progL's "
                         "own PT_LOADs end at 0x%X" % (k0.group(1), k0.group(2), base[0]))
        if int(k0.group(3), 16) != 0:
            fails.append("the library's first call, sbrk(0), allocated %d page(s)"
                         % int(k0.group(3), 16))

    # --- what each process printed ----------------------------------------
    got = {}
    for p in (0, 1):
        e = elfs[p]
        want_off = D.block_layout(e)
        want_kern = D.kernel_bytes(e)

        m = re.search(r"USER WRITE L%d START BASE ([0-9a-f]+)$" % p, cap, re.M)
        if not m:
            fails.append("process %d never printed its START line -- note the address is "
                         "LOWERCASE hex, which is printf's %%x and could not have come from "
                         "the kernel's uartPutHex" % p)
        elif int(m.group(1), 16) != base[p]:
            fails.append("process %d's printf reported base 0x%s; its ELF says 0x%X"
                         % (p, m.group(1), base[p]))

        blks = re.findall(r"USER WRITE L%d BLK ([0-9a-f]+) ([0-9a-f]+) ([0-9a-f]+)$" % p,
                          cap, re.M)
        if len(blks) != 2:
            fails.append("process %d printed %d BLK lines, expected 2" % (p, len(blks)))
        else:
            offs = [int(x, 16) for grp in blks for x in grp]
            if offs != want_off:
                fails.append("process %d's malloc returned offsets %s; derive.py computes %s "
                             "from mallocHdrBytes, mallocAlign and reqSize READ OUT OF THE ELF"
                             % (p, [hex(x) for x in offs], [hex(x) for x in want_off]))
            for o in offs:
                if o & (D.alloc_params(e)[1] - 1):
                    fails.append("process %d got an unaligned block at +0x%X" % (p, o))
                if not (0 < o < D.HEAP_TOP - base[p]):
                    fails.append("process %d got a block at +0x%X, outside its own heap" % (p, o))

        m = re.search(r"USER WRITE L%d KERNB ([0-9a-f]+) BRK ([0-9a-f]+)$" % p, cap, re.M)
        if not m:
            fails.append("process %d never printed its KERNB line" % p)
        else:
            kb, brk = int(m.group(1), 16), int(m.group(2), 16)
            if kb != want_kern:
                fails.append("process %d's malloc took 0x%X bytes from the kernel for its six "
                             "blocks; derive.py's model of the allocator says 0x%X"
                             % (p, kb, want_kern))
            if brk != kb:
                fails.append("process %d: the break moved 0x%X but malloc counted 0x%X taken "
                             "from the kernel; every byte of the break must have gone through "
                             "the allocator" % (p, brk, kb))

        # The kernel's OWN view of the same number, from a subsystem that has
        # never heard of this allocator.
        heap_lines = re.findall(r"PROC HEAP 0%d INC ([0-9A-F]{16}) OLD ([0-9A-F]{16}) "
                                r"NEW ([0-9A-F]{16}) PAGES ([0-9A-F]{8})" % p, cap)
        if not heap_lines:
            fails.append("the kernel printed no PROC HEAP lines for slot %d" % p)
        else:
            newest = int(heap_lines[-1][2], 16)
            if newest < base[p] + want_kern:
                fails.append("the kernel's last PROC HEAP for slot %d reports a break of 0x%X; "
                             "the allocator must have moved it at least 0x%X past the base "
                             "0x%X" % (p, newest, want_kern, base[p]))

        m = re.search(r"USER WRITE L%d SUM REUSE (\d+) COAL (\d+) R2 (\d+) FAILS (\d+)$" % p,
                      cap, re.M)
        if not m:
            fails.append("process %d never printed its SUM line" % p)
            continue
        reuse, coal, r2, f = (int(x) for x in m.groups())
        got[p] = (reuse, coal, r2, f)
        if f != 0:
            fails.append("process %d reported %d failed self-check(s)" % (p, f))

        expect = 1 if p in reuse_ids else 0
        for name, v in (("REUSE", reuse), ("COALESCE", coal), ("ROUND2", r2)):
            if v != expect:
                fails.append("process %d reported %s %d, expected %d. progL's free() returns "
                             "blocks to the allocator and progN's does not, and that is the "
                             "ONLY difference between the two binaries."
                             % (p, name, v, expect))

        # --- printf, conversion by conversion -----------------------------
        if ("USER WRITE L%d FMT [abc] [-12345] [beef] [Q] [%%]" % p) not in cap:
            fails.append("process %d's printf did not format %%s %%d %%x %%c %%%% correctly. "
                         "The five it implements are the five that must be exact." % p)
        badline = re.search(r"USER WRITE L%d BAD (.*)$" % p, cap, re.M)
        if not badline:
            fails.append("process %d never printed its BAD line" % p)
        else:
            marks = badline.group(1).count("%!")
            if marks != 4:
                fails.append("process %d's four unsupported conversions produced %d `%%!` "
                             "markers, expected 4: %r. An unsupported conversion that vanishes "
                             "silently turns a missing feature into wrong output."
                             % (p, marks, badline.group(1)))
        ovf = re.search(r"USER WRITE L%d OVF (.*)$" % p, cap, re.M)
        if not ovf:
            fails.append("process %d never printed its OVF line" % p)
        else:
            line = "L%d OVF %s" % (p, ovf.group(1))
            if not line.endswith(D.OVF_MARK):
                fails.append("process %d's over-long printf did not end in %r; it truncated "
                             "silently" % (p, D.OVF_MARK))
            if len(line) != D.PRINTF_MAX + len(D.OVF_MARK):
                fails.append("process %d's over-long printf produced %d bytes, expected %d "
                             "(PRINTF_MAX + the marker)"
                             % (p, len(line), D.PRINTF_MAX + len(D.OVF_MARK)))
            if len(line) > D.USER_WRITE_MAX:
                fails.append("process %d's overflow line is %d bytes, above the kernel's "
                             "%d-byte limit: the kernel would have REFUSED it and the marker "
                             "would never have been seen" % (p, len(line), D.USER_WRITE_MAX))
        if ("USER WRITE L%d OVFRET -1" % p) not in cap:
            fails.append("process %d's over-long printf did not return -1" % p)

        # --- failure propagates -------------------------------------------
        m = re.search(r"USER WRITE L%d HUGE (\d) SBRKERR ([0-9a-f]+)$" % p, cap, re.M)
        if not m:
            fails.append("process %d never reported the result of an oversized malloc" % p)
        else:
            if m.group(1) != "1":
                fails.append("process %d's malloc of four megabytes did not return NULL; the "
                             "whole window is two" % p)
            if int(m.group(2), 16) != (D.HEAP_RET_BADARG & 0xFFFFFFFF):
                fails.append("process %d's sbrk error after the oversized malloc was 0x%s; "
                             "heap.dart's heapRetBadArg is 0x%X"
                             % (p, m.group(2), D.HEAP_RET_BADARG & 0xFFFFFFFF))

        # --- the struct that clang copied with its own memcpy --------------
        if ("USER WRITE L%d REC ada lovelace 99 5a" % p) not in cap:
            fails.append("process %d never printed the record it built with a struct "
                         "assignment, strcpy and printf" % p)

    # --- the kernel read a string out of memory malloc handed out ---------
    n_heapwrite = cap.count("USER WRITE THIS LINE WAS READ BY THE KERNEL OUT OF MY MALLOC")
    if n_heapwrite != 2:
        fails.append("the kernel printed a line out of a malloc'd buffer %d times, expected 2 "
                     "(once per process). `elfOwns` walks the live page tables before believing "
                     "a ring-3 pointer, so this line IS the kernel confirming the mapping."
                     % n_heapwrite)

    # --- progN must have cost the machine MORE than progL -----------------
    kb = {}
    for p in (0, 1):
        m = re.search(r"USER WRITE L%d ROUND2 (\d) KERNB ([0-9a-f]+)$" % p, cap, re.M)
        if m:
            kb[p] = int(m.group(2), 16)
    if 0 in kb and 1 in kb:
        if not kb[1] > kb[0]:
            fails.append("after freeing everything and allocating it all again, progL had "
                         "taken 0x%X bytes from the kernel and progN 0x%X. The control build "
                         "cannot reuse anything, so it MUST have taken more."
                         % (kb[0], kb[1]))
    else:
        fails.append("one of the two processes never printed its ROUND2 line")

    # --- nothing faulted --------------------------------------------------
    if "USER FAULT" in cap:
        fails.append("a USER FAULT appears in a session in which nothing is supposed to fault")

    # --- the exit statuses, computed from the two files --------------------
    for p, slot in ((0, "00"), (1, "01")):
        if p not in got:
            continue
        reuse, coal, r2, f = got[p]
        want = D.exit_status(elfs[p], reuse, coal, r2, f)
        m = re.search(r"PROC EXIT SLOT %s ID [0-9A-F]{8} CODE ([0-9A-F]{16})" % slot, cap)
        if not m:
            fails.append("no PROC EXIT line for slot %s" % slot)
        elif int(m.group(1), 16) != want:
            fails.append("slot %s exited with 0x%s; exitBase + dataWord + the three flags, read "
                         "out of the ELF, is 0x%016X" % (slot, m.group(1), want))
    if 0 in got and 1 in got:
        d0 = D.exit_status(elfs[0], 1, 1, 1, 0)
        d1 = D.exit_status(elfs[1], 0, 0, 0, 0)
        if d0 - d1 != 0x111000:
            fails.append("the two builds' expected exit statuses differ by 0x%X, not 0x111000"
                         % (d0 - d1))

    # --- the teardown count, derived from each ELF -------------------------
    for p, slot in ((0, "00"), (1, "01")):
        if p not in kb:
            continue
        prog_pages = len(elfs[p].pages())
        heap_pages = kb[p] // D.PAGE_BYTES
        want = prog_pages + 1 + heap_pages + 4
        m = re.search(r"PROC KILL SLOT %s FREED ([0-9A-F]{8})" % slot, cap)
        if not m:
            fails.append("no PROC KILL line for slot %s" % slot)
        elif int(m.group(1), 16) != want:
            fails.append("slot %s freed %d frames; its ELF has %d program pages, plus 1 stack, "
                         "plus %d heap pages that malloc took, plus 4 table frames = %d"
                         % (slot, int(m.group(1), 16), prog_pages, heap_pages, want))

    # --- the leak check, exact --------------------------------------------
    frames = re.findall(r"PMM MANAGED [0-9A-F]{8} FREE ([0-9A-F]{8}) USED ([0-9A-F]{8})", cap)
    if len(frames) < 2:
        fails.append("expected at least two `frames` reports, got %d" % len(frames))
    elif frames[0] != frames[-1]:
        fails.append("the allocator's free count is %s before the session and %s after it"
                     % (frames[0][0], frames[-1][0]))

    if not re.search(r"PROC CAP [0-9A-F]{8} USED 00000000 LIVE 00000000", cap):
        fails.append("`proc` after the session does not report USED 0 LIVE 0")

    if fails:
        for f in fails:
            print("    - " + f, file=sys.stderr)
        return 1
    print("    (heap base 0x%X from progL's own PT_LOADs; six blocks at %s, every offset "
          "recomputed from mallocHdrBytes/mallocAlign/reqSize in the ELF; 0x%X bytes taken "
          "from the kernel by progL and 0x%X by the free()-disabled control; free count %s "
          "before and after)"
          % (base[0], " ".join(hex(x) for x in D.block_layout(elfs[0])),
             kb.get(0, 0), kb.get(1, 0), frames[0][0] if frames else "?"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
