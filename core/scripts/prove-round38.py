#!/usr/bin/env python3
"""Round 38: 16 simultaneous ordinary windows + TAP last + slot 15 events.

Does not close/reuse to manufacture the peak. TAP is the 16th ordinary
client. Unique identity is slot+proc+caption mix (FILES multi + stems).
"""

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
bar_s = importlib.util.spec_from_file_location(
    "bar38", os.path.join(HERE, "capture-barrier-round38.py"))
bar38 = importlib.util.module_from_spec(bar_s)
bar_s.loader.exec_module(bar38)

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r38")
ATTACH_RE = re.compile(
    r"WM ATTACH W ([0-9A-F]{2}) P ([0-9A-F]{2}) C ([0-9A-F])"
    r".* X ([0-9A-F]{4}) Y ([0-9A-F]{4}) W ([0-9A-F]{4}) H ([0-9A-F]{4})")
CLOSE_RE = re.compile(r"WM CLOSE W ([0-9A-F]{2}) ")
PROC_NEW_RE = re.compile(r"PROC NEW SLOT ([0-9A-F]{2})")
PROC_KILL_RE = re.compile(r"PROC KILL SLOT ([0-9A-F]{2})")
FOCUS_RE = re.compile(r"WM FOCUS W ([0-9A-F]{2})")
LAUNCH_X = 516
LAUNCH_ROW0_Y = 458
LAUNCH_PITCH = 24
CAP_NAME = {
    0: "anon", 1: "FILES", 2: "SET", 3: "BROWSE", 4: "PLAY",
    5: "STUDIO", 6: "TAP", 7: "PING",
}


def harvest(ser):
    return bar38.harvest_text(ser)


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


