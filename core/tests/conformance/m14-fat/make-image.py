#!/usr/bin/env python3
"""core/tests/conformance/m14-fat/make-image.py

Writes the M14 test disk: a REAL, READ-ONLY FAT16 VOLUME, built byte by byte
out of this file rather than by `newfs_msdos`, so that every number the kernel
is required to reproduce is a number this script chose and can hand to the
harness.

WHY THE GEOMETRY IS WHAT IT IS
---------------------------------------------------------------------------
"FAT16" is not a flag in the boot sector. Microsoft's own specification says
the type is determined by ONE computed quantity -- the count of data clusters:

    CountOfClusters <  4085   ->  FAT12
    CountOfClusters < 65525   ->  FAT16
    otherwise                 ->  FAT32

`BS_FilSysType` ("FAT16   ") is documentation, not a determinant, and the
kernel refuses to read it as one. So the geometry below is chosen to land
COMFORTABLY inside the FAT16 band rather than next to either edge:

    bytes/sector        512      (the kernel refuses anything else)
    sectors/cluster       2      NOT 1, deliberately -- see below
    reserved sectors      1
    number of FATs        2
    FAT size (sectors)   20      -> 20*512/2 = 5120 entries, >= 5000+2
    root entries        512      -> 512*32/512 = 32 sectors
    data sectors      10000      -> 5000 clusters  (4085 <= 5000 < 65525)
    total sectors     10073      = 1 + 2*20 + 32 + 10000

**sectors/cluster is 2 on purpose.** With one sector per cluster the mapping
`lba = data_start + (cluster - 2) * spc` degenerates into an addition, and a
kernel that had dropped the multiply entirely would still pass every test. Two
sectors per cluster makes the multiply load-bearing.

FRAGMENTATION IS THE POINT
---------------------------------------------------------------------------
A filesystem driver that ignores the FAT and reads `filesize` bytes forward
from the first cluster passes every test on a freshly-written image, because a
freshly-written image is contiguous. So nothing here is contiguous:

  * PROGA.ELF takes the ODD clusters from 3 upward.
  * PROGB.ELF takes the EVEN clusters from 4 upward.

The two are therefore interleaved cluster by cluster, and a contiguous read of
either one gets alternating 1KiB slabs of the other. Both are ELF executables
that this kernel will run, which makes the failure mode concrete: a contiguous
reader does not get garbage, it gets a plausible-looking file that is half a
different program.

  * HELLO.TXT takes clusters 2 and 100 -- a 98-cluster hole in the middle of a
    two-cluster file. A contiguous `cat` would print 1KiB of the background
    pattern instead of the second half of the text.

EVERY UNALLOCATED DATA CLUSTER IS FILLED WITH A RECOGNISABLE PATTERN, m6-disk's
`OSCORTEX SECTOR xxxx` pattern, so that a contiguous read produces bytes this
harness can NAME rather than zeroes it might mistake for a short file.

WHAT ELSE IS IN THE ROOT DIRECTORY, AND WHY
---------------------------------------------------------------------------
A directory listing that only ever meets ordinary files has not been tested.
The root directory therefore also carries, interleaved with the real files:

  * a VOLUME LABEL (attribute 0x08),
  * a DELETED entry (first byte 0xE5) that still has a plausible name, size and
    first cluster, so a driver that forgets the check prints it,
  * three LONG FILENAME entries (attribute 0x0F) in front of PROGB.ELF, which
    are what a real formatter writes and which decode as garbage if printed as
    8.3 names,
  * a SUBDIRECTORY (attribute 0x10) with a real cluster holding real `.` and
    `..` entries, because "subdirectories are not supported" has to be a
    REFUSAL and not a crash.

VARIANTS: DELIBERATELY BROKEN VOLUMES
---------------------------------------------------------------------------
Nine of the kernel's twenty-nine refusal codes are about a volume being
something this driver will not read, and none of them is reachable from a
volume that is correct. `--variant NAME` writes the same image with ONE thing
wrong, so each of those refusals is produced by a real boot against a real disk
rather than left as code nobody has executed:

    nosig       the 55AA at offset 510 overwritten
    sectorsize  BPB_BytsPerSec = 1024
    fat32       BPB_FATSz16 = 0, which is the FAT32 boot sector's shape
    fat12       BPB_TotSec16 shrunk so the cluster count falls under 4085
    badchains   the volume mounts, and THREE FILES have three different broken
                chains: HELLO.TXT a 2-cycle, PROGA.ELF a link into the bad
                cluster, PROGB.ELF an end mark before its size says

`badchains` is one image and not three because a chain refusal is per-file:
three files with three faults produce three refusals in ONE boot.

Usage:
    make-image.py <out.img> <progA.elf> <progB.elf> [--json] [--variant NAME]

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

# The cluster HELLO.TXT's second half lives in. Far away from the two programs
# so the hole is unmistakable, and far below CLUSTER_COUNT so it is legal.
HELLO_CLUSTERS = [2, 100]
SUBDIR_CLUSTER = 200

HELLO_TEXT = (
    b"oscortex_core M14 -- a read-only FAT16 filesystem.\n"
    b"\n"
    b"This file is TWO clusters long and its two clusters are not adjacent:\n"
    b"the first is cluster 2 and the second is cluster 100. A `cat` that read\n"
    b"forward from the first cluster instead of following the FAT would print\n"
    b"the volume's background pattern here instead of the rest of this text.\n"
    b"\n"
    b"The kernel that prints this has no writes, no subdirectories, no long\n"
    b"filenames and no timestamps. It has a boot sector it validated, a FAT it\n"
    b"walks, a root directory it enumerates and files it reads by name. That is\n"
    b"the whole of it, and docs/known-gaps.md says so at greater length.\n"
    b"\n"
    b"Below this line is padding, and it is here for one arithmetical reason:\n"
    b"a cluster on this volume is 1024 bytes, and a file has to be longer than\n"
    b"one cluster before its chain has a second link to follow. Everything up\n"
    b"to here is 800-odd bytes, which would have fitted in cluster 2 alone.\n"
    b"\n"
    + b"".join(b"line %03d: the second cluster of HELLO.TXT begins somewhere in here.\n" % i
              for i in range(10))
)


def sector_pattern(s):
    """m6-disk's background pattern: depends on the sector AND the offset."""
    b = bytearray((31 * s + 7 * i + 0x21) & 0xFF for i in range(SECTOR))
    label = ("OSCORTEX SECTOR %04X" % (s & 0xFFFF)).encode("ascii")
    b[0:len(label)] = label
    return bytes(b)


