#!/usr/bin/env python3
"""Round 28: pair each inject to virtio RESOURCE_FLUSH generation.

Waits for a new `VIRTIO SCAN ... <gen>` line after every pointer/drag/
scroll/menu/max inject. OPID→PRES is recorded as a secondary but is
not the pass criterion. Writes oscortex-round28-perf.json.
"""

import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "m24", os.path.join(HERE, "measure-round24.py"))
m24 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m24)
d15 = m24.d15

SCAN_RE = re.compile(
    r"VIRTIO SCAN ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+)")


def harvest(ser):
    ser.read()
    try:
        blob = open(ser.path, encoding="latin-1", errors="replace").read()
    except OSError:
        blob = ""
    return (blob or "") + "\n" + (ser.archive or "")


def last_scan(ser):
    gen = 0
    px = 0
    w = 0
    h = 0
    for m in SCAN_RE.finditer(harvest(ser)):
        gen = int(m.group(5), 16)
        w = int(m.group(3), 16)
        h = int(m.group(4), 16)
        px = w * h
    return gen, px, w, h


def wait_scan(ser, prev, timeout=3.0):
    t0 = time.time()
    while (time.time() - t0) < timeout:
        gen, px, w, h = last_scan(ser)
        if gen > prev:
            return gen, px, w, h, (time.time() - t0) * 1000.0
        time.sleep(0.01)
    return None


def burst(q, ser, label, points, btn=None):
    walls = []
    px_tail = []
    gen_tail = []
    paired = []
    t0 = time.time()
    for x, y in points:
        g0, _, _, _ = last_scan(ser)
        t_inj = time.time()
        try:
            if btn:
                d15.place(q, ser, x, y)
                time.sleep(0.02)
                d15.button(q, x, y, btn, True)
                time.sleep(0.03)
                d15.button(q, x, y, btn, False)
                if btn == "right":
                    try:
                        q.key("esc")
                    except Exception:
                        pass
            else:
                d15.place(q, ser, x, y)
        except Exception as e:
            print(label, "inject", e)
            continue
        got = wait_scan(ser, g0, timeout=2.5)
        if got is None:
            print(label, "unpaired-scan", x, y, "prev", g0)
            continue
        gen, px, w, h, _wait = got
        wall = (time.time() - t_inj) * 1000.0
        walls.append(wall)
        px_tail.append(px)
        gen_tail.append(gen)
        paired.append({
            "wall_ms": round(wall, 2),
            "scan_gen": gen,
            "scan_gen0": g0,
            "scan_px": px,
            "scan_w": w,
            "scan_h": h,
        })
    dur = time.time() - t0
    n = len(walls)
    walls_sorted = sorted(walls)

    def pct(p):
        if not walls_sorted:
            return None
        i = min(len(walls_sorted) - 1, int(round((p / 100.0) * (len(walls_sorted) - 1))))
        return round(walls_sorted[i], 2)

    return {
        "n": n,
        "seconds": round(dur, 3),
        "achieved_fps": round(n / dur, 2) if dur > 0 else 0,
        "ops_per_sec": round(n / dur, 2) if dur > 0 else 0,
        "scan_gen_tail": gen_tail[-8:],
        "scan_px_tail": px_tail[-8:],
        "paired_tail": paired[-8:],
        "event_present_ms": {
            "n": n,
            "p50": pct(50),
            "p95": pct(95),
            "max": round(walls_sorted[-1], 2) if walls_sorted else None,
        },
        "full_1280_flushes": sum(1 for p in px_tail if p >= (1280 * 720)),
        "label": label,
    }


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round28.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    ser = m24.open_serial(sys.argv[2])
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)
    try:
        q.key("esc")
    except Exception:
        pass
    # Open FILES so drag/scroll/max have a titled surface, not empty desk.
    d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
    time.sleep(0.05)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", True)
    time.sleep(0.04)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", False)
    time.sleep(0.8)
    d15.place(q, ser, 48, 520)
    time.sleep(0.1)
    ser.read()

    n = max(24, int(os.environ.get("DRIVE_PTR_N", "32")))
    pointer = burst(q, ser, "pointer",
                    [(36 + (i * 17) % 160, 480 + (i * 9) % 100)
                     for i in range(n)])
    drag_pts = [(120 + (i * 9) % 200, 55) for i in range(n)]
    d15.place(q, ser, drag_pts[0][0], drag_pts[0][1])
    d15.button(q, drag_pts[0][0], drag_pts[0][1], "left", True)
    drag = burst(q, ser, "drag", drag_pts[1:])
    d15.button(q, drag_pts[-1][0], drag_pts[-1][1], "left", False)
    scroll = burst(q, ser, "scroll",
                   [(120, 180 + (i * 11) % 80) for i in range(n // 2)],
                   btn="left")
    menu = burst(q, ser, "menu",
                 [(48 + (i * 11) % 100, 510 + (i * 5) % 80)
                  for i in range(n)],
                 btn="right")
    maxn = burst(q, ser, "max",
                 [(min(379, 48 + 400 - 78 + 9), 57)] * max(8, n // 6),
                 btn="left")

    dest_name = os.environ.get("OSCORTEX_PERF_OUT", "oscortex-round28-perf.json")
    payload = {
        "round": 28,
        "pairing": "VIRTIO SCAN generation (RESOURCE_FLUSH)",
        "path": os.environ.get("OSCORTEX_PERF_PATH", "venus-llvmpipe"),
        "renderer": os.environ.get("OSCORTEX_RENDERER", "llvmpipe"),
        "acceleration": False,
        "host_drm": os.path.exists("/dev/dri"),
        "pointer": pointer,
        "drag": drag,
        "scroll": scroll,
        "menu": menu,
        "max": maxn,
        "target_fps": 30,
        "target_p95_ms": 100,
        "gates": {
            "pointer_n": pointer["n"] >= 16,
            "drag_n": drag["n"] >= 8,
            "menu_n": menu["n"] >= 8,
            "drag_fps": drag["achieved_fps"] >= 8,
            "menu_fps": menu["achieved_fps"] >= 8,
            "drag_p95": (drag["event_present_ms"]["p95"] or 999) < 100,
            "menu_p95": (menu["event_present_ms"]["p95"] or 999) < 100,
            "no_full_drag": drag["full_1280_flushes"] == 0,
        },
    }
    dest = os.path.join(art, dest_name)
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps({
        "path": payload["path"],
        "pointer_fps": pointer["achieved_fps"],
        "drag_fps": drag["achieved_fps"],
        "scroll_fps": scroll["achieved_fps"],
        "menu_fps": menu["achieved_fps"],
        "max_fps": maxn["achieved_fps"],
        "pointer_p95": pointer["event_present_ms"]["p95"],
        "drag_p95": drag["event_present_ms"]["p95"],
        "menu_p95": menu["event_present_ms"]["p95"],
        "drag_full_1280": drag["full_1280_flushes"],
        "menu_full_1280": menu["full_1280_flushes"],
        "gates": payload["gates"],
    }, indent=2))
    print("wrote", dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
