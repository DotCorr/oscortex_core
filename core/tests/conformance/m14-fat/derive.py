#!/usr/bin/env python3
"""core/tests/conformance/m14-fat/derive.py

Recomputes, from the IMAGE THE HARNESS JUST BUILT and the ELFs it put on it,
every number the kernel is required to print. Nothing here is typed in from a
transcript: `make-image.py --json` says where it put things and this reads the
bytes back off the disk to check that it did.

Three groups, and the third is the one this milestone exists for:

  1. GEOMETRY. The four region offsets and the cluster count, recomputed from
     the boot sector ON THE IMAGE with the same arithmetic the kernel uses.
     Computed from the SECTOR, not from make-image.py's constants, so a
     generator that wrote a boot sector disagreeing with its own layout is
     caught here rather than agreed with.

  2. THE DIRECTORY. Which root entries a correct driver lists and which it
     skips, and their names, attributes, first clusters and sizes.

  3. THE CHAINS, AND WHAT A CONTIGUOUS READER WOULD GET INSTEAD. For each file:
     the cluster chain walked out of the FAT, and -- for the two programs -- the
     FNV-1a hash of the R+X segment as the file really is, next to the hash the
     same program would compute if its clusters had been read consecutively
     from the first one. The harness requires the first to appear in the
     transcript and the second NOT to, which is the difference between a driver
     that follows a chain and one that assumes contiguity.

Usage:
    derive.py <image> <layout.json> <progA.elf> <progB.elf>

Prints `KEY=VALUE` lines. Exit status 0, or 3 if the image contradicts itself.
"""

import json
import struct
import sys


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def fnv1a(data):
    h = 0x811C9DC5
    for c in data:
        h = ((h ^ c) * 16777619) & 0xFFFFFFFF
    return h


def ro_range(path):
    """(vaddr, filesz, file_offset) of the R+X PT_LOAD."""
    f = open(path, "rb").read()
    phoff = struct.unpack_from("<Q", f, 32)[0]
    phnum = struct.unpack_from("<H", f, 56)[0]
    for i in range(phnum):
        p = phoff + i * 56
        typ, flags = struct.unpack_from("<II", f, p)
        off = struct.unpack_from("<Q", f, p + 8)[0]
        vaddr = struct.unpack_from("<Q", f, p + 16)[0]
        filesz = struct.unpack_from("<Q", f, p + 32)[0]
        if typ == 1 and (flags & 1):
            return vaddr, filesz, off
    raise SystemExit("derive: %s has no executable PT_LOAD" % path)


