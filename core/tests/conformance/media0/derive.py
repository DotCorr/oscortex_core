#!/usr/bin/env python3
"""Restate osmedia.h constants and probe a P6 PPM. Not a golden."""
import sys

W, H = 64, 64
PX, PY = 16, 16
FRAME = 0x00C04088
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
        raise SystemExit("usage: derive.py <ppm> frame|none")
    data = load_ppm(sys.argv[1])
    kind = sys.argv[2]
    pix = rgb_at(data, PX, PY)
    print("PIXEL 0x%06X" % pix)
    if pix == 0 and kind == "frame":
        raise SystemExit("frame pixel is 0")
    if pix == DESK and kind == "frame":
        raise SystemExit("frame pixel is desktop")
    if kind == "frame":
        if not near(pix, FRAME, 20):
            raise SystemExit("frame pixel 0x%06X is not FRAME 0x%06X" % (pix, FRAME))
        print("FRAME_OK")
        return
    if kind == "none":
        if near(pix, FRAME, 20):
            raise SystemExit("negative pixel is FRAME — FFmpeg was not required")
        print("NONE_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
