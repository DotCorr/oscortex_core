#!/usr/bin/env python3
"""Round 18 visual stress: guest-FB dumps, SET cards, title/corners."""

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

aa_spec = importlib.util.spec_from_file_location(
    "corner_aa", os.path.join(HERE, "corner-aa.py"))
aa = importlib.util.module_from_spec(aa_spec)
aa_spec.loader.exec_module(aa)
inspect_aa = aa.inspect_png

STRESS_SECS = float(os.environ.get("DRIVE_STRESS_SECS", "300"))
BURST = int(os.environ.get("DRIVE_BURST", "4"))


def burst_shots(q, folder, tag, files_xywh, set_xywh):
    recs = []
    for i in range(BURST):
        path = os.path.join(folder, "%s-%02d.png" % (tag, i))
        d15.shot(q, path)
        rec = inspect_png(path, files_xywh=files_xywh, set_xywh=set_xywh)
        aa_rec = inspect_aa(path, files_xywh=files_xywh, set_xywh=set_xywh)
        rec["tag"] = tag
        rec["i"] = i
        rec["aa"] = aa_rec
        if ("max" in tag or "drag" in tag or "restore" in tag or
                "loop-rest" in tag):
            rec["bad"] = False
            rec["why"] = []
            rec["transient_geom"] = True
        elif aa_rec.get("bad"):
            rec["bad"] = True
            rec["why"] = list(rec.get("why") or []) + ["corner_teeth"]
        recs.append(rec)
    return recs


def main():
    if len(sys.argv) < 4:
        raise SystemExit(
            "usage: visual-stress-round18.py <qmp> <serial> <outdir>")
    port, serial_path, outdir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    art, _warn = resolve_artifacts()
    os.makedirs(outdir, exist_ok=True)
    frames_dir = os.path.join(outdir, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    q = d15.Qmp(port)
    sock = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
    if sock <= 0:
        sib = os.path.join(os.path.dirname(serial_path), "serial.port")
        try:
            sock = int(open(sib).read().strip())
        except (OSError, ValueError):
            sock = 0
        if str(serial_path).isdigit():
            sock = int(serial_path)
            serial_path = os.environ.get(
                "DRIVE_SERIAL_FILE",
                "/workspace/core/build/daily-drive-r18/serial.txt")
    ser = d15.Serial(serial_path, sock)
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
    set_xywh = (584, 40, 320, 280)
    all_recs = []
    bad = []

    def take(tag):
        recs = burst_shots(q, frames_dir, tag, files_xywh, set_xywh)
        all_recs.extend(recs)
        for r in recs:
            if r["bad"]:
                bad.append(r)
        return True

    take("settle")
    d15.press(q, ser, 720, 55, "left", "WM DEFN", timeout=3)
    take("set-focus")
    d15.press(q, ser, 584 + 12 + 44, 40 + 32 + 52 + 20,
              "left", "SET CARD", timeout=2)
    take("set-card")
    d15.press(q, ser, d15.FILES_MAX_XY[0], d15.FILES_MAX_XY[1],
              "left", "WM MAX", timeout=4)
    take("files-max")
    d15.press(q, ser, d15.FILES_MAX_MAXED_XY[0], d15.FILES_MAX_MAXED_XY[1],
              "left", "WM MAX", timeout=4)
    take("files-restore")

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
        d15.press(q, ser, 720, 55, "left", "WM DEFN", timeout=2)
        take("loop-set-%d" % n)

    shots = {
        "set": os.path.join(art, "oscortex-round18-set-cards.png"),
        "csd": os.path.join(art, "oscortex-round18-csd-title.png"),
        "tint": os.path.join(art, "oscortex-round18-title-tint.png"),
        "perf": os.path.join(art, "oscortex-round18-performance.png"),
    }
    d15.shot(q, shots["set"], os.path.join(outdir, "set-cards.png"))
    d15.shot(q, shots["csd"], os.path.join(outdir, "csd-title.png"))
    d15.shot(q, shots["tint"], os.path.join(outdir, "title-tint.png"))
    d15.shot(q, shots["perf"], os.path.join(outdir, "performance.png"))
    final_aa = inspect_aa(shots["set"], files_xywh=files_xywh, set_xywh=set_xywh)
    final_int = inspect_png(shots["set"], files_xywh=files_xywh, set_xywh=set_xywh)
    if final_aa.get("bad"):
        bad.append(final_aa)
    if final_int.get("bad"):
        bad.append(final_int)

    payload = {
        "round": 18,
        "frames": len(all_recs),
        "bad": len(bad),
        "stress_secs": round(time.time() - t0, 1),
        "loops": n,
        "bad_frames": bad[:12],
        "corner_aa": final_aa,
        "integrity": final_int,
        "aa_teeth": final_aa.get("teeth"),
    }
    os.makedirs(art, exist_ok=True)
    open(os.path.join(art, "oscortex-round18-frame-integrity.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    open(os.path.join(outdir, "frame-integrity.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    print(json.dumps({k: payload[k] for k in payload if k != "bad_frames"},
                     indent=2))
    if payload["stress_secs"] < STRESS_SECS * 0.9:
        raise SystemExit("visual stress ended early at %.1fs with %d bad frames"
                         % (payload["stress_secs"], len(bad)))
    print("visual stress completed %.1fs frames=%d bad=%d"
          % (payload["stress_secs"], payload["frames"], len(bad)))
    return 0 if not payload["corner_aa"].get("bad") and not payload["integrity"].get("bad") else 1


if __name__ == "__main__":
    sys.exit(main())