def entry_point(path):
    f = open(path, "rb").read()
    return struct.unpack_from("<Q", f, 24)[0]


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: derive.py <image> <layout.json> <progA.elf> <progB.elf>")
    img = open(sys.argv[1], "rb").read()
    layout = json.load(open(sys.argv[2]))
    progs = {"PROGA.ELF": sys.argv[3], "PROGB.ELF": sys.argv[4]}
    out = []

    # ---- 1. geometry, recomputed from the boot sector on the disk ----------
    bps = u16(img, 11)
    spc = img[13]
    rsv = u16(img, 14)
    nfat = img[16]
    rootent = u16(img, 17)
    tot16 = u16(img, 19)
    media = img[21]
    fatsz = u16(img, 22)
    tot32 = u32(img, 32)
    tot = tot16 if tot16 else tot32
    if u16(img, 510) != 0xAA55:
        raise SystemExit("derive: the image has no 55AA boot signature")
    rootsec = (rootent * 32) // bps
    fat_start = rsv
    root_start = rsv + nfat * fatsz
    data_start = root_start + rootsec
    clusters = (tot - data_start) // spc
    if not (4085 <= clusters < 65525):
        raise SystemExit("derive: %d clusters is not FAT16" % clusters)
    for k, v in (("bps", bps), ("spc", spc), ("rsv", rsv), ("nfat", nfat),
                 ("fatsz", fatsz), ("rootent", rootent), ("tot", tot),
                 ("fat_start", fat_start), ("root_start", root_start),
                 ("data_start", data_start), ("clusters", clusters),
                 ("media", media), ("root_sectors", rootsec)):
        out.append("%s=%d" % (k, v))
    # Cross-check against what make-image.py said it wrote. Two independent
    # statements of the same layout: the generator's, and the disk's.
    for k, want in (("bytes_per_sector", bps), ("sectors_per_cluster", spc),
                    ("reserved", rsv), ("num_fats", nfat), ("fat_sectors", fatsz),
                    ("root_entries", rootent), ("total_sectors", tot),
                    ("fat_start", fat_start), ("root_start", root_start),
                    ("data_start", data_start), ("cluster_count", clusters)):
        if layout[k] != want:
            raise SystemExit("derive: make-image.py says %s=%s and the boot sector says %s"
                             % (k, layout[k], want))

    fat = img[fat_start * bps:(fat_start + fatsz) * bps]
    if u16(fat, 0) != (0xFF00 | media):
        raise SystemExit("derive: FAT[0] is %04X, not %04X" % (u16(fat, 0), 0xFF00 | media))
    if u16(fat, 2) < 0xFFF8:
        raise SystemExit("derive: FAT[1] is not an end mark")

    def cluster_bytes(c):
        at = (data_start + (c - 2) * spc) * bps
        return img[at:at + spc * bps]

    def walk(first):
        chain, c = [], first
        while True:
            chain.append(c)
            nxt = u16(fat, c * 2)
            if nxt >= 0xFFF8:
                return chain
            if len(chain) > 4096:
                raise SystemExit("derive: chain from %d does not terminate" % first)
            c = nxt

    # ---- 2. the root directory --------------------------------------------
    root = img[root_start * bps:(root_start + rootsec) * bps]
    listed, skipped, walked = [], 0, 0
    for i in range(rootent):
        e = root[i * 32:(i + 1) * 32]
        if e[0] == 0x00:
            break
        walked += 1
        attr = e[11]
        if e[0] == 0xE5 or attr == 0x0F or (attr & 0x08):
            skipped += 1
            continue
        listed.append((i, e[0:11].decode("latin-1"), attr,
                       u16(e, 26), u32(e, 28)))
    out.append("dir_walked=%d" % walked)
    out.append("dir_listed=%d" % len(listed))
    out.append("dir_skipped=%d" % skipped)
    for n, (i, raw, attr, clus, size) in enumerate(listed):
        shown = raw[0:8] + "." + raw[8:11]
        line = "FS ENT %02X NAME %s ATTR %02X CLUS %04X SIZE %08X" % (
            i, shown, attr, clus, size)
        if attr & 0x10:
            line += " DIR"
        out.append("ls_line_%d=%s" % (n, line))
    out.append("ls_tail=FS LIST ENTRIES %04X LISTED %04X SKIPPED %04X"
               % (walked, len(listed), skipped))

    by_name = {}
    for i, raw, attr, clus, size in listed:
        by_name[raw[0:8].rstrip() + ("." + raw[8:11].rstrip() if raw[8:11].strip() else "")] = \
            (i, attr, clus, size)

    # ---- 3. the chains, and the contiguous counterfactual ------------------
    for name in ("HELLO.TXT", "PROGA.ELF", "PROGB.ELF"):
        if name not in by_name:
            raise SystemExit("derive: %s is not listed in the root directory" % name)
        i, attr, first, size = by_name[name]
        chain = walk(first)
        want = max(1, (size + spc * bps - 1) // (spc * bps))
        if len(chain) != want:
            raise SystemExit("derive: %s's chain is %d clusters and its size needs %d"
                             % (name, len(chain), want))
        if layout["files"][name]["chain"] != chain:
            raise SystemExit("derive: make-image.py says %s is at %s and the FAT says %s"
                             % (name, layout["files"][name]["chain"], chain))
        tag = name.split(".")[0].lower()
        out.append("%s_first=%d" % (tag, first))
        out.append("%s_size=%d" % (tag, size))
        out.append("%s_clusters=%d" % (tag, len(chain)))
        out.append("%s_chain=%s" % (tag, " ".join("%04X" % c for c in chain)))
        out.append("%s_open=FS OPEN %-8s.%-3s ATTR %02X CLUS %04X SIZE %08X"
                   % (tag, name.split(".")[0], name.split(".")[1], attr, first, size))
        out.append("%s_chainhdr=FS CHAIN LEN %04X FIRST %04X LAST %04X"
                   % (tag, len(chain), chain[0], chain[-1]))
        for n in range(0, len(chain), 8):
            out.append("%s_clusline_%d=FS CLUS %s"
                       % (tag, n // 8, " ".join("%04X" % c for c in chain[n:n + 8])))
        out.append("%s_lba=%d" % (tag, data_start + (first - 2) * spc))
        # Contiguity is REFUSED as a shortcut: if the chain happened to be
        # consecutive, nothing below would mean anything.
        if len(chain) > 1 and chain == list(range(chain[0], chain[0] + len(chain))):
            raise SystemExit("derive: %s is CONTIGUOUS on this image, so nothing here can "
                             "distinguish a chain-follower from a contiguous reader" % name)

        real = b"".join(cluster_bytes(c) for c in chain)[:size]
        cont = b"".join(cluster_bytes(chain[0] + k) for k in range(len(chain)))[:size]
        if real == cont:
            raise SystemExit("derive: %s reads the same contiguously as along its chain" % name)

        if name == "HELLO.TXT":
            open(sys.argv[1] + ".hello", "wb").write(real)
            out.append("hello_sha=%d" % fnv1a(real))
            out.append("hello_cont_sha=%d" % fnv1a(cont))
        else:
            vaddr, filesz, off = ro_range(progs[name])
            elf = open(progs[name], "rb").read()
            if elf != real:
                raise SystemExit("derive: %s on the image is not the ELF that was built" % name)
            out.append("%s_ro_bytes=%d" % (tag, filesz))
            # `%x` AND NOT `%08x`. The PROGRAM prints its hash with
            # oslibc's printf, which has no width modifiers at all (ADR-0017
            # §5), so a hash whose top nibble is zero comes out SEVEN digits
            # long. Zero-padding here made this harness fail whenever the
            # program's own bytes happened to hash that way -- a one-in-sixteen
            # latent break that M16's change to core/user/libc/syscall.c
            # happened to trip. See GAP-0131.
            out.append("%s_fnv=%x" % (tag, fnv1a(real[off:off + filesz])))
            # What the SAME program would hash if the loader had assumed
            # contiguity. The R+X segment's file bytes come out of `cont`
            # instead, and the hash is different because FNV-1a is
            # position-sensitive.
            out.append("%s_fnv_contiguous=%x" % (tag, fnv1a(cont[off:off + filesz])))
            pid = 0 if name == "PROGA.ELF" else 1
            # %02X, UPPER case: `uartPutHex` prints upper-case hex and this
            # string is grepped for literally. With %02x this check passed only
            # for an exit status whose two hex digits happen to be decimal --
            # which was true of both programs at M14 and stopped being true of
            # PROGB the first time the library underneath them changed size.
            # Found by M15; GAP-0125.
            out.append("%s_exit=%02X" % (tag, (fnv1a(real[off:off + filesz]) ^ (pid * 0x5A)) & 0xFF))
            out.append("%s_entry=%016x" % (tag, entry_point(progs[name])))
            # The hashed range must straddle cluster boundaries whose
            # neighbours belong to the OTHER program. This is the check that
            # says the fragmentation actually reaches the bytes being hashed.
            lo_c, hi_c = off // (spc * bps), (off + filesz - 1) // (spc * bps)
            out.append("%s_ro_span_clusters=%d" % (tag, hi_c - lo_c + 1))
            if hi_c - lo_c + 1 < 3:
                raise SystemExit("derive: %s's hashed range spans only %d clusters"
                                 % (name, hi_c - lo_c + 1))

    print("\n".join(out))


if __name__ == "__main__":
    main()
