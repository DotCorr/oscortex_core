#!/usr/bin/env python3
"""Round 37: 16 ordinary clients + DESK + reserved overlays, then reclaim."""

import importlib.util
import json
import os
import re
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)
m36s = importlib.util.spec_from_file_location(
    "m36", os.path.join(HERE, "measure-round36.py"))
m36 = importlib.util.module_from_spec(m36s)
m36s.loader.exec_module(m36)

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r37")
ATTACH_RE = re.compile(
    r"WM ATTACH W ([0-9A-F]{2}) P ([0-9A-F]{2}) .* "
    r"X ([0-9A-F]{4}) Y ([0-9A-F]{4}) W ([0-9A-F]{4}) H ([0-9A-F]{4})")
CLOSE_RE = re.compile(r"WM CLOSE W ([0-9A-F]{2}) ")
PROC_NEW_RE = re.compile(r"PROC NEW SLOT ([0-9A-F]{2})")
PROC_KILL_RE = re.compile(r"PROC KILL SLOT ([0-9A-F]{2})")
LAUNCH_X = 516
LAUNCH_ROW0_Y = 458
LAUNCH_PITCH = 24


def harvest(ser):
    live = ""
    try:
        live = ser.read() or ""
    except Exception:
        live = ""
    try:
        blob = open(ser.path, encoding="latin-1", errors="replace").read()
    except OSError:
        blob = ""
    return blob + "\n" + (getattr(ser, "archive", "") or "") + "\n" + live


def click(q, ser, x, y):
    d15.place(q, ser, int(x), int(y))
    d15.button(q, int(x), int(y), "left", True)
    time.sleep(0.03)
    d15.button(q, int(x), int(y), "left", False)


def drag(q, ser, x0, y0, x1, y1, steps=8):
    d15.place(q, ser, int(x0), int(y0))
    d15.button(q, int(x0), int(y0), "left", True)
    time.sleep(0.02)
    for i in range(1, steps + 1):
        x = x0 + (x1 - x0) * i // steps
        y = y0 + (y1 - y0) * i // steps
        d15.place(q, ser, int(x), int(y))
        time.sleep(0.015)
    d15.button(q, int(x1), int(y1), "left", False)


def dock_files(q, ser):
    x, y = d15.FILES_DOCK_XY
    click(q, ser, x, y)


def live_from(blob):
    wins = {}
    for m in ATTACH_RE.finditer(blob):
        w = int(m.group(1), 16)
        wins[w] = {
            "w": w,
            "proc": int(m.group(2), 16),
            "x": int(m.group(3), 16),
            "y": int(m.group(4), 16),
            "ww": int(m.group(5), 16),
            "hh": int(m.group(6), 16),
            "live": True,
        }
    for m in CLOSE_RE.finditer(blob):
        w = int(m.group(1), 16)
        if w in wins:
            wins[w]["live"] = False
    procs = {}
    for m in PROC_NEW_RE.finditer(blob):
        procs[int(m.group(1), 16)] = True
    for m in PROC_KILL_RE.finditer(blob):
        procs[int(m.group(1), 16)] = False
    live_wins = [w for w, info in wins.items() if info["live"]]
    ordinary = [w for w in live_wins if 0 < w < 17]
    overlays = [w for w in live_wins if w >= 17]
    live_procs = sorted([s for s, on in procs.items() if on])
    ordinary_procs = [s for s in live_procs if s > 0]
    return {
        "windows": wins,
        "live_wins": sorted(live_wins),
        "ordinary_slots": ordinary,
        "overlay_slots": overlays,
        "proc_live": live_procs,
        "ordinary_procs": ordinary_procs,
    }


def ordinary_n(blob):
    info = live_from(blob)
    return max(len(info["ordinary_slots"]), len(info["ordinary_procs"]))


def fire_f4(q):
    m36.qcode_edge(q, "f4", True)
    m36.qcode_edge(q, "f4", False)


def dismiss(q):
    m36.qcode_edge(q, "esc", True)
    m36.qcode_edge(q, "esc", False)


def launch_row(q, ser, row):
    dismiss(q)
    time.sleep(0.04)
    fire_f4(q)
    time.sleep(0.12)
    click(q, ser, LAUNCH_X, LAUNCH_ROW0_Y + row * LAUNCH_PITCH)
    t1 = time.time()
    before = ordinary_n(harvest(ser))
    while time.time() - t1 < 2.0:
        if ordinary_n(harvest(ser)) > before:
            return True
        time.sleep(0.05)
    return False


def uncover_dock(q, ser):
    info = live_from(harvest(ser))
    dock_y = d15.FILES_DOCK_XY[1]
    dock_x = d15.FILES_DOCK_XY[0]
    for w, g in info["windows"].items():
        if not g["live"]:
            continue
        if w < 1 or w >= 17:
            continue
        x1 = g["x"]
        y1 = g["y"]
        x2 = x1 + g["ww"]
        y2 = y1 + g["hh"]
        if x1 <= dock_x <= x2 and y1 <= dock_y <= y2:
            drag(q, ser, x1 + 24, y1 + 10, 80 + (w % 6) * 40, 48 + (w % 4) * 28)
            time.sleep(0.05)


