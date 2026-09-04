#!/usr/bin/env python3
"""Round 30 GOP/virtio shots: cold-scroll after drag + layered drag."""

import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

cs_spec = importlib.util.spec_from_file_location(
    "cs", os.path.join(HERE, "chip-scan-round24.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)

RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r30")
ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
FULL = 1280 * 720


def harvest():
    return open(os.path.join(RUN, "serial.txt"), encoding="latin-1",
                errors="replace").read()


def geom():
    g = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "")
    return g or (48, 40, 400, 280)


def shot_path(name):
    return os.path.join(ART, name)


def main():
    os.makedirs(ART, exist_ok=True)
    mode = os.environ.get("OSCORTEX_CAPTURE", "gop")
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    g = geom()
    tx, ty = cs.title_of(g)
    d15.place(q, ser, tx, ty)
    time.sleep(0.04)
    d15.button(q, tx, ty, "left", True)
    for i in range(6):
        d15.place(q, ser, tx + i * 12, ty)
        time.sleep(0.03)
    if mode == "virtio":
        dest = shot_path("oscortex-round30-virtio-drag.png")
        d15.shot_virtio_backing(q, dest)
    else:
        dest = shot_path("oscortex-round30-layered-drag.png")
        d15.shot(q, dest)
    d15.button(q, tx + 72, ty, "left", False)
    time.sleep(0.08)
    g = geom()
    bx, by = g[0] + 48, g[1] + 96
    d15.place(q, ser, bx, by)
    d15.button(q, bx, by, "left", True)
    d15.button(q, bx, by, "left", False)
    time.sleep(0.05)
    if mode != "virtio":
        d15.shot(q, shot_path("oscortex-round30-cold-scroll.png"))

    blob = harvest()
    frames = [int(m.group(2), 16)
              for m in re.finditer(r"WM FRAME N ([0-9A-F]+) PX ([0-9A-F]+)",
                                   blob)]
    scans = []
    for m in re.finditer(
            r"VIRTIO SCAN ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+) "
            r"([0-9A-F]+) ([0-9A-F]+)", blob):
        scans.append(int(m.group(3), 16) * int(m.group(4), 16))
    payload = {
        "round": 30,
        "mode": mode,
        "geom": list(g),
        "title": [tx, ty],
        "frame_n": len(frames),
        "scan_n": len(scans),
        "pointer_640_n": sum(1 for p in frames if p == 640),
        "menu_16182_n": sum(1 for p in frames if p == 16182),
        "full_1280_n": sum(1 for p in (scans or frames) if p >= FULL),
        "shots": {
            "cold_scroll": shot_path("oscortex-round30-cold-scroll.png"),
            "virtio_drag": shot_path("oscortex-round30-virtio-drag.png"),
            "layered_drag": dest,
        },
    }
    out = os.path.join(ART, "oscortex-round30-layer.json")
    open(out, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    print("wrote", dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
