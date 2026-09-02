#!/usr/bin/env python3
"""core/tests/conformance/frame2/make-image.py

OSCXPRG1 disk so `proc spawn <lba>` can start SURF.ELF (and the
attach-only NOCOM.ELF control). Same 32-byte header-sector format
m10-elf invented.

    +0   "OSCXPRG1"
    +8   u64       the image's length in bytes
    +16  u64       the LBA its first sector is at

    make-image.py <out.img> <surf.elf> <nocom.elf> [--json]

Exit status: 0 on success, 3 on a self-check failure.
"""

import json
import sys

SECTOR = 512
SECTORS = 512

MAGIC = b"OSCXPRG1"

SLOTS = {"SURF": 0x20, "NOCOM": 0xA0}


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


def build(paths):
    img = bytearray()
    for s in range(SECTORS):
        img += sector_bytes(s)
    img[510:512] = b"\x55\xAA"
    layout = {}
    for name, hdr_lba in sorted(SLOTS.items(), key=lambda kv: kv[1]):
        blob = open(paths[name], "rb").read()
        image_lba = hdr_lba + 1
        nsec = (len(blob) + SECTOR - 1) // SECTOR
        if (image_lba + nsec) * SECTOR > len(img):
            raise SystemExit("make-image: %s does not fit in the image" % name)
        img[hdr_lba * SECTOR:(hdr_lba + 1) * SECTOR] = header_sector(len(blob), image_lba)
        padded = blob + b"\x00" * (nsec * SECTOR - len(blob))
        img[image_lba * SECTOR:(image_lba + nsec) * SECTOR] = padded
        layout[name] = {"header_lba": hdr_lba, "image_lba": image_lba,
                        "bytes": len(blob), "sectors": nsec}
    return bytes(img), layout


def verify(path, paths, layout):
    blob = open(path, "rb").read()
    fails = []
    if len(blob) != SECTOR * SECTORS:
        fails.append("image is %d bytes, expected %d" % (len(blob), SECTOR * SECTORS))
    for name, info in layout.items():
        want = open(paths[name], "rb").read()
        h = blob[info["header_lba"] * SECTOR:(info["header_lba"] + 1) * SECTOR]
        if h[0:8] != MAGIC:
            fails.append("%s: no OSCXPRG1 at LBA 0x%X" % (name, info["header_lba"]))
        if int.from_bytes(h[8:16], "little") != info["bytes"]:
            fails.append("%s: the header's byte count is wrong" % name)
        if int.from_bytes(h[16:24], "little") != info["image_lba"]:
            fails.append("%s: the header's LBA is wrong" % name)
        got = blob[info["image_lba"] * SECTOR:
                   info["image_lba"] * SECTOR + info["bytes"]]
        if got != want:
            fails.append("%s: the image read back differently than it was written" % name)
    a = blob[layout["SURF"]["image_lba"] * SECTOR:
             layout["SURF"]["image_lba"] * SECTOR + layout["SURF"]["bytes"]]
    b = blob[layout["NOCOM"]["image_lba"] * SECTOR:
             layout["NOCOM"]["image_lba"] * SECTOR + layout["NOCOM"]["bytes"]]
    if a == b:
        fails.append("SURF and NOCOM are byte-identical on the disk")
    if blob[510:512] != b"\x55\xAA":
        fails.append("sector 0 has no MBR signature")
    if blob.count(MAGIC) != len(SLOTS):
        fails.append("OSCXPRG1 appears %d times, expected %d"
                     % (blob.count(MAGIC), len(SLOTS)))
    if fails:
        for f in fails:
            print("make-image: FAIL — " + f, file=sys.stderr)
        sys.exit(3)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    if len(args) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    out, surf, nocom = args
    paths = {"SURF": surf, "NOCOM": nocom}
    img, layout = build(paths)
    open(out, "wb").write(img)
    verify(out, paths, layout)
    if want_json:
        print(json.dumps({"slots": layout, **layout}, indent=2, sort_keys=True))
    else:
        print("make-image: SURF at LBA 0x%X (%d bytes), NOCOM at LBA 0x%X (%d bytes)"
              % (layout["SURF"]["header_lba"], layout["SURF"]["bytes"],
                 layout["NOCOM"]["header_lba"], layout["NOCOM"]["bytes"]))


if __name__ == "__main__":
    main()
