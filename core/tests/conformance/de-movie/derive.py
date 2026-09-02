#!/usr/bin/env python3
"""Restate osmedia.h movie constants and score serial / FB dumps."""
import re
import sys

FRAME = 0x00C04088
FRAME2 = 0x0020C040
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
    for name in ("OSMEDIA_FRAME", "OSMEDIA_FRAME2", "OSMEDIA_DESK",
                 "OSMEDIA_BLIT_X", "OSMEDIA_BLIT_Y", "OSMEDIA_PX",
                 "OSMEDIA_PY", "OSMEDIA_WIN_X", "OSMEDIA_WIN_Y",
                 "OSMEDIA_WIN_PX", "OSMEDIA_WIN_PY", "OSMEDIA_W",
                 "OSMEDIA_H"):
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
            "       derive.py <osmedia.h> movie|nomovie <serial>\n"
            "       derive.py <osmedia.h> win2|win1 <fb.bin> <pitch>")
    hdr = load_header(sys.argv[1])
    if hdr["OSMEDIA_FRAME"] != FRAME:
        raise SystemExit("FRAME moved")
    if hdr["OSMEDIA_FRAME2"] != FRAME2:
        raise SystemExit("FRAME2 moved")
    if hdr["OSMEDIA_WIN_X"] != WIN_X or hdr["OSMEDIA_WIN_Y"] != WIN_Y:
        raise SystemExit("WIN geom moved")
    print("FRAME 0x%08X" % FRAME)
    print("FRAME2 0x%08X" % FRAME2)
    print("WPROBE %d %d" % (WIN_X + WIN_PX, WIN_Y + WIN_PY))
    kind = sys.argv[2]
    if kind == "header":
        print("HEADER_OK")
        return
    if kind in ("movie", "nomovie"):
        text = open(sys.argv[3], "rb").read().decode("latin-1", "replace")
        m1 = re.search(r"OSMEDIA PIX ([0-9A-Fa-f]{8})", text)
        m2 = re.search(r"OSMEDIA MOV ([0-9A-Fa-f]{8})", text)
        if m1 is None:
            raise SystemExit("no OSMEDIA PIX")
        pix1 = int(m1.group(1), 16)
        print("PIX 0x%08X" % pix1)
        if not near(pix1, FRAME, SLOP):
            raise SystemExit("PIX 0x%08X is not FRAME" % pix1)
        if "OSMEDIA WIN " not in text:
            raise SystemExit("no OSMEDIA WIN")
        if kind == "movie":
            if m2 is None:
                raise SystemExit("no OSMEDIA MOV — second still missing")
            pix2 = int(m2.group(1), 16)
            print("MOV 0x%08X" % pix2)
            if not near(pix2, FRAME2, SLOP):
                raise SystemExit("MOV 0x%08X is not FRAME2" % pix2)
            if near(pix2, FRAME, SLOP):
                raise SystemExit("MOV equals FRAME — not two colours")
            print("MOVIE_OK")
            return
        if m2 is not None:
            raise SystemExit("OSMEDIA_NO_MOVIE still printed MOV")
        print("NOMOVIE_OK")
        return
    if kind in ("win2", "win1"):
        blob = open(sys.argv[3], "rb").read()
        pitch = int(sys.argv[4], 0)
        wx = WIN_X + WIN_PX
        wy = WIN_Y + WIN_PY
        win = pixel_at(blob, pitch, wx, wy)
        blit = pixel_at(blob, pitch, BLIT_X + PX, BLIT_Y + PY)
        print("WINFB 0x%06X at (%d,%d)" % (win, wx, wy))
        print("BLITFB 0x%06X" % blit)
        if kind == "win2":
            if not near(win, FRAME2, SLOP):
                raise SystemExit("window 0x%06X is not FRAME2" % win)
            if near(win, FRAME, SLOP):
                raise SystemExit("window still FRAME — pixel did not change")
            # Raw tile keeps the first still (commit_rgb blits both,
            # last wins on the Bochs origin too — accept either still
            # there; the window is the movie criterion).
            print("WIN2_OK")
            return
        if not near(win, FRAME, SLOP):
            raise SystemExit("no-movie window 0x%06X is not FRAME" % win)
        if near(win, FRAME2, SLOP):
            raise SystemExit("no-movie window is FRAME2")
        print("WIN1_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
