#!/usr/bin/env python3
"""Restate osmedia.h window constants and score a serial line or FB dump."""
import re
import sys

FRAME = 0x00C04088
DESK = 0x00184060
BG = 0x00101018
SLOP = 20
BLIT_X = 16
BLIT_Y = 400
PX = 16
PY = 16
WIN_X = 200
WIN_Y = 80
WIN_PX = 16
WIN_PY = 32


def near(c, expect, slop):
    dr = abs(((c >> 16) & 0xFF) - ((expect >> 16) & 0xFF))
    dg = abs(((c >> 8) & 0xFF) - ((expect >> 8) & 0xFF))
    db = abs((c & 0xFF) - (expect & 0xFF))
    return dr <= slop and dg <= slop and db <= slop


def load_header(path):
    text = open(path, "r", encoding="latin-1").read()
    got = {}
    for name in ("OSMEDIA_FRAME", "OSMEDIA_DESK", "OSMEDIA_BLIT_X",
                 "OSMEDIA_BLIT_Y", "OSMEDIA_PX", "OSMEDIA_PY",
                 "OSMEDIA_WIN_X", "OSMEDIA_WIN_Y", "OSMEDIA_WIN_PX",
                 "OSMEDIA_WIN_PY", "OSMEDIA_W", "OSMEDIA_H"):
        m = re.search(r"%s\s*=\s*(0x[0-9A-Fa-f]+|\d+)" % name, text)
        if m is None:
            raise SystemExit("header missing %s" % name)
        got[name] = int(m.group(1), 0)
    return got


def pixel_at(blob, pitch, x, y):
    off = y * pitch + x * 4
    if off + 4 > len(blob):
        raise SystemExit("(%d,%d) is past dump (%d bytes, pitch %d)"
                         % (x, y, len(blob), pitch))
    return int.from_bytes(blob[off:off + 4], "little") & 0x00FFFFFF


