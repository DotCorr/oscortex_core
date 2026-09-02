#!/usr/bin/env python3
"""Restate compositor policy and probe a P6 compose PPM. Not a golden."""
import sys

W, H = 800, 600
WIN_X, WIN_Y = 48, 40
WIN2_X, WIN2_Y = 140, 90
WIN_W, WIN_H = 240, 160
# ADR-0198: mockup card radius. Was 8; lockstep with OSGFX_RADIUS.
RADIUS = 18
TITLE_H = 18
CHROME_H = 24
BORDER = 2
POP_W, POP_H = 96, 64
POP_X, POP_Y = 520, 80
DESK = 0x00184060
TITLE = 0x00E8E0D0
CHROME = 0x00344050
POP = 0x00C04088
FOCUS = 0x00F5F0E8
UNFOCUS = 0x00485058
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
        raise SystemExit("usage: derive.py <ppm> compose|square")
    data = load_ppm(sys.argv[1])
    kind = sys.argv[2]
    desk = rgb_at(data, 10, 10)
    title = rgb_at(data, WIN_X + 40, WIN_Y + 8)
    chrome = rgb_at(data, W // 2, H - (CHROME_H // 2))
    pop = rgb_at(data, POP_X + (POP_W // 2), POP_Y + (POP_H // 2))
    focus = rgb_at(data, WIN2_X + (WIN_W // 2), WIN2_Y - 2)
    unfocus = rgb_at(data, WIN_X - 2, WIN_Y + 80)
    corner = rgb_at(data, WIN_X, WIN_Y)
    pop_corner = rgb_at(data, POP_X, POP_Y)
    print("DESK10 0x%06X" % desk)
    print("TITLEP 0x%06X" % title)
    print("CHROME 0x%06X" % chrome)
    print("POPCTR 0x%06X" % pop)
    print("FOCUSB 0x%06X" % focus)
    print("UNFOCB 0x%06X" % unfocus)
    print("CORNER 0x%06X" % corner)
    print("POPCRN 0x%06X" % pop_corner)
    if desk == 0:
        raise SystemExit("desktop is 0 — no paint")
    if title == 0 or chrome == 0 or pop == 0:
        raise SystemExit("a policy interior is 0 — no paint")
    if kind == "compose":
        if not near(desk, DESK, 8):
            raise SystemExit("desktop (10,10) not DESK")
        if not near(title, TITLE, 12):
            raise SystemExit("title interior not TITLE")
        if not near(chrome, CHROME, 8):
            raise SystemExit("taskbar not CHROME")
        if not near(pop, POP, 12):
            raise SystemExit("popover interior not POP")
        if not near(focus, FOCUS, 16):
            raise SystemExit("focused border not FOCUS")
        if not near(unfocus, UNFOCUS, 16):
            raise SystemExit("unfocused border not UNFOCUS")
        if near(corner, TITLE, 12):
            raise SystemExit("rrect corner is title — fill_rect not rrect")
        if near(corner, WIN_FILL, 12):
            raise SystemExit("rrect corner is window fill")
        if near(corner, UNFOCUS, 12):
            raise SystemExit("rrect corner is unfocus — box border")
        if not near(desk, DESK, 8):
            raise SystemExit("desktop drifted")
        if near(pop_corner, POP, 12):
            raise SystemExit("popover AABB is POP — fill_rect not rrect")
        if title == desk or chrome == desk or pop == desk:
            raise SystemExit("a chrome colour equals desktop")
        if focus == unfocus:
            raise SystemExit("focus equals unfocus")
        print("COMPOSE_OK")
        return
    if kind == "square":
        if not near(corner, TITLE, 12):
            raise SystemExit("square corner is not title")
        if not near(pop_corner, POP, 12):
            raise SystemExit("square popover AABB is not POP")
        print("SQUARE_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
