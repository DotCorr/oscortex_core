#!/usr/bin/env python3
"""GOP screenshots: layered drag + pointer dirty, plus layer/damage JSON."""

import importlib.util
import json
import os
import re
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r29")
ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
FULL = 1280 * 720


def harvest():
    return open(os.path.join(RUN, "serial.txt"), encoding="latin-1",
                errors="replace").read()


def main():
    os.makedirs(ART, exist_ok=True)
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    # Layered drag: hold title and step so the card is mid-move.
    d15.place(q, ser, 140, 55)
    time.sleep(0.05)
    d15.button(q, 140, 55, "left", True)
    for i in range(6):
        d15.place(q, ser, 140 + i * 12, 55)
        time.sleep(0.04)
    d15.shot(q, os.path.join(ART, "oscortex-round29-layered-drag.png"))
    d15.button(q, 200, 55, "left", False)
    time.sleep(0.05)
    # Pointer-only dirty: walk the desk, no button.
    for i in range(8):
        d15.place(q, ser, 40 + i * 18, 500 + (i % 3) * 8)
        time.sleep(0.03)
    d15.shot(q, os.path.join(ART, "oscortex-round29-pointer-flush.png"))

    blob = harvest()
    frames = []
    for m in re.finditer(r"WM FRAME N ([0-9A-F]+) PX ([0-9A-F]+)", blob):
        px = int(m.group(2), 16)
        frames.append(px)
    drag_like = [p for p in frames if 20000 < p < 400000]
    ptr_like = [p for p in frames if p == 640]
    menu_like = [p for p in frames if p == 16182]
    full = [p for p in frames if p >= FULL]
    payload = {
        "round": 29,
        "architecture": {
            "chrome_key": "size-only (w,h); position not folded",
            "drag": "wmGfxMail + osgfx_chrome_drag_step + wmPresentPair old+new",
            "pointer": "old+new 16x20 clipped (~640 px) virtgpuPresent + FRAME",
            "menu": "wmPopVis 174x93 overlay layer",
            "session_owe": "wmGfxKick only; drag uses wmGfxMail (no gen bump)",
        },
        "frame_n": len(frames),
        "pointer_640_n": len(ptr_like),
        "drag_layer_n": len(drag_like),
        "menu_16182_n": len(menu_like),
        "full_1280_n": len(full),
        "dirty_px_p50": (sorted(frames)[len(frames) // 2] if frames else 0),
        "dirty_px_max": max(frames) if frames else 0,
        "shots": {
            "layered_drag": os.path.join(ART, "oscortex-round29-layered-drag.png"),
            "pointer_flush": os.path.join(ART, "oscortex-round29-pointer-flush.png"),
        },
    }
    dest = os.path.join(ART, "oscortex-round29-layer.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    dmg = {
        "round": 29,
        "full_px": FULL,
        "interactive_full_after_warm_expected": 0,
        "pointer_px": 640,
        "menu_px": 16182,
        "files_pair_px": 232232,
        "frame_n": len(frames),
        "full_1280_n": len(full),
        "pointer_640_n": len(ptr_like),
        "drag_layer_n": len(drag_like),
    }
    open(os.path.join(ART, "oscortex-round29-damage.json"), "w").write(
        json.dumps(dmg, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    print("wrote", dest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
