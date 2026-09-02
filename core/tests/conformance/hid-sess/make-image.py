#!/usr/bin/env python3
"""core/tests/conformance/hid-sess/make-image.py

One OSCXPRG1 slot for `proc spawn <lba>`.
Usage: make-image.py <out.img> <prog.elf> [--json]
"""

import json
import sys

SECTOR = 512
SECTORS = 512
MAGIC = b"OSCXPRG1"
HDR_LBA = 0x20


def sector_bytes(s):
    b = bytearray((31 * s + 7 * i + 0x21) & 0xFF for i in range(SECTOR))
    label = ("OSCORTEX SECTOR %04X" % s).encode("ascii")
    b[0:len(label)] = label
    return bytes(b)


def header_sector(nbytes, lba):
    b = bytearray(SECTOR)
    b[0:8] = MAGIC
    b[8:16] = nbytes.to_bytes(8, "little")
    b[16:24] = lba.to_bytes(8, "little")
    return bytes(b)


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: make-image.py <out.img> <prog.elf> [--json]")
    out, elf = sys.argv[1], sys.argv[2]
    want_json = "--json" in sys.argv
    blob = open(elf, "rb").read()
    img = bytearray()
    for s in range(SECTORS):
        img += sector_bytes(s)
    img[510:512] = b"\x55\xAA"
    image_lba = HDR_LBA + 1
    nsec = (len(blob) + SECTOR - 1) // SECTOR
    if (image_lba + nsec) * SECTOR > len(img):
        raise SystemExit("make-image: prog does not fit")
    img[HDR_LBA * SECTOR:(HDR_LBA + 1) * SECTOR] = header_sector(len(blob), image_lba)
    padded = blob + b"\x00" * (nsec * SECTOR - len(blob))
    img[image_lba * SECTOR:(image_lba + nsec) * SECTOR] = padded
    open(out, "wb").write(img)
    layout = {"S": {"header_lba": HDR_LBA, "image_lba": image_lba,
                    "bytes": len(blob), "sectors": nsec}}
    got = open(out, "rb").read()
    h = got[HDR_LBA * SECTOR:(HDR_LBA + 1) * SECTOR]
    if h[0:8] != MAGIC:
        raise SystemExit("make-image: verify failed — no magic")
    body = got[image_lba * SECTOR:image_lba * SECTOR + len(blob)]
    if body != blob:
        raise SystemExit("make-image: verify failed — body mismatch")
    if want_json:
        print(json.dumps(layout))
    else:
        print("make-image: PASS — LBA 0x%X (%d bytes)" % (HDR_LBA, len(blob)))


if __name__ == "__main__":
    main()
