#!/usr/bin/env python3
"""Pixel sentinels across many rows: SET/FILES bodies must not show wallpaper."""

import json
import os
import struct
import sys
import zlib


WALL_TEAL_MIN = (0x48, 0xA0, 0x90)
WALL_TEAL_MAX = (0x78, 0xE0, 0xD8)


def _png_rgba(path):
    with open(path, "rb") as f:
        sig = f.read(8)
        if sig != b"\x89PNG\r\n\x1a\n":
            raise SystemExit("not a PNG: %s" % path)
        w = h = None
        idat = b""
        while True:
            hdr = f.read(8)
            if len(hdr) < 8:
                break
            ln, typ = struct.unpack(">I4s", hdr)
            data = f.read(ln)
            f.read(4)
            if typ == b"IHDR":
                w, h, bit, ctype = struct.unpack(">IIBB", data[:10])
                if bit != 8 or ctype not in (2, 6):
                    raise SystemExit("unsupported PNG %s" % path)
            elif typ == b"IDAT":
                idat += data
            elif typ == b"IEND":
                break
    raw = zlib.decompress(idat)
    bpp = 4 if ctype == 6 else 3
    stride = 1 + w * bpp
    out = []
    i = 0
    for _y in range(h):
        i += 1
        row = raw[i:i + w * bpp]
        i += w * bpp
        pix = []
        if bpp == 4:
            for x in range(w):
                r, g, b, _a = row[x * 4:(x + 1) * 4]
                pix.append((r << 16) | (g << 8) | b)
        else:
            for x in range(w):
                r, g, b = row[x * 3:(x + 1) * 3]
                pix.append((r << 16) | (g << 8) | b)
        out.append(pix)
    return w, h, out


def is_wallpaper(c):
    r, g, b = (c >> 16) & 255, (c >> 8) & 255, c & 255
    if r < WALL_TEAL_MIN[0] or r > WALL_TEAL_MAX[0]:
        return False
    if g < WALL_TEAL_MIN[1] or g > WALL_TEAL_MAX[1]:
        return False
    if b < WALL_TEAL_MIN[2] or b > WALL_TEAL_MAX[2]:
        return False
    return (g - r) > 40


def sample_rect(rows, x0, y0, x1, y1, step=4):
    h = len(rows)
    w = len(rows[0]) if h else 0
    x0 = max(0, min(w, x0))
    x1 = max(0, min(w, x1))
    y0 = max(0, min(h, y0))
    y1 = max(0, min(h, y1))
    n = 0
    wall = 0
    ys = list(range(y0, y1, step))
    if y1 - 1 not in ys and y1 > y0:
        ys.append(y1 - 1)
    for y in ys:
        row = rows[y]
        x = x0
        while x < x1:
            n += 1
            if is_wallpaper(row[x]):
                wall += 1
            x += step
    return n, wall


def inspect_png(path, files_xywh=(48, 40, 400, 280), set_xywh=(180, 48, 440, 280)):
    w, h, rows = _png_rgba(path)
    title = 36
    fx, fy, fw, fh = files_xywh
    sx, sy, sw, sh = set_xywh
    fn, fwll = sample_rect(rows, fx + 12, fy + title, fx + fw - 12, fy + fh - 8)
    sn, swll = sample_rect(rows, sx + 128, sy + title, sx + sw - 12, sy + sh - 8)
    side_n, side_w = sample_rect(rows, sx + 8, sy + title, sx + 110, sy + sh - 8)
    rec = {
        "png": path,
        "size": [w, h],
        "files_body_n": fn,
        "files_wall": fwll,
        "files_wall_frac": round(fwll / fn, 4) if fn else None,
        "set_body_n": sn,
        "set_wall": swll,
        "set_wall_frac": round(swll / sn, 4) if sn else None,
        "set_side_n": side_n,
        "set_side_wall": side_w,
        "bad": False,
        "why": [],
    }
    if fn and fwll / fn >= 0.08:
        rec["bad"] = True
        rec["why"].append("files_ghost")
    if sn and swll / sn >= 0.08:
        rec["bad"] = True
        rec["why"].append("set_teal")
    if side_n and side_w / side_n >= 0.12:
        rec["bad"] = True
        rec["why"].append("set_side_teal")
    return rec


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: frame-integrity.py <png> [...]")
    out = []
    bad = 0
    for p in sys.argv[1:]:
        rec = inspect_png(p)
        out.append(rec)
        if rec["bad"]:
            bad += 1
            print("BAD", json.dumps(rec))
        else:
            print("OK", rec["png"], "files_wall", rec["files_wall_frac"],
                  "set_wall", rec["set_wall_frac"])
    print(json.dumps({"n": len(out), "bad": bad, "frames": out}, indent=2))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
