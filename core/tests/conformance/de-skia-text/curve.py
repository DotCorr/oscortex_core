#!/usr/bin/env python3
"""Assert a rounded chrome corner is a Skia coverage ramp, not a stair.

Walks the diagonal of the top-left corner box of a rect and counts pixels
whose colour is strictly between the surface behind the shape and the
shape's own fill. A hand-cut corner (the old `rrect_cover` span walker at
binary coverage, or a Graphite ICD radius) steps straight from background
to fill with nothing in between.

Usage: curve.py FB PITCH X Y W H [--min-ramp N]
"""
import sys


def main():
    fb, pitch = sys.argv[1], int(sys.argv[2])
    x, y, w, h = (int(v) for v in sys.argv[3:7])
    min_ramp = 6
    if "--min-ramp" in sys.argv:
        min_ramp = int(sys.argv[sys.argv.index("--min-ramp") + 1])
    data = open(fb, "rb").read()

    def px(cx, cy):
        off = cy * pitch + cx * 4
        if off + 4 > len(data):
            return 0
        return int.from_bytes(data[off:off + 4], "little") & 0xFFFFFF

    outside = px(x, y)
    inside = px(x + w // 2, y + h // 2)
    if outside == inside:
        print("curve: nothing to test — corner and centre are both %06X"
              % outside)
        return 1

    # A band of pixels around the corner arc, not one diagonal line: the
    # arc's own AA fringe is only 1-2px wide wherever you cross it.
    ramp = set()
    span = min(w, h) // 2
    for dy in range(span):
        for dx in range(span):
            c = px(x + dx, y + dy)
            if c != outside and c != inside:
                ramp.add(c)
    if len(ramp) < min_ramp:
        print("curve: only %d intermediate shades around the corner "
              "(%06X -> %06X) — binary coverage, not an AA curve"
              % (len(ramp), outside, inside))
        return 1
    print("curve: pass  %d intermediate shades across the corner arc "
          "(%06X -> %06X)" % (len(ramp), outside, inside))
    return 0


if __name__ == "__main__":
    sys.exit(main())
