#!/usr/bin/env python3
"""core/tests/conformance/d1-mouse/make-image.py

Writes D1's test disk: m10-elf's 32-byte header-sector format, carrying ONE
program at one sector.

    +0   "OSCXPRG1"
    +8   u64       the image's length in bytes
    +16  u64       the LBA its first sector is at

This is m10-elf's generator with the six deliberately-corrupted copies removed,
because D1 is not testing the loader. What it needs from the disk is exactly one
well-formed program that `run <lba>` will load and enter at CPL 3, so that
`prog.c` can ask the kernel for the pointer from ring 3.

The background pattern is m6-disk's, for m6-disk's reason: it depends on both
the sector number and the byte offset, so a loader that reads the wrong LBA gets
bytes that are wrong rather than bytes that are plausible.

    make-image.py <out.img> <prog.elf> [--json]

Exit status: 0 on success, 3 on a self-check failure.
"""

import json
import sys

SECTOR = 512
SECTORS = 512
MAGIC = b"OSCXPRG1"
HEADER_LBA = 0x20


def sector_bytes(s):
    b = bytearray((31 * s + 7 * i + 0x21) & 0xFF for i in range(SECTOR))
    label = ("OSCORTEX SECTOR %04X" % s).encode("ascii")
    b[0:len(label)] = label
    return bytes(b)


def build(path):
    img = bytearray()
    for s in range(SECTORS):
        img += sector_bytes(s)
    img[510:512] = b"\x55\xAA"

    blob = open(path, "rb").read()
    nsec = (len(blob) + SECTOR - 1) // SECTOR
    image_lba = HEADER_LBA + 1
    if (image_lba + nsec) * SECTOR > len(img):
        raise SystemExit("make-image: the program does not fit")

    hdr = bytearray(SECTOR)
    hdr[0:8] = MAGIC
    hdr[8:16] = len(blob).to_bytes(8, "little")
    hdr[16:24] = image_lba.to_bytes(8, "little")
    img[HEADER_LBA * SECTOR:(HEADER_LBA + 1) * SECTOR] = bytes(hdr)
    img[image_lba * SECTOR:(image_lba + nsec) * SECTOR] = \
        blob + b"\x00" * (nsec * SECTOR - len(blob))

    # Read it back rather than trusting the writes above: the header must name
    # the sector the bytes are actually at, and the bytes there must be the ELF.
    if img[HEADER_LBA * SECTOR:HEADER_LBA * SECTOR + 8] != MAGIC:
        raise SystemExit("make-image: the header sector does not carry the magic")
    got_lba = int.from_bytes(img[HEADER_LBA * SECTOR + 16:HEADER_LBA * SECTOR + 24], "little")
    if got_lba != image_lba:
        raise SystemExit("make-image: the header names LBA %d, the image is at %d"
                         % (got_lba, image_lba))
    if img[image_lba * SECTOR:image_lba * SECTOR + 4] != b"\x7fELF":
        raise SystemExit("make-image: no ELF magic at the LBA the header names")

    return img, {"header_lba": HEADER_LBA, "image_lba": image_lba,
                 "bytes": len(blob), "sectors": nsec}


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: make-image.py <out.img> <prog.elf> [--json]")
    img, layout = build(sys.argv[2])
    open(sys.argv[1], "wb").write(bytes(img))
    if "--json" in sys.argv[3:]:
        print(json.dumps(layout))
    return 0


if __name__ == "__main__":
    sys.exit(main())