def close_live_ordinary(q, ser):
    closed = 0
    for _i in range(24):
        info = live_from(harvest(ser))
        targets = [info["windows"][w] for w in info["ordinary_slots"]
                   if w in info["windows"]]
        if not targets:
            break
        g = targets[-1]
        before = harvest(ser)
        click(q, ser, g["x"] + g["ww"] - 17, g["y"] + 17)
        time.sleep(0.1)
        if "WM CLOSE" in harvest(ser)[len(before):]:
            closed += 1
            continue
        click(q, ser, d15.FILES_CLOSE_XY[0], d15.FILES_CLOSE_XY[1])
        time.sleep(0.08)
    return closed


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    marked0 = harvest(ser)
    files0 = marked0.count("FILES READY") + marked0.count("FILES CSD")
    # Rapid FILES while the cascade is still above the dock.
    tries = 0
    while ordinary_n(harvest(ser)) < 16 and tries < 24:
        before = ordinary_n(harvest(ser))
        dock_files(q, ser)
        t1 = time.time()
        while time.time() - t1 < 0.9:
            if ordinary_n(harvest(ser)) > before:
                break
            time.sleep(0.04)
        tries += 1
        print("dock-files", tries, "ordinary", ordinary_n(harvest(ser)))
        if ordinary_n(harvest(ser)) == before:
            uncover_dock(q, ser)
    # Unused single-instance dock icons (skip TAP; TAP DIE ATTACH is not FILES).
    for i in (0, 2, 3, 4):
        if ordinary_n(harvest(ser)) >= 16:
            break
        x = (d15.RIGHT_X + d15.ICON_PAD + i * (d15.ICON_S + d15.ICON_GAP)
             + d15.ICON_S // 2)
        before = ordinary_n(harvest(ser))
        click(q, ser, x, d15.PANEL_Y)
        t1 = time.time()
        while time.time() - t1 < 1.6:
            if ordinary_n(harvest(ser)) > before:
                break
            time.sleep(0.05)
        print("dock-icon", i, "ordinary", ordinary_n(harvest(ser)))
    for row in (1, 2, 3, 4, 5):
        if ordinary_n(harvest(ser)) >= 16:
            break
        print("launch-row", row, "ordinary", ordinary_n(harvest(ser)))
        launch_row(q, ser, row)
    dismiss(q)
    time.sleep(0.05)
    fire_f4(q)
    time.sleep(0.2)
    d15.shot(q, os.path.join(ART, "oscortex-round37-16-clients.png"))
    try:
        q.cmd("input-send-event", events=[{
            "type": "key",
            "data": {"down": True, "key": {"type": "qcode", "data": "alt"}},
        }])
        q.cmd("input-send-event", events=[{
            "type": "key",
            "data": {"down": True, "key": {"type": "qcode", "data": "tab"}},
        }])
        q.cmd("input-send-event", events=[{
            "type": "key",
            "data": {"down": False, "key": {"type": "qcode", "data": "tab"}},
        }])
        time.sleep(0.12)
        q.cmd("input-send-event", events=[{
            "type": "key",
            "data": {"down": False, "key": {"type": "qcode", "data": "alt"}},
        }])
    except Exception:
        pass
    d15.button(q, 48, 520, "right", True)
    time.sleep(0.04)
    d15.button(q, 48, 520, "right", False)
    time.sleep(0.08)
    live = harvest(ser)
    live_info = live_from(live)
    peak_ordinary = max(len(live_info["ordinary_slots"]),
                        len(live_info["ordinary_procs"]))
    closed = close_live_ordinary(q, ser)
    uncover_dock(q, ser)
    dock_files(q, ser)
    time.sleep(0.5)
    after = harvest(ser)
    after_info = live_from(after)
    refuse = after.count("WM ATTACH REFUS") + after.count("SHM REFUS")
    refuse += after.count("procErrNoSlot") + after.count("PROC REFUSED")
    payload = {
        "round": 37,
        "procMax": 17,
        "procMax_means": "DESK + 16 ordinary client processes",
        "wmMaxWindows": 20,
        "wmClientSlots": 17,
        "wmOverlaySlot0": 17,
        "shmMax": 20,
        "fileRows": 18,
        "fileRunRow": 17,
        "slot_print_hex_digits": 2,
        "sit_in_files": files0,
        "live": {
            "ordinary_slots": live_info["ordinary_slots"],
            "overlay_slots": live_info["overlay_slots"],
            "proc_live": live_info["proc_live"],
            "ordinary_procs": live_info["ordinary_procs"],
        },
        "ordinary_live": peak_ordinary,
        "overlay_live": len(live_info["overlay_slots"]),
        "closed_clicks": closed,
        "after_close_ordinary": len(after_info["ordinary_slots"]),
        "relaunch_files": (
            "FILES READY" in after[len(live):]
            or "FILES CSD" in after[len(live):]
            or "FILES SLOT" in after[len(live):]),
        "attach_refuse": refuse,
        "oom": after.count("OSGFX OOM") + after.count(" OOM "),
        "tap_die": "TAP DIE " in after,
        "fault": after.count("FAULT "),
        "reap": after.count("REAP "),
        "wrong_slot_print": bool(re.search(r"WM ATTACH [0-9A-F] ", after)
                                 and "WM ATTACH 1 " in after
                                 and 17 in live_info["live_wins"]),
        "pass": (
            peak_ordinary >= 16
            and len(live_info["overlay_slots"]) >= 1
            and refuse == 0
            and after.count("OSGFX OOM") == 0
            and "TAP DIE " not in after),
    }
    os.makedirs(ART, exist_ok=True)
    dest = os.path.join(ART, "oscortex-round37-capacity.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print("wrote", dest)
    print(json.dumps({
        "ordinary": payload["ordinary_live"],
        "overlays": payload["overlay_live"],
        "refuse": refuse,
        "pass": payload["pass"],
        "slots": payload["live"],
        "closed": closed,
        "relaunch": payload["relaunch_files"],
    }, indent=2))
    return 0 if payload["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
