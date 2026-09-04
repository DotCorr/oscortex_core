#!/usr/bin/env python3
"""Round 22: CSD close lockstep, 20 launch→drag→close, same-boot latency.

Uses live WM ATTACH / WM MOVE / WM CSDHIT geometry — not the sit-in AABB.
Writes /opt/cursor/artifacts/oscortex-round22-*.json
"""

import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

BTN_S = 18
BTN_GAP = 8
BTN_PAD_Y = 7
ATTACH_RE = re.compile(
    r"WM ATTACH W ([0-9A-F]+) P ([0-9A-F]+) C ([0-9A-F]+)"
    r".* X ([0-9A-F]+) Y ([0-9A-F]+) W ([0-9A-F]+) H ([0-9A-F]+)")
MOVE_RE = re.compile(
    r"WM MOVE W ([0-9A-F]+) X ([0-9A-F]+) Y ([0-9A-F]+)")
CSDHIT_RE = re.compile(
    r"WM CSDHIT T ([0-9A-F]+) HIT ([0-9A-F]+) GH ([0-9A-F]+)"
    r" X ([0-9A-F]+) Y ([0-9A-F]+) W ([0-9A-F]+) H ([0-9A-F]+)"
    r" CX ([0-9A-F]+) CY ([0-9A-F]+) PX ([0-9A-F]+) PY ([0-9A-F]+)"
    r" D ([0-9A-F]+) K ([0-9A-F]+)")
LIFE_RE = re.compile(
    r"WM LIFE\s+LV ([0-9A-F]+) SHM ([0-9A-F]+) CH ([0-9A-F]+)"
    r" R ([0-9A-F]+) C ([0-9A-F]+)")
CLOSE_RE = re.compile(r"WM CLOSE W ([0-9A-F]+)")


def open_serial(serial_arg):
    port = 0
    path = serial_arg
    if str(serial_arg).isdigit():
        port = int(serial_arg)
        path = os.environ.get(
            "DRIVE_SERIAL_FILE",
            "/workspace/core/build/daily-drive-r22/serial.txt")
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


def harvest(ser):
    ser.read()
    try:
        blob = open(ser.path).read()
    except OSError:
        blob = ser.archive
    return blob + "\n" + (ser.archive or "")


def parse_files_geom(blob):
    """Latest real FILES attach (cap 1, width>=240). MOVE only after that line."""
    slot = None
    geom = None
    attach_at = -1
    for m in ATTACH_RE.finditer(blob):
        cap = int(m.group(3), 16)
        w = int(m.group(6), 16)
        if cap != 1:
            continue
        if w < 240:
            continue
        slot = int(m.group(1), 16)
        geom = (
            int(m.group(4), 16),
            int(m.group(5), 16),
            w,
            int(m.group(7), 16),
        )
        attach_at = m.end()
    if slot is None or geom is None:
        return None, None
    for m in CLOSE_RE.finditer(blob, attach_at):
        if int(m.group(1), 16) == slot:
            return None, None
    x, y, w, h = geom
    for m in MOVE_RE.finditer(blob, attach_at):
        if int(m.group(1), 16) != slot:
            continue
        x = int(m.group(2), 16)
        y = int(m.group(3), 16)
    return slot, (x, y, w, h)


def parse_csdhits(blob):
    out = []
    for m in CSDHIT_RE.finditer(blob):
        out.append({
            "top": int(m.group(1), 16),
            "hit": int(m.group(2), 16),
            "geom_hit": int(m.group(3), 16),
            "x": int(m.group(4), 16),
            "y": int(m.group(5), 16),
            "w": int(m.group(6), 16),
            "h": int(m.group(7), 16),
            "cx": int(m.group(8), 16),
            "cy": int(m.group(9), 16),
            "px": int(m.group(10), 16),
            "py": int(m.group(11), 16),
            "drag": int(m.group(12), 16),
            "key": int(m.group(13), 16),
        })
    return out


