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
FILES_GEOM = (48, 40, 400, 280)
BTN_S = 18
BTN_GAP = 8
SET_LEFT = 464


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


def files_close_xy(dx=0):
    """CSD close-disc centre, pinned west of SET's left AABB."""
    x, y, w, _h = FILES_GEOM
    bx = x + dx + w - BTN_GAP - BTN_S
    by = y + BTN_GAP
    cx = bx + 4
    if cx + 2 >= SET_LEFT:
        cx = SET_LEFT - 8
    return cx, by + BTN_S // 2


def _click_close(q, ser, cx, cy):
    marked = ser.read()
    d15.place(q, ser, cx, cy)
    time.sleep(0.06)
    d15.button(q, cx, cy, "left", True)
    time.sleep(0.04)
    d15.button(q, cx, cy, "left", False)
    return bool(d15.wait_mark(ser, "WM CLOSE", marked, 1.2))


def close_files(q, ser, dx=0):
    """Close FILES via the CSD disc. No title-pop: that card is moved
    off the window and a miss opens WALL MENU."""
    try:
        q.key("esc")
    except Exception:
        pass
    time.sleep(0.04)
    trials = [dx, 0, 1, -28, 28]
    seen = set()
    for trial in trials:
        if trial in seen:
            continue
        seen.add(trial)
        cx, cy = files_close_xy(trial)
        if _click_close(q, ser, cx, cy):
            return True
    # Maximized CSD (border 8, width 1274).
    if _click_close(q, ser, 1260, 25):
        return True
    return False


def launch_files(q, ser):
    fx, fy = d15.FILES_DOCK_XY
    for _try in range(3):
        marked = ser.read()
        if d15.press(q, ser, fx, fy, "left", "DESK LAUNCH", timeout=1.4):
            if (d15.wait_mark(ser, "FILES READY", marked, 6)
                    or d15.wait_mark(ser, "FILES CSD", marked, 3)):
                return True
        if d15.press(q, ser, fx, fy, "left", "FILES CSD", timeout=1.5):
            d15.wait_mark(ser, "FILES READY", ser.read(), 6)
            return True
        time.sleep(0.15)
    return False


