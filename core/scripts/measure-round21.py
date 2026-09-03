#!/usr/bin/env python3
"""Round 21: first-drag / pointer / menu / damage / FILES OPEN.

>=20 fresh first drags, >=100 pointer, >=100 menu open/close.
Writes /opt/cursor/artifacts/oscortex-round21-performance.json
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
FILES_TITLE = (120, 55)
SET_TITLE = (624, 55)
OPEN_XY = (364, 196)
CTX_XY = (300, 180)


def open_serial(serial_arg):
    port = 0
    path = serial_arg
    if str(serial_arg).isdigit():
        port = int(serial_arg)
        path = os.environ.get(
            "DRIVE_SERIAL_FILE",
            "/workspace/core/build/daily-drive-r21/serial.txt")
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
    cum = []
    cptr = []
    cons = []
    for ln in hits:
        m = re.match(
            r"WM DMG ([0-9A-F]+) RG ([0-9A-F]+) FL ([0-9A-F]+)"
            r"(?: PTR ([0-9A-F]+))?"
            r"(?: CUM ([0-9A-F]+))?"
            r"(?: CRG ([0-9A-F]+))?"
            r"(?: CFL ([0-9A-F]+))?"
            r"(?: CPTR ([0-9A-F]+))?"
            r"(?: CONS ([0-9A-F]+))?",
            ln)
        if not m:
            continue
        px.append(int(m.group(1), 16))
        regs.append(int(m.group(2), 16))
        full.append(int(m.group(3), 16))
        if m.group(4):
            ptr.append(int(m.group(4), 16))
        if m.group(5):
            cum.append(int(m.group(5), 16))
        if m.group(8):
            cptr.append(int(m.group(8), 16))
        if m.group(9):
            cons.append(int(m.group(9), 16))
    return {
        "lines": hits[-16:],
        "px": px,
        "regs": regs,
        "full": full,
        "ptr": ptr,
        "cum": cum,
        "cptr": cptr,
        "cons": cons,
    }


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
            "samples": [round(x, 1) for x in walls[:24]],
        },
        "guest_present_ms": {
            "n": len(presents),
            "p50": pct(presents, 0.50),
            "p95": pct(presents, 0.95),
            "max": round(max(presents), 1) if presents else None,
        },
    }


def first_drags(q, ser, n=22):
    walls = []
    presents = []
    for i in range(n):
        if i > 0:
            try:
                d15.press(q, ser, d15.FILES_CLOSE_XY[0], d15.FILES_CLOSE_XY[1],
                          "left", "WM CLOSE", timeout=4)
            except Exception as e:
                print("close miss", i, e)
            time.sleep(0.25)
            try:
                d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                          "left", "FILES READY", timeout=8)
            except Exception as e:
                print("relaunch miss", i, e)
                continue
            time.sleep(0.35)
        d15.place(q, ser, FILES_TITLE[0], FILES_TITLE[1])
        time.sleep(0.08)
        d15.button(q, FILES_TITLE[0], FILES_TITLE[1], "left", True)
        time.sleep(0.12)
        nx = FILES_TITLE[0] + 28
        ny = FILES_TITLE[1]
        ax, ay = d15.abs_xy(nx, ny)
        wall = d15.pair_inject(q, ser, [
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}},
        ], 3.0, want_opid=True, label="first_drag")
        d15.button(q, nx, ny, "left", False)
        time.sleep(0.08)
        if wall is not None:
            walls.append(wall)
        if d15.PHASE_TIMELINES:
            rec = d15.PHASE_TIMELINES[-1]
            if rec.get("present_ms") is not None:
                presents.append(rec["present_ms"])
        print("first_drag", i, wall)
    return {
        "n": len(walls),
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


def files_open_proof(q, ser):
    marked = ser.read()
    d15.place(q, ser, CTX_XY[0], CTX_XY[1])
    time.sleep(0.12)
    d15.button(q, CTX_XY[0], CTX_XY[1], "right", True)
    time.sleep(0.05)
    d15.button(q, CTX_XY[0], CTX_XY[1], "right", False)
    d15.wait_mark(ser, "FILES MENU", marked, 4)
    marked = ser.read()
    d15.place(q, ser, OPEN_XY[0], OPEN_XY[1])
    time.sleep(0.12)
    d15.button(q, OPEN_XY[0], OPEN_XY[1], "left", True)
    time.sleep(0.05)
    d15.button(q, OPEN_XY[0], OPEN_XY[1], "left", False)
    ok = d15.wait_mark(ser, "FILES OPEN", marked, 4)
    blob = ser.read()
    cat = "FILES CAT " in blob or "FILES CAT " in open(ser.path).read()[-4000:]
    return {
        "opened": bool(ok),
        "cat": bool(cat),
        "refused": "FILES OPEN REFUSED" in blob,
    }


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round21.py <qmp> <serial-or-port>")
    port = int(sys.argv[1])
    ser = open_serial(sys.argv[2])
    q = d15.Qmp(port)
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)

    first = first_drags(q, ser, 22)

    pointer_pts = [(80 + (i * 17) % 900, 110 + (i % 7) * 9) for i in range(110)]
    pointer = collect(q, ser, "pointer", pointer_pts, want_opid=False)

    menu_pts = []
    for i in range(55):
        menu_pts.append((200, 200))
        menu_pts.append((90, 400))
    menu = collect(q, ser, "menu", menu_pts, btn="right", want_opid=True)
    try:
        q.key("esc")
    except Exception:
        pass
    time.sleep(0.15)

    q.type_line("wm dmg")
    time.sleep(0.3)
    open_proof = files_open_proof(q, ser)
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

    payload = {
        "round": 21,
        "screen_px": SCREEN_PX,
        "note": (
            "No daily-drive claim from this file alone. "
            "First-drag is one step after a fresh FILES launch."
        ),
        "first_drag": first,
        "pointer": pointer,
        "menu": menu,
        "files_open": open_proof,
        "dirty": {
            "last_px": dmg["px"][-8:],
            "pointer_transfer_px": dmg["ptr"][-8:],
            "cumulative_px": dmg["cum"][-4:],
            "cumulative_ptr": dmg["cptr"][-4:],
            "consumed": dmg["cons"][-4:],
            "wm_dmg_lines": dmg["lines"],
            "ptr_640": any(v == 640 for v in dmg["ptr"][-16:]),
        },
        "wm_pace_serial": [ln for ln in blob.splitlines()
                           if ln.startswith("WM PACE ")][-4:],
        "faults": len(re.findall(r"M1 FAULT", blob)),
        "reaps": len(re.findall(r"WM REAP", blob)),
        "oom": len(re.findall(r"OOM", blob)),
    }
    path = os.path.join(art, "oscortex-round21-performance.json")
    open(path, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