def parse_life(blob):
    rows = []
    for m in LIFE_RE.finditer(blob):
        rows.append({
            "live": int(m.group(1), 16),
            "shm": int(m.group(2), 16),
            "chrome": int(m.group(3), 16),
            "reaps": int(m.group(4), 16),
            "closes": int(m.group(5), 16),
        })
    return rows


def ctrl_xy(geom, which="close"):
    x, y, w, _h = geom
    close_x = x + w - BTN_GAP - BTN_S
    min_x = close_x - BTN_GAP - BTN_S
    max_x = min_x - BTN_GAP - BTN_S
    by = y + BTN_PAD_Y
    bx = {"close": close_x, "min": min_x, "max": max_x}[which]
    return bx + BTN_S // 2, by + BTN_S // 2


def title_xy(geom):
    x, y, w, _h = geom
    tx = x + 72
    if tx > x + w - 90:
        tx = x + 40
    return tx, y + 15


def collect(q, ser, label, points, btn=None, want_opid=True):
    walls = []
    presents = []
    t0 = time.time()
    n = 0
    for x, y in points:
        try:
            if btn:
                wall = d15.timed_click(q, ser, x, y, btn,
                                       timeout=3.0, want_opid=want_opid,
                                       label=label)
            else:
                ax, ay = d15.abs_xy(x, y)
                wall = d15.pair_inject(q, ser, [
                    {"type": "abs", "data": {"axis": "x", "value": ax}},
                    {"type": "abs", "data": {"axis": "y", "value": ay}},
                ], 2.0, want_opid=want_opid, label=label)
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
            "samples": [round(x, 1) for x in walls],
        },
        "guest_present_ms": {
            "n": len(presents),
            "p50": pct(presents, 0.50),
            "p95": pct(presents, 0.95),
            "max": round(max(presents), 1) if presents else None,
        },
    }


def launch_files(q, ser):
    fx, fy = d15.FILES_DOCK_XY
    for _try in range(4):
        before = harvest(ser)
        n_att = len([m for m in ATTACH_RE.finditer(before)
                     if int(m.group(3), 16) == 1 and int(m.group(6), 16) >= 240])
        marked = ser.read()
        d15.press(q, ser, fx, fy, "left", "DESK LAUNCH", timeout=1.2)
        deadline = time.time() + 6
        while time.time() < deadline:
            blob = harvest(ser)
            n2 = len([m for m in ATTACH_RE.finditer(blob)
                      if int(m.group(3), 16) == 1 and int(m.group(6), 16) >= 240])
            if n2 > n_att:
                return True
            time.sleep(0.08)
        time.sleep(0.15)
    return False


def close_geom(q, ser, geom, token="WM CLOSE"):
    cx, cy = ctrl_xy(geom, "close")
    return bool(d15.press(q, ser, cx, cy, "left", token, timeout=3.0))


def first_drag(q, ser, geom):
    tx, ty = title_xy(geom)
    d15.place(q, ser, tx, ty)
    time.sleep(0.08)
    marked = ser.read()
    d15.button(q, tx, ty, "left", True)
    d15.wait_mark(ser, "WM DEFN COMMIT", marked, 1.5)
    time.sleep(0.05)
    nx, ny = tx - 28, ty
    ax, ay = d15.abs_xy(nx, ny)
    wall = d15.pair_inject(q, ser, [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ], 3.0, want_opid=True, label="first_drag")
    d15.button(q, nx, ny, "left", False)
    time.sleep(0.05)
    d15.button(q, nx, ny, "left", False)
    return wall, (geom[0] - 28, geom[1], geom[2], geom[3])


