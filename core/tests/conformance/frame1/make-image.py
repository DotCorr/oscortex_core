#!/usr/bin/env python3
"""core/tests/conformance/frame1/make-image.py

FAT16 volume for FRAME1: ABITST.ELF and a planted copy of osframe.h
as FRAME.H. Geometry matches m15-fileio so fsck_msdos accepts it.

--variant=trunc drops the last `#define SYS_*` row from FRAME.H so the
guest checksum cannot match the full table.

    make-image.py <out.img> <abitst.elf> <osframe.h> [--json] [--variant=trunc]
"""

import json
import os
import re
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


def truncate_one_row(text):
    """Drop the last `#define SYS_* <n>` line — FRAME1's negative control."""
    lines = text.splitlines(keepends=True)
    idxs = [i for i, ln in enumerate(lines)
            if re.match(r"^#define SYS_[A-Z0-9_]+ \d+\s*$", ln)]
    if len(idxs) < 2:
        raise SystemExit("make-image: need at least two SYS_ rows to truncate one")
    del lines[idxs[-1]]
    return "".join(lines)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    variant = None
    for a in sys.argv[1:]:
        if a.startswith("--variant="):
            variant = a.split("=", 1)[1]
    if variant not in (None, "trunc"):
        raise SystemExit("make-image: unknown variant %r" % variant)
    if len(args) != 3:
        raise SystemExit("usage: make-image.py <out.img> <abitst.elf> <osframe.h>")
    out, elf_path, hdr_path = args

    hdr_text = open(hdr_path, "r", encoding="utf-8").read()
    if not hdr_text.startswith("/* OSFRAME "):
        raise SystemExit("make-image: osframe.h must start with /* OSFRAME <ver>")
    rows = re.findall(r"^#define SYS_[A-Z0-9_]+ (\d+)\s*$", hdr_text, re.M)
    if len(set(rows)) < 2:
        raise SystemExit("make-image: FRAME.H must name at least two distinct "
                         "syscall numbers (anti-vacuity)")
    planted = hdr_text
    if variant == "trunc":
        planted = truncate_one_row(hdr_text)
        if planted == hdr_text:
            raise SystemExit("make-image: truncate left the header unchanged")
    planted_bytes = planted.encode("utf-8")
    if variant is None and len(planted_bytes) <= 512:
        raise SystemExit("make-image: planted FRAME.H is %d bytes; FRAME1 "
                         "needs more than one 512-byte read" % len(planted_bytes))

    blobs = {
        "ABITST.ELF": open(elf_path, "rb").read(),
        "FRAME.H": planted_bytes,
    }

    taken = set()
    chains = {}
    c = 2
    for name in ("ABITST.ELF", "FRAME.H"):
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
    # rewrite the volume label's 11-byte name
    root[-32:-21] = b"OSCORTEX   "
    add("ABITST.ELF", 0x20, chains["ABITST.ELF"][0], len(blobs["ABITST.ELF"]))
    add("FRAME.H", 0x20, chains["FRAME.H"][0], len(blobs["FRAME.H"]))
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

    sidecar = out + ".frame"
    with open(sidecar, "wb") as f:
        f.write(planted_bytes)

    back = open(out, "rb").read()
    if len(back) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(back), TOTAL_SECTORS * SECTOR))
    for name, chain in chains.items():
        joined = b"".join(back[cluster_at(cl):cluster_at(cl) + CLUSTER_BYTES]
                          for cl in chain)
        if joined[:len(blobs[name])] != blobs[name]:
            raise SystemExit("make-image: %s does not read back" % name)

    layout = {
        "variant": variant or "full",
        "frame_bytes": len(planted_bytes),
        "sys_rows": len(rows) if variant is None else len(rows) - 1,
        "files": {n: {"bytes": len(blobs[n]), "clusters": len(chains[n])}
                  for n in blobs},
    }
    if want_json:
        print(json.dumps(layout))
    else:
        print("make-image: %s — FRAME.H %d bytes (%s), ABITST.ELF %d bytes"
              % (os.path.basename(out), len(planted_bytes),
                 layout["variant"], len(blobs["ABITST.ELF"])))


if __name__ == "__main__":
    main()
