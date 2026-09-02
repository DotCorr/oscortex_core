#!/usr/bin/env python3
"""core/tests/conformance/m6-disk/make-image.py

Builds the deterministic raw disk image the M6 harness attaches to QEMU, and
then VERIFIES WHAT IT WROTE by reading the file back.

Why the image is generated rather than committed: the bytes this kernel prints
have to be compared against something, and the only comparison worth anything
is against the bytes that are actually on the disk. A committed binary would
make the expected output a golden somebody produced once; a generator makes it
a function, and run.sh derives the expected hexdump by calling the same
function rather than by quoting a capture.

THE LAYOUT, AND WHY EACH PIECE IS THERE
---------------------------------------------------------------------------
Every sector is filled with an arithmetic pattern that depends on BOTH the
sector number and the byte offset:

    byte[i] of sector s = (31 * s + 7 * i + 0x21) & 0xFF

  * it depends on `s`, so a driver that reads the wrong sector produces a
    wrong dump rather than a plausible one -- an off-by-one in the LBA cannot
    pass;
  * it depends on `i` with an odd stride, so a driver that swaps the two bytes
    of a 16-bit word, or reads the data port with the wrong width, produces a
    visibly wrong sequence rather than the same bytes in a different order;
  * it is not constant and not zero, so "the buffer was never filled" and "the
    read returned zeros" are both distinguishable from success.

On top of that pattern:

  * offset 0x000 of EVERY sector: the ASCII label `OSCORTEX SECTOR nnnn` with
    the LBA in the same four-hex-digit form the kernel prints. This is the
    piece a human reads in the screenshot, and it is why a sector mix-up is
    obvious rather than subtle.
  * offset 0x100 of SECTOR 0 ONLY: the ASCII signature. A distinctive run at a
    known offset that appears in exactly one sector.
  * offset 0x1FE of SECTOR 0 ONLY: 0x55 0xAA, the MBR boot signature -- the
    one two-byte pattern that is instantly recognisable in a hexdump, placed
    at the very end of the sector so that a dump which stops early loses it.

Usage:
    make-image.py <out.img>            build and verify
    make-image.py <out.img> --flip N   build, then flip one bit in sector N
                                       (the negative control's image)

Exit status: 0 on success, 3 on a self-check failure.
"""

import sys

SECTOR = 512
SECTORS = 128
SIGNATURE = b"OSCORTEX-ATA-PIO-SIGNATURE"
SIG_OFFSET = 0x100
BOOTSIG_OFFSET = 0x1FE


def sector_bytes(s):
    """The content of sector `s`, as a bytes object of length 512."""
    b = bytearray((31 * s + 7 * i + 0x21) & 0xFF for i in range(SECTOR))
    label = ("OSCORTEX SECTOR %04X" % s).encode("ascii")
    b[0:len(label)] = label
    if s == 0:
        b[SIG_OFFSET:SIG_OFFSET + len(SIGNATURE)] = SIGNATURE
        b[BOOTSIG_OFFSET] = 0x55
        b[BOOTSIG_OFFSET + 1] = 0xAA
    return bytes(b)


def image_bytes():
    return b"".join(sector_bytes(s) for s in range(SECTORS))


def hexdump(data):
    """Formats one sector EXACTLY as core/kernel/ata.dart's ataDumpLine does:
    a four-hex-digit offset, then sixteen space-prefixed bytes, then a newline.

    This is the function that makes the harness's expectation derived rather
    than typed. It is deliberately written from the kernel's output format, and
    if the two ever disagree the assertion fails -- which is the point.
    """
    out = []
    for off in range(0, len(data), 16):
        row = data[off:off + 16]
        out.append("%04X" % off + "".join(" %02X" % b for b in row))
    return "\n".join(out) + "\n"


def verify(path):
    """Reads the file back off the filesystem and checks it, rather than
    trusting the bytes that were just written. A generator that is wrong in the
    same way as its own expectation proves nothing."""
    blob = open(path, "rb").read()
    fails = []
    if len(blob) != SECTOR * SECTORS:
        fails.append("image is %d bytes, expected %d" % (len(blob), SECTOR * SECTORS))
    if len(blob) % SECTOR != 0:
        fails.append("image size is not a whole number of 512-byte sectors")
    for s in (0, 1, 5, 0x2A, SECTORS - 1):
        got = blob[s * SECTOR:(s + 1) * SECTOR]
        if got != sector_bytes(s):
            fails.append("sector %d read back differently than it was written" % s)
    if blob[SIG_OFFSET:SIG_OFFSET + len(SIGNATURE)] != SIGNATURE:
        fails.append("the signature is not at offset 0x%X of sector 0" % SIG_OFFSET)
    if blob[BOOTSIG_OFFSET:BOOTSIG_OFFSET + 2] != b"\x55\xAA":
        fails.append("0x55 0xAA is not at offset 0x%X of sector 0" % BOOTSIG_OFFSET)
    if blob.count(SIGNATURE) != 1:
        fails.append("the signature appears %d times, expected exactly once"
                     % blob.count(SIGNATURE))
    # The sector-dependent term must actually make sectors differ.
    if blob[0:SECTOR] == blob[SECTOR:2 * SECTOR]:
        fails.append("sectors 0 and 1 are identical -- the pattern does not "
                     "depend on the sector number, so an LBA off-by-one could "
                     "not be detected")
    if len(set(blob[16:SECTOR])) < 32:
        fails.append("sector 0 past its label has fewer than 32 distinct byte "
                     "values -- the pattern is too flat to catch a byte order "
                     "or width error")
    if fails:
        for f in fails:
            print("make-image: FAIL -- " + f, file=sys.stderr)
        return False
    print("make-image: %s (%d sectors, %d bytes) verified after write: "
          "per-sector labels, signature at 0x%X, 55 AA at 0x%X, sectors differ"
          % (path, SECTORS, len(blob), SIG_OFFSET, BOOTSIG_OFFSET))
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 3
    path = sys.argv[1]
    blob = bytearray(image_bytes())
    flip = None
    if "--flip" in sys.argv:
        flip = int(sys.argv[sys.argv.index("--flip") + 1], 0)
    with open(path, "wb") as fh:
        fh.write(bytes(blob))
    if not verify(path):
        return 3
    if flip is not None:
        # The negative control's image: ONE bit, in ONE byte, of ONE sector.
        # Written after verification so that what is verified is the real
        # image, and what differs from it differs by exactly this much.
        blob[flip * SECTOR + 3] ^= 0x01
        with open(path, "wb") as fh:
            fh.write(bytes(blob))
        print("make-image: flipped bit 0 of byte 3 of sector %d -- this image "
              "is the negative control and must NOT match the expectation"
              % flip)
    return 0


if __name__ == "__main__":
    sys.exit(main())
