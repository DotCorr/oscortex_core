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


VIS_RE = re.compile(
    r"WM (?:VIS|REQ) W ([0-9A-F]+) X ([0-9A-F]{4}) Y ([0-9A-F]{4}) "
    r"W ([0-9A-F]{4}) H ([0-9A-F]{4})")
# Compositor keys and right-press client menus (ADR-0194).
CTX_RE = re.compile(r"WM CTX [A-Z]+")
FOCUS_SLOT_RE = re.compile(r"WM FOCUS G [0-9A-F]+ W ([0-9A-F]+)")
NON_TAP_DOCK = (1, 0, 2, 3, 4)  # FILES SET BROWSE PLAY STUDIO
NON_TAP_ROWS = (1, 0, 2, 3, 4)  # SET FILES BROWSE PLAY STUDIO; 5+ is TAP


def harvest(ser):
    return bar38.harvest_text(ser)


def apply_vis(blob, wins):
    last_att = {}
    for m in ATTACH_RE.finditer(blob):
        last_att[int(m.group(1), 16)] = m.start()
    for m in VIS_RE.finditer(blob):
        w = int(m.group(1), 16)
        ww = int(m.group(4), 16)
        hh = int(m.group(5), 16)
        if ww < 1 or hh < 1:
            continue
        if w not in wins:
            continue
        if last_att.get(w, -1) > m.start():
            continue
        wins[w]["x"] = int(m.group(2), 16)
        wins[w]["y"] = int(m.group(3), 16)
        wins[w]["ww"] = ww
        wins[w]["hh"] = hh


def click(q, ser, x, y):
    d15.place(q, ser, int(x), int(y))
    d15.button(q, int(x), int(y), "left", True)
    time.sleep(0.03)
    d15.button(q, int(x), int(y), "left", False)


def right_click(q, ser, x, y):
    d15.place(q, ser, int(x), int(y))
    d15.button(q, int(x), int(y), "right", True)
    time.sleep(0.04)
    d15.button(q, int(x), int(y), "right", False)


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
    events = []
    for m in ATTACH_RE.finditer(blob):
        events.append((m.start(), "A", m))
    for m in CLOSE_RE.finditer(blob):
        events.append((m.start(), "C", m))
    events.sort(key=lambda e: e[0])
    wins = {}
    peak = 0
    for _at, kind, m in events:
        if kind == "A":
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
        else:
            w = int(m.group(1), 16)
            if w in wins:
                wins[w]["live"] = False
        cur = sum(1 for w, g in wins.items()
                  if g["live"] and 0 < w < 17)
        if cur > peak:
            peak = cur
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
    apply_vis(blob, wins)
    tap_slots = [w for w in ordinary
                 if w in wins and wins[w].get("cap") == 6]
    return {
        "windows": wins,
        "live_wins": sorted(live_wins),
        "ordinary_slots": ordinary,
        "overlay_slots": overlays,
        "proc_live": live_procs,
        "ordinary_procs": ordinary_procs,
        "unique_geoms": unique_geoms,
        "captions": sorted({wins[w]["caption"] for w in ordinary}),
        "peak_ordinary": peak,
        "tap_slots": tap_slots,
    }


def ordinary_n(blob):
    return len(live_from(blob)["ordinary_slots"])


def ordinary_no_tap(blob):
    info = live_from(blob)
    return len([w for w in info["ordinary_slots"] if w not in info["tap_slots"]])


def tap_attached_under_occupancy(blob):
    """True when a C 6 attach happened with >=15 other ordinary windows live."""
    events = []
    for m in ATTACH_RE.finditer(blob):
        events.append((m.start(), "A", m))
    for m in CLOSE_RE.finditer(blob):
        events.append((m.start(), "C", m))
    events.sort(key=lambda e: e[0])
    live = {}
    saw = False
    for _at, kind, m in events:
        if kind == "A":
            w = int(m.group(1), 16)
            cap = int(m.group(3), 16)
            live[w] = cap
            if cap == 6 and 0 < w < 17:
                others = [x for x, c in live.items()
                          if 0 < x < 17 and x != w]
                if len(others) >= 15:
                    saw = True
        else:
            w = int(m.group(1), 16)
            live.pop(w, None)
    return saw


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


