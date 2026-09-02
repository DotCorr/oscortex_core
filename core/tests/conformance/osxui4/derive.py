#!/usr/bin/env python3
"""Restate osxui.h constants and probe a P6 PPM. Not a golden."""
import sys

W, H = 800, 600
BTN_X, BTN_Y = 352, 276
BTN_W, BTN_H = 96, 48
RADIUS = 10
PANEL_X, PANEL_Y = 352, 252
PANEL_W, PANEL_H = 96, 18
DESK = 0x00184060
PANEL = 0x00E8E0D0
IDLE = 0x0020A060
HIT = 0x00E04090


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
        raise SystemExit("usage: derive.py <ppm> idle|click|miss|square")
    data = load_ppm(sys.argv[1])
    kind = sys.argv[2]
    corner = rgb_at(data, BTN_X, BTN_Y)
    interior = rgb_at(data, BTN_X + BTN_W // 2, BTN_Y + BTN_H // 2)
    panel = rgb_at(data, PANEL_X + PANEL_W // 2, PANEL_Y + PANEL_H // 2)
    desk = rgb_at(data, 10, 10)
    print("CORNER 0x%06X" % corner)
    print("INTERIOR 0x%06X" % interior)
    print("PANEL 0x%06X" % panel)
    print("DESK10 0x%06X" % desk)
    if not near(desk, DESK, 4):
        raise SystemExit("desktop (10,10) not DESK")
    if not near(panel, PANEL, 4):
        raise SystemExit("panel strip not PANEL")
    if kind == "idle":
        if near(corner, IDLE, 4) or near(corner, HIT, 4):
            raise SystemExit("idle AABB is button — fill_rect not rrect")
        if not near(corner, DESK, 4):
            raise SystemExit("idle AABB is not desktop")
        if not near(interior, IDLE, 4):
            raise SystemExit("idle interior not IDLE")
        if interior == desk:
            raise SystemExit("idle interior equals desktop")
        print("IDLE_OK")
        return
    if kind == "click":
        if near(corner, HIT, 4) or near(corner, IDLE, 4):
            raise SystemExit("click AABB is button — fill_rect not rrect")
        if not near(corner, DESK, 4):
            raise SystemExit("click AABB is not desktop")
        if not near(interior, HIT, 4):
            raise SystemExit("click interior not HIT")
        if interior == desk:
            raise SystemExit("click interior equals desktop")
        print("CLICK_OK")
        return
    if kind == "miss":
        if not near(corner, DESK, 4):
            raise SystemExit("miss AABB is not desktop")
        if not near(interior, IDLE, 4):
            raise SystemExit("miss left the button at HIT — any-press is vacuous")
        print("MISS_OK")
        return
    if kind == "square":
        if not near(corner, IDLE, 4):
            raise SystemExit("square AABB is not IDLE")
        print("SQUARE_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