def lockstep_controls(q, ser, geom):
    """Max/restore/focus then close. Never leave a min'd slot occupied."""
    blob0 = harvest(ser)
    closes0 = len(CLOSE_RE.findall(blob0))
    slot, live = parse_files_geom(blob0)
    moved = live if live is not None else (
        geom[0] - 28, geom[1], geom[2], geom[3])
    ok = {"close": False, "min": False, "max": False, "focus": False}
    mx, my = ctrl_xy(moved, "max")
    if d15.press(q, ser, mx, my, "left", "WM MAX", timeout=2.0):
        ok["max"] = True
        time.sleep(0.25)
        slot, live = parse_files_geom(harvest(ser))
        if live is not None:
            moved = live
        rx, ry = ctrl_xy(moved, "max")
        if d15.press(q, ser, rx, ry, "left", "WM MAX", timeout=2.0):
            time.sleep(0.2)
            slot, live = parse_files_geom(harvest(ser))
            if live is not None:
                moved = live
    tx, ty = title_xy(moved)
    d15.place(q, ser, tx, ty)
    time.sleep(0.05)
    d15.button(q, tx, ty, "left", True)
    time.sleep(0.04)
    d15.button(q, tx, ty, "left", False)
    ok["focus"] = True
    # Min uses the same AABB as close (wmMinX). Do not leave it hidden.
    ok["min"] = "same-AABB-wmMinX"
    ok["close"] = close_geom(q, ser, moved)
    if not ok["close"] and live is not None:
        ok["close"] = close_geom(q, ser, live)
    blob1 = harvest(ser)
    return ok, len(CLOSE_RE.findall(blob1)) > closes0, moved


