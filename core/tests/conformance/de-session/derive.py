#!/usr/bin/env python3
"""Derived pixels for de-session — generative desktop + Graphite chrome."""
import struct
import sys


def read_px(fb, pitch, x, y):
    off = y * pitch + x * 4
    b, g, r = fb[off], fb[off + 1], fb[off + 2]
    return (r << 16) | (g << 8) | b


def desktop_variety(fb_path, pitch, width, height, chrome_h=40):
    data = open(fb_path, "rb").read()
    desk_h = height - chrome_h
    samples = []
    for y in range(8, desk_h - 8, max(1, desk_h // 16)):
        for x in range(8, width - 8, max(1, width // 16)):
            samples.append(read_px(data, pitch, x, y))
    uniq = set(samples)
    flat = {0x00184060, 0x001C6A38}
    if len(uniq) < 3:
        print("DESK: only %d unique sample colours" % len(uniq))
        return 1
    if uniq <= flat:
        print("DESK: still flat solid (%s)" % ", ".join("%08X" % c for c in sorted(uniq)))
        return 1
    print("DESK: pass  %d unique colours (not flat)" % len(uniq))
    return 0


def probe(fb_path, pitch, x, y, expect, label):
    data = open(fb_path, "rb").read()
    got = read_px(data, pitch, x, y)
    if got != expect:
        print("%s: got %08X expected %08X" % (label, got, expect))
        return 1
    print("%s: pass  %08X" % (label, got))
    return 0


def close_rrect(fb_path, pitch, cx, cy, size, radius, expect):
    """Close button mid is expect; AABB corner is not (proves rrect, not square blob)."""
    data = open(fb_path, "rb").read()
    mid = read_px(data, pitch, cx + size // 2, cy + size // 2)
    if mid != expect:
        print("close_mid: got %08X expected %08X" % (mid, expect))
        return 1
    corner = read_px(data, pitch, cx, cy)
    if corner == expect:
        print("close_corner: still solid blob %08X (no rrect cut)" % corner)
        return 1
    print("close_rrect: pass  mid %08X corner %08X (not a flat blob)" % (mid, corner))
    return 0


def close_aa_fringe(fb_path, pitch, cx, cy, size, radius, expect):
    """Soft AA: a pixel on the radius must blend — not mid fill, not title."""
    data = open(fb_path, "rb").read()
    mid = read_px(data, pitch, cx + size // 2, cy + size // 2)
    # West edge on the circle (cx, cy+r) — coverage fringe for a soft disc.
    fx = cx
    fy = cy + radius
    fringe = read_px(data, pitch, fx, fy)
    if fringe == mid:
        print("close_aa: fringe %08X equals mid — still binary disc" % fringe)
        return 1
    if fringe == expect:
        print("close_aa: fringe still opaque expect %08X" % fringe)
        return 1
    # Outside title pearl must not be the only "soft" evidence.
    title = 0x00E8E0D0
    if fringe == title:
        print("close_aa: fringe %08X is title — sample missed the disc edge" % fringe)
        return 1
    print("close_aa: pass  fringe %08X mid %08X (soft edge)" % (fringe, mid))
    return 0


def title_gradient(fb_path, pitch, x, y, h, top, bot):
    """The title band is a Skia LinearGradient, so no single row equals a
    constant. Assert the ends and that the middle really does travel.

    Replaces an exact `== OSGFX_TITLE` probe, which could only pass while
    the band was one flat fill plus a stamped sheen rectangle."""
    data = open(fb_path, "rb").read()
    got_top = read_px(data, pitch, x, y + 1)
    got_bot = read_px(data, pitch, x, y + h - 2)
    steps = set()
    for yy in range(y + 1, y + h - 1):
        steps.add(read_px(data, pitch, x, yy))

    def near(a, b, tol=10):
        return all(abs(((a >> s) & 255) - ((b >> s) & 255)) <= tol
                   for s in (16, 8, 0))

    if not near(got_top, top):
        print("title_gradient: top row %06X is not %06X" % (got_top, top))
        return 1
    if not near(got_bot, bot):
        print("title_gradient: bottom row %06X is not %06X" % (got_bot, bot))
        return 1
    if len(steps) < 4:
        print("title_gradient: only %d shades down the band — flat fill, "
              "not a gradient" % len(steps))
        return 1
    print("title_gradient: %06X -> %06X over %d rows, %d shades"
          % (got_top, got_bot, h, len(steps)))
    return 0


def main():
    if len(sys.argv) < 2:
        print("usage: derive.py variety|probe|close_rrect|close_aa"
              "|title_gradient ...", file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    if cmd == "variety":
        fb, pitch, w, h = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
        chrome_h = 40
        if len(sys.argv) > 6:
            chrome_h = int(sys.argv[6])
        return desktop_variety(fb, pitch, w, h, chrome_h)
    if cmd == "probe":
        fb, pitch, x, y, expect, label = (
            sys.argv[2],
            int(sys.argv[3]),
            int(sys.argv[4]),
            int(sys.argv[5]),
            int(sys.argv[6], 16),
            sys.argv[7],
        )
        return probe(fb, pitch, x, y, expect, label)
    if cmd == "close_rrect":
        fb, pitch, cx, cy, size, radius, expect = (
            sys.argv[2],
            int(sys.argv[3]),
            int(sys.argv[4]),
            int(sys.argv[5]),
            int(sys.argv[6]),
            int(sys.argv[7]),
            int(sys.argv[8], 16),
        )
        return close_rrect(fb, pitch, cx, cy, size, radius, expect)
    if cmd == "close_aa":
        fb, pitch, cx, cy, size, radius, expect = (
            sys.argv[2],
            int(sys.argv[3]),
            int(sys.argv[4]),
            int(sys.argv[5]),
            int(sys.argv[6]),
            int(sys.argv[7]),
            int(sys.argv[8], 16),
        )
        return close_aa_fringe(fb, pitch, cx, cy, size, radius, expect)
    if cmd == "title_gradient":
        fb, pitch, x, y, h, top, bot = (
            sys.argv[2],
            int(sys.argv[3]),
            int(sys.argv[4]),
            int(sys.argv[5]),
            int(sys.argv[6]),
            int(sys.argv[7], 16),
            int(sys.argv[8], 16),
        )
        return title_gradient(fb, pitch, x, y, h, top, bot)
    print("unknown cmd %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
