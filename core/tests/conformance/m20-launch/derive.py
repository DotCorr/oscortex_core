#!/usr/bin/env python3
"""core/tests/conformance/m19-argv/derive.py

Computes, ON THE HOST, every number the M19 boots are required to produce.

Nothing in run.sh is a literal that came from watching the kernel. The counts
come from counting the bytes make-image.py wrote; the exit statuses come from
evaluating prog.c's own expression over those counts; the kernel's bounds and
refusal codes come from parsing core/kernel/args.dart; and the C library's view
of the same numbers comes from parsing core/user/libc/oslibc.h. When any of
those disagree, this script says so instead of the harness quietly passing.

Usage:
    derive.py <disk.img> <wc.elf> <wcn.elf> <kernel-dir> <libc-dir> <prog.c>

Output: KEY=VALUE lines on stdout.
"""

import os
import re
import struct
import sys


def die(msg):
    print("derive: %s" % msg, file=sys.stderr)
    raise SystemExit(2)


def dartconst(src, name):
    m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(name), src, re.M)
    if not m:
        die("core/kernel does not define `const int %s`" % name)
    return int(m.group(1), 0)


def cdefine(src, name):
    m = re.search(r"^#define %s (0x[0-9A-Fa-f]+UL|\d+UL|\d+)\b" % re.escape(name), src, re.M)
    if not m:
        die("oslibc.h does not define %s" % name)
    return int(m.group(1).rstrip("UL"), 0)


def counts(blob):
    """THE THREE COLUMNS, counted the way prog.c is required to count them.

    `lines` is NEWLINE CHARACTERS, not "lines of text": ALPHA.TXT's last line
    has no newline and therefore does not count, which is the classic `wc`
    boundary and is why the two files differ about it on purpose.

    `words` is RUNS of non-whitespace, over the same six whitespace bytes
    prog.c's isSpaceByte lists -- not `str.split()`, which would agree here by
    accident and would stop agreeing the day the program met a vertical tab.
    """
    lines = blob.count(b"\n")
    space = set(b" \n\t\r\v\f")
    words = 0
    inword = False
    for c in blob:
        if c in space:
            inword = False
        elif not inword:
            inword = True
            words += 1
    return lines, words, len(blob)


def status_of(l, w, c):
    """prog.c's statusOf, evaluated here rather than read off a boot."""
    return ((l * 31 + w) * 31 + c) & 0xFF


