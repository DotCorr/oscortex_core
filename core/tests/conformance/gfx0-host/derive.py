#!/usr/bin/env python3
"""Restate osgfx.h constants and probe a P6 PPM. Not a golden."""
import sys

W, H = 800, 600
WIN_X, WIN_Y = 48, 40
# ADR-0198: mockup card radius. Was 8 (ADR-0196); lockstep with header.
RADIUS = 18
DESK = 0x00184060
TITLE = 0x00E8E0D0
WIN_FILL = 0x001A2430


def load_ppm(path):
    with open(path, "rb") as f:
        magic = f.readline()
        if magic != b"P6\n":
            raise SystemExit("not P6")
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        wh = line.split()
        w, h = int(wh[0]), int(wh[1])
        maxv = f.readline()
        if maxv.strip() != b"255":
            raise SystemExit("maxval")
        data = f.read()
    if w != W or h != H:
        raise SystemExit("size %d %d" % (w, h))
    if len(data) != W * H * 3:
        raise SystemExit("short")
    return data


def rgb_at(data, x, y):
    i = (y * W + x) * 3
    r, g, b = data[i], data[i + 1], data[i + 2]
    return (r << 16) | (g << 8) | b


def near(c, expect, slop):
    dr = abs(((c >> 16) & 0xFF) - ((expect >> 16) & 0xFF))
    dg = abs(((c >> 8) & 0xFF) - ((expect >> 8) & 0xFF))
    db = abs((c & 0xFF) - (expect & 0xFF))
    return dr <= slop and dg <= slop and db <= slop


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: derive.py <ppm> rrect|square")
    data = load_ppm(sys.argv[1])
    kind = sys.argv[2]
    corner = rgb_at(data, WIN_X, WIN_Y)
    title = rgb_at(data, WIN_X + 40, WIN_Y + 8)
    desk = rgb_at(data, 10, 10)
    print("CORNER 0x%06X" % corner)
    print("TITLEP 0x%06X" % title)
    print("DESK10 0x%06X" % desk)
    if kind == "rrect":
        if near(corner, TITLE, 12):
            raise SystemExit("rrect corner is title — fill_rect not rrect")
        if near(corner, WIN_FILL, 12):
            raise SystemExit("rrect corner is window fill")
        if not near(desk, DESK, 8):
            raise SystemExit("desktop (10,10) not DESK")
        if not near(title, TITLE, 12):
            raise SystemExit("title interior not TITLE")
        if title == desk:
            raise SystemExit("title equals desktop")
        print("RRECT_OK")
        return
    if kind == "square":
        if not near(corner, TITLE, 12):
            raise SystemExit("square corner is not title")
        print("SQUARE_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
