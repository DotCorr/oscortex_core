#!/usr/bin/env python3
"""core/tests/conformance/m18-preempt/make-image.py

Writes the M11 test disk: the SAME 32-byte header-sector format m10-elf
invented, carrying TWO DIFFERENT PROGRAMS instead of one program and six
mutations of it.

    +0   "OSCXPRG1"
    +8   u64       the image's length in bytes
    +16  u64       the LBA its first sector is at

There is still no filesystem and this file is still the entire metadata format
(docs/known-gaps.md GAP-0090). What M11 changes is only that the kernel is now
told TWO sector numbers instead of one.

    make-image.py <out.img> <progC.elf> <progD.elf> [--json]

Exit status: 0 on success, 3 on a self-check failure.
"""

import json
import os
import sys

SECTOR = 512
SECTORS = 512

MAGIC = b"OSCXPRG1"

# Header sector, image one sector later, and the two programs 128 sectors
# apart -- which is more than six times the size of either, so an off-by-a-lot
# in the loader's sector arithmetic lands in the background pattern rather than
# in the OTHER program. That matters more here than it did at M10: two
# programs that both loaded because the kernel read the wrong one twice would
# print the same lines twice and look like a working scheduler.
SLOTS = {"C": 0x20, "D": 0xA0}


def file_offset(blob, vaddr):
    """The file offset of `vaddr`, through the program headers."""
    phoff = int.from_bytes(blob[32:40], "little")
    phentsize = int.from_bytes(blob[54:56], "little")
    phnum = int.from_bytes(blob[56:58], "little")
    for i in range(phnum):
        p = blob[phoff + i * phentsize: phoff + (i + 1) * phentsize]
        if int.from_bytes(p[0:4], "little") != 1:
            continue
        off = int.from_bytes(p[8:16], "little")
        va = int.from_bytes(p[16:24], "little")
        filesz = int.from_bytes(p[32:40], "little")
        if va <= vaddr < va + filesz:
            return off + (vaddr - va)
    raise SystemExit("make-image: 0x%X is in no file-backed segment" % vaddr)


def sector_bytes(s):
    """m6-disk's pattern: depends on the sector AND the byte offset."""
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
    # m6-disk put an MBR signature at sector 0 and nothing reads it. Kept so
    # this image is the same shape as that one.
    img[510:512] = b"\x55\xAA"
    layout = {}
    for name, hdr_lba in sorted(SLOTS.items()):
        blob = open(paths[name], "rb").read()
        image_lba = hdr_lba + 1
        nsec = (len(blob) + SECTOR - 1) // SECTOR
        if (image_lba + nsec) * SECTOR > len(img):
            raise SystemExit("make-image: prog%s does not fit in the image" % name)
        img[hdr_lba * SECTOR:(hdr_lba + 1) * SECTOR] = header_sector(len(blob), image_lba)
        padded = blob + b"\x00" * (nsec * SECTOR - len(blob))
        img[image_lba * SECTOR:(image_lba + nsec) * SECTOR] = padded
        layout[name] = {"header_lba": hdr_lba, "image_lba": image_lba,
                        "bytes": len(blob), "sectors": nsec}
    return bytes(img), layout


def verify(path, paths, layout):
    """Reads the file back off the filesystem rather than trusting the bytes
    that were just written."""
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
    # The two programs must be genuinely different ON THE DISK, not only as
    # files: this is what "two different programs ran" rests on.
    a = blob[layout["C"]["image_lba"] * SECTOR:
             layout["C"]["image_lba"] * SECTOR + layout["C"]["bytes"]]
    b = blob[layout["D"]["image_lba"] * SECTOR:
             layout["D"]["image_lba"] * SECTOR + layout["D"]["bytes"]]
    if a == b:
        fails.append("the two programs are byte-identical on the disk")
    if blob[0:510] != sector_bytes(0)[0:510]:
        fails.append("sector 0 is not the background pattern")
    if blob[510:512] != b"\x55\xAA":
        fails.append("sector 0 has no MBR signature")
    if blob[0:SECTOR] == blob[SECTOR:2 * SECTOR]:
        fails.append("sectors 0 and 1 are identical -- the pattern does not depend "
                     "on the sector number, so an LBA off-by-one could not be detected")
    if blob.count(MAGIC) != len(SLOTS):
        fails.append("OSCXPRG1 appears %d times, expected %d"
                     % (blob.count(MAGIC), len(SLOTS)))
    if fails:
        for f in fails:
            print("make-image: FAIL — " + f, file=sys.stderr)
        sys.exit(3)


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    out = sys.argv[1]
    paths = {"C": sys.argv[2], "D": sys.argv[3]}
    img, layout = build(paths)
    open(out, "wb").write(img)
    verify(out, paths, layout)
    if "--json" in sys.argv[4:]:
        print(json.dumps(layout, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
