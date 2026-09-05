#!/usr/bin/env python3
"""Host check for the Round 39 sealed VIS parser."""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "vis39", os.path.join(HERE, "vis-tokens.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

c = m.csum(0xF, 0x123, 0x48, 0xF0, 0xA0, 1)
line = ("WM VIS W 0F X 0123 Y 0048 W 00F0 H 00A0 G 0001 C %02X" % c)
rec, why = m.parse_vis_line(line)
if rec is None or why is not None:
    raise SystemExit("good line rejected: %s %s" % (rec, why))
rec, why = m.parse_vis_line(line[:-2] + "00")
if why != "checksum":
    raise SystemExit("bad checksum not rejected: %s" % why)
rec, why = m.parse_vis_line("WM VIS W 0F VIRTIO SCAN 00000000")
if why not in ("interleaved", "malformed"):
    raise SystemExit("interleave not rejected: %s" % why)
rec, why = m.parse_vis_line("WM VIS W F X 0123 Y 0048 W 00F0 H 00A0")
if why != "malformed":
    raise SystemExit("1-digit VIS not rejected: %s" % why)
# Round 41: reproduce the R40 stress splice (SCAN inside VIS) and reject it.
spliced = "WM VIS W 0F XVIRTIO SCAN 00000000 Y 0048 W 00F0 H 00A0 G 0001 C 00"
rec, why = m.parse_vis_line(spliced)
if why not in ("interleaved", "malformed"):
    raise SystemExit("reproduced splice not rejected: %s" % why)
print("vis-tokens host PASS (malformed splice reproduced and rejected)")
sys.exit(0)