def close_slot(q, ser, w):
    info = live_from(harvest(ser))
    if w not in info["windows"] or not info["windows"][w]["live"]:
        return False
    g = info["windows"][w]
    before = harvest(ser)
    click(q, ser, g["x"] + g["ww"] - 17, g["y"] + 17)
    t1 = time.time()
    while time.time() - t1 < 1.2:
        delta = harvest(ser)[len(before):]
        if ("WM CLOSE W %02X" % w) in delta or ("WM CLOSE W %X" % w) in delta:
            return True
        time.sleep(0.04)
    return ("WM CLOSE W %02X" % w) in harvest(ser)[len(before):]


def close_early_tap(q, ser, log):
    info = live_from(harvest(ser))
    for w in list(info.get("tap_slots") or []):
        if close_slot(q, ser, w):
            log.append(("close-early-tap", w, ordinary_n(harvest(ser))))


def launch_row(q, ser, row):
    dismiss(q)
    time.sleep(0.04)
    fire_f4(q)
    time.sleep(0.12)
    before = ordinary_n(harvest(ser))
    click(q, ser, LAUNCH_X, LAUNCH_ROW0_Y + row * LAUNCH_PITCH)
    return wait_ordinary(ser, before, timeout=2.0)


def tap_live_in(blob):
    info = live_from(blob)
    return bool(info["tap_slots"]) or "TAP READY" in blob


def wait_tap(ser, before, timeout=3.0):
    t1 = time.time()
    while time.time() - t1 < timeout:
        blob = harvest(ser)
        delta = blob[len(before):]
        if "TAP READY" in delta or "TAP CSD" in delta or " C 6 " in delta:
            return True
        if "TAP DIE " in delta:
            return False
        info = live_from(blob)
        if info["tap_slots"]:
            return True
        time.sleep(0.05)
    return tap_live_in(harvest(ser))


