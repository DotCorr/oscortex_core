#!/usr/bin/env python3
"""Restate osmedia.h constants and score a serial PIX line."""
import re
import sys

FRAME = 0x00C04088
DESK = 0x00184060
SLOP = 20


def near(c, expect, slop):
    dr = abs(((c >> 16) & 0xFF) - ((expect >> 16) & 0xFF))
    dg = abs(((c >> 8) & 0xFF) - ((expect >> 8) & 0xFF))
    db = abs((c & 0xFF) - (expect & 0xFF))
    return dr <= slop and dg <= slop and db <= slop


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: derive.py <serial> frame|none")
    text = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
    kind = sys.argv[2]
    print("FRAME 0x%08X" % FRAME)
    print("DESK 0x%08X" % DESK)
    m = re.search(r"OSMEDIA PIX ([0-9A-Fa-f]{8})", text)
    if kind == "frame":
        if m is None:
            raise SystemExit("no OSMEDIA PIX line")
        pix = int(m.group(1), 16)
        print("PIXEL 0x%08X" % pix)
        if pix == 0:
            raise SystemExit("frame pixel is 0")
        if pix == DESK:
            raise SystemExit("frame pixel is desktop")
        if not near(pix, FRAME, SLOP):
            raise SystemExit("frame pixel 0x%08X is not FRAME" % pix)
        if "OSMEDIA BACKEND ffmpeg" not in text:
            raise SystemExit("no BACKEND ffmpeg")
        print("FRAME_OK")
        return
    if kind == "none":
        if "OSMEDIA MISS" not in text and m is None:
            raise SystemExit("negative produced no MISS and no PIX")
        if m is not None:
            pix = int(m.group(1), 16)
            print("PIXEL 0x%08X" % pix)
            if near(pix, FRAME, SLOP):
                raise SystemExit("negative pixel is FRAME — missing file was not required")
        if "OSMEDIA BACKEND ffmpeg" in text and "OSMEDIA MISS" not in text:
            raise SystemExit("negative still says ffmpeg without MISS")
        print("NONE_OK")
        return
    raise SystemExit("kind")


if __name__ == "__main__":
    main()
