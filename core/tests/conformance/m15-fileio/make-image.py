#!/usr/bin/env python3
"""core/tests/conformance/m15-fileio/make-image.py

Writes the M15 test disk: a REAL FAT16 VOLUME whose DATA FILES are scattered,
built byte by byte out of this file so that every number the kernel and the
program are required to reproduce is a number this script chose.

m14-fat/make-image.py's geometry EXACTLY -- 512-byte sectors, 2 sectors per
cluster, 1 reserved, 2 FATs of 20 sectors, 512 root entries, 10000 data sectors,
5000 clusters -- copied rather than shared for m11-proc's reason: the milestone
that owns a harness owns its inputs, and an image generator edited for one
milestone must not silently relayout another's volume. `fsck_msdos` and macOS's
own `msdos` driver are required to accept what comes out, exactly as at M14.

WHAT IS DIFFERENT FROM M14, AND WHY
---------------------------------------------------------------------------
M14 proved a LOADER follows a cluster chain. M15 proves a PROGRAM can read a
file through the `read` syscall, in pieces, at offsets it chooses. So the file
that matters here is not an executable, it is DATA:

  * DATA.BIN is 20000 bytes -- TWENTY clusters, twice the largest file M14 ever
    read (GAP-0116 item 6 said the largest was 9632 bytes; this moves it).

  * DATA.BIN'S CHAIN IS NOT MONOTONIC. M14's fragmentation interleaved two files
    in increasing cluster order, so a driver that sorted a chain would still have
    passed. This chain goes BACKWARDS repeatedly -- link i+1 is a lower cluster
    number than link i at least eight times -- and the script refuses to write an
    image where that is not true.

  * OTHER.BIN is 6000 bytes on six clusters interleaved with DATA.BIN's, so that
    a program alternating reads between the two makes the kernel rebuild a
    cluster chain on every single read. `fat.dart` holds ONE chain (GAP-0116
    item 5) and M15's descriptor table makes it a cache of one; this volume is
    what makes that mechanism run rather than sit there.

  * EVERY BYTE OF DATA.BIN DEPENDS ON ITS OFFSET, so a permutation of clusters
    is visible in an FNV-1a hash. It carries an eight-byte marker at each end so
    that "the first bytes are the first bytes" is something the PROGRAM checks.

  * SMALL.TXT is a few hundred bytes of real text on ONE cluster, for the
    line-oriented buffered path and for the sub-cluster case.

  * SUB is a real subdirectory, so that `open("SUB")` being refused is produced
    by a boot rather than asserted.

Everything M14's root directory carried for realism is carried here too: a
volume label, a deleted entry with a plausible name, and three long-filename
entries. A directory listing that only ever meets ordinary files has not been
tested.

VARIANTS: DELIBERATELY BROKEN VOLUMES
---------------------------------------------------------------------------
    nodata      DATA.BIN's directory entry is renamed, so the PROGRAM's open()
                is refused and it says so and exits with its own code. The
                negative control for "the file is found by name".
    datacycle   DATA.BIN's chain is a cycle, so the kernel refuses the OPEN with
                its I/O refusal and the program reports that instead of a hash.

Usage:
    make-image.py <out.img> <prog.elf> <progn.elf> [--json] [--variant=NAME]

Exit status: 0 on success, 3 on a self-check failure.
"""

import json
import os
import struct
import sys

SECTOR = 512

BYTES_PER_SECTOR = 512
SECTORS_PER_CLUSTER = 2
RESERVED = 1
NUM_FATS = 2
FAT_SECTORS = 20
ROOT_ENTRIES = 512
DATA_SECTORS = 10000

ROOT_SECTORS = (ROOT_ENTRIES * 32) // BYTES_PER_SECTOR      # 32
FAT_START = RESERVED                                         # 1
ROOT_START = RESERVED + NUM_FATS * FAT_SECTORS               # 41
DATA_START = ROOT_START + ROOT_SECTORS                       # 73
TOTAL_SECTORS = DATA_START + DATA_SECTORS                    # 10073
CLUSTER_COUNT = DATA_SECTORS // SECTORS_PER_CLUSTER          # 5000
CLUSTER_BYTES = SECTORS_PER_CLUSTER * BYTES_PER_SECTOR       # 1024

MEDIA = 0xF8
FAT_EOC = 0xFFFF
FAT_BAD = 0xFFF7

DATA_BYTES = 20000
OTHER_BYTES = 6000
SUBDIR_CLUSTER = 4900

