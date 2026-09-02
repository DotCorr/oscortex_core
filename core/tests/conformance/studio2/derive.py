#!/usr/bin/env python3
"""core/tests/conformance/studio2/derive.py

Expectations from the planted catalog and studio.c geometry, not from
a guest transcript.

    derive.py <apps.txt> <studio.c>
"""

import re
import sys


def c_defs(path):
    out = {}
    for m in re.finditer(r"^#define\s+([A-Z_0-9]+)\s+(0[xX][0-9A-Fa-f]+|\d+)U?L?$",
                         open(path).read(), re.M):
        out[m.group(1)] = int(m.group(2), 0)
    return out


def steps_to(dx, dy, cap=120):
    out = []
    x, y = dx, dy
    while x != 0 or y != 0:
        sx = max(-cap, min(cap, x))
        sy = max(-cap, min(cap, y))
        if sx == 0 and sy == 0:
            raise SystemExit("derive: cannot step (%d,%d)" % (dx, dy))
        out.append((sx, sy))
        x -= sx
        y -= sy
    return out


if len(sys.argv) != 3:
    raise SystemExit("usage: derive.py <apps.txt> <studio.c>")

catalog = open(sys.argv[1], "rb").read()
lines = [ln for ln in catalog.split(b"\n") if ln]
names = [ln.decode("ascii") for ln in lines]
if not names:
    raise SystemExit("derive: planted catalog is empty")
if names[0] != "APP1.ELF":
    raise SystemExit("derive: first planted name is %r, not APP1.ELF" % names[0])

P = c_defs(sys.argv[2])
for k in ("WIN_W", "WIN_H", "SURF_X", "SURF_Y", "KEY_DIGIT1"):
    if k not in P:
        raise SystemExit("derive: studio.c does not define %s" % k)

sx, sy = P["SURF_X"], P["SURF_Y"]
w, h = P["WIN_W"], P["WIN_H"]
band_h = h // len(names) if len(names) > 1 else h
if band_h < 1:
    band_h = 1
hit_x = sx + (w // 2)
hit_y = sy + (band_h // 2)
rels = ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps_to(hit_x, hit_y))

print("catalog_lines=%d" % len(names))
print("catalog_len=%d" % len(catalog))
print("token_0=%s" % names[0])
print("name_0=USER WRITE STUDIO1 NAME %s" % names[0])
print("list_line=USER WRITE STUDIO1 LIST")
print("ready_line=USER WRITE STUDIO2 READY")
print("launch_line=USER WRITE STUDIO2 LAUNCH %s" % names[0])
print("ok_prefix=USER WRITE STUDIO2 OK")
print("app1_hello=USER WRITE APPS1 APP1")
print("app1_heap=USER WRITE APPS1 APP1 HEAP 1")
print("app1_heap_fail=USER WRITE APPS1 APP1 HEAP 0")
print("key_qcode=1")
print("key_scan=%02x" % P["KEY_DIGIT1"])
print("hit_x=%d" % hit_x)
print("hit_y=%d" % hit_y)
print("rels_hit=%s" % rels)
print("has_app1=%d" % (1 if b"APP1.ELF" in catalog else 0))