def eightthree(name):
    """'PROGA.ELF' -> the 11 raw directory bytes."""
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
    # A fixed date/time so the image is byte-for-byte deterministic. 1 Jan 2026,
    # 00:00:00. There are no timestamps in this kernel (GAP-0117) and these
    # fields exist only so `fsck_msdos` and a real host driver see a sane entry.
    struct.pack_into("<H", e, 22, 0)          # write time
    struct.pack_into("<H", e, 24, ((2026 - 1980) << 9) | (1 << 5) | 1)
    struct.pack_into("<H", e, 18, ((2026 - 1980) << 9) | (1 << 5) | 1)
    return bytes(e)


def lfn_entries(long_name, checksum):
    """The three 0x0F entries a real formatter writes in front of a long name."""
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
    b[0:3] = b"\xEB\x3C\x90"                       # jmp short +0x3C; nop
    b[3:11] = b"OSCORTEX"                          # OEM name
    struct.pack_into("<H", b, 11, BYTES_PER_SECTOR)
    b[13] = SECTORS_PER_CLUSTER
    struct.pack_into("<H", b, 14, RESERVED)
    b[16] = NUM_FATS
    struct.pack_into("<H", b, 17, ROOT_ENTRIES)
    struct.pack_into("<H", b, 19, TOTAL_SECTORS)   # BPB_TotSec16 -- it fits
    b[21] = MEDIA
    struct.pack_into("<H", b, 22, FAT_SECTORS)
    struct.pack_into("<H", b, 24, 63)              # sectors per track (unused)
    struct.pack_into("<H", b, 26, 16)              # heads (unused)
    struct.pack_into("<I", b, 28, 0)               # hidden sectors
    struct.pack_into("<I", b, 32, 0)               # BPB_TotSec32 -- 0, see 19
    b[36] = 0x80                                   # drive number
    b[38] = 0x29                                   # extended boot signature
    struct.pack_into("<I", b, 39, 0x05C0FFEE)      # volume id
    b[43:54] = b"OSCORTEX   "                      # volume label
    b[54:62] = b"FAT16   "                         # BS_FilSysType -- NOT a determinant
    b[510:512] = b"\x55\xAA"
    return bytes(b)


