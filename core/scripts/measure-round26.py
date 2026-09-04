#!/usr/bin/env python3
"""Round 26: achieved interactive present rate (not a cap) + p95 latency.

Measures pointer / drag / scroll / menu / max on the live daily-drive.
Reuses Round 24 pairing (OPID→PRES). Writes oscortex-round26-perf.json.
"""

import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "m24", os.path.join(HERE, "measure-round24.py"))
m24 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m24)
d15 = m24.d15


def burst_fps(q, ser, label, points, btn=None):
    """Drive as fast as pairing allows; report achieved presents/sec."""
    rec = m24.collect(q, ser, label, points, btn=btn, want_opid=True)
    n = rec["n"]
    sec = rec["seconds"] or 0.001
    rec["achieved_fps"] = round(n / sec, 2)
    rec["label"] = label
    return rec


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round26.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    ser = m24.open_serial(sys.argv[2])
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)
    d15.PHASE_TIMELINES.clear()
    try:
        q.key("esc")
    except Exception:
        pass
    d15.place(q, ser, 48, 520)
    time.sleep(0.1)
    ser.read()

    n = max(40, int(os.environ.get("DRIVE_PTR_N", "48")))
    pointer = burst_fps(q, ser, "pointer",
                        [(36 + (i * 17) % 160, 480 + (i * 9) % 100)
                         for i in range(n)])
    drag_pts = [(80 + (i * 9) % 200, 90) for i in range(n)]
    # Title-bar drag: hold left, move, release once after the burst.
    d15.place(q, ser, drag_pts[0][0], drag_pts[0][1])
    d15.button(q, drag_pts[0][0], drag_pts[0][1], "left", True)
    drag = burst_fps(q, ser, "drag", drag_pts[1:])
    d15.button(q, drag_pts[-1][0], drag_pts[-1][1], "left", False)
    scroll = burst_fps(q, ser, "scroll",
                       [(120, 180 + (i * 11) % 80) for i in range(n // 2)],
                       btn="left")
    menu = burst_fps(q, ser, "menu",
                     [(48 + (i * 11) % 100, 510 + (i * 5) % 80)
                      for i in range(n)],
                     btn="right")
    maxn = burst_fps(q, ser, "max",
                     [(min(379, 48 + 400 - 78 + 9), 57)] * max(8, n // 6),
                     btn="left")

    payload = {
        "round": 26,
        "path": os.environ.get("OSCORTEX_PERF_PATH", "cpu-tcg"),
        "pointer": pointer,
        "drag": drag,
        "scroll": scroll,
        "menu": menu,
        "max": maxn,
        "target_fps": 30,
        "host_allows_30": True,
        "gates": {
            "pointer_n": pointer["n"] >= 20,
            "pointer_fps": pointer["achieved_fps"] >= 8,
            "pointer_p95": (pointer["event_present_ms"]["p95"] or 999) < 250,
            "menu_n": menu["n"] >= 20,
            "menu_p95": (menu["event_present_ms"]["p95"] or 999) < 250,
        },
    }
    dest = os.path.join(art, "oscortex-round26-perf.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps({
        "pointer_fps": pointer["achieved_fps"],
        "drag_fps": drag["achieved_fps"],
        "scroll_fps": scroll["achieved_fps"],
        "menu_fps": menu["achieved_fps"],
        "max_fps": maxn["achieved_fps"],
        "pointer_p95": pointer["event_present_ms"]["p95"],
        "menu_p95": menu["event_present_ms"]["p95"],
        "gates": payload["gates"],
    }, indent=2))
    print("wrote", dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
