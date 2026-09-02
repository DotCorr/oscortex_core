#!/usr/bin/env python3
"""core/tests/conformance/drm-abi/make-image.py

Writes this unit's test disk: a REAL FAT16 VOLUME carrying the two programs
build-progs.sh produced.

m19-argv/make-image.py's geometry and helpers EXACTLY -- 512-byte sectors, 2
sectors per cluster, 1 reserved, 2 FATs of 20 sectors, 512 root entries, 10000
data sectors, 5000 clusters -- copied rather than shared for m11-proc's reason:
the unit that owns a harness owns its inputs. `fsck_msdos` and macOS's own
`msdos` driver are required to accept what comes out, exactly as at M14.

WHAT IS DIFFERENT FROM M19, AND WHY IT IS SO MUCH SMALLER
---------------------------------------------------------------------------
M19's volume existed to make "which file was the program told to read" an
observable property, so it carried two text files whose counts had to differ in
all three columns. THIS unit's program reads nothing: everything it reports it
computed from headers at compile time. So the volume's only job is to be a real
FAT16 volume that the kernel can load two ELFs off, and the properties kept are
the ones that make THAT non-trivial:

  * BOTH CHAINS ARE SCATTERED AND GO BACKWARDS. Inherited from M15's `scatter`.
    A loader that assumed contiguous clusters would produce a program whose
    .rodata is somebody else's bytes -- and, uniquely here, that program would
    still RUN and print a WRONG HASH rather than faulting. The hash is what
    catches it.
  * NEITHER ELF IS A MULTIPLE OF A CLUSTER, so the last cluster of each is
    partial.
  * THE TWO ELFs MUST NOT BE BYTE-IDENTICAL. build-progs.sh checks this too;
    checked again here because a volume with the control and the real program
    the same way round is a volume that cannot fail.
  * The realism M15 put in the root directory is kept: a volume label, a
    deleted entry, three long-filename entries, a zero-length file, one bad
    cluster and a subdirectory.

Usage:
    make-image.py <out.img> <drmabi.elf> <drmabin.elf> [--json]

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

SUBDIR_CLUSTER = 4900
BAD_CLUSTER = 4800

README_TEXT = (
    b"oscortex_core drm-abi -- the first C library this OS was pointed at.\n"
    b"DRMABI.ELF was compiled against include/drm/drm.h and\n"
    b"include/drm/virtgpu_drm.h out of an unmodified libdrm checkout. It\n"
    b"issues no ioctl, because this kernel has none: it reports the request\n"
    b"numbers its own compiler computed, so that the ABI can be checked\n"
    b"before anything is built on top of it. DRMABIN.ELF is the same program\n"
    b"compiled against BSD's _IOC encoding instead, and must disagree.\n"
)


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
    """m15-fileio's deterministic, DELIBERATELY NON-MONOTONIC cluster run."""
    span = hi - lo
    out = []
    c = start
    while len(out) < count:
        v = lo + (c % span)
        if v not in taken and v not in out:
            out.append(v)
        c += step
    return out


def backlinks(chain):
    return sum(1 for i in range(len(chain) - 1) if chain[i + 1] < chain[i])


def eightthree(name):
    if "." in name:
        stem, ext = name.split(".", 1)
    else:
        stem, ext = name, ""
    if len(stem) > 8 or len(ext) > 3:
        raise SystemExit("make-image: %r is not an 8.3 name" % name)
    return (stem.ljust(8) + ext.ljust(3)).upper().encode("ascii")


