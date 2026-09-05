#!/usr/bin/env python3
"""Round 38: 100 immediate first-frame captures after launcher show/hide.

Waits for GOP SCAN / FRAME generation after kind 7, then dumps immediately
(not a settled last shot). Double-dump compare rejects stale orange.
"""

import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "m36", os.path.join(HERE, "measure-round36.py"))
m36 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m36)
d15 = m36.d15
m37s = importlib.util.spec_from_file_location(
    "m37", os.path.join(HERE, "measure-round37.py"))
m37 = importlib.util.module_from_spec(m37s)
m37s.loader.exec_module(m37)
bar_s = importlib.util.spec_from_file_location(
    "bar38", os.path.join(HERE, "capture-barrier-round38.py"))
bar38 = importlib.util.module_from_spec(bar_s)
bar_s.loader.exec_module(bar38)

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r38")
KIND_LAUNCH = 7


def fire_f4(q):
    m36.qcode_edge(q, "f4", True)
    m36.qcode_edge(q, "f4", False)


def dismiss_esc(q):
    m36.qcode_edge(q, "esc", True)
    m36.qcode_edge(q, "esc", False)


def immediate_shot(q, ser, name):
    dest = os.path.join(ART, name)
    meta = bar38.shot_barrier(q, d15.shot, dest, ser)
    return dest, meta


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round38.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    if str(sys.argv[2]).isdigit():
        os.environ.setdefault(
            "DRIVE_SERIAL_FILE", os.path.join(RUN, "serial.txt"))
    ser = m36.m24.open_serial(sys.argv[2])
    os.makedirs(ART, exist_ok=True)
    try:
        q.key("esc")
    except Exception:
        pass
    m36.wallpaper_park(q, ser)
    m37.wait_catalog(ser)
    n = max(100, int(os.environ.get("DRIVE_CAPTURE_N", "100")))
    show_ok = 0
    hide_ok = 0
    first_stale = 0
    first_show = None
    first_hide = None
    walls = []
    t0 = time.time()
    for i in range(n):
        prev = m36.last_done_opid(ser)
        t_inj = time.time()
        fire_f4(q)
        ev, _w = m36.wait_done(ser, prev, KIND_LAUNCH, timeout=2.5)
        wall = (time.time() - t_inj) * 1000.0
        walls.append(wall)
        png, meta = immediate_shot(
            q, ser, "oscortex-round38-first-frame.png" if i == 0
            else "oscortex-round38-capture-show.png")
        proof = m37.analyze_launch(png, hide=False)
        proof["barrier"] = meta
        if meta.get("first_dump_stale"):
            first_stale += 1
        if proof.get("pass"):
            show_ok += 1
        if i == 0:
            first_show = proof
        dismiss_esc(q)
        time.sleep(0.01)
        hide_png, hide_meta = immediate_shot(
            q, ser, "oscortex-round38-capture-hide.png")
        hide_proof = m37.analyze_launch(hide_png, hide=True)
        hide_proof["barrier"] = hide_meta
        if hide_proof.get("pass"):
            hide_ok += 1
        if i == 0:
            first_hide = hide_proof
        print("cap", i, "show", proof.get("pass"), "hide",
              hide_proof.get("pass"), "stale", meta.get("first_dump_stale"),
              "ms", round(wall, 2))
    first_ok = bool(first_show and first_show.get("pass"))
    hide_first_ok = bool(first_hide and first_hide.get("pass"))
    payload = {
        "round": 38,
        "barrier": (
            "wait GOP VIRTIO SCAN / WM FRAME after kind 7, then immediate "
            "QMP dump; double-dump compare until two consecutive PNGs match"),
        "n": n,
        "show_ok": show_ok,
        "hide_ok": hide_ok,
        "first_show_pass": first_ok,
        "first_hide_pass": hide_first_ok,
        "first_dump_stale_n": first_stale,
        "used_settled_last_shot": False,
        "seconds": round(time.time() - t0, 3),
        "p95_ms": None,
        "first_show": first_show,
        "first_hide": first_hide,
        "pass": (
            show_ok >= n
            and hide_ok >= n
            and first_ok
            and hide_first_ok),
    }
    if walls:
        s = sorted(walls)
        payload["p95_ms"] = round(s[int(0.95 * (len(s) - 1))], 2)
        payload["max_ms"] = round(max(walls), 2)
    dest = os.path.join(ART, "oscortex-round38-capture.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print("wrote", dest)
    print(json.dumps({
        "n": n,
        "show_ok": show_ok,
        "hide_ok": hide_ok,
        "first_show": first_ok,
        "first_hide": hide_first_ok,
        "stale": first_stale,
        "pass": payload["pass"],
    }, indent=2))
    return 0 if payload["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
