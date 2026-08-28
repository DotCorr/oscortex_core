#!/usr/bin/env python3
"""core/tests/conformance/d2-compositor/probe.py

Reads ONE pixel out of a framebuffer dump and compares it against a colour.

    probe.py <fb.bin> <pitch> <x> <y> <expected-hex> [name]

The dump is guest physical memory as `pmemsave` wrote it: 32 bits per pixel,
`pitch` bytes per scanline, little-endian, and the top byte is the unused
alpha/reserved lane of the 0x00RRGGBB format `fb.dart` writes. It is MASKED OFF
rather than asserted: `fbPutPixel` stores whatever the caller passed and every
caller passes a 24-bit colour, so the top byte is not a value anybody chose and
requiring it to be zero would be asserting an accident.

Exit status: 0 on a match, 1 on a mismatch (with both colours printed), 2 on a
setup error. **A mismatch is exit 1 and NOT an exception**, because run.sh uses
this in two ways: for a probe that must pass, and for the control that must
fail.
"""

import sys


def main():
    if len(sys.argv) not in (6, 7):
        print("usage: probe.py <fb.bin> <pitch> <x> <y> <expected-hex> [name]",
              file=sys.stderr)
        return 2
    path, pitch, x, y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    want = int(sys.argv[5], 16) & 0x00FFFFFF
    name = sys.argv[6] if len(sys.argv) == 7 else "probe"
    try:
        blob = open(path, "rb").read()
    except OSError as e:
        print("probe: cannot read %s: %s" % (path, e), file=sys.stderr)
        return 2
    off = y * pitch + x * 4
    if off + 4 > len(blob):
        print("probe: (%d,%d) is at byte %d and the dump is %d bytes"
              % (x, y, off, len(blob)), file=sys.stderr)
        return 2
    got = int.from_bytes(blob[off:off + 4], "little") & 0x00FFFFFF
    if got == want:
        print("    %-22s (%3d,%3d) = %06X" % (name, x, y, got))
        return 0
    print("    %-22s (%3d,%3d) = %06X, expected %06X"
          % (name, x, y, got, want), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
