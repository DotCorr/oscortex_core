#!/usr/bin/env python3
"""core/tests/conformance/m15-fileio/derive.py

Computes, ON THE HOST, every number the boot is required to produce — out of
the volume make-image.py just wrote and the ELFs build-progs.sh just linked.
Nothing here is read back out of the kernel and nothing is typed twice: the
constants that describe the program's read loop are parsed OUT OF prog.c, and
the constants that describe the kernel's refusals are parsed OUT OF file.dart.

The output is `key=value`, one per line, for run.sh to grep.

WHY THE COUNTERS ARE DERIVED AND NOT BOUNDED. `FILE OPENS ... READS ... BYTES
... CHAINS` is a line the kernel prints at exit, and every one of those numbers
is a consequence of prog.c's call sequence and the sizes of the files on the
volume. Computing them here makes the kernel's line a claim that can be wrong;
asserting `> 0` would make it a claim that cannot be.
"""

import os
import re
import struct
import sys

FNV_INIT = 0x811C9DC5
FNV_PRIME = 16777619


def fnv1a(b):
    h = FNV_INIT
    for c in b:
        h ^= c
        h = (h * FNV_PRIME) & 0xFFFFFFFF
    return h


def ro_range(path):
    """The R+X PT_LOAD's file bytes, which is what __ro_start/__ro_end bracket."""
    f = open(path, "rb").read()
    phoff = struct.unpack_from("<Q", f, 32)[0]
    phnum = struct.unpack_from("<H", f, 56)[0]
    for i in range(phnum):
        p = phoff + i * 56
        typ, flags = struct.unpack_from("<II", f, p)
        off, = struct.unpack_from("<Q", f, p + 8)
        filesz, = struct.unpack_from("<Q", f, p + 32)
        if typ == 1 and (flags & 1):
            return f[off:off + filesz]
    raise SystemExit("derive: %s has no executable PT_LOAD" % path)


def cconst(src, name):
    m = re.search(r"^#define %s (\d+)" % re.escape(name), src, re.M)
    if not m:
        raise SystemExit("derive: prog.c has no #define %s" % name)
    return int(m.group(1))


