#!/usr/bin/env python3
"""core/tests/conformance/studio1/derive.py

Expectations from the planted catalog (a file the kernel did not write),
not from a guest transcript.

    derive.py <apps.txt>
"""

import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: derive.py <apps.txt>")

catalog = open(sys.argv[1], "rb").read()
lines = [ln for ln in catalog.split(b"\n") if ln]
names = [ln.decode("ascii") for ln in lines]
if not names:
    raise SystemExit("derive: planted catalog is empty")

print("catalog_lines=%d" % len(names))
print("catalog_len=%d" % len(catalog))
print("names_line=USER WRITE STUDIO1 NAMES %d LEN %08x" % (
    len(names), len(catalog)))
print("list_line=USER WRITE STUDIO1 LIST")
for i, name in enumerate(names):
    print("name_%d=USER WRITE STUDIO1 NAME %s" % (i, name))
    print("token_%d=%s" % (i, name))
print("has_app1=%d" % (1 if b"APP1.ELF" in catalog else 0))
print("has_app2=%d" % (1 if b"APP2.ELF" in catalog else 0))
