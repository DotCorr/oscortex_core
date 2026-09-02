#!/usr/bin/env python3
"""core/tests/conformance/apps1/derive.py

Expectations from the planted catalog (a file the kernel did not write),
not from a guest transcript.

    derive.py <apps.txt>
"""

import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: derive.py <apps.txt>")

catalog = open(sys.argv[1], "rb").read()
if catalog != b"APP1.ELF\nAPP2.ELF\n":
    raise SystemExit("derive: catalog is not the two-name list this harness planted")

# fatPrintName: 8-byte padded stem, a dot, 3-byte ext.
print("elf_file_a=ELF FILE APP1    .ELF")
print("elf_file_b=ELF FILE APP2    .ELF")
print("fs_open_a=FS OPEN APP1    .ELF")
print("fs_open_b=FS OPEN APP2    .ELF")
print("marker_a=USER WRITE APPS1 APP1")
print("marker_b=USER WRITE APPS1 APP2")
print("heap_a=USER WRITE APPS1 APP1 HEAP 1")
print("heap_b=USER WRITE APPS1 APP2 HEAP 1")
print("heap_fail_a=USER WRITE APPS1 APP1 HEAP 0")
print("heap_fail_b=USER WRITE APPS1 APP2 HEAP 0")
print("cat_a=APP1.ELF")
print("cat_b=APP2.ELF")
print("missing=FS ERR 10 no such name in the root directory")
print("catalog_lines=2")