def first_drags(q, ser, n=22):
    walls = []
    presents = []
    fresh = 0
    # Sit-in already paid a 1px title step on the first FILES tile.
    # Every counted sample is a new client: close that tile, spawn, drag.
    if not close_files(q, ser, 1):
        close_files(q, ser, 0)
    time.sleep(0.2)
    for i in range(n):
        if not launch_files(q, ser):
            print("relaunch miss", i)
            continue
        fresh += 1
        time.sleep(0.35)
        d15.place(q, ser, FILES_TITLE[0], FILES_TITLE[1])
        time.sleep(0.08)
        marked = ser.read()
        d15.button(q, FILES_TITLE[0], FILES_TITLE[1], "left", True)
        # Split focus raise from the first move. Wait for the raise
        # drain so first-drag LAT is the step, not the cold DrawWindow.
        d15.wait_mark(ser, "WM DEFN COMMIT", marked, 1.5)
        time.sleep(0.05)
        # West, so the close disc stays left of SET (464).
        nx = FILES_TITLE[0] - 28
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
        print("first_drag", i, "fresh", fresh, wall)
        if i == 0 and wall is not None:
            try:
                d15.shot(q, os.path.join(
                    os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts"),
                    "oscortex-round21-first-drag.png"))
            except Exception as e:
                print("first-drag shot", e)
        if not close_files(q, ser, -28):
            print("close miss", i)
            continue
        time.sleep(0.15)
    return {
        "n": len(walls),
        "fresh_relaunches": fresh,
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


def files_open_proof(q, ser, relaunch=False):
    """CTX FILE then Open. Default tile after sit-in; relaunch only if asked."""
    if relaunch:
        close_files(q, ser, 28)
        close_files(q, ser, 0)
        time.sleep(0.25)
        if not launch_files(q, ser):
            return {
                "opened": False,
                "cat": False,
                "menu": False,
                "refused": False,
                "none": False,
                "launch": False,
            }
        time.sleep(0.4)
    marked = ser.read()
    d15.place(q, ser, CTX_XY[0], CTX_XY[1])
    time.sleep(0.12)
    d15.button(q, CTX_XY[0], CTX_XY[1], "right", True)
    time.sleep(0.05)
    d15.button(q, CTX_XY[0], CTX_XY[1], "right", False)
    menu = d15.wait_mark(ser, "FILES MENU", marked, 4)
    if not menu:
        menu = d15.wait_mark(ser, "WM CTX FILE", marked, 2)
    marked = ser.read()
    # Click the Open row, then Enter if the pointer missed.
    d15.place(q, ser, OPEN_XY[0], OPEN_XY[1])
    time.sleep(0.12)
    d15.button(q, OPEN_XY[0], OPEN_XY[1], "left", True)
    time.sleep(0.05)
    d15.button(q, OPEN_XY[0], OPEN_XY[1], "left", False)
    ok = d15.wait_mark(ser, "FILES OPEN", marked, 1.5)
    clicked = bool(ok)
    if not ok:
        marked = ser.read()
        try:
            q.key("ret")
        except Exception:
            pass
        ok = d15.wait_mark(ser, "FILES OPEN", marked, 2.0)
    blob = ser.read()
    try:
        tail = open(ser.path).read()[-8000:]
    except OSError:
        tail = blob
    cat = "FILES CAT " in blob or "FILES CAT " in tail
    none = "FILES CAT NONE" in blob or "FILES CAT NONE" in tail
    refused = "FILES OPEN REFUSED" in blob or "FILES OPEN REFUSED" in tail
    return {
        "opened": bool(ok) and cat and (not none) and (not refused),
        "cat": bool(cat) and (not none),
        "menu": bool(menu),
        "clicked": clicked,
        "refused": refused,
        "none": none,
        "launch": True,
    }


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round21.py <qmp> <serial-or-port>")
    port = int(sys.argv[1])
    ser = open_serial(sys.argv[2])
    q = d15.Qmp(port)
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)

    # Open while FILES is still on the default tile (sit-in only moved 1px).
    open_proof = files_open_proof(q, ser)
    try:
        d15.shot(q, os.path.join(art, "oscortex-round21-files-open.png"))
    except Exception as e:
        print("files-open shot", e)

    first = first_drags(q, ser, 22)
    if first.get("fresh_relaunches", 0) < 20:
        print("WARN: fresh first-drags", first.get("fresh_relaunches"),
              "< 20")

    # Leave a default FILES tile for chip-scan / stress.
    launch_files(q, ser)
    time.sleep(0.25)

    # Release any leftover title grab so pointer pairing is sprite-only.
    d15.button(q, FILES_TITLE[0], FILES_TITLE[1], "left", False)
    time.sleep(0.1)
    dmg_after_drag = parse_dmg(ser.read())

    pointer_pts = [(80 + (i * 17) % 900, 110 + (i % 7) * 9) for i in range(110)]
    pointer = collect(q, ser, "pointer", pointer_pts, want_opid=False)
    dmg_after_ptr = parse_dmg(ser.read())

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
            "Each first-drag sample is the first title step on a new "
            "FILES client after CSD close + dock spawn."
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
            "ptr_640": any(v == 640 for v in dmg["ptr"][-16:])
            or any(v > 0 and v % 640 == 0 for v in dmg["cptr"][-8:]),
            "after_drag": {
                "cum": dmg_after_drag["cum"][-2:],
                "lines": dmg_after_drag["lines"][-2:],
            },
            "after_pointer": {
                "cum": dmg_after_ptr["cum"][-2:],
                "cptr": dmg_after_ptr["cptr"][-2:],
                "lines": dmg_after_ptr["lines"][-2:],
            },
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
