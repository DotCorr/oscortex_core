#!/usr/bin/env python3
"""FAT16 volume for cef-somap (ADR-0176).

Full: PLAT.ELF + ASK.ELF + thirty-two LIB*.SO faces + SOMAP.TXT (32 aliases).
Miss-alias: same ELFs + all faces + SOMAP missing ld-linux line — no LINE32.
"""

import os
import struct
import sys

SECTOR = 512
BYTES_PER_SECTOR = 512
SECTORS_PER_CLUSTER = 2
RESERVED = 1
NUM_FATS = 2
FAT_SECTORS = 32
ROOT_ENTRIES = 512
DATA_SECTORS = 16000
ROOT_SECTORS = (ROOT_ENTRIES * 32) // BYTES_PER_SECTOR
FAT_START = RESERVED
ROOT_START = RESERVED + NUM_FATS * FAT_SECTORS
DATA_START = ROOT_START + ROOT_SECTORS
TOTAL_SECTORS = DATA_START + DATA_SECTORS
CLUSTER_COUNT = DATA_SECTORS // SECTORS_PER_CLUSTER
CLUSTER_BYTES = SECTORS_PER_CLUSTER * BYTES_PER_SECTOR
MEDIA = 0xF8
FAT_EOC = 0xFFFF

# Host stem (from build-progs) → FAT 8.3 plant name.
STEM_TO_FAT = {
    "libc": "LIBC.SO",
    "libm": "LIBM.SO",
    "libdl": "LIBDL.SO",
    "libpt": "LIBPT.SO",
    "libgb": "LIBGB.SO",
    "libgo": "LIBGO.SO",
    "libnp": "LIBNP.SO",
    "libns": "LIBNS.SO",
    "libnu": "LIBNU.SO",
    "libsm": "LIBSM.SO",
    "libdb": "LIBDB.SO",
    "libgi": "LIBGI.SO",
    "libat": "LIBAT.SO",
    "libab": "LIBAB.SO",
    "libcu": "LIBCU.SO",
    "libx1": "LIBX1.SO",
    "libxc": "LIBXC.SO",
    "libxd": "LIBXD.SO",
    "libxe": "LIBXE.SO",
    "libxf": "LIBXF.SO",
    "libxr": "LIBXR.SO",
    "libgm": "LIBGM.SO",
    "libex": "LIBEX.SO",
    "libxb": "LIBXB.SO",
    "libxk": "LIBXK.SO",
    "libca": "LIBCA.SO",
    "libpg": "LIBPG.SO",
    "libud": "LIBUD.SO",
    "libas": "LIBAS.SO",
    "libap": "LIBAP.SO",
    "libgc": "LIBGC.SO",
    "libld": "LIBLD.SO",
}


def sector_pattern(s):
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
    b[36] = 0x80
    b[38] = 0x29
    struct.pack_into("<I", b, 39, 0x05C0FFEE)
    b[43:54] = b"OSCORTEX   "
    b[54:62] = b"FAT16   "
    b[510:512] = b"\x55\xAA"
    return bytes(b)


def read_blob(path, label, lo=1, hi=65536):
    data = open(path, "rb").read()
    if len(data) < lo or len(data) > hi:
        raise SystemExit("make-image: %s size %d out of range [%d,%d]"
                         % (label, len(data), lo, hi))
    return data


def build(out, elf_path, so_paths, somap_path):
    blob = read_blob(elf_path, "ELF", lo=64)
    blobs = {"PLAT.ELF": blob, "ASK.ELF": blob}
    names = ["PLAT.ELF", "ASK.ELF"]

    for path in so_paths:
        base = os.path.basename(path)
        stem = base.split(".", 1)[0].lower()
        if stem not in STEM_TO_FAT:
            raise SystemExit("make-image: unknown stand-in %r" % base)
        fat_name = STEM_TO_FAT[stem]
        blobs[fat_name] = read_blob(path, fat_name, lo=64)
        names.append(fat_name)

    if somap_path is not None:
        somap = read_blob(somap_path, "SOMAP.TXT", lo=12, hi=4096)
        if b"libdl.so.2=LIBDL.SO" not in somap:
            raise SystemExit("make-image: SOMAP.TXT missing libdl.so.2=LIBDL.SO")
        blobs["SOMAP.TXT"] = somap
        names.append("SOMAP.TXT")

    if blobs["PLAT.ELF"] != blobs["ASK.ELF"]:
        raise SystemExit("make-image: the two ELF names must be the same bytes")

    taken = set()
    chains = {}
    c = 2
    for name in names:
        need = max(1, (len(blobs[name]) + CLUSTER_BYTES - 1) // CLUSTER_BYTES)
        chain = []
        while len(chain) < need:
            if c >= CLUSTER_COUNT + 2:
                raise SystemExit("make-image: ran out of clusters placing %s" % name)
            if c not in taken:
                chain.append(c)
                taken.add(c)
            c += 1
        chains[name] = chain

    img = bytearray()
    for s in range(TOTAL_SECTORS):
        img += sector_pattern(s)
    img[0:SECTOR] = boot_sector()

    fat = bytearray(FAT_SECTORS * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFF00 | MEDIA)
    struct.pack_into("<H", fat, 2, FAT_EOC)
    for name, chain in chains.items():
        for i, cl in enumerate(chain):
            nxt = chain[i + 1] if i + 1 < len(chain) else FAT_EOC
            struct.pack_into("<H", fat, cl * 2, nxt)
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR
        img[at:at + len(fat)] = fat

    root = bytearray()

    def add(name, attr, first, size):
        root.extend(dir_entry(eightthree(name), attr, first, size))

    add("OSCORTEX", 0x08, 0, 0)
    root[-32:-21] = b"OSCORTEX   "
    for name in names:
        add(name, 0x20, chains[name][0], len(blobs[name]))
    root += b"\x00" * (ROOT_ENTRIES * 32 - len(root))
    img[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR] = root

    def cluster_at(cl):
        return (DATA_START + (cl - 2) * SECTORS_PER_CLUSTER) * SECTOR

    for name, chain in chains.items():
        piece_blob = blobs[name]
        for i, cl in enumerate(chain):
            piece = piece_blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
            piece = piece + b"\0" * (CLUSTER_BYTES - len(piece))
            img[cluster_at(cl):cluster_at(cl) + CLUSTER_BYTES] = piece

    with open(out, "wb") as f:
        f.write(bytes(img))

    back = open(out, "rb").read()
    if len(back) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(back), TOTAL_SECTORS * SECTOR))
    for name, chain in chains.items():
        joined = b"".join(back[cluster_at(cl):cluster_at(cl) + CLUSTER_BYTES]
                          for cl in chain)
        if joined[:len(blobs[name])] != blobs[name]:
            raise SystemExit("make-image: %s does not read back" % name)

    extras = [n for n in names if n not in ("PLAT.ELF", "ASK.ELF")]
    print("make-image: %s — PLAT/ASK %d, %d extras"
          % (os.path.basename(out), len(blob), len(extras)))


def main():
    if len(sys.argv) < 4:
        raise SystemExit(
            "usage: make-image.py <out.img> <plat.elf> [--somap path] "
            "<so>...")
    out = sys.argv[1]
    elf = sys.argv[2]
    somap = None
    sos = []
    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == "--somap" and i + 1 < len(args):
            somap = args[i + 1]
            i += 2
        else:
            sos.append(args[i])
            i += 1
    if len(sos) < 1:
        raise SystemExit("make-image: need at least one .so")
    build(out, elf, sos, somap)


if __name__ == "__main__":
    main()
