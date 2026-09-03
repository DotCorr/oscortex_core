#!/usr/bin/env python3
"""Round 16 visual stress: high-rate QMP dumps, zero wallpaper holes."""

import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

from artifacts import resolve_artifacts

fi_spec = importlib.util.spec_from_file_location(
    "frame_integrity", os.path.join(HERE, "frame-integrity.py"))
fi = importlib.util.module_from_spec(fi_spec)
fi_spec.loader.exec_module(fi)
inspect_png = fi.inspect_png

STRESS_SECS = float(os.environ.get("DRIVE_STRESS_SECS", "300"))
BURST = int(os.environ.get("DRIVE_BURST", "6"))


def burst_shots(q, folder, tag, files_xywh, set_xywh):
    recs = []
    for i in range(BURST):
        path = os.path.join(folder, "%s-%02d.png" % (tag, i))
        d15.shot(q, path)
        rec = inspect_png(path, files_xywh=files_xywh, set_xywh=set_xywh)
        rec["tag"] = tag
        rec["i"] = i
        recs.append(rec)
        if rec["bad"]:
            return recs
    return recs


def main():
    if len(sys.argv) < 4:
        raise SystemExit(
            "usage: visual-stress-round16.py <qmp> <serial> <outdir>")
    port, serial_path, outdir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    art, _warn = resolve_artifacts()
    os.makedirs(outdir, exist_ok=True)
    frames_dir = os.path.join(outdir, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    q = d15.Qmp(port)
    ser = d15.Serial(serial_path, int(os.environ.get("DRIVE_SERIAL_PORT", "0")))
    skip = os.environ.get("DRIVE_SKIP_BOOT", "0") == "1"
    if not skip:
        deadline = time.time() + 40
        while time.time() < deadline and "M1 END" not in ser.read():
            time.sleep(0.2)
        time.sleep(1.2)
        for cmd, wait in (("fb", 1.5), ("wm on", 2.5), ("wm gfx", 1.0),
                          ("wm de", 1.0), ("wm pace", 0.5), ("vtab", 0.4),
                          ("proc spawn desk.elf", 2.0)):
            q.type_line(cmd)
            time.sleep(wait)
        d15.wait_mark(ser, "DESK READY", ser.read(), 12)
        time.sleep(0.6)
        d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                  "left", "FILES CSD", timeout=8)
        d15.wait_mark(ser, "FILES READY", ser.read(), 8)
        d15.press(q, ser, d15.SET_DOCK_XY[0], d15.SET_DOCK_XY[1],
                  "left", "SET CSD", timeout=8)
        d15.wait_mark(ser, "SET READY", ser.read(), 8)
        time.sleep(0.3)

    files_xywh = (48, 40, 400, 280)
    set_xywh = (180, 48, 440, 280)
    all_recs = []
    bad = []

    def take(tag):
        recs = burst_shots(q, frames_dir, tag, files_xywh, set_xywh)
        all_recs.extend(recs)
        for r in recs:
            if r["bad"]:
                bad.append(r)
                return False
        return True

    if not take("settle"):
        pass
    d15.press(q, ser, d15.SET_TITLE_XY[0], d15.SET_TITLE_XY[1],
              "left", "WM DEFN", timeout=3)
    take("set-focus")
    d15.press(q, ser, d15.FILES_MAX_XY[0], d15.FILES_MAX_XY[1],
              "left", "WM MAX", timeout=4)
    d15.wait_mark(ser, "FILES PHZ PAINT E", ser.read(), 2)
    take("files-max")
    d15.press(q, ser, d15.FILES_MAX_MAXED_XY[0], d15.FILES_MAX_MAXED_XY[1],
              "left", "WM MAX", timeout=4)
    take("files-restore")
    # Drag FILES title a few steps.
    d15.place(q, ser, 120, 55)
    d15.button(q, 120, 55, "left", True)
    for dx in (20, 40, 60, 40, 20, 0):
        d15.place(q, ser, 120 + dx, 55)
        take("files-drag-%d" % dx)
    d15.button(q, 120 + 0, 55, "left", False)
    take("files-drag-end")
    d15.press(q, ser, d15.FILES_BODY_XY[0], d15.FILES_BODY_XY[1],
              "right", "WM WIN MENU", timeout=3)
    take("files-menu")
    q.key("esc")
    time.sleep(0.15)

    t0 = time.time()
    n = 0
    while time.time() - t0 < STRESS_SECS:
        n += 1
        d15.press(q, ser, d15.FILES_MAX_XY[0], d15.FILES_MAX_XY[1],
                  "left", "WM MAX", timeout=3)
        take("loop-max-%d" % n)
        d15.press(q, ser, d15.FILES_MAX_MAXED_XY[0], d15.FILES_MAX_MAXED_XY[1],
                  "left", "WM MAX", timeout=3)
        take("loop-rest-%d" % n)
        d15.press(q, ser, d15.SET_TITLE_XY[0], d15.SET_TITLE_XY[1],
                  "left", "WM DEFN", timeout=2)
        take("loop-set-%d" % n)
        if bad:
            break

    shot_set = os.path.join(art, "oscortex-round16-set-atomic.png")
    shot_ghost = os.path.join(art, "oscortex-round16-no-ghost.png")
    d15.shot(q, shot_set, os.path.join(outdir, "set-atomic.png"))
    d15.shot(q, shot_ghost, os.path.join(outdir, "no-ghost.png"))
    final_set = inspect_png(shot_set, files_xywh=files_xywh, set_xywh=set_xywh)
    final_ghost = inspect_png(shot_ghost, files_xywh=files_xywh, set_xywh=set_xywh)
    all_recs.append(final_set)
    all_recs.append(final_ghost)
    if final_set["bad"]:
        bad.append(final_set)
    if final_ghost["bad"]:
        bad.append(final_ghost)

    payload = {
        "round": 16,
        "frames": len(all_recs),
        "bad": len(bad),
        "stress_secs": round(time.time() - t0, 1),
        "loops": n,
        "bad_frames": bad[:12],
        "set_atomic": final_set,
        "no_ghost": final_ghost,
    }
    os.makedirs(art, exist_ok=True)
    open(os.path.join(art, "oscortex-round16-frame-integrity.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    open(os.path.join(outdir, "frame-integrity.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    if bad:
        raise SystemExit("visual integrity: %d bad frames (first %s)"
                         % (len(bad), bad[0].get("why")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