HEAD_MAGIC = b"M15DATA\n"
TAIL_MAGIC = b"ENDDATA\n"

SMALL_TEXT = (
    b"oscortex_core M15 -- a program can read a file.\n"
    b"This file is under one cluster long and is read a line at a time\n"
    b"through core/user/libc/rfile.c, which buffers 512 bytes per read()\n"
    b"syscall and hands them out a line at a time.\n"
    b"It is NOT called FILE and rfopen is not called fopen, because it\n"
    b"cannot write, has no stdin, no stdout and no stderr, and does not\n"
    b"flush anything. A name that promised those would be a lie the\n"
    b"compiler could not catch.\n"
)


def data_bytes(n):
    """DATA.BIN's contents: every byte depends on its OFFSET.

    A constant, or a per-cluster pattern, would be invisible under a permutation
    of clusters -- which is the one corruption this whole volume exists to make
    detectable. The two 8-byte markers let the PROGRAM check the ends.
    """
    b = bytearray(n)
    for i in range(n):
        b[i] = ((i * 173) ^ (i >> 5) ^ ((i * i) >> 7) ^ 0x5A) & 0xFF
    b[0:8] = HEAD_MAGIC
    b[n - 8:n] = TAIL_MAGIC
    return bytes(b)


def other_bytes(n):
    b = bytearray(n)
    for i in range(n):
        b[i] = ((i * 61) + (i >> 3) + 0xA5) & 0xFF
    b[0:8] = b"M15OTHR\n"
    return bytes(b)


def sector_pattern(s):
    """m6-disk's background pattern: depends on the sector AND the offset."""
    b = bytearray((31 * s + 7 * i + 0x21) & 0xFF for i in range(SECTOR))
    label = ("OSCORTEX SECTOR %04X" % (s & 0xFFFF)).encode("ascii")
    b[0:len(label)] = label
    return bytes(b)


def eightthree(name):
    if "." in name:
        stem, ext = name.split(".", 1)
    else:
        stem, ext = name, ""
    if len(stem) > 8 or len(ext) > 3:
        raise SystemExit("make-image: %r is not an 8.3 name" % name)
    return (stem.ljust(8) + ext.ljust(3)).upper().encode("ascii")


def dir_entry(raw11, attr, first_cluster, size):
    e = bytearray(32)
    e[0:11] = raw11
    e[11] = attr
    struct.pack_into("<H", e, 26, first_cluster)
    struct.pack_into("<I", e, 28, size)
    struct.pack_into("<H", e, 22, 0)
    struct.pack_into("<H", e, 24, ((2026 - 1980) << 9) | (1 << 5) | 1)
    struct.pack_into("<H", e, 18, ((2026 - 1980) << 9) | (1 << 5) | 1)
    return bytes(e)


def lfn_entries(long_name, checksum):
    units = long_name.encode("utf-16-le") + b"\x00\x00"
    per = 26
    chunks = [units[i:i + per] for i in range(0, len(units), per)]
    chunks[-1] = chunks[-1] + b"\xFF" * (per - len(chunks[-1]))
    out = []
    for i, chunk in enumerate(reversed(chunks)):
        seq = len(chunks) - i
        b = bytearray(32)
        b[0] = seq | (0x40 if i == 0 else 0)
        b[1:11] = chunk[0:10]
        b[11] = 0x0F
        b[12] = 0
        b[13] = checksum
        b[14:26] = chunk[10:22]
        b[26:28] = b"\x00\x00"
        b[28:32] = chunk[22:26]
        out.append(bytes(b))
    return out


def lfn_checksum(raw11):
    s = 0
    for c in raw11:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def boot_sector():
    b = bytearray(SECTOR)
    b[0:3] = b"\xEB\x3C\x90"
    b[3:11] = b"OSCORTEX"
    struct.pack_into("<H", b, 11, BYTES_PER_SECTOR)
    b[13] = SECTORS_PER_CLUSTER
    struct.pack_into("<H", b, 14, RESERVED)
    b[16] = NUM_FATS
    struct.pack_into("<H", b, 17, ROOT_ENTRIES)
    struct.pack_into("<H", b, 19, TOTAL_SECTORS)
    b[21] = MEDIA
    struct.pack_into("<H", b, 22, FAT_SECTORS)
    struct.pack_into("<H", b, 24, 63)
    struct.pack_into("<H", b, 26, 16)
    struct.pack_into("<I", b, 28, 0)
    struct.pack_into("<I", b, 32, 0)
    b[36] = 0x80
    b[38] = 0x29
    struct.pack_into("<I", b, 39, 0x05C0FFEE)
    b[43:54] = b"OSCORTEX   "
    b[54:62] = b"FAT16   "
    b[510:512] = b"\x55\xAA"
    return bytes(b)


