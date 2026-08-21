#!/usr/bin/env python3
"""core/tests/conformance/m10-elf/make-image.py

Builds the raw disk image the M10 harness attaches to QEMU: a background
pattern, and SEVEN programs on it -- one that must run, four that must be refused
before they start, one that must be loaded and then die in ring 3, and one that
must be loaded and never stop, each for a different named reason.

THIS IS NOT A FILESYSTEM, AND THE SHAPE OF THIS FILE IS THE ADMISSION
---------------------------------------------------------------------------
There is no directory here. A program is "at" an LBA because this generator
wrote it there and because run.sh tells the kernel that number. The 32-byte
header sector is the entire metadata format:

    +0   8 bytes   b"OSCXPRG1"
    +8   u64       the image's length in bytes
    +16  u64       the LBA its first sector is at

That is enough for `run <lba>` to take one number instead of three, and it is
not a filesystem in any sense: no names, no allocation, no free list, no
directories, no writing, no way to find a program whose sector you do not
already know. docs/known-gaps.md GAP-0090 lists what a real one has to add.

THE SIX ALTERED PROGRAMS ARE DERIVED FROM THE GOOD ONE
---------------------------------------------------------------------------
Each is prog.elf with ONE field changed, so the difference between "runs" and
"refused with this sentence" is exactly that field and nothing else. A
separately-built broken binary would differ in a hundred ways and prove much
less:

  bad-magic   e_ident[EI_MAG0] 0x7F -> 0x7E.  The kernel must say so and run
              nothing.
  wx          the R+X segment's p_flags 5 -> 7 (PF_R|PF_W|PF_X). The kernel
              enforces W^X on itself and must not make an exception for a
              guest.
  interp      the RW segment's p_type PT_LOAD -> PT_INTERP. A file that needs a
              dynamic linker, and this kernel does not link.
  badentry    e_entry moved onto the RW segment's page. Well-formed in every
              other respect; the kernel must notice that the entry point is on
              a page it just mapped NON-EXECUTABLE and refuse before entering
              ring 3 rather than taking an instruction-fetch fault there.
  spin        the two bytes AT e_entry replaced with `eb fe` (`jmp .`). It
              loads, it enters ring 3, and it never leaves -- so the machine can
              be stopped with a loaded program ON THE CPU and its page tables
              read out of guest memory while the U/W/X bits are actually set.
              RIP then equals e_entry exactly, which is the most direct possible
              statement that the kernel jumped where the file said.
  gp          the three bytes AT e_entry replaced with `0f 20 d8`
              (`mov %cr3,%rax`). A perfectly well-formed ELF containing a
              privileged instruction: it loads, it runs, and it dies in ring 3 --
              which is what tests the FAULT path's teardown. Every other program
              here either runs to completion or is refused before it starts.

The background pattern is m6-disk's, for m6-disk's reason: it depends on both
the sector number and the byte offset, so a loader that reads the wrong LBA
gets bytes that are wrong rather than bytes that are plausible.

Usage:
    make-image.py <out.img> <prog.elf>              build and verify
    make-image.py <out.img> <prog.elf> --json       also print the layout as JSON
    make-image.py <out.img> <prog.elf> --emit <dir> also write each mutated ELF
                                                    to <dir>/prog-<name>.elf, so
                                                    run.sh can derive its
                                                    expectations from the exact
                                                    file it told the kernel to
                                                    load rather than from the
                                                    unmutated one

Exit status: 0 on success, 3 on a self-check failure.
"""

import json
import os
import sys

SECTOR = 512
SECTORS = 512

MAGIC = b"OSCXPRG1"

# Header sector, then the image one sector later. 64 sectors apart, which is
# more than three times the size of the program -- so an off-by-a-lot in the
# loader's sector arithmetic lands in the background pattern rather than in
# another copy of the program.
SLOTS = {
    "good": 0x20,
    "badmagic": 0x60,
    "wx": 0xA0,
    "interp": 0xE0,
    "gp": 0x120,
    "badentry": 0x160,
    "spin": 0x1A0,
}


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


