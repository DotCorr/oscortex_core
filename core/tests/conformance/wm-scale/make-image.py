#!/usr/bin/env python3
"""core/tests/conformance/files-unl/make-image.py

FAT16 volume carrying only PROG.ELF. The program creates and unlinks
its own names — no planted KILL.DAT (anti-vacuity).

    make-image.py <out.img> <prog.elf>
"""

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
ROOT_SECTORS = (ROOT_ENTRIES * 32) // BYTES_PER_SECTOR
FAT_START = RESERVED
ROOT_START = RESERVED + NUM_FATS * FAT_SECTORS
DATA_START = ROOT_START + ROOT_SECTORS
TOTAL_SECTORS = DATA_START + DATA_SECTORS
CLUSTER_COUNT = DATA_SECTORS // SECTORS_PER_CLUSTER
CLUSTER_BYTES = SECTORS_PER_CLUSTER * BYTES_PER_SECTOR
MEDIA = 0xF8
FAT_EOC = 0xFFFF


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
    return (stem.ljust(8) + ext.ljust(3)).upper().encode("ascii")


def dir_entry(raw11, attr, first_cluster, size):
    e = bytearray(32)
    e[0:11] = raw11
    e[11] = attr
    struct.pack_into("<H", e, 26, first_cluster)
    struct.pack_into("<I", e, 28, size)
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


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: make-image.py <out.img> <prog.elf>")
    out, elfp = sys.argv[1], sys.argv[2]
    blob = open(elfp, "rb").read()
    need = max(1, (len(blob) + CLUSTER_BYTES - 1) // CLUSTER_BYTES)
    chain = list(range(2, 2 + need))
    if chain[-1] >= CLUSTER_COUNT + 2:
        raise SystemExit("make-image: program too large")

    img = bytearray()
    for s in range(TOTAL_SECTORS):
        img += sector_pattern(s)
    img[0:SECTOR] = boot_sector()

    fat = bytearray(FAT_SECTORS * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFF00 | MEDIA)
    struct.pack_into("<H", fat, 2, FAT_EOC)
    for i, cl in enumerate(chain):
        nxt = chain[i + 1] if i + 1 < len(chain) else FAT_EOC
        struct.pack_into("<H", fat, cl * 2, nxt)
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR
        img[at:at + len(fat)] = fat

    root = bytearray()
    root.extend(dir_entry(b"OSCORTEX   ", 0x08, 0, 0))
    root.extend(dir_entry(eightthree("PROG.ELF"), 0x20, chain[0], len(blob)))
    root += b"\x00" * (ROOT_ENTRIES * 32 - len(root))
    img[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR] = root

    def cluster_at(cl):
        return (DATA_START + (cl - 2) * SECTORS_PER_CLUSTER) * SECTOR

    for i, cl in enumerate(chain):
        piece = blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
        piece = piece + b"\0" * (CLUSTER_BYTES - len(piece))
        img[cluster_at(cl):cluster_at(cl) + CLUSTER_BYTES] = piece

    with open(out, "wb") as f:
        f.write(bytes(img))
    print("make-image: %s — PROG.ELF %d bytes (%d clusters)"
          % (os.path.basename(out), len(blob), len(chain)))


if __name__ == "__main__":
    main()