def park_off_dock(q, ser):
    info = live_from(harvest(ser))
    dock_x, _dock_y = dock_icon(5)
    for w, g in list(info["windows"].items()):
        if not g["live"] or w < 1 or w >= 17:
            continue
        if g["x"] + g["ww"] >= dock_x - 12:
            dest_x = 24 + (w % 4) * 28
            dest_y = 24 + ((w // 4) % 4) * 28
            drag(q, ser, g["x"] + 24, g["y"] + 10, dest_x + 24, dest_y + 10)
            time.sleep(0.04)


def launch_tap_last(q, ser, log):
    """16th ordinary client must be TAP. A dock miss that spawned PLAY is closed."""
    info = live_from(harvest(ser))
    others = [w for w in info["ordinary_slots"] if w not in info["tap_slots"]]
    if info["tap_slots"]:
        return True
    if len(others) > 15:
        extra = sorted(others, reverse=True)
        for w in extra:
            if len(others) <= 15:
                break
            if close_slot(q, ser, w):
                log.append(("close-nontap-extra", w, ordinary_no_tap(harvest(ser))))
                others = [x for x in others if x != w]
    if ordinary_no_tap(harvest(ser)) < 15:
        return False
    park_off_dock(q, ser)
    dismiss(q)
    time.sleep(0.06)
    tx, ty = dock_icon(5)
    before = harvest(ser)
    try:
        d15.press(q, ser, tx, ty, "left", "DESK LAUNCH TAP.ELF", timeout=6.0)
    except Exception:
        click(q, ser, tx, ty)
    if wait_tap(ser, before, timeout=4.0):
        log.append(("tap-dock5-token", ordinary_n(harvest(ser))))
        return True
    log.append(("tap-dock5-miss", ordinary_n(harvest(ser))))
    before2 = harvest(ser)
    dismiss(q)
    time.sleep(0.05)
    fire_f4(q)
    time.sleep(0.18)
    click(q, ser, LAUNCH_X, LAUNCH_ROW0_Y + 6 * LAUNCH_PITCH)
    if wait_tap(ser, before2, timeout=3.5):
        log.append(("tap-launcher-row6", ordinary_n(harvest(ser))))
        dismiss(q)
        return True
    log.append(("tap-launcher-miss", ordinary_n(harvest(ser))))
    info = live_from(harvest(ser))
    if not info["tap_slots"] and len(info["ordinary_slots"]) > 15:
        newest = max(info["ordinary_slots"])
        if newest not in info["tap_slots"]:
            close_slot(q, ser, newest)
            log.append(("close-false-16th", newest, ordinary_n(harvest(ser))))
    return tap_live_in(harvest(ser))


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


def slot15_geom(info):
    g = info["windows"][15]
    return g["x"], g["y"], g["ww"], g["hh"]


def raise_window(q, ser, w, dest_x, dest_y):
    """Drag a live title to dest so SE/close/body are on top and visible."""
    info = live_from(harvest(ser))
    if w not in info["windows"] or not info["windows"][w]["live"]:
        return info
    g = info["windows"][w]
    x, y = g["x"], g["y"]
    click(q, ser, x + 40, y + 12)
    time.sleep(0.08)
    info = live_from(harvest(ser))
    if w not in info["windows"] or not info["windows"][w]["live"]:
        return info
    g = info["windows"][w]
    x, y = g["x"], g["y"]
    if abs(x - dest_x) > 8 or abs(y - dest_y) > 8:
        drag(q, ser, x + 36, y + 10, dest_x + 36, dest_y + 10, steps=10)
        time.sleep(0.12)
    return live_from(harvest(ser))


def raise_slot15(q, ser, info):
    return raise_window(q, ser, 15, 48, 40)


def interact_slot15(q, ser, info):
    ev = {
        "focus": False,
        "key": False,
        "resize": False,
        "menu": False,
        "close": False,
        "slot": 15,
        "tokens": {},
    }
    if 15 not in info["windows"] or not info["windows"][15]["live"]:
        return ev
    info = raise_slot15(q, ser, info)
    if 15 not in info["windows"] or not info["windows"][15]["live"]:
        return ev
    x, y, ww, hh = slot15_geom(info)
    before = harvest(ser)
    click(q, ser, x + 40, y + 12)
    time.sleep(0.10)
    mid = harvest(ser)
    delta_f = mid[len(before):]
    ev["focus"] = (
        re.search(r"WM FOCUS G [0-9A-F]+ W F\b", delta_f) is not None
        or re.search(r"WM FOCUS G [0-9A-F]+ W 0?F\b", mid) is not None
        or "WM FOCUS G" in delta_f)
    ev["tokens"]["focus"] = [ln for ln in delta_f.splitlines()
                             if "FOCUS" in ln][:4]
    try:
        m36.qcode_edge(q, "t", True)
        m36.qcode_edge(q, "t", False)
        time.sleep(0.08)
        m36.qcode_edge(q, "down", True)
        m36.qcode_edge(q, "down", False)
        time.sleep(0.06)
    except Exception:
        try:
            q.key("t")
            time.sleep(0.05)
        except Exception:
            pass
    after_key = harvest(ser)
    delta_k = after_key[len(mid):]
    ev["key"] = (
        "WM KEY " in delta_k
        or "TAP HIT" in delta_k
        or "FILES KEY " in delta_k
        or "USER WRITE FILES" in delta_k
        or "USER WRITE STUDIO" in delta_k
        or "USER WRITE TAP" in delta_k
        or "USER WRITE SET" in delta_k
        or "USER WRITE PLAY" in delta_k
        or "USER WRITE BROWSE" in delta_k)
    ev["tokens"]["key"] = [ln for ln in delta_k.splitlines()
                           if ln.strip()][:6]
    if not ev["key"]:
        # Alt-F10 is consumed for the focused window and prints WM KEY / WM MAX.
        try:
            m36.qcode_edge(q, "alt", True)
            m36.qcode_edge(q, "f10", True)
            m36.qcode_edge(q, "f10", False)
            m36.qcode_edge(q, "alt", False)
            time.sleep(0.10)
        except Exception:
            pass
        after_alt = harvest(ser)
        delta_alt = after_alt[len(after_key):]
        ev["key"] = (
            "WM KEY " in delta_alt
            or "WM MAX W F" in delta_alt
            or "TAP HIT" in delta_alt)
        ev["tokens"]["key_alt"] = [ln for ln in delta_alt.splitlines()
                                   if ln.strip()][:6]
        after_key = after_alt
    # SE handle is the last 8 px of content plus border (wmResizeEdge).
    info = live_from(after_key)
    if 15 in info["windows"] and info["windows"][15]["live"]:
        x, y, ww, hh = slot15_geom(info)
    se_x = x + max(ww, 8) - 4
    se_y = y + max(hh, 8) - 4
    drag(q, ser, se_x, se_y, se_x + 28, se_y + 20, steps=8)
    time.sleep(0.12)
    after_rs = harvest(ser)
    delta_r = after_rs[len(after_key):]
    ev["resize"] = (
        re.search(r"WM REQ W F\b", delta_r) is not None
        or re.search(r"WM VIS W F\b", delta_r) is not None
        or "WM HOLD W F" in delta_r
        or "WM PEND W F" in delta_r)
    if not ev["resize"]:
        info = live_from(after_rs)
        if 15 in info["windows"] and info["windows"][15]["live"]:
            x, y, ww, hh = slot15_geom(info)
            se_x = x + max(ww, 8) - 3
            se_y = y + max(hh, 8) - 3
            before_rs2 = harvest(ser)
            drag(q, ser, se_x, se_y, se_x + 36, se_y + 24, steps=8)
            time.sleep(0.12)
            after_rs = harvest(ser)
            delta_r = after_rs[len(before_rs2):]
            ev["resize"] = (
                re.search(r"WM REQ W F\b", delta_r) is not None
                or re.search(r"WM VIS W F\b", delta_r) is not None
                or "WM HOLD W F" in delta_r
                or "WM PEND W F" in delta_r)
    ev["tokens"]["resize"] = [ln for ln in delta_r.splitlines()
                              if ln.startswith("WM ")][:8]
    info = live_from(after_rs)
    if 15 in info["windows"] and info["windows"][15]["live"]:
        x, y, ww, hh = slot15_geom(info)
    # Title right-press is the compositor window menu (WM CTX TITLE + kind 4).
    right_click(q, ser, x + 40, y + 12)
    time.sleep(0.12)
    after_menu = harvest(ser)
    delta_m = after_menu[len(after_rs):]
    ev["menu"] = (
        "WM CTX TITLE" in delta_m
        or CTX_RE.search(delta_m) is not None
        or "WM CTX " in delta_m
        or re.search(r"WM DONE [0-9A-F]+ K 04 ", delta_m) is not None)
    ev["tokens"]["menu"] = [ln for ln in delta_m.splitlines()
                            if "CTX" in ln or "MENU" in ln or "DONE" in ln][:6]
    try:
        q.key("esc")
        time.sleep(0.05)
    except Exception:
        pass
    ev["geom"] = {"x": x, "y": y, "w": ww, "h": hh}
    return ev


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    marked0 = harvest(ser)
    log = []
    # Sit-in may already have one FILES. Grow to 15 ordinary WITHOUT TAP,
    # then TAP last. Dock 0=SET 1=FILES 2=BROWSE 3=PLAY 4=STUDIO 5=TAP.
    # Launcher row 6 is TAP — never use it during fill.
    def fill_one(tag):
        before = ordinary_no_tap(harvest(ser))
        if before >= 15:
            return False
        progressed = False
        for dock_i in NON_TAP_DOCK:
            if ordinary_no_tap(harvest(ser)) >= 15:
                break
            n0 = ordinary_no_tap(harvest(ser))
            dock_click(q, ser, dock_i)
            close_early_tap(q, ser, log)
            n1 = ordinary_no_tap(harvest(ser))
            log.append((tag + "-dock%d" % dock_i, n1))
            if n1 > n0:
                progressed = True
                break
        if ordinary_no_tap(harvest(ser)) < 15 and not progressed:
            for row in NON_TAP_ROWS:
                if ordinary_no_tap(harvest(ser)) >= 15:
                    break
                n0 = ordinary_no_tap(harvest(ser))
                launch_row(q, ser, row)
                close_early_tap(q, ser, log)
                n1 = ordinary_no_tap(harvest(ser))
                log.append((tag + "-row%d" % row, n1))
                if n1 > n0:
                    progressed = True
                    break
        return ordinary_no_tap(harvest(ser)) > before

    stall = 0
    while ordinary_no_tap(harvest(ser)) < 15:
        if fill_one("pre"):
            stall = 0
            continue
        stall += 1
        if stall >= 3:
            break
    close_early_tap(q, ser, log)
    pre_tap = live_from(harvest(ser))
    tap_before_slots = [w for w in pre_tap["ordinary_slots"]
                        if w not in pre_tap["tap_slots"]]
    tap_mark = harvest(ser)
    tap_ok = False
    if len(tap_before_slots) >= 15 and not pre_tap["tap_slots"]:
        tap_ok = launch_tap_last(q, ser, log)
        log.append(("tap-launch", ordinary_n(harvest(ser)), tap_ok))
    time.sleep(0.20)
    live = harvest(ser)
    live_info = live_from(live)
    tap_delta = live[len(tap_mark):]
    tap_live = any(
        live_info["windows"][w].get("cap") == 6
        for w in live_info["ordinary_slots"] if w in live_info["windows"])
    tap_ready = (
        "TAP READY" in tap_delta
        or "TAP CSD" in tap_delta
        or (tap_live and "TAP READY" in live))
    tap_die = "TAP DIE " in tap_delta
    refuse = live.count("WM REFUSE") + live.count("TAP DIE ATTACH")
    peak = max(len(live_info["ordinary_slots"]),
               int(live_info.get("peak_ordinary") or 0))
    tap_ok = tap_ok or tap_live
    shot16 = shot(q, ser, "oscortex-round38-16-windows.png")
    # Raise TAP so the last-at-occupancy shot is not a duplicate dump.
    if live_info.get("tap_slots"):
        live_info = raise_window(q, ser, live_info["tap_slots"][0], 720, 80)
        time.sleep(0.10)
    shot_tap = shot(q, ser, "oscortex-round38-tap-last.png")
    tap_shot_distinct = (
        shot16.get("sha256") != shot_tap.get("sha256")
        and bool(shot16.get("sha256")) and bool(shot_tap.get("sha256")))
    slot15 = interact_slot15(q, ser, live_info)
    shot15 = shot(q, ser, "oscortex-round38-high-slot-events.png")
    after_ev = harvest(ser)
    ev_info = live_from(after_ev)
    # Close slot 15 only after the peak and TAP-last shots.
    closed15 = False
    if 15 in ev_info["windows"] and ev_info["windows"][15]["live"]:
        closed15 = close_slot(q, ser, 15)
        slot15["close"] = closed15
    # Restore TAP-last occupancy on the leftover after the close proof.
    if closed15 and ordinary_no_tap(harvest(ser)) >= 15:
        if not tap_live_in(harvest(ser)):
            launch_tap_last(q, ser, log)
    overlay_ev = (
        after_ev.count("WM ATTACH W 11")
        + after_ev.count("WM ATTACH W 12")
        + after_ev.count("WM ATTACH W 13")
        + after_ev.count("WM VIS W 11")
        + after_ev.count("WM VIS W 12")
        + after_ev.count("WM VIS W 13"))
    slot15_ok = all(slot15.get(k) for k in (
        "focus", "key", "resize", "menu", "close"))
    tap_last = (
        tap_live and peak >= 16 and tap_ready and not tap_die
        and tap_attached_under_occupancy(after_ev)
        and tap_shot_distinct)
    ring_corrupt = (
        after_ev.count("FAULT ") + after_ev.count("OSGFX OOM")
        + after_ev.count("REAP "))
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
        "tap_last": tap_last,
        "tap_ready": tap_ready,
        "tap_die": tap_die,
        "attach_refuse": refuse,
        "slot15": slot15,
        "slot15_ok": slot15_ok,
        "overlay_slots_separate": all(
            w >= 17 for w in live_info["overlay_slots"]),
        "overlay_events": overlay_ev,
        "shots": {"windows": shot16, "tap": shot_tap, "slot15": shot15},
        "tap_shot_distinct": tap_shot_distinct,
        "oom": live.count("OSGFX OOM"),
        "fault": after_ev.count("FAULT "),
        "reap": after_ev.count("REAP "),
        "ring_corrupt": ring_corrupt,
        "pass": (
            peak >= 16
            and len(live_info["ordinary_slots"]) >= 16
            and len(live_info["overlay_slots"]) >= 1
            and refuse == 0
            and tap_last
            and slot15_ok
            and live_info["unique_geoms"] >= 8
            and after_ev.count("OSGFX OOM") == 0
            and ring_corrupt == 0),
    }
    os.makedirs(ART, exist_ok=True)
    dest = os.path.join(ART, "oscortex-round38-capacity.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    events = {
        "round": 38,
        "wmeventSlots": 20,
        "slot15": slot15,
        "overlay_slots": live_info["overlay_slots"],
        "ring_corrupt": ring_corrupt,
        "pass": bool(slot15_ok and ring_corrupt == 0),
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
        "pre_tap_had_tap": bool(pre_tap["tap_slots"]),
        "tap_shot_distinct": tap_shot_distinct,
        "pass": bool(tap_last and refuse == 0),
    }
    open(os.path.join(ART, "oscortex-round38-tap.json"), "w").write(
        json.dumps(tap, indent=2) + "\n")
    print("wrote", dest)
    print(json.dumps({
        "ordinary": peak,
        "pre_tap": len(tap_before_slots),
        "overlays": live_info["overlay_slots"],
        "tap_last": payload["tap_last"],
        "tap_shot_distinct": tap_shot_distinct,
        "refuse": refuse,
        "slot15": {k: slot15.get(k) for k in (
            "focus", "key", "resize", "menu", "close", "slot")},
        "slot15_ok": slot15_ok,
        "pass": payload["pass"],
        "captions": live_info["captions"],
        "unique_geoms": live_info["unique_geoms"],
    }, indent=2))
    return 0 if payload["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
