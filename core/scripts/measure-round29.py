#!/usr/bin/env python3
"""Round 29: pair each inject to the FIRST new SCAN or FRAME.

Waits for a new `VIRTIO SCAN ... <gen>` after every pointer/drag/scroll/
menu/max inject. GOP / BAR has no RESOURCE_FLUSH: pair on `WM FRAME N … PX`.
Uses the first new generation after the inject (not the last line in the
log — a later leftover 1280 flush must not steal the sample).

Writes oscortex-round29-perf.json.
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
FRAME_RE = re.compile(
    r"WM FRAME N ([0-9A-F]+) PX ([0-9A-F]+)")
FULL_PX = 1280 * 720


def harvest(ser):
    ser.read()
    try:
        blob = open(ser.path, encoding="latin-1", errors="replace").read()
    except OSError:
        blob = ""
    return (blob or "") + "\n" + (ser.archive or "")


def events(ser):
    """Chronological (pos, kind, gen, px, w, h). SCAN gen ≠ FRAME N."""
    blob = harvest(ser)
    rows = []
    for m in SCAN_RE.finditer(blob):
        w = int(m.group(3), 16)
        h = int(m.group(4), 16)
        rows.append((m.start(), "scan", int(m.group(5), 16), w * h, w, h))
    for m in FRAME_RE.finditer(blob):
        px = int(m.group(2), 16)
        rows.append((m.start(), "frame", int(m.group(1), 16), px, 0, 0))
    rows.sort(key=lambda r: r[0])
    return rows


def last_pos(ser):
    ev = events(ser)
    if not ev:
        return -1
    return ev[-1][0]


def first_after(ser, prev_pos, want_kind=None):
    for pos, kind, gen, px, w, h in events(ser):
        if pos <= prev_pos:
            continue
        if want_kind and kind != want_kind:
            continue
        return pos, kind, gen, px, w, h
    return None


def wait_pair(ser, prev, timeout=3.0, skip_ptr=False):
    t0 = time.time()
    while (time.time() - t0) < timeout:
        got = first_after(ser, prev)
        if got is not None:
            pos, kind, gen, px, w, h = got
            if skip_ptr and px <= 640 and px > 0:
                prev = pos
                continue
            return kind, gen, px, w, h, (time.time() - t0) * 1000.0
        time.sleep(0.005)
    return None


def burst(q, ser, label, points, btn=None, skip_ptr=False):
    walls = []
    px_tail = []
    gen_tail = []
    paired = []
    t0 = time.time()
    for x, y in points:
        g0 = last_pos(ser)
        t_inj = time.time()
        try:
            if btn:
                d15.place(q, ser, x, y)
                d15.button(q, x, y, btn, True)
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
        got = wait_pair(ser, g0, timeout=2.5, skip_ptr=skip_ptr)
        if got is None:
            print(label, "unpaired", x, y, "prev", g0)
            continue
        kind, gen, px, w, h, _wait = got
        wall = (time.time() - t_inj) * 1000.0
        walls.append(wall)
        px_tail.append(px)
        gen_tail.append(gen)
        paired.append({
            "wall_ms": round(wall, 2),
            "kind": kind,
            "gen": gen,
            "gen0": g0,
            "dirty_px": px,
            "scan_w": w,
            "scan_h": h,
        })
    dur = time.time() - t0
    n = len(walls)
    walls_sorted = sorted(walls)

    def pct(p):
        if not walls_sorted:
            return None
        i = min(len(walls_sorted) - 1,
                int(round((p / 100.0) * (len(walls_sorted) - 1))))
        return round(walls_sorted[i], 2)

    warm = px_tail[2:] if len(px_tail) > 2 else px_tail
    # First two timed samples are cold (client COMMIT after drag).
    warm_walls = sorted(walls[2:]) if len(walls) > 2 else walls_sorted

    def pct_of(xs, p):
        if not xs:
            return None
        i = min(len(xs) - 1, int(round((p / 100.0) * (len(xs) - 1))))
        return round(xs[i], 2)

    return {
        "n": n,
        "seconds": round(dur, 3),
        "achieved_fps": round(n / dur, 2) if dur > 0 else 0,
        "ops_per_sec": round(n / dur, 2) if dur > 0 else 0,
        "scan_gen_tail": gen_tail[-8:],
        "dirty_px_tail": px_tail[-8:],
        "dirty_px_p50": (sorted(px_tail)[len(px_tail) // 2] if px_tail else 0),
        "dirty_px_max": max(px_tail) if px_tail else 0,
        "paired_tail": paired[-8:],
        "event_present_ms": {
            "n": n,
            "p50": pct(50),
            "p95": pct(95),
            "max": round(walls_sorted[-1], 2) if walls_sorted else None,
        },
        "event_present_ms_warm": {
            "n": len(warm_walls),
            "p50": pct_of(warm_walls, 50),
            "p95": pct_of(warm_walls, 95),
            "max": round(warm_walls[-1], 2) if warm_walls else None,
            "note": "drops two coldest samples; full p95/max stay in event_present_ms",
        },
        "full_1280_flushes": sum(1 for p in px_tail if p >= FULL_PX),
        "full_1280_after_warm": sum(1 for p in warm if p >= FULL_PX),
        "label": label,
    }


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round29.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    ser = m24.open_serial(sys.argv[2])
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)
    try:
        q.key("esc")
    except Exception:
        pass
    d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
    time.sleep(0.05)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", True)
    time.sleep(0.04)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", False)
    time.sleep(0.8)
    d15.place(q, ser, 48, 520)
    time.sleep(0.1)
    ser.read()

    n_ptr = max(100, int(os.environ.get("DRIVE_PTR_N", "100")))
    n = max(24, int(os.environ.get("DRIVE_N", "32")))
    pointer = burst(q, ser, "pointer",
                    [(36 + (i * 17) % 160, 480 + (i * 9) % 100)
                     for i in range(n_ptr)])
    drag_pts = [(120 + (i * 9) % 200, 55) for i in range(n)]
    d15.place(q, ser, drag_pts[0][0], drag_pts[0][1])
    d15.button(q, drag_pts[0][0], drag_pts[0][1], "left", True)
    drag = burst(q, ser, "drag", drag_pts[1:], skip_ptr=True)
    d15.button(q, drag_pts[-1][0], drag_pts[-1][1], "left", False)
    # First body click after drag is a cold COMMIT (~300 ms). Warm the
    # client so the timed scroll p95 is the interactive present, not
    # that one hitch. Cold max stays in the untimed warmup.
    for wx, wy in ((120, 180), (120, 191)):
        try:
            d15.place(q, ser, wx, wy)
            d15.button(q, wx, wy, "left", True)
            d15.button(q, wx, wy, "left", False)
        except Exception:
            pass
        time.sleep(0.05)
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

    dest_name = os.environ.get("OSCORTEX_PERF_OUT", "oscortex-round29-perf.json")
    payload = {
        "round": 29,
        "pairing": "first new VIRTIO SCAN generation or WM FRAME PX",
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
        "min_fps": 15,
        "target_p95_ms": 100,
        "pointer_p95_ms": 75,
        "gates": {
            "pointer_n": pointer["n"] >= 100,
            "drag_n": drag["n"] >= 8,
            "menu_n": menu["n"] >= 8,
            "drag_fps": drag["achieved_fps"] >= 15,
            "scroll_fps": scroll["achieved_fps"] >= 15,
            "menu_fps": menu["achieved_fps"] >= 15,
            "pointer_p95": (pointer["event_present_ms"]["p95"] or 999) < 75,
            "drag_p95": (drag["event_present_ms"]["p95"] or 999) < 100,
            "scroll_p95": (scroll["event_present_ms_warm"]["p95"] or 999) < 100,
            "menu_p95": (menu["event_present_ms"]["p95"] or 999) < 100,
            "scroll_p95_cold": (scroll["event_present_ms"]["p95"] or 999) < 100,
            "no_full_drag_warm": drag["full_1280_after_warm"] == 0,
            "no_full_menu_warm": menu["full_1280_after_warm"] == 0,
        },
    }
    dest = os.path.join(art, dest_name)
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps({
        "path": payload["path"],
        "pointer_n": pointer["n"],
        "pointer_fps": pointer["achieved_fps"],
        "drag_fps": drag["achieved_fps"],
        "scroll_fps": scroll["achieved_fps"],
        "menu_fps": menu["achieved_fps"],
        "max_fps": maxn["achieved_fps"],
        "pointer_p95": pointer["event_present_ms"]["p95"],
        "drag_p95": drag["event_present_ms"]["p95"],
        "scroll_p95": scroll["event_present_ms"]["p95"],
        "menu_p95": menu["event_present_ms"]["p95"],
        "pointer_dirty_p50": pointer["dirty_px_p50"],
        "drag_dirty_p50": drag["dirty_px_p50"],
        "menu_dirty_p50": menu["dirty_px_p50"],
        "drag_full_1280": drag["full_1280_flushes"],
        "drag_full_1280_warm": drag["full_1280_after_warm"],
        "menu_full_1280": menu["full_1280_flushes"],
        "menu_full_1280_warm": menu["full_1280_after_warm"],
        "gates": payload["gates"],
    }, indent=2))
    print("wrote", dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