# ---------------------------------------------------------------------------
# The six mutations. Each takes prog.elf and changes ONE field.
# ---------------------------------------------------------------------------

def phdr_offsets(blob):
    phoff = int.from_bytes(blob[32:40], "little")
    phentsize = int.from_bytes(blob[54:56], "little")
    phnum = int.from_bytes(blob[56:58], "little")
    return [phoff + i * phentsize for i in range(phnum)]


def mutate_badmagic(blob):
    b = bytearray(blob)
    b[0] = 0x7E                      # 0x7F -> 0x7E
    return bytes(b)


def mutate_wx(blob):
    """Give the executable segment PF_W as well."""
    b = bytearray(blob)
    for off in phdr_offsets(blob):
        p_type = int.from_bytes(b[off:off + 4], "little")
        p_flags = int.from_bytes(b[off + 4:off + 8], "little")
        if p_type == 1 and p_flags & 1:          # PT_LOAD with PF_X
            b[off + 4:off + 8] = (p_flags | 2).to_bytes(4, "little")
            return bytes(b)
    raise SystemExit("make-image: prog.elf has no executable PT_LOAD to mutate")


def mutate_interp(blob):
    """Turn the writable segment into a PT_INTERP, i.e. a file that needs ld.so."""
    b = bytearray(blob)
    for off in phdr_offsets(blob):
        p_type = int.from_bytes(b[off:off + 4], "little")
        p_flags = int.from_bytes(b[off + 4:off + 8], "little")
        if p_type == 1 and p_flags & 2:          # PT_LOAD with PF_W
            b[off:off + 4] = (3).to_bytes(4, "little")   # PT_INTERP
            return bytes(b)
    raise SystemExit("make-image: prog.elf has no writable PT_LOAD to mutate")


def _file_offset(blob, vaddr):
    """The file offset of `vaddr`, via the PT_LOAD that contains it."""
    for off in phdr_offsets(blob):
        p_type = int.from_bytes(blob[off:off + 4], "little")
        p_off = int.from_bytes(blob[off + 8:off + 16], "little")
        p_va = int.from_bytes(blob[off + 16:off + 24], "little")
        p_fsz = int.from_bytes(blob[off + 32:off + 40], "little")
        if p_type == 1 and p_va <= vaddr < p_va + p_fsz:
            return p_off + (vaddr - p_va)
    raise SystemExit("make-image: 0x%X is not inside any PT_LOAD's file image"
                     % vaddr)


def mutate_badentry(blob):
    """Point e_entry at the writable, non-executable segment."""
    b = bytearray(blob)
    for off in phdr_offsets(blob):
        p_type = int.from_bytes(b[off:off + 4], "little")
        p_flags = int.from_bytes(b[off + 4:off + 8], "little")
        if p_type == 1 and p_flags & 2:
            p_va = int.from_bytes(b[off + 16:off + 24], "little")
            b[24:32] = p_va.to_bytes(8, "little")
            return bytes(b)
    raise SystemExit("make-image: prog.elf has no writable PT_LOAD")


def mutate_spin(blob):
    """`jmp .` as the program's first instruction: it never exits."""
    b = bytearray(blob)
    entry = int.from_bytes(blob[24:32], "little")
    at = _file_offset(blob, entry)
    b[at:at + 2] = bytes((0xEB, 0xFE))
    return bytes(b)


def mutate_gp(blob):
    """`mov %cr3,%rax` as the program's first instruction: #GP at CPL 3."""
    b = bytearray(blob)
    entry = int.from_bytes(blob[24:32], "little")
    at = _file_offset(blob, entry)
    b[at:at + 3] = bytes((0x0F, 0x20, 0xD8))
    return bytes(b)


MUTATE = {
    "good": lambda blob: blob,
    "badentry": mutate_badentry,
    "gp": mutate_gp,
    "spin": mutate_spin,
    "badmagic": mutate_badmagic,
    "wx": mutate_wx,
    "interp": mutate_interp,
}


