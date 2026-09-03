#!/usr/bin/env python3
"""Round 20: cold/warm menu+focus, drag fps/pixels, pointer transfer px.

Does not conflate the 50 fps cap with achieved fps.
Writes /opt/cursor/artifacts/oscortex-round20-performance.json
"""

import importlib.util
import json
import os
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

SCREEN_PX = 1280 * 720
SET_XYWH = (464, 40, 320, 280)
SET_TITLE = (624, 55)
SET_CARD0 = (464 + 132 + 44, 40 + 84 + 16)
SET_CARD1 = (464 + 228 + 44, 40 + 84 + 16)
FILES_TITLE = (120, 55)


def open_serial(serial_arg):
    port = 0
    path = serial_arg
    if str(serial_arg).isdigit():
        port = int(serial_arg)
        path = os.environ.get(
            "DRIVE_SERIAL_FILE",
            "/workspace/core/build/daily-drive-r20/serial.txt")
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
    last = None
    for _try in range(20):
        ser = d15.Serial(path, port)
        if ser.sock is not None:
            return ser
        last = "no socket"
        time.sleep(0.2)
    print("WARN: serial socket not connected after retries (%s)" % last)
    return d15.Serial(path, port)


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return round(s[max(0, int(len(s) * p) - 1)], 1)


def parse_dmg(blob):
    hits = [ln for ln in blob.splitlines() if ln.startswith("WM DMG ")]
    px = []
    regs = []
    full = []
    ptr = []
    for ln in hits:
        m = re.match(
            r"WM DMG ([0-9A-F]+) RG ([0-9A-F]+) FL ([0-9A-F]+)(?: PTR ([0-9A-F]+))?",
            ln)
        if not m:
            continue
        px.append(int(m.group(1), 16))
        regs.append(int(m.group(2), 16))
        full.append(int(m.group(3), 16))
        if m.group(4):
            ptr.append(int(m.group(4), 16))
    return {
        "lines": hits[-12:],
        "px": px,
        "regs": regs,
        "full": full,
        "ptr": ptr,
    }


def parse_phz(blob):
    lines = [ln for ln in blob.splitlines() if ln.startswith("OSGFX PHZ ")]
    return lines[-16:]


def parse_chrome(blob):
    miss = len(re.findall(r"^OSGFX CHROME MISS$", blob, re.M))
    hit = len(re.findall(r"^OSGFX CHROME HIT$", blob, re.M))
    overlay = len(re.findall(r"^OSGFX CHROME OVERLAY$", blob, re.M))
    focus = len(re.findall(r"^OSGFX CHROME FOCUS$", blob, re.M))
    return {"miss": miss, "hit": hit, "overlay": overlay, "focus": focus}


