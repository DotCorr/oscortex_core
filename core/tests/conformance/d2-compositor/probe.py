#!/usr/bin/env python3
"""core/tests/conformance/d2-compositor/probe.py

Reads one 32-bit BGRx pixel from a guest framebuffer dump and compares it to
an expected 0xRRGGBB value. Exit 0 on match, 1 on mismatch, 2 on usage error.
"""

import sys


def read_px(fb, pitch, x, y):
    off = y * pitch + x * 4
    b, g, r = fb[off], fb[off + 1], fb[off + 2]
    return (r << 16) | (g << 8) | b


def main():
    if len(sys.argv) != 7:
        print(
            "usage: probe.py <fb.bin> <pitch> <x> <y> <colour> <name>",
            file=sys.stderr,
        )
        raise SystemExit(2)
    fb_path, pitch_s, x_s, y_s, colour_s, name = sys.argv[1:]
    pitch = int(pitch_s)
    x = int(x_s)
    y = int(y_s)
    expect = int(colour_s, 16) & 0xFFFFFF
    fb = open(fb_path, "rb").read()
    got = read_px(fb, pitch, x, y)
    if got != expect:
        print(
            "%s: MISMATCH at (%d,%d) got %06X expected %06X"
            % (name, x, y, got, expect)
        )
        raise SystemExit(1)
    print("%s: pass  %06X at (%d,%d)" % (name, got, x, y))
    raise SystemExit(0)


if __name__ == "__main__":
    main()