def main():
    if len(sys.argv) != 7:
        die("usage: derive.py <disk.img> <wc.elf> <wcn.elf> <kernel-dir> "
            "<libc-dir> <prog.c>")
    img_path, wc_path, wcn_path, kdir, libc_dir, progc_path = sys.argv[1:7]

    args_src = open(os.path.join(kdir, "args.dart")).read()
    vm_src = open(os.path.join(kdir, "vm.dart")).read()
    libc_h = open(os.path.join(libc_dir, "oslibc.h")).read()
    progc = open(progc_path).read()

    out = {}

    # ---- the kernel's bounds and the library's copy of them ---------------
    max_count = dartconst(args_src, "argsMaxCount")
    max_bytes = dartconst(args_src, "argsMaxBytes")
    min_stack = dartconst(args_src, "argsMinStack")
    store_bytes = dartconst(args_src, "argsStoreBytes")
    meta_off = dartconst(args_src, "argsMetaOffset")
    off_off = dartconst(args_src, "argsOffOffset")
    text_off = dartconst(args_src, "argsTextOffset")
    meta_words = dartconst(args_src, "argsMetaWords")
    stack_top = dartconst(vm_src, "vmProgStackTop")
    stack_page = dartconst(vm_src, "vmProgStackPage")

    if cdefine(libc_h, "ARGS_MAX_COUNT") != max_count:
        die("oslibc.h's ARGS_MAX_COUNT is not args.dart's argsMaxCount")
    if cdefine(libc_h, "ARGS_MAX_BYTES") != max_bytes:
        die("oslibc.h's ARGS_MAX_BYTES is not args.dart's argsMaxBytes")

    out["max_count"] = max_count
    out["max_bytes"] = max_bytes
    out["min_stack"] = min_stack
    out["store_bytes"] = store_bytes
    out["meta_off"] = meta_off
    out["off_off"] = off_off
    out["text_off"] = text_off
    out["meta_words"] = meta_words
    out["stack_top"] = stack_top
    out["stack_page"] = stack_page

    # The region arithmetic, multiplied out here so a block whose regions
    # overlapped would fail on the host rather than corrupt the one after it.
    if meta_off != 0:
        die("argsMetaOffset is %d, expected 0" % meta_off)
    if meta_off + meta_words * 8 != off_off:
        die("the %d metadata words at %d do not end where the offset array "
            "begins (%d)" % (meta_words, meta_off, off_off))
    if off_off + max_count * 8 != text_off:
        die("the %d offsets at %d do not end where the text begins (%d)"
            % (max_count, off_off, text_off))
    if text_off + max_bytes != store_bytes:
        die("the %d bytes of text at %d do not end at the block's end (%d)"
            % (max_bytes, text_off, store_bytes))

    # ---- the refusal codes, and that they are distinct --------------------
    errs = dict(re.findall(r"^const int (argsErr[A-Za-z]+) = (\d+);", args_src, re.M))
    for name in ("argsErrOk", "argsErrTooMany", "argsErrTooLong",
                 "argsErrBadByte", "argsErrNoRoom"):
        if name not in errs:
            die("args.dart does not define %s" % name)
        out["err_" + name[7:].lower()] = int(errs[name])
    vals = [int(v) for v in errs.values()]
    if len(set(vals)) != len(vals):
        die("args.dart's refusal codes are not distinct: %r" % errs)
    out["err_count"] = len(vals)

    # ---- the two text files, straight off the image ----------------------
    img = open(img_path, "rb").read()
    bps = struct.unpack_from("<H", img, 11)[0]
    spc = img[13]
    reserved = struct.unpack_from("<H", img, 14)[0]
    nfats = img[16]
    rootents = struct.unpack_from("<H", img, 17)[0]
    fatsz = struct.unpack_from("<H", img, 22)[0]
    root_start = reserved + nfats * fatsz
    root_sectors = (rootents * 32) // bps
    data_start = root_start + root_sectors
    fat = img[reserved * bps:(reserved + fatsz) * bps]

    def find(name):
        raw = (name.split(".")[0].ljust(8) + name.split(".")[1].ljust(3)).encode()
        for i in range(rootents):
            at = root_start * bps + i * 32
            e = img[at:at + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F:
                continue
            if e[0:11] == raw:
                return (struct.unpack_from("<H", e, 26)[0],
                        struct.unpack_from("<I", e, 28)[0])
        die("%s is not in the image's root directory" % name)

    def read_file(name):
        first, size = find(name)
        blob = b""
        c = first
        seen = set()
        while len(blob) < size:
            if c in seen:
                die("%s's chain is a cycle" % name)
            seen.add(c)
            at = (data_start + (c - 2) * spc) * bps
            blob += img[at:at + spc * bps]
            c = struct.unpack_from("<H", fat, c * 2)[0]
            if c >= 0xFFF8:
                break
        return blob[:size]

    alpha = read_file("ALPHA.TXT")
    beta = read_file("BETA.TXT")

    ca, cb = counts(alpha), counts(beta)
    for i, col in enumerate(("lines", "words", "chars")):
        if ca[i] == cb[i]:
            die("ALPHA.TXT and BETA.TXT have the same %s count; the harness "
                "cannot tell an argument that was used from one that was not"
                % col)
    out["alpha_lines"], out["alpha_words"], out["alpha_chars"] = ca
    out["beta_lines"], out["beta_words"], out["beta_chars"] = cb
    out["alpha_status"] = "%x" % status_of(*ca)
    out["beta_status"] = "%x" % status_of(*cb)

    tot = tuple(a + b for a, b in zip(ca, cb))
    out["both_lines"], out["both_words"], out["both_chars"] = tot
    out["both_status"] = "%x" % status_of(*tot)

    # ---- the chunk the program reads in, and how many reads that is ------
    def elfsym_word(path, name):
        """The value of a `volatile const unsigned long` in the built ELF.

        The symbol's ADDRESS comes from the symbol table and its BYTES come from
        the PT_LOAD that covers that address -- the same two steps the kernel's
        loader takes, so a number read here is a number the guest will see.
        """
        data = open(path, "rb").read()
        shoff = struct.unpack_from("<Q", data, 40)[0]
        shentsize = struct.unpack_from("<H", data, 58)[0]
        shnum = struct.unpack_from("<H", data, 60)[0]

        def sh(i):
            o = shoff + i * shentsize
            (sh_name, sh_type, sh_flags, sh_addr, sh_off, sh_size,
             sh_link, sh_info, sh_align, sh_ent) = struct.unpack_from(
                "<IIQQQQIIQQ", data, o)
            return dict(type=sh_type, addr=sh_addr, off=sh_off, size=sh_size,
                        link=sh_link)

        symtab = None
        for i in range(shnum):
            s_ = sh(i)
            if s_["type"] == 2:          # SHT_SYMTAB
                symtab = s_
                break
        if symtab is None:
            die("%s has no symbol table" % path)
        strtab = sh(symtab["link"])
        addr = None
        for i in range(symtab["size"] // 24):
            o = symtab["off"] + i * 24
            nameoff, info, other, shndx, value, size = struct.unpack_from(
                "<IBBHQQ", data, o)
            e = data.index(b"\0", strtab["off"] + nameoff)
            if data[strtab["off"] + nameoff:e].decode() == name:
                addr = value
                break
        if addr is None:
            die("%s has no symbol %s" % (path, name))

        phoff = struct.unpack_from("<Q", data, 32)[0]
        phnum = struct.unpack_from("<H", data, 56)[0]
        for i in range(phnum):
            o = phoff + i * 56
            typ, flags = struct.unpack_from("<II", data, o)
            vaddr, = struct.unpack_from("<Q", data, o + 16)
            filesz, = struct.unpack_from("<Q", data, o + 32)
            poff, = struct.unpack_from("<Q", data, o + 8)
            if typ == 1 and vaddr <= addr < vaddr + filesz:
                return struct.unpack_from("<Q", data, poff + (addr - vaddr))[0]
        die("%s: %s at 0x%X is not inside any PT_LOAD's file bytes"
            % (path, name, addr))

    chunk = elfsym_word(wc_path, "wcChunk")
    out["chunk"] = chunk
    if elfsym_word(wc_path, "wcNeg") != 0:
        die("wc.elf was built with WC_NEG set; it is supposed to be the REAL one")
    if elfsym_word(wcn_path, "wcNeg") != 1:
        die("wcn.elf was not built with WC_NEG=1; it is not a negative control")
    for name, blob in (("alpha", alpha), ("beta", beta)):
        if len(blob) % chunk == 0:
            die("%s is a multiple of the %d-byte chunk; the last read would not "
                "be short" % (name, chunk))
        out[name + "_reads"] = (len(blob) + chunk - 1) // chunk

    # ---- what the NEGATIVE CONTROL prints, predicted ---------------------
    m = re.search(r'#define WC_NEG_FILE "([A-Z0-9.]+)"', progc)
    if not m:
        die("prog.c does not define WC_NEG_FILE")
    negname = m.group(1)
    negblob = {"ALPHA.TXT": alpha, "BETA.TXT": beta}.get(negname)
    if negblob is None:
        die("prog.c's WC_NEG_FILE is %s, which this image does not carry" % negname)
    cn = counts(negblob)
    out["neg_file"] = negname
    out["neg_lines"], out["neg_words"], out["neg_chars"] = cn
    out["neg_status"] = "%x" % status_of(*cn)
    # The control is only a control if what it prints differs from the truth
    # for the file it was TOLD to count.
    if cn == cb:
        die("the negative control's compiled-in file has the same counts as "
            "BETA.TXT; it controls for nothing")

    for k in sorted(out):
        print("%s=%s" % (k, out[k]))


if __name__ == "__main__":
    main()
