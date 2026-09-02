#!/usr/bin/env python3
"""Restate oschrome.h constants and probe a P6 PPM. Not a golden."""
import sys

W, H = 128, 128
PX, PY = 32, 32
PAGE = 0x00C03890
DESK = 0x00184060


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
        raise SystemExit("usage: derive.py <ppm> page|none")
    data = load_ppm(sys.argv[1])
    kind = sys.argv[2]
    pix = rgb_at(data, PX, PY)
    print("PIXEL 0x%06X" % pix)
    if pix == 0 and kind == "page":
        raise SystemExit("page pixel is 0")
    if pix == DESK and kind == "page":
        raise SystemExit("page pixel is desktop")
    if kind == "page":
        if not near(pix, PAGE, 12):
            raise SystemExit("page pixel 0x%06X is not PAGE 0x%06X" % (pix, PAGE))
        print("PAGE_OK")
        return
    if kind == "none":
        if near(pix, PAGE, 12):
            raise SystemExit("no-init pixel is PAGE — Chromium was not required")
        print("NONE_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