def timed_ops(q, ser, label, points, btn=None):
    walls = []
    presents = []
    t0 = time.time()
    n = 0
    for x, y in points:
        try:
            if btn:
                wall = d15.timed_click(q, ser, x, y, btn,
                                       timeout=3.0, want_opid=True,
                                       label=label)
            else:
                wall = d15.timed_place(q, ser, x, y, timeout=2.0, label=label)
            n += 1
            if wall is not None:
                walls.append(wall)
            if d15.PHASE_TIMELINES:
                rec = d15.PHASE_TIMELINES[-1]
                if rec.get("present_ms") is not None:
                    presents.append(rec["present_ms"])
        except Exception as e:
            print(label, "miss", e)
    dur = time.time() - t0
    return {
        "n": n,
        "seconds": round(dur, 3),
        "ops_per_sec": round(n / dur, 2) if dur > 0 else 0,
        "event_present_ms": {
            "n": len(walls),
            "p50": pct(walls, 0.50),
            "p95": pct(walls, 0.95),
            "max": round(max(walls), 1) if walls else None,
            "samples": [round(x, 1) for x in walls[:16]],
        },
        "guest_present_ms": {
            "n": len(presents),
            "p50": pct(presents, 0.50),
            "p95": pct(presents, 0.95),
            "max": round(max(presents), 1) if presents else None,
        },
    }


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: perf-round20.py <qmp> <serial-or-port>")
    port = int(sys.argv[1])
    ser = open_serial(sys.argv[2])
    q = d15.Qmp(port)
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)

    ser.read()
    try:
        blob0 = open(ser.path).read()
    except OSError:
        blob0 = ""
    chrome0 = parse_chrome(blob0)

    # Cold first wall / file menu / focus after this process's first clicks.
    cold_wall = timed_ops(q, ser, "menu_wall_cold", [(80, 400)], btn="right")
    try:
        q.key("esc")
    except Exception:
        pass
    time.sleep(0.12)
    cold_file = timed_ops(q, ser, "menu_file_cold", [(200, 180)], btn="right")
    try:
        q.key("esc")
    except Exception:
        pass
    time.sleep(0.12)
    cold_focus = timed_ops(q, ser, "focus_cold", [SET_TITLE], btn="left")

    q.type_line("wm dmg")
    time.sleep(0.25)
    ser.read()

    pointer_pts = [(80 + i * 16, 120 + (i % 5) * 8) for i in range(16)]
    pointer = timed_ops(q, ser, "pointer", pointer_pts)

    d15.place(q, ser, FILES_TITLE[0], FILES_TITLE[1])
    d15.button(q, FILES_TITLE[0], FILES_TITLE[1], "left", True)
    drag = timed_ops(q, ser, "drag",
                     [(FILES_TITLE[0] + i * 12, FILES_TITLE[1])
                      for i in range(12)])
    d15.button(q, FILES_TITLE[0] + 132, FILES_TITLE[1], "left", False)

    focus_pts = [FILES_TITLE if i % 2 == 0 else SET_TITLE for i in range(12)]
    focus = timed_ops(q, ser, "focus", focus_pts, btn="left")

    menu_pts = [(200, 200), (90, 400), (200, 200), (90, 400)]
    menu = timed_ops(q, ser, "menu", menu_pts, btn="right")
    try:
        q.key("esc")
    except Exception:
        pass
    time.sleep(0.15)

    max_pts = [d15.FILES_MAX_XY, d15.FILES_MAX_MAXED_XY]
    maxrest = timed_ops(q, ser, "max_restore", max_pts, btn="left")

    try:
        d15.press(q, ser, SET_CARD0[0], SET_CARD0[1], "left", "SET CARD",
                  timeout=2)
        d15.press(q, ser, SET_CARD1[0], SET_CARD1[1], "left", "SET CARD",
                  timeout=2)
    except Exception as e:
        print("set card miss", e)

    q.type_line("wm dmg")
    time.sleep(0.3)
    q.type_line("wm pace")
    time.sleep(0.4)
    pace_txt = ser.read()
    try:
        blob = open(ser.path).read()
    except OSError:
        blob = pace_txt
    dmg = parse_dmg(blob)
    dirty = dmg["px"][-48:]
    full_n = dmg["full"][-1] if dmg["full"] else 0
    mean_px = round(statistics.mean(dirty), 1) if dirty else None
    med_px = round(statistics.median(dirty), 1) if dirty else None
    chrome1 = parse_chrome(blob)

    q.type_line("wm fps")
    time.sleep(2.2)
    fps_txt = ser.read()
    try:
        blob2 = open(ser.path).read()[-8000:]
        fps_hits = [ln for ln in blob2.splitlines() if ln.startswith("WM FPS")]
        if fps_hits:
            fps_txt = "\n".join(fps_hits[-8:])
    except OSError:
        pass

    commit_w = None
    for ln in blob.splitlines():
        if "WM COMMIT" in ln and "W " in ln:
            m = re.search(r"W ([0-9A-F]{4}) H ([0-9A-F]{4})", ln)
            if m:
                commit_w = (int(m.group(1), 16), int(m.group(2), 16))

    payload = {
        "round": 20,
        "screen_px": SCREEN_PX,
        "cap_fps": 50,
        "set_tile": {"xywh": SET_XYWH, "last_commit_wh": commit_w},
        "note": (
            "Achieved ops/sec and transferred px/frame, not the 50 fps cap. "
            "No daily-drive claim from this file alone."
        ),
        "chrome_counts": {"before": chrome0, "after": chrome1},
        "phase_profile": parse_phz(blob),
        "cold": {
            "wall_menu": cold_wall,
            "file_menu": cold_file,
            "focus": cold_focus,
        },
        "pointer": pointer,
        "drag": drag,
        "focus": focus,
        "menu": menu,
        "max_restore": maxrest,
        "dirty": {
            "last_px": dirty[-8:],
            "mean_px": mean_px,
            "median_px": med_px,
            "vs_full": (round(mean_px / SCREEN_PX, 4) if mean_px else None),
            "full_fallbacks": full_n,
            "last_regs": dmg["regs"][-8:],
            "pointer_transfer_px": dmg["ptr"][-8:],
            "wm_dmg_lines": dmg["lines"],
        },
        "wm_pace_serial": [ln for ln in blob.splitlines()
                           if ln.startswith("WM PACE ")][-4:],
        "wm_fps_serial": fps_txt[-400:],
    }
    path = os.path.join(art, "oscortex-round20-performance.json")
    open(path, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