def main():
    if len(sys.argv) < 3:
        raise SystemExit(
            "usage: derive.py <osmedia.h> header\n"
            "       derive.py <osmedia.h> frame|none <serial>\n"
            "       derive.py <osmedia.h> blit|noblit|win|nowin <fb.bin> <pitch>")
    hdr = load_header(sys.argv[1])
    if hdr["OSMEDIA_FRAME"] != FRAME:
        raise SystemExit("FRAME moved")
    if hdr["OSMEDIA_DESK"] != DESK:
        raise SystemExit("DESK moved")
    if hdr["OSMEDIA_BLIT_X"] != BLIT_X:
        raise SystemExit("BLIT_X moved")
    if hdr["OSMEDIA_BLIT_Y"] != BLIT_Y:
        raise SystemExit("BLIT_Y moved")
    if hdr["OSMEDIA_PX"] != PX:
        raise SystemExit("PX moved")
    if hdr["OSMEDIA_PY"] != PY:
        raise SystemExit("PY moved")
    if hdr["OSMEDIA_WIN_X"] != WIN_X:
        raise SystemExit("WIN_X moved")
    if hdr["OSMEDIA_WIN_Y"] != WIN_Y:
        raise SystemExit("WIN_Y moved")
    if hdr["OSMEDIA_WIN_PX"] != WIN_PX:
        raise SystemExit("WIN_PX moved")
    if hdr["OSMEDIA_WIN_PY"] != WIN_PY:
        raise SystemExit("WIN_PY moved")
    if hdr["OSMEDIA_W"] != 64:
        raise SystemExit("W moved")
    if hdr["OSMEDIA_H"] != 64:
        raise SystemExit("H moved")
    print("FRAME 0x%08X" % FRAME)
    print("DESK 0x%08X" % DESK)
    print("BLIT %d %d" % (BLIT_X, BLIT_Y))
    print("WIN %d %d" % (WIN_X, WIN_Y))
    print("WPROBE %d %d" % (WIN_X + WIN_PX, WIN_Y + WIN_PY))
    print("BPROBE %d %d" % (BLIT_X + PX, BLIT_Y + PY))
    kind = sys.argv[2]
    if kind == "header":
        print("HEADER_OK")
        return
    if kind in ("frame", "none"):
        text = open(sys.argv[3], "rb").read().decode("latin-1", "replace")
        m = re.search(r"OSMEDIA PIX ([0-9A-Fa-f]{8})", text)
        if kind == "frame":
            if m is None:
                raise SystemExit("no OSMEDIA PIX line")
            pix = int(m.group(1), 16)
            print("PIXEL 0x%08X" % pix)
            if pix == 0:
                raise SystemExit("frame pixel is 0")
            if pix == DESK or pix == BG:
                raise SystemExit("frame pixel is desktop/bg")
            if not near(pix, FRAME, SLOP):
                raise SystemExit("frame pixel 0x%08X is not FRAME" % pix)
            if "OSMEDIA BACKEND ffmpeg" not in text:
                raise SystemExit("no BACKEND ffmpeg")
            if "OSMEDIA BLIT " not in text:
                raise SystemExit("no OSMEDIA BLIT — serial PIX is not a surface")
            if "OSMEDIA WIN " not in text:
                raise SystemExit("no OSMEDIA WIN — blit tile is not a window")
            if "WM ATTACH " not in text:
                raise SystemExit("no WM ATTACH — no wmsurface")
            print("FRAME_OK")
            return
        if "OSMEDIA MISS" not in text and m is None:
            raise SystemExit("negative produced no MISS and no PIX")
        if m is not None:
            pix = int(m.group(1), 16)
            print("PIXEL 0x%08X" % pix)
            if near(pix, FRAME, SLOP):
                raise SystemExit("negative pixel is FRAME")
        if "OSMEDIA WIN " in text:
            raise SystemExit("negative still committed a window")
        print("NONE_OK")
        return
    if kind in ("blit", "noblit", "win", "nowin"):
        blob = open(sys.argv[3], "rb").read()
        pitch = int(sys.argv[4], 0)
        bx = BLIT_X + PX
        by = BLIT_Y + PY
        wx = WIN_X + WIN_PX
        wy = WIN_Y + WIN_PY
        blit = pixel_at(blob, pitch, bx, by)
        win = pixel_at(blob, pitch, wx, wy)
        print("BLITFB 0x%06X at (%d,%d)" % (blit, bx, by))
        print("WINFB 0x%06X at (%d,%d)" % (win, wx, wy))
        if kind == "blit":
            if blit == 0:
                raise SystemExit("blit pixel is 0")
            if blit == DESK or blit == BG:
                raise SystemExit("blit pixel is desktop/bg — vblit broke")
            if not near(blit, FRAME, SLOP):
                raise SystemExit("blit pixel 0x%06X is not FRAME" % blit)
            print("BLIT_OK")
            return
        if kind == "noblit":
            if near(blit, FRAME, SLOP):
                raise SystemExit("skip-blit pixel 0x%06X is FRAME" % blit)
            print("NOBLIT_OK")
            return
        if kind == "win":
            if win == 0:
                raise SystemExit("window pixel is 0")
            if win == DESK or win == BG:
                raise SystemExit("window pixel is desktop/bg — no shm blit")
            if not near(win, FRAME, SLOP):
                raise SystemExit("window pixel 0x%06X is not FRAME" % win)
            # The raw tile is a different coordinate. A window probe
            # that sampled (32,416) would be vacuous.
            if wx == bx and wy == by:
                raise SystemExit("window probe equals the Bochs tile")
            outside = pixel_at(blob, pitch, WIN_X - 8, WIN_Y)
            print("OUT 0x%06X at (%d,%d)" % (outside, WIN_X - 8, WIN_Y))
            if near(outside, FRAME, SLOP):
                raise SystemExit("pixel outside the window is FRAME")
            print("WIN_OK")
            return
        if near(win, FRAME, SLOP):
            raise SystemExit("no-win pixel 0x%06X is FRAME" % win)
        print("NOWIN_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