def build(prog_path):
    """Returns (image bytes, layout dict)."""
    prog = open(prog_path, "rb").read()
    img = bytearray(b"".join(sector_bytes(s) for s in range(SECTORS)))
    layout = {}
    for name, hdr_lba in sorted(SLOTS.items()):
        blob = MUTATE[name](prog)
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


def verify(path, prog_path, layout):
    """Reads the file back off the filesystem and checks it, rather than
    trusting the bytes that were just written."""
    blob = open(path, "rb").read()
    prog = open(prog_path, "rb").read()
    fails = []
    if len(blob) != SECTOR * SECTORS:
        fails.append("image is %d bytes, expected %d" % (len(blob), SECTOR * SECTORS))
    for name, info in layout.items():
        h = blob[info["header_lba"] * SECTOR:(info["header_lba"] + 1) * SECTOR]
        if h[0:8] != MAGIC:
            fails.append("%s: no OSCXPRG1 at LBA 0x%X" % (name, info["header_lba"]))
        if int.from_bytes(h[8:16], "little") != info["bytes"]:
            fails.append("%s: the header's byte count is wrong" % name)
        if int.from_bytes(h[16:24], "little") != info["image_lba"]:
            fails.append("%s: the header's LBA is wrong" % name)
        got = blob[info["image_lba"] * SECTOR:
                   info["image_lba"] * SECTOR + info["bytes"]]
        want = MUTATE[name](prog)
        if got != want:
            fails.append("%s: the image read back differently than it was written"
                         % name)
        # Each broken one must differ from the good one in EXACTLY the bytes its
        # mutation touches -- otherwise the negative control is testing something
        # else as well.
        if name != "good":
            diff = sum(1 for a, b in zip(want, prog) if a != b)
            if name == "badmagic" and diff != 1:
                fails.append("badmagic differs from prog.elf in %d bytes, expected 1"
                             % diff)
            if name in ("wx", "interp") and not 1 <= diff <= 4:
                fails.append("%s differs from prog.elf in %d bytes, expected at "
                             "most 4 (one 32-bit field)" % (name, diff))
            if name == "badentry" and not 1 <= diff <= 8:
                fails.append("badentry differs from prog.elf in %d bytes, "
                             "expected at most 8 (e_entry)" % diff)
            if name == "spin" and not 1 <= diff <= 2:
                fails.append("spin differs from prog.elf in %d bytes, expected "
                             "at most 2 (one instruction)" % diff)
            if name == "gp" and not 1 <= diff <= 3:
                fails.append("gp differs from prog.elf in %d bytes, expected at "
                             "most 3 (one instruction)" % diff)
    # The background must still be the background where nothing was written.
    if blob[0:SECTOR] != sector_bytes(0):
        fails.append("sector 0 is not the background pattern")
    if blob[0:SECTOR] == blob[SECTOR:2 * SECTOR]:
        fails.append("sectors 0 and 1 are identical -- the pattern does not "
                     "depend on the sector number, so an LBA off-by-one could "
                     "not be detected")
    if blob.count(MAGIC) != len(SLOTS):
        fails.append("OSCXPRG1 appears %d times, expected %d"
                     % (blob.count(MAGIC), len(SLOTS)))
    if fails:
        for f in fails:
            print("make-image: FAIL — " + f, file=sys.stderr)
        sys.exit(3)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    out, prog_path = sys.argv[1], sys.argv[2]
    img, layout = build(prog_path)
    open(out, "wb").write(img)
    verify(out, prog_path, layout)
    if "--emit" in sys.argv:
        d = sys.argv[sys.argv.index("--emit") + 1]
        os.makedirs(d, exist_ok=True)
        prog = open(prog_path, "rb").read()
        for name in SLOTS:
            open(os.path.join(d, "prog-%s.elf" % name), "wb").write(MUTATE[name](prog))
    if "--json" in sys.argv[3:]:
        print(json.dumps(layout, indent=2, sort_keys=True))
    else:
        print("make-image: PASS — %s (%d sectors, %d programs, verified by "
              "re-reading)" % (out, SECTORS, len(layout)))


if __name__ == "__main__":
    main()