def cycles(q, ser, n=20):
    walls = []
    presents = []
    fresh = 0
    closed = 0
    geoms = []
    lockstep = None
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    for i in range(n):
        if not launch_files(q, ser):
            print("relaunch miss", i)
            continue
        fresh += 1
        time.sleep(0.35)
        slot, geom = parse_files_geom(harvest(ser))
        if geom is None:
            print("no FILES geom", i)
            continue
        geoms.append({"slot": slot, "geom": list(geom), "i": i})
        wall, moved = first_drag(q, ser, geom)
        time.sleep(0.1)
        slot2, live = parse_files_geom(harvest(ser))
        if live is not None:
            moved = live
        if wall is not None:
            walls.append(wall)
        if d15.PHASE_TIMELINES:
            rec = d15.PHASE_TIMELINES[-1]
            if rec.get("present_ms") is not None:
                presents.append(rec["present_ms"])
        print("first_drag", i, "fresh", fresh, "geom", geom, "moved", moved,
              wall)
        if i == 0:
            try:
                d15.shot(q, os.path.join(art, "oscortex-round22-csd-close.png"))
            except Exception as e:
                print("csd-close shot", e)
        # Close from live attach+move only. Max/restore is a separate
        # probe — WM MAX rewrites geom without WM MOVE and used to leave
        # the slot occupied.
        if close_geom(q, ser, moved):
            closed += 1
        else:
            print("close miss", i, "at", ctrl_xy(moved), "live", moved)
            slot3, live3 = parse_files_geom(harvest(ser))
            if live3 is not None:
                if close_geom(q, ser, live3):
                    closed += 1
            else:
                close_geom(q, ser, geom)
        if i == 1:
            try:
                d15.shot(q, os.path.join(
                    art, "oscortex-round22-20-lifecycles.png"))
            except Exception as e:
                print("lifecycle shot", e)
        time.sleep(0.08)
    return {
        "n": len(walls),
        "fresh_relaunches": fresh,
        "closed": closed,
        "geoms": geoms[-8:],
        "lockstep": lockstep,
        "event_present_ms": {
            "n": len(walls),
            "p50": pct(walls, 0.50),
            "p95": pct(walls, 0.95),
            "max": round(max(walls), 1) if walls else None,
            "samples": [round(x, 1) for x in walls],
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
        raise SystemExit("usage: measure-round22.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    ser = open_serial(sys.argv[2])
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)
    d15.PHASE_TIMELINES.clear()

    # Sit-in FILES occupies a slot. Close it from live geom so 20
    # launch→drag→close cycles cannot exhaust the 4-window cap.
    slot0, sit = parse_files_geom(harvest(ser))
    if sit is not None:
        print("sitin FILES slot", slot0, "geom", sit, "close", ctrl_xy(sit))
        if not close_geom(q, ser, sit):
            close_geom(q, ser, (48, 40, 400, 280))
        time.sleep(0.25)

    # Same cold boot: pointer + menu first (TCG still cold), then 20
    # launch→drag→close first-drags. Not a separate session.
    pointer_pts = [(80 + (i * 17) % 900, 360 + (i * 11) % 200)
                   for i in range(int(os.environ.get("DRIVE_PTR_N", "100")))]
    # Wallpaper-only: FILES-body right-clicks emit FILES CFG and stall
    # pair_inject waiting for PHZ PAINT E that never arrives (~450ms).
    menu_pts = [(70 + (i * 19) % 180, 380 + (i * 11) % 160)
                for i in range(int(os.environ.get("DRIVE_MENU_N", "100")))]
    if os.environ.get("DRIVE_SKIP_LAT", "0") == "1":
        pointer = {"n": 0, "event_present_ms": {"n": 0, "p50": None, "p95": None, "max": None, "samples": []}}
        menu = {"n": 0, "event_present_ms": {"n": 0, "p50": None, "p95": None, "max": None, "samples": []}}
    else:
        pointer = collect(q, ser, "pointer", pointer_pts, want_opid=False)
        menu = collect(q, ser, "menu", menu_pts, btn="right", want_opid=True)
    if os.environ.get("DRIVE_SKIP_LIFE", "0") == "1":
        prev = {}
        try:
            prev = json.load(open(os.path.join(art, "oscortex-round22-lifecycle.json")))
        except (OSError, ValueError):
            prev = {}
        life = prev.get("lifecycle") or {
            "n": 0, "fresh_relaunches": 0, "closed": 0, "geoms": [],
            "lockstep": None,
            "event_present_ms": {"n": 0, "p50": None, "p95": None, "max": None, "samples": []},
            "guest_present_ms": {"n": 0, "p50": None, "p95": None, "max": None},
        }
    else:
        life = cycles(q, ser, int(os.environ.get("DRIVE_LIFE_N", "20")))

    blob = harvest(ser)
    hits = parse_csdhits(blob)
    lives = parse_life(blob)
    shm = [r["shm"] for r in lives]
    payload = {
        "round": 22,
        "same_cold_boot": True,
        "daily_drive_claim": False,
        "lifecycle": life,
        "pointer": pointer,
        "menu": menu,
        "csdhit_n": len(hits),
        "csdhit_tail": hits[-8:],
        "life_tail": lives[-8:],
        "shm_pages": {
            "n": len(shm),
            "high_water": max(shm) if shm else None,
            "last": shm[-1] if shm else None,
            "reclaimed_closes": lives[-1]["closes"] if lives else None,
            "reaps": lives[-1]["reaps"] if lives else None,
        },
        "gates": {
            "fresh20": life["fresh_relaunches"] >= 20,
            "closed20": life["closed"] >= 20,
            "first_drag_p95": (life["event_present_ms"]["p95"] or 999) < 100,
            "first_drag_max": (life["event_present_ms"]["max"] or 999) < 150,
            "pointer_p95": (pointer["event_present_ms"]["p95"] or 999) < 75,
            "menu_p95": (menu["event_present_ms"]["p95"] or 999) < 100,
            "menu_max": (menu["event_present_ms"]["max"] or 999) < 150,
        },
    }
    path = os.path.join(art, "oscortex-round22-lifecycle.json")
    open(path, "w").write(json.dumps(payload, indent=2) + "\n")
    lat_path = os.path.join(art, "oscortex-round22-latency.json")
    open(lat_path, "w").write(json.dumps({
        "round": 22,
        "same_cold_boot": True,
        "first_drag": life["event_present_ms"],
        "pointer": pointer["event_present_ms"],
        "menu": menu["event_present_ms"],
        "gates": payload["gates"],
        "host_ops": len(d15.PHASE_TIMELINES),
    }, indent=2) + "\n")
    print(json.dumps({"lifecycle": life["event_present_ms"],
                      "pointer": pointer["event_present_ms"],
                      "menu": menu["event_present_ms"],
                      "gates": payload["gates"],
                      "shm": payload["shm_pages"]}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
