#!/usr/bin/env python3
"""core/tests/conformance/de-sitfat/make-image.py

FAT16 volume for sit-in / ADR-0108 / ADR-0173. Directory order is the
FAT plant order; `wm de` Start caches only the first wmDeLaunchMax
ELF names. Geometry matches de-chrome / apps1 so fsck_msdos accepts it.

    make-image.py <out.img> [--json] NAME=path [NAME=path ...]

Each NAME is 8.3. ELF names are spawnable; non-ELF companions
(FACTS.DAT, APPS.TXT) sit on the volume but are not launch rows.
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


def parse_pairs(args):
    order = []
    blobs = {}
    for a in args:
        if "=" not in a:
            raise SystemExit("make-image: want NAME=path, got %r" % a)
        name, path = a.split("=", 1)
        name = name.upper()
        if name in blobs:
            raise SystemExit("make-image: duplicate name %s" % name)
        eightthree(name)
        if not os.path.isfile(path):
            raise SystemExit("make-image: no file %s" % path)
        blob = open(path, "rb").read()
        if name.endswith(".ELF") and blob[:4] != b"\x7fELF":
            raise SystemExit("make-image: %s is not ELF" % name)
        blobs[name] = blob
        order.append(name)
    return order, blobs


def main():
    raw = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    if len(raw) < 2:
        raise SystemExit(
            "usage: make-image.py <out.img> [--json] NAME=path [NAME=path ...]")
    out = raw[0]
    order, blobs = parse_pairs(raw[1:])
    elves = [n for n in order if n.endswith(".ELF")]
    if not elves:
        raise SystemExit("make-image: need at least one .ELF")

    taken = set()
    chains = {}
    c = 2
    for name in order:
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
    for name in order:
        add(name, 0x20, chains[name][0], len(blobs[name]))
    root += b"\x00" * (ROOT_ENTRIES * 32 - len(root))
    img[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR] = root

    def cluster_at(cl):
        return (DATA_START + (cl - 2) * SECTORS_PER_CLUSTER) * SECTOR

    for name, chain in chains.items():
        blob = blobs[name]
        for i, cl in enumerate(chain):
            piece = blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
            piece = piece + b"\0" * (CLUSTER_BYTES - len(piece))
            img[cluster_at(cl):cluster_at(cl) + CLUSTER_BYTES] = piece

    with open(out, "wb") as f:
        f.write(bytes(img))

    back = open(out, "rb").read()
    if len(back) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(back), TOTAL_SECTORS * SECTOR))
    if back[0:8] == b"OSCXPRG1":
        raise SystemExit("make-image: image begins with OSCXPRG1 — that is LBA, not FAT")
    if back[54:62] != b"FAT16   ":
        raise SystemExit("make-image: boot sector is not FAT16")
    for name, chain in chains.items():
        joined = b"".join(back[cluster_at(cl):cluster_at(cl) + CLUSTER_BYTES]
                          for cl in chain)
        if joined[:len(blobs[name])] != blobs[name]:
            raise SystemExit("make-image: %s does not read back" % name)

    layout = {
        "files": {n: {"bytes": len(blobs[n]), "clusters": len(chains[n])}
                  for n in order},
        "elves": elves,
        "order": order,
    }
    if want_json:
        print(json.dumps(layout))
    else:
        bits = ["%s %d" % (n, len(blobs[n])) for n in order]
        print("make-image: %s — %s" % (os.path.basename(out), ", ".join(bits)))


if __name__ == "__main__":
    main()
