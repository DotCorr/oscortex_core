#!/usr/bin/env python3
"""core/tests/conformance/nvm6/make-image.py

FAT16 volume with one 8.3 ELF whose chain has a hole: first cluster is
2, the rest start at 20. A reader that walks LBA+1 after the first
sector, or that still reads NVM3's LBA 7, cannot assemble the file.

    make-image.py <out.img> <prog.elf>
"""

import os
import struct
import sys

SECTOR = 512
BPS = 512
SPC = 1
RESERVED = 1
NUM_FATS = 2
FAT_SECTORS = 16
ROOT_ENTRIES = 512
CLUSTERS = 4085
ROOT_SECTORS = (ROOT_ENTRIES * 32) // BPS
FAT_START = RESERVED
ROOT_START = RESERVED + NUM_FATS * FAT_SECTORS
DATA_START = ROOT_START + ROOT_SECTORS
TOTAL = DATA_START + CLUSTERS
CLUS_FIRST = 2
CLUS_REST = 20
FAT_EOC = 0xFFFF


def boot_sector():
    b = bytearray(SECTOR)
    b[0:3] = b"\xEB\x3C\x90"
    b[3:11] = b"OSCORTEX"
    struct.pack_into("<H", b, 11, BPS)
    b[13] = SPC
    struct.pack_into("<H", b, 14, RESERVED)
    b[16] = NUM_FATS
    struct.pack_into("<H", b, 17, ROOT_ENTRIES)
    struct.pack_into("<H", b, 19, TOTAL)
    b[21] = 0xF8
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


def put_fat(img, cluster, value):
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR + cluster * 2
        struct.pack_into("<H", img, at, value)


def cluster_lba(c):
    return DATA_START + (c - 2) * SPC


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: make-image.py <out.img> <prog.elf>")
    out, elf_path = sys.argv[1], sys.argv[2]
    blob = open(elf_path, "rb").read()
    if len(blob) < 64:
        raise SystemExit("make-image: ELF shorter than one ELF64 header")
    if blob[:4] != b"\x7fELF":
        raise SystemExit("make-image: not an ELF")
    need = max(1, (len(blob) + SECTOR - 1) // SECTOR)
    chain = [CLUS_FIRST]
    c = CLUS_REST
    while len(chain) < need:
        if c >= CLUSTERS + 2:
            raise SystemExit("make-image: ran out of clusters")
        chain.append(c)
        c += 1
    if chain[0] + 1 == chain[1] if len(chain) > 1 else False:
        raise SystemExit("make-image: chain is contiguous — the hole is gone")
    if cluster_lba(chain[1] if len(chain) > 1 else chain[0]) == 7:
        raise SystemExit("make-image: a file cluster landed at LBA 7")

    img = bytearray(TOTAL * SECTOR)
    img[0:SECTOR] = boot_sector()
    put_fat(img, 0, 0xFFF8)
    put_fat(img, 1, 0xFFFF)
    for i, cl in enumerate(chain):
        nxt = chain[i + 1] if i + 1 < len(chain) else FAT_EOC
        put_fat(img, cl, nxt)

    e = bytearray(32)
    e[0:11] = b"PROG    ELF"
    e[11] = 0x20
    struct.pack_into("<H", e, 26, chain[0])
    struct.pack_into("<I", e, 28, len(blob))
    struct.pack_into("<H", e, 24, ((2026 - 1980) << 9) | (1 << 5) | 1)
    root = ROOT_START * SECTOR
    img[root:root + 32] = e

    for i, cl in enumerate(chain):
        src = blob[i * SECTOR:(i + 1) * SECTOR]
        at = cluster_lba(cl) * SECTOR
        img[at:at + len(src)] = src

    # Cluster 3 sits immediately after the first file sector. A contiguous
    # reader would consume this decoy as image sector 1.
    decoy = os.urandom(16)
    img[cluster_lba(3) * SECTOR:cluster_lba(3) * SECTOR + 16] = decoy

    open(out, "wb").write(img)
    meta = os.path.splitext(out)[0] + ".meta"
    open(meta, "w").write(
        "data_start=%d clus2_lba=%d clus20_lba=%d clus3_lba=%d "
        "sectors=%d bytes=%d chain=%s\n"
        % (DATA_START, cluster_lba(chain[0]), cluster_lba(chain[1] if len(chain) > 1 else chain[0]),
           cluster_lba(3), need, len(blob), ",".join(str(x) for x in chain))
    )
    print("make-image: %s  %d bytes  chain %s  first LBA %d rest LBA %d"
          % (out, len(blob), chain[:3], cluster_lba(chain[0]),
             cluster_lba(chain[1] if len(chain) > 1 else chain[0])))


if __name__ == "__main__":
    main()