def scatter(count, taken, lo, hi, step, start):
    """A deterministic, DELIBERATELY NON-MONOTONIC cluster run.

    Modular stepping across a band, which produces a sequence that goes up until
    it wraps and then lands well below where it was. The self-check below
    REQUIRES at least eight backward links, so a change to these numbers that
    accidentally produced an increasing chain fails here rather than silently
    weakening the volume.
    """
    span = hi - lo
    out = []
    c = start
    while len(out) < count:
        v = lo + (c % span)
        if v not in taken and v not in out:
            out.append(v)
        c += step
    return out


VARIANTS = ("nodata", "datacycle")


def apply_variant(img, name, chains, entry_offsets):
    if name == "nodata":
        # The name, and only the name. The file is still there, its chain is
        # still correct and `fsck_msdos` would still be happy; the PROGRAM
        # simply cannot find it, which is the one thing being controlled for.
        at = entry_offsets["DATA.BIN"]
        img[at:at + 11] = eightthree("OTHER1.BIN")
        return "DATA.BIN's directory entry is named OTHER1.BIN instead"
    if name == "datacycle":
        chain = chains["DATA.BIN"]
        for n in range(NUM_FATS):
            at = (FAT_START + n * FAT_SECTORS) * SECTOR
            struct.pack_into("<H", img, at + chain[3] * 2, chain[0])
        return ("DATA.BIN's chain loops from its fourth cluster back to its "
                "first, so the walk repeats a cluster it has already seen")
    raise SystemExit("make-image: unknown variant %r" % name)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    variant = None
    for a in sys.argv[1:]:
        if a.startswith("--variant="):
            variant = a.split("=", 1)[1]
    if variant is not None and variant not in VARIANTS:
        raise SystemExit("make-image: unknown variant %r (have %s)"
                         % (variant, ", ".join(VARIANTS)))
    if len(args) != 3:
        raise SystemExit("usage: make-image.py <out.img> <prog.elf> <progn.elf>")
    out, p_path, n_path = args

    blobs = {
        "PROG.ELF": open(p_path, "rb").read(),
        "PROGN.ELF": open(n_path, "rb").read(),
        "DATA.BIN": data_bytes(DATA_BYTES),
        "OTHER.BIN": other_bytes(OTHER_BYTES),
        "SMALL.TXT": SMALL_TEXT,
    }
    if blobs["PROG.ELF"] == blobs["PROGN.ELF"]:
        raise SystemExit("make-image: the real program and its negative control are "
                         "byte-identical; the control controls for nothing")

    def need(blob):
        return max(1, (len(blob) + CLUSTER_BYTES - 1) // CLUSTER_BYTES)

    # ---- cluster allocation --------------------------------------------
    taken = {SUBDIR_CLUSTER}
    chains = {}
    # The two data files FIRST, scattered across the middle of the volume and
    # interleaved with each other by construction: the two bands overlap and the
    # allocator below skips what the other has taken.
    chains["DATA.BIN"] = scatter(need(blobs["DATA.BIN"]), taken, 1500, 3500, 1497, 0)
    taken |= set(chains["DATA.BIN"])
    chains["OTHER.BIN"] = scatter(need(blobs["OTHER.BIN"]), taken, 1500, 3500, 1097, 313)
    taken |= set(chains["OTHER.BIN"])
    chains["SMALL.TXT"] = scatter(need(blobs["SMALL.TXT"]), taken, 4000, 4500, 97, 41)
    taken |= set(chains["SMALL.TXT"])
    # The two programs take the odd and the even low clusters, m14's shape, so
    # that the EXECUTABLES are interleaved too and `run PROG.ELF` is still a
    # statement about a chain.
    for name, start in (("PROG.ELF", 3), ("PROGN.ELF", 4)):
        chain = []
        c = start
        while len(chain) < need(blobs[name]):
            if c >= CLUSTER_COUNT + 2:
                raise SystemExit("make-image: ran out of clusters placing %s" % name)
            if c not in taken:
                chain.append(c)
                taken.add(c)
            c += 2
        chains[name] = chain

    for name, chain in chains.items():
        if len(chain) != len(set(chain)):
            raise SystemExit("make-image: %s's chain repeats a cluster" % name)
        if len(chain) > 1 and chain == list(range(chain[0], chain[0] + len(chain))):
            raise SystemExit("make-image: %s came out CONTIGUOUS (%s)" % (name, chain))

    back = sum(1 for i in range(len(chains["DATA.BIN"]) - 1)
               if chains["DATA.BIN"][i + 1] < chains["DATA.BIN"][i])
    if back < 8:
        raise SystemExit("make-image: DATA.BIN's chain only goes backwards %d times; "
                         "this image exists so that a driver which SORTED a chain "
                         "would be wrong" % back)

    # ---- the image -----------------------------------------------------
    img = bytearray()
    for s in range(TOTAL_SECTORS):
        img += sector_pattern(s)
    img[0:SECTOR] = boot_sector()

    fat = bytearray(FAT_SECTORS * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFF00 | MEDIA)
    struct.pack_into("<H", fat, 2, FAT_EOC)
    for name, chain in chains.items():
        for i, c in enumerate(chain):
            nxt = chain[i + 1] if i + 1 < len(chain) else FAT_EOC
            struct.pack_into("<H", fat, c * 2, nxt)
    struct.pack_into("<H", fat, SUBDIR_CLUSTER * 2, FAT_EOC)
    struct.pack_into("<H", fat, 4999 * 2, FAT_BAD)   # one real bad cluster
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR
        img[at:at + len(fat)] = fat

    # ---- the root directory --------------------------------------------
    root = bytearray()
    entry_offsets = {}

    def add(name, attr, first, size, raw=None):
        entry_offsets[name] = ROOT_START * SECTOR + len(root)
        root.extend(dir_entry(raw if raw is not None else eightthree(name),
                              attr, first, size))

    add("OSCORTEX", 0x08, 0, 0, raw=b"OSCORTEX   ")
    add("DATA.BIN", 0x20, chains["DATA.BIN"][0], len(blobs["DATA.BIN"]))
    add("PROG.ELF", 0x20, chains["PROG.ELF"][0], len(blobs["PROG.ELF"]))
    ghost = bytearray(dir_entry(eightthree("GHOST.BIN"), 0x20,
                                chains["DATA.BIN"][0], 4096))
    ghost[0] = 0xE5
    root += bytes(ghost)
    b11 = eightthree("OTHER.BIN")
    for e in lfn_entries("other-data-with-a-long-name.bin", lfn_checksum(b11)):
        root += e
    add("OTHER.BIN", 0x20, chains["OTHER.BIN"][0], len(blobs["OTHER.BIN"]))
    add("SMALL.TXT", 0x20, chains["SMALL.TXT"][0], len(blobs["SMALL.TXT"]))
    # A REAL, LEGAL, ZERO-LENGTH FILE: first cluster 0 and size 0, which is what
    # every FAT formatter writes for one. `fsck_msdos` accepts it. This kernel
    # REFUSES to open it (fileRetEmpty) rather than handing back a descriptor
    # every read of which would return 0 -- and without this entry that refusal
    # would be a line no boot had ever executed.
    add("EMPTY.TXT", 0x20, 0, 0)
    add("PROGN.ELF", 0x20, chains["PROGN.ELF"][0], len(blobs["PROGN.ELF"]))
    add("SUB", 0x10, SUBDIR_CLUSTER, 0)
    root += b"\x00" * (ROOT_ENTRIES * 32 - len(root))
    img[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR] = root

    def cluster_at(c):
        return (DATA_START + (c - 2) * SECTORS_PER_CLUSTER) * SECTOR

    sub = bytearray(CLUSTER_BYTES)
    sub[0:32] = dir_entry(b".          ", 0x10, SUBDIR_CLUSTER, 0)
    sub[32:64] = dir_entry(b"..         ", 0x10, 0, 0)
    img[cluster_at(SUBDIR_CLUSTER):cluster_at(SUBDIR_CLUSTER) + CLUSTER_BYTES] = sub

    for name, chain in chains.items():
        blob = blobs[name]
        for i, c in enumerate(chain):
            piece = blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
            piece = piece + b"\0" * (CLUSTER_BYTES - len(piece))
            img[cluster_at(c):cluster_at(c) + CLUSTER_BYTES] = piece

    broke = None
    if variant is not None:
        broke = apply_variant(img, variant, chains, entry_offsets)

    with open(out, "wb") as f:
        f.write(bytes(img))

    if variant is not None:
        if want_json:
            print(json.dumps({"variant": variant, "broke": broke}))
        else:
            print("make-image: %s — VARIANT %s: %s"
                  % (os.path.basename(out), variant, broke))
        return

    # ---- self-check: read it back the way the kernel will ---------------
    backimg = open(out, "rb").read()
    if len(backimg) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(backimg), TOTAL_SECTORS * SECTOR))
    fat_back = backimg[FAT_START * SECTOR:(FAT_START + FAT_SECTORS) * SECTOR]

    def walk(first, size):
        got, c = [], first
        while True:
            got.append(c)
            nxt = struct.unpack_from("<H", fat_back, c * 2)[0]
            if nxt >= 0xFFF8:
                break
            if len(got) > 4096:
                raise SystemExit("make-image: chain from %d does not terminate" % first)
            c = nxt
        want = max(1, (size + CLUSTER_BYTES - 1) // CLUSTER_BYTES)
        if len(got) != want:
            raise SystemExit("make-image: chain from %d is %d clusters, size says %d"
                             % (first, len(got), want))
        return got

    layout = {
        "bytes_per_sector": BYTES_PER_SECTOR, "sectors_per_cluster": SECTORS_PER_CLUSTER,
        "reserved": RESERVED, "num_fats": NUM_FATS, "fat_sectors": FAT_SECTORS,
        "root_entries": ROOT_ENTRIES, "total_sectors": TOTAL_SECTORS,
        "fat_start": FAT_START, "root_start": ROOT_START, "root_sectors": ROOT_SECTORS,
        "data_start": DATA_START, "cluster_count": CLUSTER_COUNT,
        "cluster_bytes": CLUSTER_BYTES, "media": MEDIA,
        "subdir_cluster": SUBDIR_CLUSTER, "backward_links": back,
        "files": {},
    }
    for name, chain in sorted(chains.items()):
        blob = blobs[name]
        if walk(chain[0], len(blob)) != chain:
            raise SystemExit("make-image: %s's chain does not read back" % name)
        joined = b"".join(backimg[cluster_at(c):cluster_at(c) + CLUSTER_BYTES]
                          for c in chain)
        if joined[:len(blob)] != blob:
            raise SystemExit("make-image: %s does not read back byte-for-byte along "
                             "its chain" % name)
        contiguous = b"".join(
            backimg[cluster_at(chain[0] + i):cluster_at(chain[0] + i) + CLUSTER_BYTES]
            for i in range(len(chain)))
        if len(chain) > 1 and contiguous[:len(blob)] == blob:
            raise SystemExit("make-image: %s reads back correctly CONTIGUOUSLY too, so "
                             "this image cannot tell a chain-follower from a "
                             "contiguous reader" % name)
        layout["files"][name] = {
            "chain": chain, "bytes": len(blob), "clusters": len(chain),
            "first_sector": DATA_START + (chain[0] - 2) * SECTORS_PER_CLUSTER,
        }

    # The bytes a CONTIGUOUS reader would get for DATA.BIN, so the harness can
    # require the hash of THOSE not to appear in the transcript.
    contig = b"".join(
        backimg[cluster_at(chains["DATA.BIN"][0] + i):
                cluster_at(chains["DATA.BIN"][0] + i) + CLUSTER_BYTES]
        for i in range(len(chains["DATA.BIN"])))[:DATA_BYTES]
    outdir = os.path.dirname(os.path.abspath(out)) or "."
    base = os.path.basename(out)
    open(os.path.join(outdir, base + ".data"), "wb").write(blobs["DATA.BIN"])
    open(os.path.join(outdir, base + ".other"), "wb").write(blobs["OTHER.BIN"])
    open(os.path.join(outdir, base + ".small"), "wb").write(blobs["SMALL.TXT"])
    open(os.path.join(outdir, base + ".contig"), "wb").write(contig)

    if want_json:
        print(json.dumps(layout))
    else:
        print("make-image: %s — %d sectors, %d clusters; DATA.BIN %d bytes on %d "
              "clusters with %d backward links; OTHER.BIN %d on %d; SMALL.TXT %d on 1"
              % (base, TOTAL_SECTORS, CLUSTER_COUNT, DATA_BYTES,
                 len(chains["DATA.BIN"]), back, OTHER_BYTES,
                 len(chains["OTHER.BIN"]), len(SMALL_TEXT)))


if __name__ == "__main__":
    main()
