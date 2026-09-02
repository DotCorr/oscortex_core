#!/usr/bin/env python3
"""core/tests/conformance/d2-compositor/make-image.py

Writes D4/D5's test disk: the SAME 32-byte header-sector format m10-elf invented,
carrying THE SAME PROGRAM TWICE, at two sector numbers.

    +0   "OSCXPRG1"
    +8   u64       the image's length in bytes
    +16  u64       the LBA its first sector is at

WHY TWO SLOTS OF THE SAME BYTES
---------------------------------------------------------------------------
`proc coop <lbaA> <lbaB>` refuses `lbaA == lbaB` (procErrSameLba), so the two
processes must come from two different sector numbers. It does NOT care whether
the bytes are the same -- and for M20 they must be, because the milestone's
claim is that the two processes take different roles ON THE KERNEL'S SAY-SO
rather than because they are different programs.

So this file writes one ELF to two slots and then ASSERTS THE TWO SECTOR RANGES
ARE BYTE-IDENTICAL, re-read out of the image it just wrote. That assertion is
the negative-control half of "the same binary, two roles": if the two ranges
ever differed, the milestone's headline claim would be vacuous and this is the
only place that could notice.

    make-image.py <out.img> <wm.elf> [--json]

Exit status: 0 on success, 3 on a self-check failure.
"""

import json
import sys

SECTOR = 512
SECTORS = 512

MAGIC = b"OSCXPRG1"

# Header sector, image one sector later, and the two copies 128 sectors apart --
# which is more than six times the size of the program, so an off-by-a-lot in
# the loader's sector arithmetic lands in the background pattern rather than in
# the other copy. m18's slots and m18's reasoning.
SLOTS = {"A": 0x20, "B": 0xA0}


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


def build(path):
    img = bytearray()
    for s in range(SECTORS):
        img += sector_bytes(s)
    # m6-disk put an MBR signature at sector 0 and nothing reads it. Kept so
    # this image is the same shape as that one.
    img[510:512] = b"\x55\xAA"

    blob = open(path, "rb").read()
    nsec = (len(blob) + SECTOR - 1) // SECTOR
    layout = {}
    for name, hdr_lba in sorted(SLOTS.items()):
        image_lba = hdr_lba + 1
        if (image_lba + nsec) * SECTOR > len(img):
            raise SystemExit("make-image: the program does not fit in slot %s" % name)
        img[hdr_lba * SECTOR:(hdr_lba + 1) * SECTOR] = header_sector(len(blob), image_lba)
        padded = blob + b"\x00" * (nsec * SECTOR - len(blob))
        img[image_lba * SECTOR:(image_lba + nsec) * SECTOR] = padded
        layout[name] = {"header_lba": hdr_lba, "image_lba": image_lba,
                        "bytes": len(blob), "sectors": nsec}
    return img, layout, nsec


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    want_json = "--json" in sys.argv[1:]
    if len(args) != 2:
        raise SystemExit("usage: make-image.py <out.img> <wm.elf> [--json]")
    out, elf = args
    img, layout, nsec = build(elf)
    open(out, "wb").write(img)

    # ---- SELF-CHECK, out of the file that was actually written. ----
    back = open(out, "rb").read()
    if len(back) != SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(back), SECTORS * SECTOR))
    ranges = {}
    for name, s in layout.items():
        lo = s["image_lba"] * SECTOR
        hi = lo + s["sectors"] * SECTOR
        ranges[name] = back[lo:hi]
        hdr = back[s["header_lba"] * SECTOR: s["header_lba"] * SECTOR + 24]
        if hdr[0:8] != MAGIC:
            raise SystemExit("make-image: slot %s has no OSCXPRG1 header" % name)
        if int.from_bytes(hdr[8:16], "little") != s["bytes"]:
            raise SystemExit("make-image: slot %s header length is wrong" % name)
        if int.from_bytes(hdr[16:24], "little") != s["image_lba"]:
            raise SystemExit("make-image: slot %s header LBA is wrong" % name)
        if ranges[name][0:4] != b"\x7fELF":
            raise SystemExit("make-image: slot %s does not begin with ELF magic" % name)

    # THE ASSERTION THIS FILE EXISTS FOR.
    if ranges["A"] != ranges["B"]:
        raise SystemExit("make-image: the two program slots are NOT byte-identical -- "
                         "the compositor milestone's claim is that ONE binary takes two roles, and this "
                         "image cannot support it")
    if layout["A"]["header_lba"] == layout["B"]["header_lba"]:
        raise SystemExit("make-image: both slots have the same header LBA; "
                         "`proc coop` refuses lbaA == lbaB")

    if want_json:
        print(json.dumps({"image": out, "bytes": len(back), "sectors": SECTORS,
                          "program_sectors": nsec, "slots": layout,
                          "identical": True}, indent=2))
    else:
        for name in sorted(layout):
            s = layout[name]
            print("slot %s: header LBA 0x%X, image LBA 0x%X, %d bytes / %d sectors"
                  % (name, s["header_lba"], s["image_lba"], s["bytes"], s["sectors"]))
        print("the two slots are byte-identical (%d bytes each)" % len(ranges["A"]))


if __name__ == "__main__":
    main()
