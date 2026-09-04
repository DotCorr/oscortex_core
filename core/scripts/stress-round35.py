#!/usr/bin/env python3
"""Round 35 integrity: 5 min, no CPATH 3 after DESK READY, >=1000 frames."""

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
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r35")
SECS = float(os.environ.get("DRIVE_STRESS_SECS", "300"))


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    t0 = time.time()
    n = 0
    # Simultaneous dock launch: SET FILES BROWSE PLAY STUDIO TAP.
    for i in range(6):
        x = (d15.RIGHT_X + d15.ICON_PAD + i * (d15.ICON_S + d15.ICON_GAP)
             + d15.ICON_S // 2)
        d15.place(q, ser, x, d15.PANEL_Y)
        d15.button(q, x, d15.PANEL_Y, "left", True)
        time.sleep(0.03)
        d15.button(q, x, d15.PANEL_Y, "left", False)
        time.sleep(0.12)
    # 100 close/reopen cycles on FILES (default geom close chip).
    for i in range(100):
        d15.place(q, ser, d15.FILES_CLOSE_XY[0], d15.FILES_CLOSE_XY[1])
        d15.button(q, d15.FILES_CLOSE_XY[0], d15.FILES_CLOSE_XY[1],
                   "left", True)
        time.sleep(0.02)
        d15.button(q, d15.FILES_CLOSE_XY[0], d15.FILES_CLOSE_XY[1],
                   "left", False)
        time.sleep(0.04)
        d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
        d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                   "left", True)
        time.sleep(0.02)
        d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                   "left", False)
        time.sleep(0.05)
    while time.time() - t0 < SECS:
        d15.place(q, ser, 90 + (n * 19) % 360, 70 + (n * 7) % 40)
        if n % 4 == 0:
            d15.button(q, 90 + (n * 19) % 360, 70, "left", True)
            d15.place(q, ser, 140 + (n * 11) % 200, 70)
            d15.button(q, 140 + (n * 11) % 200, 70, "left", False)
        if n % 6 == 0:
            d15.button(q, 120, 180, "left", True)
            d15.button(q, 120, 180, "left", False)
        if n % 9 == 0:
            d15.button(q, 48, 520, "right", True)
            d15.button(q, 48, 520, "right", False)
            try:
                q.key("esc")
            except Exception:
                pass
        if n % 20 == 0:
            try:
                q.key("f4")
                time.sleep(0.05)
                q.key("esc")
            except Exception:
                pass
        n += 1
        time.sleep(0.05)
    blob = open(os.path.join(RUN, "serial.txt"), encoding="latin-1",
                errors="replace").read()
    after = blob.split("DESK READY", 1)[-1] if "DESK READY" in blob else blob
    reasons = []
    for line in after.splitlines():
        if line.startswith("WM CPATH 3"):
            reasons.append(line)
    out = {
        "round": 35,
        "secs": round(time.time() - t0, 1),
        "cycles": n,
        "fault": ("FAULT 0E" in blob) or ("FAULT 0D" in blob)
                 or ("FAULT 06" in blob),
        "reap": blob.count("WM REAP W "),
        "oom": ("DESK READY" in blob) and (
            "OSGFX OOM" in after),
        "qtimeout": "VIRTIO QTIMEOUT" in blob,
        "abort": "OSGFX ABORT" in blob,
        "tap_die": "TAP DIE " in blob,
        "attach_refuse": "WM RET " in blob or "FILE REFUSED" in blob and blob.count("FILE REFUSED") > 200,
        "close_reopen": 100,
        "cpath_compose": after.count("WM CPATH 3"),
        "cpath3_reasons": reasons[-12:],
        "done_n": after.count("WM DONE "),
        "frames": after.count("WM FRAME N "),
        "closes": after.count("WM CLOSE W "),
        "pref_ack": "WM PREF ACK" in blob,
        "mkdir": "FILES MKDIR" in blob,
        "focus_g": "WM FOCUS G" in blob,
    }
    dest = os.path.join(ART, "oscortex-round35-integrity.json")
    open(dest, "w").write(json.dumps(out, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round35-cpath.json"), "w").write(
        json.dumps({
            "round": 35,
            "source": "stress",
            "cpath3": out["cpath_compose"],
            "reasons": reasons,
            "legitimate": "boot/mode switch only (HAVE=0, why=1)",
        }, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    if out["fault"] or out["oom"] or out["abort"] or out["reap"] >= 3:
        raise SystemExit("stress: faults")
    if out["qtimeout"]:
        raise SystemExit("stress: QTIMEOUT")
    if out["cpath_compose"]:
        raise SystemExit("stress: CPATH 3 during interaction")
    if out["frames"] < 1000 and SECS >= 300:
        raise SystemExit("stress: fewer than 1000 transition frames")
    print("stress: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
