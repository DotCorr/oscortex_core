#!/usr/bin/env python3
"""core/tests/conformance/m13-libc/make-image.py

Writes the M13 test disk: the same 32-byte header-sector format m10-elf
invented, carrying TWO program slots.

    +0   "OSCXPRG1"
    +8   u64       the image's length in bytes
    +16  u64       the LBA its first sector is at

There is still no filesystem and this is still the entire metadata format
(docs/known-gaps.md GAP-0090, which M13 does NOT narrow: a C library is a
userland question and this is a storage one -- there is no `open`, no `read`,
no `FILE` and no `fopen` in core/user/libc, and GAP-0113 says so).

TWO SLOTS, NOT FOUR. m12-heap needed four because the page tables had to be read
out of guest RAM at two chosen moments, which meant two extra copies of one
binary with `jmp .` patched over a labelled `nop; nop`. M13 asserts nothing
about page tables that M12 did not already assert about the same kernel, so it
carries exactly the two programs it runs:

    L   the library as written
    N   the same source with `free()` disabled -- the NEGATIVE CONTROL

    make-image.py <out.img> <progL.elf> <progN.elf> [--json]

Exit status: 0 on success, 3 on a self-check failure.
"""

import json
import os
import sys

SECTOR = 512
SECTORS = 512

MAGIC = b"OSCXPRG1"

# 128 sectors apart -- more than twice the size of either -- so an off-by-a-lot
# in the loader's sector arithmetic lands in the background pattern rather than
# in the other program. The two programs differ by ONE WORD of .rodata, so two
# slots loading each other would be very nearly invisible; the LBAs are far
# apart for that reason.
SLOTS = {"L": 0x20, "N": 0xA0}


def sector_bytes(s):
    """m6-disk's pattern: depends on the sector AND the byte offset."""
    b = bytearray((31 * s + 7 * i + 0x21) & 0xFF for i in range(SECTOR))
    label = ("OSCORTEX SECTOR %04X" % s).encode("ascii")
    b[0:len(label)] = label
    return bytes(b)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    if len(args) != 3:
        raise SystemExit("usage: make-image.py <out.img> <progL.elf> <progN.elf> [--json]")
    out, l_path, n_path = args

    progs = {"L": open(l_path, "rb").read(), "N": open(n_path, "rb").read()}
    if progs["L"] == progs["N"]:
        raise SystemExit("make-image: the two programs are byte-identical")
    if len(progs["L"]) != len(progs["N"]):
        raise SystemExit("make-image: the two programs are different sizes (%d, %d); the "
                         "control build must differ only in one .rodata word"
                         % (len(progs["L"]), len(progs["N"])))

    img = bytearray()
    for s in range(SECTORS):
        img += sector_bytes(s)
    img[510:512] = b"\x55\xAA"            # m6-disk's MBR signature, still unread

    layout = {"sectors": SECTORS, "slots": {}}

    for tag, lba in SLOTS.items():
        blob = progs[tag]
        need = (len(blob) + SECTOR - 1) // SECTOR
        if lba + 1 + need > SECTORS:
            raise SystemExit("make-image: slot %s does not fit" % tag)
        hdr = bytearray(SECTOR)
        hdr[0:8] = MAGIC
        hdr[8:16] = len(blob).to_bytes(8, "little")
        hdr[16:24] = (lba + 1).to_bytes(8, "little")
        img[lba * SECTOR:(lba + 1) * SECTOR] = hdr
        padded = blob + b"\0" * (need * SECTOR - len(blob))
        img[(lba + 1) * SECTOR:(lba + 1 + need) * SECTOR] = padded
        layout["slots"][tag] = {"lba": lba, "image_lba": lba + 1,
                                "bytes": len(blob), "sectors": need}

    with open(out, "wb") as f:
        f.write(bytes(img))

    # Self-check: read it back off the disk and decode every header the way the
    # kernel does.
    back = open(out, "rb").read()
    if len(back) != SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d" % (len(back), SECTORS * SECTOR))
    for tag, lba in SLOTS.items():
        hdr = back[lba * SECTOR:(lba + 1) * SECTOR]
        if hdr[0:8] != MAGIC:
            raise SystemExit("make-image: slot %s has no magic after write-back" % tag)
        n = int.from_bytes(hdr[8:16], "little")
        at = int.from_bytes(hdr[16:24], "little")
        if back[at * SECTOR:at * SECTOR + n] != progs[tag]:
            raise SystemExit("make-image: slot %s does not read back byte-for-byte" % tag)

    if want_json:
        print(json.dumps(layout))
    else:
        print("make-image: %s — %d sectors, slots %s"
              % (os.path.basename(out), SECTORS,
                 ", ".join("%s@0x%X" % (t, l) for t, l in sorted(SLOTS.items(), key=lambda kv: kv[1]))))


if __name__ == "__main__":
    main()
