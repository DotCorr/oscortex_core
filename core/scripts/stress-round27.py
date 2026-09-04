#!/usr/bin/env python3
"""5+ min mix stress against the live Round 27 leftover."""

import importlib.util
import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r27")
SECS = float(os.environ.get("DRIVE_STRESS_SECS", "300"))
SCREEN_W = 1280
ICON_S, ICON_GAP, ICON_PAD, ICON_N = 32, 8, 16, 6
RIGHT_W = ICON_PAD + ICON_N * ICON_S + (ICON_N - 1) * ICON_GAP + ICON_PAD
RIGHT_X = SCREEN_W - 16 - RIGHT_W
PANEL_Y = 720 - 48 + 20


def dock_xy(i):
    return (RIGHT_X + ICON_PAD + i * (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    t0 = time.time()
    n = 0
    menus = 0
    focus = 0
    launches = 0
    while time.time() - t0 < SECS:
        d15.place(q, ser, 80 + (n * 17) % 400, 200 + (n * 11) % 200)
        if n % 11 == 0:
            dx, dy = dock_xy(n % 6)
            d15.timed_click(q, ser, dx, dy, "left", timeout=2.0)
            launches += 1
        if n % 5 == 0:
            d15.timed_click(q, ser, 48, 520, "right", timeout=2.0)
            try:
                q.key("esc")
            except Exception:
                pass
            menus += 1
        if n % 7 == 0:
            d15.timed_click(q, ser, 500, 55, "left", timeout=2.0,
                            want_opid=True, label="focus")
            focus += 1
        n += 1
        time.sleep(0.08)
    path = os.path.join(RUN, "serial.txt")
    blob = open(path).read()
    out = {
        "round": 27,
        "secs": round(time.time() - t0, 1),
        "cycles": n,
        "menus": menus,
        "focus": focus,
        "launches": launches,
        "fault": ("FAULT 0E" in blob) or ("FAULT 0D" in blob),
        "reap": blob.count("WM REAP W "),
        "oom": ("DESK READY" in blob) and ("OSGFX OOM" in blob.split("DESK READY", 1)[-1]),
        "qtimeout": "VIRTIO QTIMEOUT" in blob,
        "integrity": "OSGFX ABORT" in blob,
        "tap_die": "TAP DIE " in blob,
    }
    dest = os.path.join(ART, "oscortex-round27-stress.json")
    open(dest, "w").write(json.dumps(out, indent=2) + "\n")
    print(out)
    if out["fault"] or out["oom"] or out["integrity"] or out["reap"] >= 3:
        raise SystemExit("stress: faults")
    if out["qtimeout"]:
        raise SystemExit("stress: QTIMEOUT")
    print("stress: PASS")


if __name__ == "__main__":
    main()
