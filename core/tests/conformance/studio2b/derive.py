#!/usr/bin/env python3
"""core/tests/conformance/studio2b/derive.py

Expectations from the planted two-name catalog and studio.c geometry.
SEL.DAT is four bytes, the selected row as a little-endian u32.
The other planted name must not appear selected.

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
if len(names) < 2:
    raise SystemExit("derive: catalog must plant two names, got %d" % len(names))
if names[0] != "APP1.ELF":
    raise SystemExit("derive: first planted name is %r, not APP1.ELF" % names[0])
if names[1] != "APP2.ELF":
    raise SystemExit("derive: second planted name is %r, not APP2.ELF" % names[1])

P = c_defs(sys.argv[2])
for k in ("WIN_W", "WIN_H", "SURF_X", "SURF_Y", "KEY_DIGIT1", "SEL_BYTES",
          "CHUNK"):
    if k not in P:
        raise SystemExit("derive: studio.c does not define %s" % k)

persist_bytes = P["SEL_BYTES"]
sizeof_buf = P["CHUNK"]
if persist_bytes != 4:
    raise SystemExit("derive: SEL_BYTES is %d; persist is a u32" % persist_bytes)
if sizeof_buf == persist_bytes:
    raise SystemExit("derive: sizeof-buf equals persist_bytes — vacuous")

sx, sy = P["SURF_X"], P["SURF_Y"]
w, h = P["WIN_W"], P["WIN_H"]
band_h = h // len(names) if len(names) > 1 else h
if band_h < 1:
    band_h = 1
hit_x = sx + (w // 2)
hit_y = sy + (band_h // 2)
rels = ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps_to(hit_x, hit_y))

sel_row = 0
other_row = 1
sel_word = sel_row

print("catalog_lines=%d" % len(names))
print("catalog_len=%d" % len(catalog))
print("token_0=%s" % names[0])
print("token_1=%s" % names[1])
print("name_0=USER WRITE STUDIO1 NAME %s" % names[0])
print("name_1=USER WRITE STUDIO1 NAME %s" % names[1])
print("list_line=USER WRITE STUDIO1 LIST")
print("ready_line=USER WRITE STUDIO2 READY")
print("launch_line=USER WRITE STUDIO2 LAUNCH %s" % names[0])
print("ok_prefix=USER WRITE STUDIO2 OK")
print("save_line=USER WRITE STUDIO2 SAVE")
print("sel_line=USER WRITE STUDIO2 SEL %s" % names[0])
print("other_sel=USER WRITE STUDIO2 SEL %s" % names[1])
print("app1_hello=USER WRITE APPS1 APP1")
print("app1_heap=USER WRITE APPS1 APP1 HEAP 1")
print("app1_heap_fail=USER WRITE APPS1 APP1 HEAP 0")
print("app2_hello=USER WRITE APPS1 APP2")
print("app2_heap=USER WRITE APPS1 APP2 HEAP 1")
print("key_qcode=1")
print("key_scan=%02x" % P["KEY_DIGIT1"])
print("hit_x=%d" % hit_x)
print("hit_y=%d" % hit_y)
print("rels_hit=%s" % rels)
print("sel_row=%d" % sel_row)
print("other_row=%d" % other_row)
print("sel_word=%d" % sel_word)
print("persist_bytes=%d" % persist_bytes)
print("sizeof_buf=%d" % sizeof_buf)
print("sel_file=SEL.DAT")
print("has_app1=%d" % (1 if b"APP1.ELF" in catalog else 0))
print("has_app2=%d" % (1 if b"APP2.ELF" in catalog else 0))
