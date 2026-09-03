#!/usr/bin/env python3
"""Measure isolated interactive present rate and event→present latency.

TCG ~2 fps is the documented cost-bound, not a daily-drive claim.
Writes /opt/cursor/artifacts/oscortex-round18-performance.json
"""

import importlib.util
import json
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)


def open_serial(serial_arg):
    """Socket ingest. Path argv still works; a port int or sibling serial.port is preferred."""
    port = 0
    path = serial_arg
    if str(serial_arg).isdigit():
        port = int(serial_arg)
        path = os.environ.get(
            "DRIVE_SERIAL_FILE",
            "/workspace/core/build/daily-drive-r18/serial.txt")
    else:
        envp = os.environ.get("DRIVE_SERIAL_PORT", "0")
        if str(envp).isdigit() and int(envp) > 0:
            port = int(envp)
        else:
            sib = os.path.join(os.path.dirname(path), "serial.port")
            try:
                port = int(open(sib).read().strip())
            except (OSError, ValueError):
                port = 0
    return d15.Serial(path, port)


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: perf-round18.py <qmp> <serial-or-port>")
    port = int(sys.argv[1])
    serial_arg = sys.argv[2]
    q = d15.Qmp(port)
    ser = open_serial(serial_arg)
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)

    ser.read()
    q.type_line("wm fps")
    time.sleep(2.5)
    fps_txt = ser.read()
    try:
        blob = open(ser.path).read()[-8000:]
        fps_hits = [ln for ln in blob.splitlines() if ln.startswith("WM FPS")]
        if fps_hits:
            fps_txt = "\n".join(fps_hits[-12:])
    except OSError:
        pass

    # Event → present: focus flip FILES↔SET, OPID-paired PRES (not wait_mark).
    lat = []
    present = []
    for i in range(8):
        xy = (120, 55) if (i % 2) == 0 else (720, 55)
        try:
            wall = d15.timed_click(q, ser, xy[0], xy[1], "left",
                                   timeout=3.0, want_opid=True, label="focus")
            lat.append(wall if wall is not None else float("nan"))
            if d15.PHASE_TIMELINES:
                rec = d15.PHASE_TIMELINES[-1]
                if rec.get("present_ms") is not None:
                    present.append(rec["present_ms"])
        except Exception as e:
            lat.append(float("nan"))
            print("focus miss", e)

    # Sustained dump rate around a drag (guest-FB, not host chrome).
    tmp = "/tmp/oscortex-r18-perf-frames"
    os.makedirs(tmp, exist_ok=True)
    d15.place(q, ser, 120, 55)
    d15.button(q, 120, 55, "left", True)
    t1 = time.time()
    nd = 0
    dump_ms = []
    while time.time() - t1 < 8.0:
        p = os.path.join(tmp, "p%03d.png" % nd)
        s0 = time.time()
        d15.shot(q, p)
        dump_ms.append((time.time() - s0) * 1000.0)
        d15.place(q, ser, 120 + (nd % 6) * 8, 55)
        nd += 1
    d15.button(q, 120, 55, "left", False)
    wall = time.time() - t1
    dump_fps = nd / wall if wall > 0 else 0

    # Max/restore is the chrome-regen path (shadow + title), not focus patch.
    max_lat = []
    try:
        wall = d15.timed_click(q, ser, d15.FILES_MAX_XY[0], d15.FILES_MAX_XY[1],
                               "left", timeout=4.0, want_opid=True,
                               label="max_r18")
        if wall is not None:
            max_lat.append(wall)
        wall = d15.timed_click(q, ser, d15.FILES_MAX_MAXED_XY[0],
                               d15.FILES_MAX_MAXED_XY[1], "left", timeout=4.0,
                               want_opid=True, label="restore_r18")
        if wall is not None:
            max_lat.append(wall)
    except Exception as e:
        print("max/restore miss", e)

    q.type_line("wm pace")
    time.sleep(0.4)
    pace_txt = ser.read()
    try:
        blob = open(ser.path).read()[-4000:]
        pace_hits = [ln for ln in blob.splitlines() if ln.startswith("WM PACE")]
        if pace_hits:
            pace_txt = "\n".join(pace_hits[-4:])
    except OSError:
        pass

    clean = [x for x in lat if x == x]
    payload = {
        "round": 18,
        "baseline_de_pace_fps": 1.9,
        "wm_fps_serial": fps_txt[-400:],
        "wm_pace_serial": pace_txt[-400:],
        "focus_present_ms": {
            "n": len(clean),
            "samples": [round(x, 1) for x in clean],
            "median": round(statistics.median(clean), 1) if clean else None,
            "p95": round(sorted(clean)[max(0, int(len(clean) * 0.95) - 1)], 1)
            if clean else None,
            "note": "host inject→OPID-paired PRES wall_ms; not wait_mark",
        },
        "focus_guest_present_ms": {
            "n": len(present),
            "samples": [round(x, 1) for x in present],
            "median": round(statistics.median(present), 1) if present else None,
        },
        "max_restore_present_ms": {
            "n": len(max_lat),
            "samples": [round(x, 1) for x in max_lat],
            "median": round(statistics.median(max_lat), 1) if max_lat else None,
        },
        "guest_fb_dump": {
            "seconds": round(wall, 2),
            "frames": nd,
            "fps": round(dump_fps, 2),
            "dump_ms_median": round(statistics.median(dump_ms), 1)
            if dump_ms else None,
            "note": "QMP screendump rate, not compose fps",
        },
        "note": (
            "TCG: not a daily-drive or 50 fps claim. de-pace cost-bound "
            "is ~1.9 fps full present. Focus can be a border patch; "
            "max/restore is chrome regen. Dump fps is QMP, not compose."
        ),
    }
    path = os.path.join(art, "oscortex-round18-performance.json")
    open(path, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