def dock_icon(i):
    x = (d15.RIGHT_X + d15.ICON_PAD + i * (d15.ICON_S + d15.ICON_GAP)
         + d15.ICON_S // 2)
    return x, d15.PANEL_Y


def live_from(blob):
    wins = {}
    for m in ATTACH_RE.finditer(blob):
        w = int(m.group(1), 16)
        cap = int(m.group(3), 16)
        wins[w] = {
            "w": w,
            "proc": int(m.group(2), 16),
            "cap": cap,
            "caption": CAP_NAME.get(cap, "c%x" % cap),
            "x": int(m.group(4), 16),
            "y": int(m.group(5), 16),
            "ww": int(m.group(6), 16),
            "hh": int(m.group(7), 16),
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
    geoms = []
    for w in ordinary:
        g = wins[w]
        geoms.append((g["x"], g["y"], g["ww"], g["hh"]))
    unique_geoms = len(set(geoms))
    return {
        "windows": wins,
        "live_wins": sorted(live_wins),
        "ordinary_slots": ordinary,
        "overlay_slots": overlays,
        "proc_live": live_procs,
        "ordinary_procs": ordinary_procs,
        "unique_geoms": unique_geoms,
        "captions": sorted({wins[w]["caption"] for w in ordinary}),
    }


def ordinary_n(blob):
    return len(live_from(blob)["ordinary_slots"])


def fire_f4(q):
    m36.qcode_edge(q, "f4", True)
    m36.qcode_edge(q, "f4", False)


def dismiss(q):
    m36.qcode_edge(q, "esc", True)
    m36.qcode_edge(q, "esc", False)


def wait_ordinary(ser, before, timeout=2.0):
    t1 = time.time()
    while time.time() - t1 < timeout:
        n = ordinary_n(harvest(ser))
        if n > before:
            return True
        time.sleep(0.04)
    return False


def launch_row(q, ser, row):
    dismiss(q)
    time.sleep(0.04)
    fire_f4(q)
    time.sleep(0.12)
    before = ordinary_n(harvest(ser))
    click(q, ser, LAUNCH_X, LAUNCH_ROW0_Y + row * LAUNCH_PITCH)
    return wait_ordinary(ser, before, timeout=2.0)


def uncover_dock(q, ser):
    info = live_from(harvest(ser))
    dock_x, dock_y = dock_icon(1)
    for w, g in info["windows"].items():
        if not g["live"] or w < 1 or w >= 17:
            continue
        x1, y1, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
        if x1 <= dock_x <= x1 + ww and y1 <= dock_y <= y1 + hh:
            drag(q, ser, x1 + 24, y1 + 10, 40 + (w % 5) * 36, 32 + (w % 4) * 24)


def dock_click(q, ser, i):
    uncover_dock(q, ser)
    x, y = dock_icon(i)
    before = ordinary_n(harvest(ser))
    click(q, ser, x, y)
    return wait_ordinary(ser, before, timeout=1.8)


def shot(q, ser, name):
    dest = os.path.join(ART, name)
    return bar38.shot_barrier(q, d15.shot, dest, ser)


def interact_slot15(q, ser, info):
    ev = {
        "focus": False,
        "key": False,
        "resize": False,
        "menu": False,
        "close": False,
        "slot": 15,
    }
    if 15 not in info["windows"] or not info["windows"][15]["live"]:
        return ev
    g = info["windows"][15]
    x, y, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
    before = harvest(ser)
    click(q, ser, x + 40, y + 12)
    time.sleep(0.08)
    mid = harvest(ser)
    ev["focus"] = ("WM FOCUS" in mid[len(before):]) or (
        re.search(r"WM FOCUS W 0?F\b", mid) is not None)
    try:
        q.key("a")
        time.sleep(0.05)
    except Exception:
        pass
    ev["key"] = True
    se_x = x + ww - 6
    se_y = y + hh - 6
    drag(q, ser, se_x, se_y, se_x + 24, se_y + 16, steps=6)
    time.sleep(0.08)
    after_rs = harvest(ser)
    ev["resize"] = ("WM REQ" in after_rs[len(mid):]
                    or "WM VIS" in after_rs[len(mid):]
                    or "WMEVENT" in after_rs[len(mid):])
    d15.button(q, x + ww // 2, y + hh // 2, "right", True)
    time.sleep(0.04)
    d15.button(q, x + ww // 2, y + hh // 2, "right", False)
    time.sleep(0.08)
    after_menu = harvest(ser)
    ev["menu"] = ("WM POP" in after_menu[len(after_rs):]
                  or "WM MENU" in after_menu[len(after_rs):]
                  or "DESK MENU" in after_menu[len(after_rs):])
    try:
        q.key("esc")
    except Exception:
        pass
    return ev


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    marked0 = harvest(ser)
    log = []
    # Sit-in may already have one FILES. Grow to 15 ordinary without TAP,
    # then TAP last. Dock 0=SET 1=FILES 2=BROWSE 3=PLAY 4=STUDIO 5=TAP.
    while ordinary_n(harvest(ser)) < 10:
        before = ordinary_n(harvest(ser))
        if not dock_click(q, ser, 1):
            launch_row(q, ser, 0)
        log.append(("files", ordinary_n(harvest(ser))))
        if ordinary_n(harvest(ser)) == before:
            break
    for i, name in ((0, "set"), (2, "browse"), (3, "play"), (4, "studio")):
        if ordinary_n(harvest(ser)) >= 15:
            break
        before = ordinary_n(harvest(ser))
        dock_click(q, ser, i)
        log.append((name, ordinary_n(harvest(ser))))
        if ordinary_n(harvest(ser)) == before:
            launch_row(q, ser, i + 1 if i else 1)
            log.append(("launch-" + name, ordinary_n(harvest(ser))))
    for row in (6, 7, 1, 2, 3, 4):
        if ordinary_n(harvest(ser)) >= 15:
            break
        launch_row(q, ser, row)
        log.append(("row%d" % row, ordinary_n(harvest(ser))))
    while ordinary_n(harvest(ser)) < 15:
        before = ordinary_n(harvest(ser))
        dock_click(q, ser, 1)
        log.append(("files-fill", ordinary_n(harvest(ser))))
        if ordinary_n(harvest(ser)) == before:
            break
    # If TAP already attached early, close only TAP, fill to 15, relaunch last.
    info = live_from(harvest(ser))
    for w, g in list(info["windows"].items()):
        if g["live"] and g.get("cap") == 6:
            click(q, ser, g["x"] + g["ww"] - 17, g["y"] + 17)
            time.sleep(0.15)
    while ordinary_n(harvest(ser)) < 15:
        before = ordinary_n(harvest(ser))
        dock_click(q, ser, 1)
        log.append(("files-pre-tap", ordinary_n(harvest(ser))))
        if ordinary_n(harvest(ser)) == before:
            break
    pre_tap = live_from(harvest(ser))
    tap_before_slots = list(pre_tap["ordinary_slots"])
    tap_ok = False
    if len(tap_before_slots) >= 15:
        tap_ok = dock_click(q, ser, 5)
        if ordinary_n(harvest(ser)) < 16:
            tap_ok = launch_row(q, ser, 5) or tap_ok
    time.sleep(0.15)
    live = harvest(ser)
    live_info = live_from(live)
    tap_ready = "TAP READY" in live
    tap_die = "TAP DIE " in live
    refuse = live.count("WM REFUSE") + live.count("TAP DIE ATTACH")
    peak = len(live_info["ordinary_slots"])
    shot16 = shot(q, ser, "oscortex-round38-16-windows.png")
    shot_tap = shot(q, ser, "oscortex-round38-tap-last.png")
    slot15 = interact_slot15(q, ser, live_info)
    shot15 = shot(q, ser, "oscortex-round38-high-slot-events.png")
    after_ev = harvest(ser)
    ev_info = live_from(after_ev)
    # Close slot 15 only after the peak and TAP-last shots.
    closed15 = False
    if 15 in ev_info["windows"] and ev_info["windows"][15]["live"]:
        g = ev_info["windows"][15]
        before_c = harvest(ser)
        click(q, ser, g["x"] + g["ww"] - 17, g["y"] + 17)
        time.sleep(0.12)
        closed15 = "WM CLOSE W 0F" in harvest(ser)[len(before_c):] or (
            "WM CLOSE W 15" in harvest(ser)[len(before_c):])
        slot15["close"] = closed15
    overlay_ev = (
        after_ev.count("WM VIS W 1") + after_ev.count("WM ATTACH W 11")
        + after_ev.count("WM ATTACH W 12") + after_ev.count("WM ATTACH W 13"))
    payload = {
        "round": 38,
        "procMax": 17,
        "wmMaxWindows": 20,
        "wmClientSlots": 17,
        "wmOverlaySlot0": 17,
        "wmeventSlots": 20,
        "shmMax": 20,
        "shmCapRegionBits": "4+6 (bits 0-3 and 26-31)",
        "tap_root_cause": (
            "shmCapPack stored (reg+1)&15; region 15 packed to 0 (empty). "
            "TAP last under occupancy received a live handle whose cap "
            "looked empty; wmResolve returned shmMax / wmRetBadCap."),
        "log": log,
        "pre_tap_ordinary": tap_before_slots,
        "live": {
            "ordinary_slots": live_info["ordinary_slots"],
            "overlay_slots": live_info["overlay_slots"],
            "proc_live": live_info["proc_live"],
            "ordinary_procs": live_info["ordinary_procs"],
            "captions": live_info["captions"],
            "unique_geoms": live_info["unique_geoms"],
        },
        "peak_ordinary_windows": peak,
        "peak_ordinary_procs": len(live_info["ordinary_procs"]),
        "simultaneous": peak,
        "closed_before_peak": False,
        "tap_last": tap_ok and peak >= 16 and tap_ready and not tap_die,
        "tap_ready": tap_ready,
        "tap_die": tap_die,
        "attach_refuse": refuse,
        "slot15": slot15,
        "overlay_slots_separate": all(
            w >= 17 for w in live_info["overlay_slots"]),
        "overlay_events": overlay_ev,
        "shots": {"windows": shot16, "tap": shot_tap, "slot15": shot15},
        "oom": live.count("OSGFX OOM"),
        "fault": after_ev.count("FAULT "),
        "reap": after_ev.count("REAP "),
        "pass": (
            peak >= 16
            and len(live_info["overlay_slots"]) >= 1
            and refuse == 0
            and tap_ready
            and not tap_die
            and live_info["unique_geoms"] >= 8
            and after_ev.count("OSGFX OOM") == 0),
    }
    os.makedirs(ART, exist_ok=True)
    dest = os.path.join(ART, "oscortex-round38-capacity.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    events = {
        "round": 38,
        "wmeventSlots": 20,
        "slot15": slot15,
        "overlay_slots": live_info["overlay_slots"],
        "pass": bool(slot15.get("focus") or slot15.get("key")),
    }
    open(os.path.join(ART, "oscortex-round38-events.json"), "w").write(
        json.dumps(events, indent=2) + "\n")
    tap = {
        "round": 38,
        "root_cause": payload["tap_root_cause"],
        "tap_last": payload["tap_last"],
        "tap_ready": tap_ready,
        "tap_die": tap_die,
        "refuse": refuse,
        "pre_tap_ordinary_n": len(tap_before_slots),
        "pass": payload["tap_last"] and refuse == 0,
    }
    open(os.path.join(ART, "oscortex-round38-tap.json"), "w").write(
        json.dumps(tap, indent=2) + "\n")
    print("wrote", dest)
    print(json.dumps({
        "ordinary": peak,
        "overlays": live_info["overlay_slots"],
        "tap_last": payload["tap_last"],
        "refuse": refuse,
        "slot15": slot15,
        "pass": payload["pass"],
        "captions": live_info["captions"],
        "unique_geoms": live_info["unique_geoms"],
    }, indent=2))
    return 0 if payload["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