def dartconst(src, name):
    m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(name), src, re.M)
    if not m:
        raise SystemExit("derive: file.dart has no const int %s" % name)
    return int(m.group(1), 0)


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: derive.py <img> <prog.elf> <progn.elf> <kernel-src-dir>")
    img, prog, progn, kdir = sys.argv[1:5]

    data = open(img + ".data", "rb").read()
    other = open(img + ".other", "rb").read()
    small = open(img + ".small", "rb").read()
    contig = open(img + ".contig", "rb").read()

    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "prog.c")).read()
    CHUNK = cconst(src, "CHUNK")
    ALT = cconst(src, "ALT")
    ALTN = cconst(src, "ALTN")
    PEEK = cconst(src, "PEEK")

    hdr = open(os.path.join(kdir, "..", "user", "libc", "oslibc.h")).read()
    m = re.search(r"^#define RFILE_BUFSZ (\d+)", hdr, re.M)
    BUFSZ = int(m.group(1))

    fdart = open(os.path.join(kdir, "file.dart")).read()

    out = {}

    # ---- the volume ----------------------------------------------------
    out["data_bytes"] = len(data)
    out["other_bytes"] = len(other)
    out["small_bytes"] = len(small)

    # ---- phase 1: the whole file in CHUNK-byte pieces -------------------
    out["chunk"] = CHUNK
    out["data_reads"] = (len(data) + CHUNK - 1) // CHUNK
    out["data_fnv"] = fnv1a(data)

    # The NEGATIVE CONTROL's answer: it hashes CHUNK bytes every time, and the
    # buffer is memset to zero before each read, so the last chunk is the tail
    # of the file followed by zeroes.
    negbuf = bytearray()
    off = 0
    while off < len(data):
        piece = data[off:off + CHUNK]
        negbuf += piece + b"\0" * (CHUNK - len(piece))
        off += CHUNK
    out["neg_fnv"] = fnv1a(bytes(negbuf))
    if out["neg_fnv"] == out["data_fnv"]:
        raise SystemExit("derive: the negative control hashes the same value as the real "
                         "program; the file size must not be a multiple of CHUNK")

    # What a CONTIGUOUS reader would have hashed. Must never appear.
    out["contig_fnv"] = fnv1a(contig)
    if out["contig_fnv"] == out["data_fnv"]:
        raise SystemExit("derive: a contiguous read of DATA.BIN hashes the same as the "
                         "chained one; this volume proves nothing")

    # ---- phase 3: the alternating reads ---------------------------------
    out["alt_bytes"] = ALT * ALTN
    out["alt_fnva"] = fnv1a(data[:ALT * ALTN])
    out["alt_fnvb"] = fnv1a(other[:ALT * ALTN])

    # ---- phase 4: two descriptors on the same file, independent offsets --
    out["peek_at5000"] = fnv1a(data[5000:5000 + PEEK])
    out["peek_atalt"] = fnv1a(data[ALT * ALTN:ALT * ALTN + PEEK])
    if out["peek_at5000"] == out["peek_atalt"]:
        raise SystemExit("derive: the two 16-byte peeks hash the same, so 'two descriptors "
                         "keep independent offsets' would be untestable")

    # ---- the exit statuses ----------------------------------------------
    out["exit"] = (out["data_fnv"] ^ out["alt_fnvb"]) & 0xFF
    out["neg_exit"] = (out["neg_fnv"] ^ out["alt_fnvb"]) & 0xFF
    if out["exit"] == out["neg_exit"]:
        raise SystemExit("derive: the real program and its negative control exit with the "
                         "same status; the control controls for nothing observable")

    # ---- the buffered layer ---------------------------------------------
    out["rf_bytes"] = len(data)
    out["rf_fnv"] = out["data_fnv"]
    lines = small.split(b"\n")
    if lines and lines[-1] == b"":
        lines = lines[:-1]
    out["rf_lines"] = len(lines)
    out["rf_chars"] = len(small)
    out["first_line"] = lines[0].decode("latin-1")

    # ---- the kernel's own exit line -------------------------------------
    #
    # Every number below is a consequence of prog.c's call sequence. They are
    # written out in the order the program makes them so that a reader can
    # check the arithmetic against the source rather than trust it.
    opens = 7        # DATA, OTHER, DATA again, SMALL, and three rfopen()s
    closes = 6       # one per successful open EXCEPT fd3, which the program
                     # deliberately leaves open so the teardown has to close it
    seeks = 5        # 0, size-8, size (phase 2); 0 (phase 3); 5000 (phase 4)
    refused = 14     # the fifth open, the seek past the end, four bad opens, a
                     # bad NAME pointer, a zero-length file, FIVE bad reads (one
                     # of them a range straddling the end of the mapped image)
                     # and one bad close
    reads = 0
    rbytes = 0
    # phase 1
    reads += out["data_reads"]
    rbytes += len(data)
    # phase 2: the head and the tail markers (the read AT the end returns 0 and
    # is not counted -- the kernel's EOF arm bumps nothing)
    reads += 2
    rbytes += 16
    # phase 3
    reads += 2 * ALTN
    rbytes += 2 * ALTN * ALT
    # phase 4
    reads += 2
    rbytes += 2 * PEEK
    # phase 7a: rfread over the whole of DATA.BIN, one BUFSZ read at a time
    reads += (len(data) + BUFSZ - 1) // BUFSZ
    rbytes += len(data)
    # phase 7b and 7c: SMALL.TXT twice, one short read each
    reads += 2
    rbytes += 2 * len(small)
    out["k_opens"] = opens
    out["k_closes"] = closes
    out["k_seeks"] = seeks
    out["k_refused"] = refused
    out["k_reads"] = reads
    out["k_bytes"] = rbytes
    # Chain rebuilds: one per read in the alternating phase, and nowhere else,
    # because every other read follows an open() of the same file.
    out["k_chains"] = 2 * ALTN
    # Peak concurrent descriptors: the program deliberately holds all four at
    # once before it opens a fifth.
    out["k_peak"] = dartconst(fdart, "fileMaxFds")
    # Descriptors the program left open for the teardown to close.
    out["k_orphans"] = 1
    # Sectors are BOUNDED rather than derived: the exact count depends on where
    # every read starts inside a sector, which is a simulation of the program
    # rather than a property of the volume. The bounds are still tight.
    out["k_sectors_lo"] = (rbytes + 511) // 512
    out["k_sectors_hi"] = reads * 2 + (rbytes // 512) + 4

    # ---- the refusal values, read out of the kernel ---------------------
    for key, name in (("ret_notfound", "fileRetNotFound"),
                      ("ret_isdir", "fileRetIsDir"),
                      ("ret_badname", "fileRetBadName"),
                      ("ret_badlen", "fileRetBadLen"),
                      ("ret_badptr", "fileRetBadPtr"),
                      ("ret_badfd", "fileRetBadFd"),
                      ("ret_noslot", "fileRetNoSlot"),
                      ("ret_badseek", "fileRetBadSeek"),
                      ("ret_io", "fileRetIo"),
                      ("ret_empty", "fileRetEmpty")):
        out[key] = "%x" % (dartconst(fdart, name) & 0xFFFFFFFF)
    out["max_fds"] = dartconst(fdart, "fileMaxFds")
    out["read_max"] = dartconst(fdart, "fileReadMax")

    # ---- the programs' self-hashes --------------------------------------
    ro = ro_range(prog)
    out["self_bytes"] = len(ro)
    out["self_fnv"] = fnv1a(ro)
    ron = ro_range(progn)
    out["neg_self_bytes"] = len(ron)
    out["neg_self_fnv"] = fnv1a(ron)

    for k in sorted(out):
        v = out[k]
        if isinstance(v, int):
            print("%s=%d" % (k, v))
        else:
            print("%s=%s" % (k, v))
    # And the hex spellings the program prints, since printf uses lower-case
    # hex with no leading zeros.
    for k in ("data_fnv", "neg_fnv", "contig_fnv", "alt_fnva", "alt_fnvb",
              "peek_at5000", "peek_atalt", "self_fnv", "neg_self_fnv", "rf_fnv"):
        print("%s_hex=%x" % (k, out[k]))
    for k in ("data_bytes", "data_reads", "alt_bytes", "rf_bytes", "rf_lines",
              "rf_chars", "self_bytes", "neg_self_bytes"):
        print("%s_hex=%x" % (k, out[k]))


if __name__ == "__main__":
    main()
