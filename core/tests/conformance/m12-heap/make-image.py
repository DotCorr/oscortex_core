#!/usr/bin/env python3
"""core/tests/conformance/m12-heap/make-image.py

Writes the M12 test disk: the SAME 32-byte header-sector format m10-elf
invented, carrying FOUR program slots built from TWO ELF files.

    +0   "OSCXPRG1"
    +8   u64       the image's length in bytes
    +16  u64       the LBA its first sector is at

There is still no filesystem and this file is still the entire metadata format
(docs/known-gaps.md GAP-0090, which M12 does NOT narrow -- a heap is a memory
question and this is a storage one).

WHY FOUR SLOTS FOR TWO PROGRAMS
-------------------------------
`progH` and `progP` are the two processes. The other two slots are `progH` with
TWO BYTES CHANGED, and they exist because the page tables have to be read out of
guest RAM at two different moments and a running process cannot be paused from
outside:

    Hearly   `jmp .` written over `heapHoldEarly`  -- the process is alive,
             running, and has allocated NOTHING. This is the BEFORE picture:
             every heap page must be absent from its page table.
    Hlate    `jmp .` written over `heapHoldLate`   -- the process is alive with
             every page it was ever given still mapped and still written. This
             is the AFTER picture.

m10-elf and m11-proc patched `e_entry` for the same reason. A heap needs the
stop to be somewhere the entry point is not, so the patch is applied AT A NAMED
SYMBOL and the two bytes there are checked to be `90 90` (`nop; nop`) before
they are replaced -- build-progs.sh checks the same thing independently.

    make-image.py <out.img> <progH.elf> <progP.elf> [--json]

Exit status: 0 on success, 3 on a self-check failure.
"""

import json
import os
import sys

SECTOR = 512
SECTORS = 512

MAGIC = b"OSCXPRG1"

# The four slots, 128 sectors apart -- more than six times the size of any of
# them, so an off-by-a-lot in the loader's sector arithmetic lands in the
# background pattern rather than in another program. That matters more here than
# ever, because three of the four slots are the SAME program: two of them
# loading identically would look exactly like a working test.
SLOTS = {"H": 0x20, "P": 0xA0, "Hearly": 0x120, "Hlate": 0x1A0}


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


def symbol(blob, name):
    """The value of `name` in the ELF's own .symtab, read out of the raw bytes.

    Read from the FILE rather than shelled out to readelf, so that this
    generator and build-progs.sh reach the same number by two different routes.
    """
    shoff = int.from_bytes(blob[40:48], "little")
    shentsize = int.from_bytes(blob[58:60], "little")
    shnum = int.from_bytes(blob[60:62], "little")
    for i in range(shnum):
        sh = blob[shoff + i * shentsize: shoff + (i + 1) * shentsize]
        sh_type = int.from_bytes(sh[4:8], "little")
        if sh_type != 2:  # SHT_SYMTAB
            continue
        off = int.from_bytes(sh[24:32], "little")
        size = int.from_bytes(sh[32:40], "little")
        link = int.from_bytes(sh[40:44], "little")
        entsize = int.from_bytes(sh[56:64], "little")
        strsh = blob[shoff + link * shentsize: shoff + (link + 1) * shentsize]
        stroff = int.from_bytes(strsh[24:32], "little")
        for j in range(size // entsize):
            e = blob[off + j * entsize: off + (j + 1) * entsize]
            nameoff = int.from_bytes(e[0:4], "little")
            end = blob.index(b"\0", stroff + nameoff)
            if blob[stroff + nameoff:end].decode("ascii") == name:
                return int.from_bytes(e[8:16], "little")
    raise SystemExit("make-image: no symbol %s in the ELF" % name)


def mutate_hold(blob, sym):
    """`progH` with `jmp .` (EB FE) written over the two bytes at `sym`.

    The two bytes MUST be `90 90` going in. A patch that landed in the middle of
    a longer instruction would produce a program that does something nobody
    wrote, and "the process stopped where I meant it to" would be an assumption
    rather than a fact.
    """
    b = bytearray(blob)
    va = symbol(blob, sym)
    off = file_offset(blob, va)
    if bytes(b[off:off + 2]) != b"\x90\x90":
        raise SystemExit("make-image: %s at 0x%X starts with %s, expected 90 90"
                         % (sym, va, bytes(b[off:off + 2]).hex()))
    b[off:off + 2] = b"\xEB\xFE"          # jmp .
    return bytes(b), va


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
        raise SystemExit("usage: make-image.py <out.img> <progH.elf> <progP.elf> [--json]")
    out, h_path, p_path = args

    h = open(h_path, "rb").read()
    p = open(p_path, "rb").read()
    hearly, early_va = mutate_hold(h, "heapHoldEarly")
    hlate, late_va = mutate_hold(h, "heapHoldLate")
    if hearly == h or hlate == h or hearly == hlate:
        raise SystemExit("make-image: the two mutations did not both change the file")

    progs = {"H": h, "P": p, "Hearly": hearly, "Hlate": hlate}

    img = bytearray()
    for s in range(SECTORS):
        img += sector_bytes(s)
    img[510:512] = b"\x55\xAA"            # m6-disk's MBR signature, still unread

    layout = {"sectors": SECTORS, "slots": {}, "holds": {
        "heapHoldEarly": early_va, "heapHoldLate": late_va}}

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

    # Every slot must be distinguishable from every other one on the disk: two
    # slots whose bytes are equal would make "the kernel loaded the one I asked
    # for" unfalsifiable.
    for a in SLOTS:
        for b in SLOTS:
            if a < b and progs[a] == progs[b]:
                raise SystemExit("make-image: slots %s and %s hold identical bytes" % (a, b))

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