def sector_pattern(s):
    """m6-disk's background pattern: depends on the sector AND the offset."""
    b = bytearray((31 * s + 7 * i + 0x21) & 0xFF for i in range(SECTOR))
    label = ("OSCORTEX SECTOR %04X" % (s & 0xFFFF)).encode("ascii")
    b[0:len(label)] = label
    return bytes(b)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    if len(args) != 3:
        raise SystemExit("usage: make-image.py <out.img> <drmabi.elf> <drmabin.elf>")
    out, real_path, neg_path = args

    blobs = {
        "DRMABI.ELF": open(real_path, "rb").read(),
        "DRMABIN.ELF": open(neg_path, "rb").read(),
        "README.TXT": README_TEXT,
    }
    if blobs["DRMABI.ELF"] == blobs["DRMABIN.ELF"]:
        raise SystemExit("make-image: the real program and its negative control are "
                         "byte-identical; the control controls for nothing")
    for name in ("DRMABI.ELF", "DRMABIN.ELF"):
        if blobs[name][:4] != b"\x7fELF":
            raise SystemExit("make-image: %s is not an ELF" % name)
        if len(blobs[name]) % CLUSTER_BYTES == 0:
            raise SystemExit("make-image: %s is %d bytes, an exact multiple of the "
                             "cluster size; its last cluster would not be partial"
                             % (name, len(blobs[name])))

    def need(blob):
        return max(1, (len(blob) + CLUSTER_BYTES - 1) // CLUSTER_BYTES)

    # ---- cluster allocation ------------------------------------------------
    taken = {SUBDIR_CLUSTER, BAD_CLUSTER}
    chains = {}
    chains["DRMABI.ELF"] = scatter(need(blobs["DRMABI.ELF"]), taken, 1500, 3500, 1497, 0)
    taken |= set(chains["DRMABI.ELF"])
    chains["DRMABIN.ELF"] = scatter(need(blobs["DRMABIN.ELF"]), taken, 1500, 3500, 1097, 313)
    taken |= set(chains["DRMABIN.ELF"])
    chains["README.TXT"] = scatter(need(README_TEXT), taken, 4000, 4500, 97, 41)
    taken |= set(chains["README.TXT"])

    for name, chain in chains.items():
        if len(chain) != len(set(chain)):
            raise SystemExit("make-image: %s's chain repeats a cluster" % name)
        if len(chain) > 1 and chain == list(range(chain[0], chain[0] + len(chain))):
            raise SystemExit("make-image: %s came out CONTIGUOUS (%s)" % (name, chain))

    back = backlinks(chains["DRMABI.ELF"]) + backlinks(chains["DRMABIN.ELF"])
    if back < 4:
        raise SystemExit("make-image: the two ELF chains only go backwards %d times "
                         "between them; this image exists so that a driver that "
                         "walked clusters forwards could not pass" % back)

    # ---- the FAT -----------------------------------------------------------
    fat = bytearray(FAT_SECTORS * SECTOR)

    def set_fat(cluster, value):
        struct.pack_into("<H", fat, cluster * 2, value)

    set_fat(0, 0xFF00 | MEDIA)
    set_fat(1, FAT_EOC)
    for chain in chains.values():
        for i, c in enumerate(chain):
            set_fat(c, FAT_EOC if i == len(chain) - 1 else chain[i + 1])
    set_fat(SUBDIR_CLUSTER, FAT_EOC)
    set_fat(BAD_CLUSTER, FAT_BAD)

    # ---- the root directory ------------------------------------------------
    root = bytearray()

    def add(name, attr, first, size, raw=None):
        raw11 = raw if raw is not None else eightthree(name)
        root.extend(dir_entry(raw11, attr, first, size))

    add("OSCORTEX", 0x08, 0, 0)                       # volume label

    deleted = bytearray(eightthree("OLDFILE.BIN"))
    deleted[0] = 0xE5
    add(None, 0x20, 71, 4096, raw=bytes(deleted))     # a deleted entry

    long_raw = eightthree("DRMABI.ELF")
    for e in lfn_entries("the-drm-abi-probe.elf", lfn_checksum(long_raw)):
        root.extend(e)
    add("DRMABI.ELF", 0x20, chains["DRMABI.ELF"][0], len(blobs["DRMABI.ELF"]))

    add("DRMABIN.ELF", 0x20, chains["DRMABIN.ELF"][0], len(blobs["DRMABIN.ELF"]))
    add("README.TXT", 0x20, chains["README.TXT"][0], len(README_TEXT))
    add("EMPTY.TXT", 0x20, 0, 0)                      # a real zero-length file
    add("SUBDIR", 0x10, SUBDIR_CLUSTER, 0)            # a subdirectory

    if len(root) > ROOT_SECTORS * SECTOR:
        raise SystemExit("make-image: the root directory does not fit")
    root.extend(b"\x00" * (ROOT_SECTORS * SECTOR - len(root)))

    # ---- the image ---------------------------------------------------------
    img = bytearray()
    img.extend(boot_sector())
    img.extend(bytes(fat))
    img.extend(bytes(fat))
    img.extend(bytes(root))
    for s in range(DATA_SECTORS):
        img.extend(sector_pattern(DATA_START + s))

    def cluster_off(c):
        return (DATA_START + (c - 2) * SECTORS_PER_CLUSTER) * SECTOR

    for name, chain in chains.items():
        blob = blobs[name]
        for i, c in enumerate(chain):
            piece = blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
            off = cluster_off(c)
            img[off:off + len(piece)] = piece

    # SUBDIR's own cluster: `.` and `..` and nothing else.
    sub = bytearray()
    sub.extend(dir_entry(b".          ", 0x10, SUBDIR_CLUSTER, 0))
    sub.extend(dir_entry(b"..         ", 0x10, 0, 0))
    sub.extend(b"\x00" * (CLUSTER_BYTES - len(sub)))
    off = cluster_off(SUBDIR_CLUSTER)
    img[off:off + CLUSTER_BYTES] = bytes(sub)

    if len(img) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: image is %d bytes, expected %d"
                         % (len(img), TOTAL_SECTORS * SECTOR))

    # ---- self-check: read the two ELFs BACK out of the image the way the
    #      kernel will, by walking the FAT, and require them byte-identical to
    #      what went in. An image generator that got the chain wrong would
    #      otherwise produce a volume that only the harness's own expectations
    #      agreed with.
    def walk(first, size):
        got = bytearray()
        c = first
        seen = set()
        while len(got) < size:
            if c in seen or c < 2 or c >= CLUSTER_COUNT + 2:
                raise SystemExit("make-image: chain from %d is broken at %d" % (first, c))
            seen.add(c)
            o = cluster_off(c)
            got.extend(img[o:o + CLUSTER_BYTES])
            c = struct.unpack_from("<H", fat, c * 2)[0]
            if c >= 0xFFF8:
                break
        return bytes(got[:size])

    for name in blobs:
        first = chains[name][0]
        if walk(first, len(blobs[name])) != blobs[name]:
            raise SystemExit("make-image: %s does not read back out of the image "
                             "byte-for-byte" % name)

    with open(out, "wb") as f:
        f.write(bytes(img))

    info = {
        "image": os.path.abspath(out),
        "total_sectors": TOTAL_SECTORS,
        "cluster_bytes": CLUSTER_BYTES,
        "files": {n: {"size": len(blobs[n]), "chain": chains[n]} for n in blobs},
        "backlinks": back,
    }
    if want_json:
        print(json.dumps(info, indent=2))
    else:
        print("make-image: %s (%d sectors, %d backwards cluster links)"
              % (out, TOTAL_SECTORS, back))
    return 0


if __name__ == "__main__":
    sys.exit(main())
