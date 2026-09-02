#!/usr/bin/env python3
"""Restate osmedia.h blit constants and score a serial line or FB dump."""
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


def near(c, expect, slop):
    dr = abs(((c >> 16) & 0xFF) - ((expect >> 16) & 0xFF))
    dg = abs(((c >> 8) & 0xFF) - ((expect >> 8) & 0xFF))
    db = abs((c & 0xFF) - (expect & 0xFF))
    return dr <= slop and dg <= slop and db <= slop


def load_header(path):
    text = open(path, "r", encoding="latin-1").read()
    got = {}
    for name in ("OSMEDIA_FRAME", "OSMEDIA_DESK", "OSMEDIA_BLIT_X",
                 "OSMEDIA_BLIT_Y", "OSMEDIA_PX", "OSMEDIA_PY"):
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
            "       derive.py <osmedia.h> blit|noblit <fb.bin> <pitch>")
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
    print("FRAME 0x%08X" % FRAME)
    print("DESK 0x%08X" % DESK)
    print("BLIT %d %d" % (BLIT_X, BLIT_Y))
    print("PROBE %d %d" % (BLIT_X + PX, BLIT_Y + PY))
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
            print("FRAME_OK")
            return
        if "OSMEDIA MISS" not in text and m is None:
            raise SystemExit("negative produced no MISS and no PIX")
        if m is not None:
            pix = int(m.group(1), 16)
            print("PIXEL 0x%08X" % pix)
            if near(pix, FRAME, SLOP):
                raise SystemExit("negative pixel is FRAME")
        if "OSMEDIA BLIT " in text:
            raise SystemExit("negative still blitted")
        print("NONE_OK")
        return
    if kind in ("blit", "noblit"):
        blob = open(sys.argv[3], "rb").read()
        pitch = int(sys.argv[4], 0)
        x = BLIT_X + PX
        y = BLIT_Y + PY
        got = pixel_at(blob, pitch, x, y)
        print("FB 0x%06X at (%d,%d)" % (got, x, y))
        if kind == "blit":
            if got == 0:
                raise SystemExit("blit pixel is 0")
            if got == DESK or got == BG:
                raise SystemExit("blit pixel is desktop/bg — skip blit")
            if not near(got, FRAME, SLOP):
                raise SystemExit("blit pixel 0x%06X is not FRAME" % got)
            outside = pixel_at(blob, pitch, 8, BLIT_Y)
            print("OUT 0x%06X at (8,%d)" % (outside, BLIT_Y))
            if near(outside, FRAME, SLOP):
                raise SystemExit("pixel outside the tile is FRAME")
            print("BLIT_OK")
            return
        if near(got, FRAME, SLOP):
            raise SystemExit("skip-blit pixel 0x%06X is FRAME" % got)
        print("NOBLIT_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
