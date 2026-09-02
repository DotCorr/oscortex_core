#!/usr/bin/env python3
"""Crop and nearest-neighbour magnify a BGRA framebuffer dump to a PNG.

Chrome quality lives in 2-3 pixel fringes, so eyeballing an 800x600 dump
proves nothing. This makes the fringe visible.

Usage: zoom.py FB PITCH X Y W H SCALE OUT.png
"""
import struct
import sys
import zlib


def main():
    fb, pitch = sys.argv[1], int(sys.argv[2])
    x0, y0, w, h, scale = (int(v) for v in sys.argv[3:8])
    out = sys.argv[8]
    data = open(fb, "rb").read()
    raw = bytearray()
    for y in range(y0, y0 + h):
        row = bytearray()
        for x in range(x0, x0 + w):
            off = y * pitch + x * 4
            b, g, r = (data[off], data[off + 1], data[off + 2]) \
                if off + 4 <= len(data) else (0, 0, 0)
            row.extend((r, g, b) * scale)
        for _ in range(scale):
            raw.append(0)
            raw.extend(row)

    def chunk(tag, payload):
        crc = zlib.crc32(tag + payload) & 0xFFFFFFFF
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", crc))

    ihdr = struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0)
    open(out, "wb").write(
        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    print("zoom: %s (%dx%d at %dx)" % (out, w, h, scale))


main()
