#!/usr/bin/env python3
"""Round 39 VIS token protocol: sealed two-digit records with checksum.

Rejects interleaved/malformed lines instead of updating geom.
Checksum is (slot ^ x ^ y ^ w ^ h ^ gen) & 0xFF, matching uartTokCsum.
"""

import re

VIS_RE = re.compile(
    r"WM VIS W ([0-9A-F]{2}) X ([0-9A-F]{4}) Y ([0-9A-F]{4}) "
    r"W ([0-9A-F]{4}) H ([0-9A-F]{4}) G ([0-9A-F]{4}) C ([0-9A-F]{2})"
)
VIS_LOOSE_RE = re.compile(r"WM VIS W ")
REQ_RE = re.compile(
    r"WM REQ W ([0-9A-F]{2}) X ([0-9A-F]{4}) Y ([0-9A-F]{4}) "
    r"W ([0-9A-F]{4}) H ([0-9A-F]{4}) G ([0-9A-F]{4}) C ([0-9A-F]{2})"
)
SCAN_RE = re.compile(
    r"VIRTIO SCAN ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8}) "
    r"([0-9A-F]{8}) ([0-9A-F]{8})"
)


def csum(slot, x, y, w, h, gen):
    return (slot ^ x ^ y ^ w ^ h ^ gen) & 0xFF


def parse_vis_line(line):
    if "VIRTIO" in line and "WM VIS" in line:
        return None, "interleaved"
    m = VIS_RE.search(line)
    if not m:
        if "WM VIS W " in line:
            return None, "malformed"
        return None, None
    slot = int(m.group(1), 16)
    x = int(m.group(2), 16)
    y = int(m.group(3), 16)
    w = int(m.group(4), 16)
    h = int(m.group(5), 16)
    gen = int(m.group(6), 16)
    got = int(m.group(7), 16)
    if got != csum(slot, x, y, w, h, gen):
        return None, "checksum"
    return {
        "slot": slot, "x": x, "y": y, "w": w, "h": h, "gen": gen, "c": got,
    }, None


def harvest_vis(blob):
    ok = []
    rejected = {"malformed": 0, "checksum": 0, "interleaved": 0, "zero": 0}
    for line in blob.splitlines():
        rec, why = parse_vis_line(line)
        if why:
            rejected[why] = rejected.get(why, 0) + 1
            continue
        if rec is None:
            continue
        if rec["w"] < 1 or rec["h"] < 1:
            rejected["zero"] += 1
            continue
        ok.append(rec)
    return ok, rejected


def apply_vis_strict(wins, rec):
    w = rec["slot"]
    if w not in wins or not wins[w].get("live"):
        return False
    wins[w]["x"] = rec["x"]
    wins[w]["y"] = rec["y"]
    wins[w]["ww"] = rec["w"]
    wins[w]["hh"] = rec["h"]
    wins[w]["vis_gen"] = rec["gen"]
    return True