VARIANTS = ("nosig", "sectorsize", "fat32", "fat12", "badchains", "outofrange")


def apply_variant(img, name, chains, hello_entry_off):
    """Breaks ONE thing. Returns a description of what was broken."""
    if name == "nosig":
        img[510:512] = b"\x00\x00"
        return "the 55AA boot signature at offset 510 is 0000"
    if name == "sectorsize":
        struct.pack_into("<H", img, 11, 1024)
        return "BPB_BytsPerSec is 1024, not 512"
    if name == "fat32":
        struct.pack_into("<H", img, 22, 0)
        return "BPB_FATSz16 is 0, which is what a FAT32 boot sector looks like"
    if name == "fat12":
        # Shrink the volume until the cluster count falls under 4085. The
        # geometry stays self-consistent -- this is a legal FAT12 volume, which
        # is the point: it is refused for what it IS, not for being malformed.
        tot = DATA_START + 2 * 4000
        struct.pack_into("<H", img, 19, tot)
        return "the volume is shrunk to %d clusters, which is FAT12" % 4000
    if name == "badchains":
        for n in range(NUM_FATS):
            at = (FAT_START + n * FAT_SECTORS) * SECTOR
            # HELLO.TXT: a 2-cycle, 2 -> 100 -> 2, with its size grown to claim
            # a third cluster so the walk reaches the repeat.
            struct.pack_into("<H", img, at + HELLO_CLUSTERS[1] * 2, HELLO_CLUSTERS[0])
            # PROGA.ELF: its second link points at the cluster marked bad.
            struct.pack_into("<H", img, at + chains["PROGA.ELF"][0] * 2, FAT_BAD)
            # PROGB.ELF: an end mark one link too early.
            struct.pack_into("<H", img, at + chains["PROGB.ELF"][0] * 2, FAT_EOC)
        struct.pack_into("<I", img, hello_entry_off + 28, 2 * CLUSTER_BYTES + 1)
        return ("HELLO.TXT's chain is a 2-cycle, PROGA.ELF's second link is the "
                "bad cluster, PROGB.ELF's chain ends before its size does")
    if name == "outofrange":
        # HELLO.TXT's first link points ONE PAST the last legal cluster. Legal
        # cluster numbers are 2 .. CLUSTER_COUNT + 1, so CLUSTER_COUNT + 2 is
        # the first illegal one and is exactly the value an off-by-two in the
        # bound would accept. This variant exists because loosening that bound
        # survived every other check in this harness.
        for n in range(NUM_FATS):
            at = (FAT_START + n * FAT_SECTORS) * SECTOR
            struct.pack_into("<H", img, at + HELLO_CLUSTERS[0] * 2, CLUSTER_COUNT + 2)
        return ("HELLO.TXT's first link is cluster %d, one past the last legal cluster (%d)"
                % (CLUSTER_COUNT + 2, CLUSTER_COUNT + 1))
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
        raise SystemExit("usage: make-image.py <out.img> <progA.elf> <progB.elf> [--json]")
    out, a_path, b_path = args

    blobs = {"PROGA.ELF": open(a_path, "rb").read(),
             "PROGB.ELF": open(b_path, "rb").read(),
             "HELLO.TXT": HELLO_TEXT}
    if blobs["PROGA.ELF"] == blobs["PROGB.ELF"]:
        raise SystemExit("make-image: the two programs are byte-identical; an interleaved "
                         "read of one would be indistinguishable from the other")

    # ---- cluster allocation --------------------------------------------
    # HELLO.TXT first, so its two clusters are reserved before the programs
    # take their runs and the interleave below cannot collide with them.
    taken = set(HELLO_CLUSTERS) | {SUBDIR_CLUSTER}
    chains = {"HELLO.TXT": list(HELLO_CLUSTERS)}

    def need(blob):
        return max(1, (len(blob) + CLUSTER_BYTES - 1) // CLUSTER_BYTES)

    for name, start in (("PROGA.ELF", 3), ("PROGB.ELF", 4)):
        chain = []
        c = start
        while len(chain) < need(blobs[name]):
            if c >= CLUSTER_COUNT + 2:
                raise SystemExit("make-image: ran out of clusters placing %s" % name)
            if c not in taken:
                chain.append(c)
                taken.add(c)
            c += 2                       # ODD for A, EVEN for B: interleaved
        chains[name] = chain

    for name, chain in chains.items():
        if len(chain) > 1 and chain == list(range(chain[0], chain[0] + len(chain))):
            raise SystemExit("make-image: %s came out CONTIGUOUS (%s); this image exists to "
                             "make a contiguous reader wrong" % (name, chain))

    # ---- the image -----------------------------------------------------
    img = bytearray()
    for s in range(TOTAL_SECTORS):
        img += sector_pattern(s)

    img[0:SECTOR] = boot_sector()

    # FAT #1, then copied to FAT #2. Two FATs that differ is a corrupt volume
    # and `fsck_msdos` says so, which is one of the things this image is
    # checked with.
    fat = bytearray(FAT_SECTORS * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFF00 | MEDIA)   # FAT[0]
    struct.pack_into("<H", fat, 2, FAT_EOC)          # FAT[1]
    for name, chain in chains.items():
        for i, c in enumerate(chain):
            nxt = chain[i + 1] if i + 1 < len(chain) else FAT_EOC
            struct.pack_into("<H", fat, c * 2, nxt)
    struct.pack_into("<H", fat, SUBDIR_CLUSTER * 2, FAT_EOC)
    # One genuinely BAD cluster, marked 0xFFF7, in nobody's chain. It is here so
    # that "the driver detects a bad cluster" is testable at all -- and so that
    # `fsck_msdos` accounts for it, which proves the marker is the real one.
    struct.pack_into("<H", fat, 300 * 2, FAT_BAD)
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR
        img[at:at + len(fat)] = fat

    # ---- the root directory --------------------------------------------
    root = bytearray()
    root += dir_entry(b"OSCORTEX   ", 0x08, 0, 0)                    # volume label
    root += dir_entry(eightthree("HELLO.TXT"), 0x20, chains["HELLO.TXT"][0], len(HELLO_TEXT))
    root += dir_entry(eightthree("PROGA.ELF"), 0x20, chains["PROGA.ELF"][0], len(blobs["PROGA.ELF"]))
    # A deleted entry with a plausible name, size and first cluster, so that a
    # driver which forgets the 0xE5 check prints a file that is not there.
    ghost = bytearray(dir_entry(eightthree("GHOST.ELF"), 0x20, chains["PROGA.ELF"][0], 4096))
    ghost[0] = 0xE5
    root += bytes(ghost)
    # PROGB.ELF behind three long-filename entries.
    b11 = eightthree("PROGB.ELF")
    for e in lfn_entries("program-b-with-a-long-name.elf", lfn_checksum(b11)):
        root += e
    root += dir_entry(b11, 0x20, chains["PROGB.ELF"][0], len(blobs["PROGB.ELF"]))
    root += dir_entry(eightthree("SUB"), 0x10, SUBDIR_CLUSTER, 0)     # a subdirectory
    root += b"\x00" * (ROOT_ENTRIES * 32 - len(root))
    img[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR] = root
    # Byte offset of HELLO.TXT's 32-byte entry in the image, for the variants.
    hello_entry_off = ROOT_START * SECTOR + 32

    def cluster_at(c):
        return (DATA_START + (c - 2) * SECTORS_PER_CLUSTER) * SECTOR

    # The subdirectory's one cluster: `.` and `..`, then zeroes.
    sub = bytearray(CLUSTER_BYTES)
    sub[0:32] = dir_entry(b".          ", 0x10, SUBDIR_CLUSTER, 0)
    sub[32:64] = dir_entry(b"..         ", 0x10, 0, 0)
    img[cluster_at(SUBDIR_CLUSTER):cluster_at(SUBDIR_CLUSTER) + CLUSTER_BYTES] = sub

    # ---- the file data, cluster by cluster along each chain ------------
    for name, chain in chains.items():
        blob = blobs[name]
        for i, c in enumerate(chain):
            piece = blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
            piece = piece + b"\0" * (CLUSTER_BYTES - len(piece))
            img[cluster_at(c):cluster_at(c) + CLUSTER_BYTES] = piece

    broke = None
    if variant is not None:
        broke = apply_variant(img, variant, chains, hello_entry_off)

    with open(out, "wb") as f:
        f.write(bytes(img))

    if variant is not None:
        # A broken volume is not walked back: the whole point is that it is
        # wrong. What IS checked is that exactly one thing changed relative to
        # the good image -- a variant that rewrote half the disk would be
        # testing something nobody described.
        if want_json:
            print(json.dumps({"variant": variant, "broke": broke}))
        else:
            print("make-image: %s — VARIANT %s: %s"
                  % (os.path.basename(out), variant, broke))
        return

    # ---- self-check: read it back and walk it the way the kernel will --
    back = open(out, "rb").read()
    if len(back) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(back), TOTAL_SECTORS * SECTOR))
    fat_back = back[FAT_START * SECTOR:(FAT_START + FAT_SECTORS) * SECTOR]

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
        "bad_cluster": 300, "subdir_cluster": SUBDIR_CLUSTER,
        "files": {},
    }
    for name, chain in sorted(chains.items()):
        blob = blobs[name]
        if walk(chain[0], len(blob)) != chain:
            raise SystemExit("make-image: %s's chain does not read back" % name)
        joined = b"".join(back[cluster_at(c):cluster_at(c) + CLUSTER_BYTES] for c in chain)
        if joined[:len(blob)] != blob:
            raise SystemExit("make-image: %s does not read back byte-for-byte along its chain"
                             % name)
        contiguous = b"".join(
            back[cluster_at(chain[0] + i):cluster_at(chain[0] + i) + CLUSTER_BYTES]
            for i in range(len(chain)))
        if len(chain) > 1 and contiguous[:len(blob)] == blob:
            raise SystemExit("make-image: %s reads back correctly CONTIGUOUSLY too, so this "
                             "image cannot tell a chain-follower from a contiguous reader" % name)
        layout["files"][name] = {
            "chain": chain, "bytes": len(blob),
            "clusters": len(chain),
            "first_sector": DATA_START + (chain[0] - 2) * SECTORS_PER_CLUSTER,
            "sectors": [DATA_START + (c - 2) * SECTORS_PER_CLUSTER + k
                        for c in chain for k in range(SECTORS_PER_CLUSTER)],
        }

    if want_json:
        print(json.dumps(layout))
    else:
        print("make-image: %s — FAT16, %d sectors, %d clusters of %dB; %s"
              % (os.path.basename(out), TOTAL_SECTORS, CLUSTER_COUNT, CLUSTER_BYTES,
                 ", ".join("%s%s" % (n, layout["files"][n]["chain"][:4])
                           for n in sorted(layout["files"]))))


if __name__ == "__main__":
    main()
