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
ATTACH_RE = re.compile(r"WM ATTACH ([0-9A-F]{2}) ")
PROC_RE = re.compile(r"PROC (?:NEW|START) SLOT ([0-9A-F]{2})")
CLOSE_RE = re.compile(r"WM CLOSE ([0-9A-F]{2}) ")


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


def dock_files(q, ser):
    x, y = d15.FILES_DOCK_XY
    click(q, ser, x, y)


def slots_from(blob):
    att = sorted({int(m.group(1), 16) for m in ATTACH_RE.finditer(blob)})
    procs = sorted({int(m.group(1), 16) for m in PROC_RE.finditer(blob)})
    closes = [int(m.group(1), 16) for m in CLOSE_RE.finditer(blob)]
    overlays = [s for s in att if s >= 17]
    ordinary = [s for s in att if s < 17]
    return {
        "attach_slots": att,
        "proc_slots": procs,
        "close_slots": closes,
        "overlay_slots": overlays,
        "ordinary_slots": ordinary,
    }


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    marked0 = harvest(ser)
    files0 = marked0.count("FILES READY") + marked0.count("FILES CSD")
    # Sit-in already spawned DESK + one FILES. Spawn 15 more FILES.
    for i in range(15):
        dock_files(q, ser)
        time.sleep(0.18)
    t1 = time.time()
    while time.time() - t1 < 8.0:
        blob = harvest(ser)
        nfiles = blob.count("FILES READY") + blob.count("FILES SLOT")
        if nfiles >= 16 or blob.count("WM ATTACH ") >= 17:
            break
        time.sleep(0.1)
    # Overlays: launcher, then Esc, switcher, menu.
    m36.qcode_edge(q, "f4", True)
    m36.qcode_edge(q, "f4", False)
    time.sleep(0.2)
    d15.shot(q, os.path.join(ART, "oscortex-round37-16-clients.png"))
    m36.qcode_edge(q, "esc", True)
    m36.qcode_edge(q, "esc", False)
    time.sleep(0.08)
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
    click(q, ser, 48, 520)
    d15.button(q, 48, 520, "right", True)
    time.sleep(0.04)
    d15.button(q, 48, 520, "right", False)
    time.sleep(0.1)
    try:
        q.key("esc")
    except Exception:
        pass
    live = harvest(ser)
    live_info = slots_from(live)
    # Close every ordinary client we can see, then relaunch one FILES.
    closed = 0
    for _i in range(20):
        blob = harvest(ser)
        # Default FILES close chip; extras may stack. Click a few title closes.
        for x, y in ((48 + 400 - 17, 40 + 17), (80 + 400 - 17, 70 + 17),
                     (120 + 400 - 17, 100 + 17), (d15.FILES_CLOSE_XY[0],
                     d15.FILES_CLOSE_XY[1])):
            before = harvest(ser)
            click(q, ser, x, y)
            time.sleep(0.08)
            if harvest(ser)[len(before):].find("WM CLOSE") >= 0:
                closed += 1
    dock_files(q, ser)
    time.sleep(0.4)
    after = harvest(ser)
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
        "live": live_info,
        "ordinary_live": len(live_info["ordinary_slots"]),
        "overlay_live": len(live_info["overlay_slots"]),
        "closed_clicks": closed,
        "relaunch_files": "FILES READY" in after[len(live):] or (
            "FILES CSD" in after[len(live):]),
        "attach_refuse": refuse,
        "oom": after.count("OSGFX OOM") + after.count(" OOM "),
        "tap_die": "TAP DIE " in after,
        "fault": after.count("FAULT "),
        "reap": after.count("REAP "),
        "wrong_slot_print": bool(re.search(r"WM ATTACH [0-9A-F] ", after)
                                 and "WM ATTACH 1 " in after
                                 and 17 in live_info["attach_slots"]),
        "pass": (
            len(live_info["ordinary_slots"]) >= 16
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
        "slots": live_info,
    }, indent=2))
    return 0 if payload["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
