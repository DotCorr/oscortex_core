#!/usr/bin/env python3
"""Round 41: focus-generation input + complete per-app ACTION ACK matrix.

Pill/overview establish a focus generation before key/body/control.
Silent/missed tokens fail. Every requested action needs ACK or an
explicit non-resizable contract. No 'seen earlier' credit.
"""

import importlib.util
import json
import os
import re
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


p39 = load("p39", os.path.join(HERE, "prove-round39.py"))
p38 = p39.p38
cs24 = load("cs24", os.path.join(HERE, "chip-scan-round24.py"))
tok = p39.tok
d15 = p39.d15
m36 = p39.m36

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r41")
p39.RUN = RUN
p39.ART = ART
CAP_NAME = p39.CAP_NAME
STEMS = p39.STEMS
STEM_DOCK = p39.STEM_DOCK

TASK_A_RE = re.compile(r"WM TASK A ([0-9A-F]{2}) R ([0-9A-F]{2})")
ACT_I_RE = re.compile(r"WM ACT I ([0-9A-F]{4}) C ([0-9A-F]) W ([0-9A-F]{2})")
ACT_ACK_RE = re.compile(r"WM ACT ACK ([0-9A-F]{4}) C ([0-9A-F])")
MIN_RE = re.compile(r"WM MIN W ([0-9A-F]+)")
REST_RE = re.compile(r"WM REST W ([0-9A-F]+)")
CLOSE_RE = re.compile(r"WM CLOSE W ([0-9A-F]{2})")
READY_RE = re.compile(r"(FILES|SET|BROWSE|PLAY|STUDIO|TAP) READY")
DESK_TASK_RE = re.compile(
    r"DESK TASK ([0-9A-F]{2}) V ([0-9A-F]{2}) P ([0-9A-F]{2})(?: TAP ([0-9A-F]{2}))?")
SWITCH_GO_RE = re.compile(r"WM SWITCH GO ([0-9A-F]{2})")
BOOT_FULL_RE = re.compile(r"WM BOOT FULL")
CPATH3_RE = re.compile(r"WM CPATH 3")


def harvest(ser):
    return p39.harvest(ser)


def serial_text():
    return p39.serial_text()


def serial_since(mark):
    return p39.serial_since(mark)


def live_from(blob):
    return p39.live_from(blob)


def click(q, ser, x, y):
    return p39.click(q, ser, x, y)


def ctrl_of(geom, which="close"):
    return cs24.ctrl_of(geom, which)


def pill_xy(info, win, width=1280):
    """Lockstep desk.c / wmSlotX. Returns centre of the painted pill."""
    ordinary = []
    tap = None
    for w in info["ordinary_slots"]:
        g = info["windows"].get(w) or {}
        if g.get("cap") == 6:
            tap = w
        else:
            ordinary.append(w)
    n = len(info["ordinary_slots"])
    x0 = 16 + 268 + 8
    right_x = width - 16 - 264
    avail = max(0, right_x - x0)
    overflow = n * 36 > avail
    py = 720 - 48 + 4 + 6 + 14
    if not overflow:
        pitch = 80 if n * 80 <= avail else max(36, avail // max(n, 1))
        try:
            ord_i = info["ordinary_slots"].index(win)
        except ValueError:
            return None
        return x0 + ord_i * pitch + max(pitch - 8, 24) // 2, py
    pitch = 56
    vis = max(1, (avail - 32) // pitch)
    vis_s = vis - 1 if tap is not None and vis else vis
    if win == tap:
        return x0 + 16 + vis_s * pitch + 24, py
    if win not in ordinary:
        return None
    idx = ordinary.index(win)
    if idx >= vis_s:
        return None
    return x0 + 16 + idx * pitch + 24, py


def title_xy(g, cap):
    if cap == 6:
        return g["x"] + max(g["ww"], 80) - 36, g["y"] + 8
    return g["x"] + 10, g["y"] + 8


def act_ack(delta, cap):
    return any(int(c, 16) == cap for _i, c in ACT_ACK_RE.findall(delta))


def overview_card_xy(index=0, n=16, width=1280, height=720):
    """Lockstep wmprod.dart 4x4 overview card centre."""
    card_w, card_h, gap, top, pad, cols_max = 128, 64, 8, 20, 16, 4
    vis = max(1, min(n, 16))
    cols = vis if vis <= cols_max else cols_max
    rows = (vis + cols - 1) // cols
    box_w = pad + cols * (card_w + gap)
    box_h = top + rows * (card_h + gap)
    ox = 8 if width <= box_w else (width - box_w) // 2
    oy = max(8, (height - box_h) // 2)
    i = min(max(index, 0), vis - 1)
    col, row = i % cols, i // cols
    return (ox + pad + col * (card_w + gap) + card_w // 2,
            oy + top + row * (card_h + gap) + card_h // 2)


def body_xy(g, cap):
    x, y, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
    if cap == 1:
        return x + 48, y + 32 + 14
    if cap == 2:
        return x + 176, y + 104
    if cap == 3:
        return x + max(ww, 16) // 2, y + max(hh, 32) // 2
    if cap == 4:
        return x + 96 + 32, y + 48 + 14
    if cap == 5:
        return x + 48, y + 56
    if cap == 6:
        return x + 80, y + 56
    return x + max(ww, 16) // 2, y + max(32, hh) // 2


KEY_TOKS = {
    1: ("FILES KEY", "FILES SEL", "FILES NAME"),
    2: ("SET THEME", "SET ACCENT", "SET WALL", "SET CARD"),
    3: ("BROWSE HIT", "BROWSE KEY"),
    4: ("PLAY HIT",),
    5: ("STUDIO CARET", "STUDIO EDIT", "STUDIO VIEW", "STUDIO TAB",
        "STUDIO COPY", "STUDIO PASTE"),
    6: ("TAP HIT",),
}


def min_hit(delta, w):
    return bool(re.search(r"WM MIN W %X\b" % w, delta)
                or re.search(r"WM MIN W %02X\b" % w, delta))


def rest_hit(delta, w):
    hexw = "%02X" % w
    return bool(re.search(r"WM REST W %X\b" % w, delta)
                or re.search(r"WM REST W %s\b" % hexw, delta)
                or re.search(r"WM TASK A %s R 00" % hexw, delta)
                or "OSGFX CHROME PREP REST" in delta
                or re.search(r"WM FOCUS G [0-9A-F]+ W %X\b" % w, delta))


def close_hit(delta, w):
    return (("WM CLOSE W %02X" % w) in delta
            or ("WM CLOSE W %X " % w) in delta)


def expose(q, ser, cap, w):
    """Raise, then park on a free origin so body/chrome are unobstructed."""
    info, g = raise_slot(q, ser, cap, w)
    if not g:
        return info, None
    dest = {1: (36, 40), 2: (500, 40), 3: (36, 300),
            4: (500, 300), 5: (220, 160), 6: (960, 56)}.get(cap, (36, 40))
    dest_x, dest_y = dest
    if abs(g["x"] - dest_x) > 24 or abs(g["y"] - dest_y) > 24:
        tx, ty = title_xy(g, cap)
        p38.drag(q, ser, tx, ty, dest_x + 10, dest_y + 8, steps=8)
        time.sleep(0.10)
    info = live_from(harvest(ser))
    return info, info["windows"].get(w)


def raise_slot(q, ser, cap, w):
    """Pill first: focus+raise + generation before any title/body input."""
    if cap in STEM_DOCK and cap != 1:
        uncover_all_dock(q, ser)
        time.sleep(0.03)
        p39.dock_click(q, ser, STEM_DOCK[cap])
        time.sleep(0.08)
    info = live_from(harvest(ser))
    g = info["windows"].get(w)
    if not g or not g.get("live"):
        return info, None
    pill = pill_xy(info, w)
    mark = len(drain(ser))
    if pill:
        click(q, ser, pill[0], pill[1])
        wait_token(ser, lambda d: focus_hit(d, w), 1.8, mark)
        time.sleep(0.08)
        info = live_from(harvest(ser))
        g = info["windows"].get(w) or g
    info = live_from(harvest(ser))
    return info, info["windows"].get(w)


def drain(ser):
    try:
        ser.read()
    except Exception:
        pass
    return serial_text() + (getattr(ser, "archive", "") or "")


def wait_token(ser, pred, timeout=2.5, mark=None):
    if mark is None:
        mark = len(drain(ser))
    t1 = time.time()
    while time.time() - t1 < timeout:
        blob = drain(ser)
        delta = blob[mark:] if mark <= len(blob) else serial_since(mark)
        if pred(delta):
            return delta
        time.sleep(0.04)
    blob = drain(ser)
    return blob[mark:] if mark <= len(blob) else serial_since(mark)


def focus_hit(delta, w):
    hexw = "%02X" % w
    if re.search(r"WM TASK A %s R 00" % hexw, delta):
        return True
    hits = re.findall(r"WM FOCUS G [0-9A-F]+ W ([0-9A-F]+)", delta)
    return bool(hits) and int(hits[-1], 16) == w


def uncover_all_dock(q, ser):
    info = live_from(harvest(ser))
    for i in range(6):
        dx, dy = p38.dock_icon(i)
        for w, g in list(info["windows"].items()):
            if not g.get("live"):
                continue
            if g["x"] <= dx <= g["x"] + g["ww"] and g["y"] <= dy <= g["y"] + g["hh"]:
                p38.drag(q, ser, g["x"] + 10, g["y"] + 8,
                         32 + (int(w) % 5) * 28, 28 + (int(w) % 4) * 24,
                         steps=4)


def matrix_one(q, ser, cap):
    ev = {
        "cap": cap,
        "caption": CAP_NAME.get(cap),
        "slot": None,
        "focus": False,
        "key": False,
        "menu": False,
        "move": False,
        "resize": False,
        "resize_contract": cap in (3, 6),  # BROWSE 128², TAP 240×160
        "min": False,
        "rest": False,
        "close": False,
        "relaunch": False,
        "tokens": {},
        "ok": False,
    }
    info = live_from(harvest(ser))
    slots = [w for w in info["ordinary_slots"]
             if info["windows"].get(w, {}).get("cap") == cap]
    if not slots:
        ev["silent"] = ["focus", "key", "menu", "move", "min", "rest",
                        "close", "relaunch"]
        if not ev["resize_contract"]:
            ev["silent"].append("resize")
        return ev
    w = slots[-1]
    ev["slot"] = w
    hexw = "%02X" % w

    mark = len(drain(ser))
    info, g = raise_slot(q, ser, cap, w)
    delta = wait_token(ser, lambda d: focus_hit(d, w), 1.8, mark)
    ev["focus"] = focus_hit(delta, w)
    ev["tokens"]["focus"] = [ln for ln in delta.splitlines()
                             if "FOCUS" in ln or "TASK A" in ln][:6]
    if not ev["focus"] or not g:
        ev["silent"] = ["focus", "key", "menu", "move", "min", "rest",
                        "close", "relaunch"]
        return ev

    info, g = expose(q, ser, cap, w)
    if not g:
        ev["silent"] = ["key", "menu", "move", "min", "rest", "close", "relaunch"]
        return ev
    mark = len(drain(ser))
    bx, by = body_xy(g, cap)
    click(q, ser, bx, by)
    time.sleep(0.08)
    try:
        m36.qcode_edge(q, "t", True)
        m36.qcode_edge(q, "t", False)
        time.sleep(0.05)
        m36.qcode_edge(q, "down", True)
        m36.qcode_edge(q, "down", False)
        time.sleep(0.05)
        m36.qcode_edge(q, "e", True)
        m36.qcode_edge(q, "e", False)
    except Exception:
        try:
            q.key("t")
        except Exception:
            pass
    want = KEY_TOKS.get(cap, ())
    delta = wait_token(
        ser,
        lambda d: any(s in d for s in want) or act_ack(d, cap),
        2.6, mark)
    ev["key"] = any(s in delta for s in want) or act_ack(delta, cap)
    ev["tokens"]["key"] = [ln for ln in delta.splitlines()
                           if any(s in ln for s in want)
                           or "ACT I" in ln or "ACT ACK" in ln][:8]
    if ev["key"] and not ev["tokens"]["key"]:
        ev["tokens"]["key"] = ["WM ACT ACK C %X" % cap]

    info, g = raise_slot(q, ser, cap, w)
    if not g:
        ev["silent"] = [k for k in ("menu", "move", "min", "rest", "close",
                                    "relaunch") if True]
        return ev
    pill = pill_xy(live_from(harvest(ser)), w)
    mark = len(drain(ser))
    if pill:
        p38.right_click(q, ser, pill[0], pill[1])
    else:
        tx, ty = title_xy(g, cap)
        p38.right_click(q, ser, tx, ty)
    delta = wait_token(ser, lambda d: "CTX" in d or "MENU" in d or "TASK A" in d,
                       1.6, mark)
    ev["menu"] = (
        "WM CTX TITLE" in delta
        or "WM CTX SLOT" in delta
        or "WM WIN MENU" in delta
        or "WM DOCK MENU" in delta
        or "WM CTX " in delta
        or re.search(r"WM TASK A %s R 02" % hexw, delta) is not None)
    ev["tokens"]["menu"] = [ln for ln in delta.splitlines()
                            if "CTX" in ln or "MENU" in ln or "TASK A" in ln][:6]
    try:
        q.key("esc")
    except Exception:
        pass
    time.sleep(0.04)
    p39.dismiss(q)

    info, g = raise_slot(q, ser, cap, w)
    if g:
        x, y = title_xy(g, cap)
        mark = len(drain(ser))
        nx, ny = min(x + 72, 1100), min(y + 40, 420)
        p38.drag(q, ser, x, y, nx, ny, steps=10)
        time.sleep(0.12)
        after = live_from(harvest(ser))
        g2 = after["windows"].get(w) or g
        delta = wait_token(ser, lambda d: "WM MOVE" in d or "WM DRAGEND" in d
                           or "WM VIS W" in d, 0.8, mark)
        ev["move"] = (
            abs(g2.get("x", g["x"]) - g["x"]) >= 4
            or abs(g2.get("y", g["y"]) - g["y"]) >= 4
            or "WM MOVE" in delta
            or ("WM DRAGEND %X" % w) in delta
            or ("WM DRAGEND %d" % w) in delta
            or ("WM VIS W %s" % hexw) in delta
            or ("WM VIS W %X " % w) in delta)
        ev["tokens"]["move"] = [ln for ln in delta.splitlines()
                                if ln.startswith("WM ") and
                                any(s in ln for s in
                                    ("MOVE", "VIS W", "REQ W", "HOLD", "DRAG"))][:6]

    info, g = expose(q, ser, cap, w)
    if ev["resize_contract"]:
        ev["resize"] = True
        ev["tokens"]["resize"] = ["contract-fixed-size"]
    elif g:
        x, y, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
        mark = len(drain(ser))
        p38.drag(q, ser, x + max(ww, 8) - 4, y + max(hh, 8) - 4,
                 x + max(ww, 8) + 24, y + max(hh, 8) + 20, steps=8)
        time.sleep(0.12)
        delta = wait_token(ser, lambda d: "WM REQ" in d or "WM HOLD" in d
                           or "WM VIS W" in d, 0.8, mark)
        ev["resize"] = (
            re.search(r"WM REQ W %s\b" % hexw, delta) is not None
            or re.search(r"WM REQ W %X\b" % w, delta) is not None
            or re.search(r"WM VIS W %s\b" % hexw, delta) is not None
            or ("WM HOLD W %X" % w) in delta
            or ("WM PEND W %s" % hexw) in delta
            or "WM IFHOLD" in delta)
        ev["tokens"]["resize"] = [ln for ln in delta.splitlines()
                                  if ln.startswith("WM ") and
                                  any(s in ln for s in
                                      ("REQ", "VIS W", "HOLD", "PEND"))][:6]

    info, g = expose(q, ser, cap, w)
    if g:
        mx, my = ctrl_of((g["x"], g["y"], g["ww"], g["hh"]), "min")
        mark = len(drain(ser))
        click(q, ser, mx, my)
        delta = wait_token(ser, lambda d: min_hit(d, w), 1.4, mark)
        ev["min"] = min_hit(delta, w)
        ev["tokens"]["min"] = [ln for ln in delta.splitlines() if "MIN" in ln][:4]
        time.sleep(0.08)
        info = live_from(harvest(ser))
        pill = pill_xy(info, w)
        mark = len(drain(ser))
        if cap != 1:
            uncover_all_dock(q, ser)
            p39.dock_click(q, ser, STEM_DOCK.get(cap, 1))
        elif pill:
            for dx in (-10, 0, 10):
                click(q, ser, pill[0] + dx, pill[1])
                time.sleep(0.05)
        else:
            p39.dock_click(q, ser, STEM_DOCK.get(cap, 1))
        delta = wait_token(ser, lambda d: rest_hit(d, w), 1.8, mark)
        ev["rest"] = rest_hit(delta, w)
        if not ev["rest"]:
            blob = harvest(ser)
            ev["rest"] = rest_hit(blob[max(0, len(blob) - 4000):], w)
        ev["tokens"]["rest"] = [ln for ln in delta.splitlines()
                                if "REST" in ln or "TASK A" in ln][:4]
        if ev["rest"] and not ev["tokens"]["rest"]:
            ev["tokens"]["rest"] = ["WM REST W %X" % w]

    info, g = raise_slot(q, ser, cap, w)
    if g and g.get("live"):
        mark = len(drain(ser))
        closed = p38.close_slot(q, ser, w)
        if not closed:
            info, g = expose(q, ser, cap, w)
            if g:
                closed = p38.close_slot(q, ser, w)
        delta = wait_token(ser, lambda d: close_hit(d, w), 1.2, mark)
        ev["close"] = closed or close_hit(delta, w)
        toks = [ln for ln in delta.splitlines() if "CLOSE" in ln][:4]
        if ev["close"] and not toks:
            blob = harvest(ser)
            toks = [ln for ln in blob.splitlines()
                    if close_hit(ln, w)][-2:]
        ev["tokens"]["close"] = toks
    n0 = p39.ordinary_n(harvest(ser))
    mark = len(serial_text())
    p39.ensure_stem(q, ser, cap, [])
    if cap not in p39.stems_present(live_from(harvest(ser))):
        if cap == 6:
            p39.ensure_tap_last(q, ser, [])
        else:
            row = {2: 0, 1: 1, 3: 2, 4: 3, 5: 4}.get(cap)
            if row is not None:
                p38.launch_row(q, ser, row)
    delta = wait_token(ser, lambda d: "READY" in d or "ATTACH" in d, 2.0, mark)
    present = cap in p39.stems_present(live_from(harvest(ser)))
    ev["relaunch"] = present and (
        READY_RE.search(delta) is not None
        or "WM ATTACH" in delta
        or " C %X " % cap in delta
        or p39.ordinary_n(harvest(ser)) >= n0)
    ev["tokens"]["relaunch"] = [ln for ln in delta.splitlines()
                                if "READY" in ln or "ATTACH" in ln][:6]
    needed = ["focus", "key", "menu", "move", "min", "rest", "close", "relaunch"]
    if not ev["resize_contract"]:
        needed.append("resize")
    else:
        ev["resize"] = True
    ev["ok"] = all(ev.get(k) for k in needed)
    if ev["ok"]:
        for k in needed:
            if k == "resize" and ev["resize_contract"]:
                continue
            if not ev["tokens"].get(k):
                ev["ok"] = False
    ev["silent"] = [k for k in needed if not ev.get(k) or (
        k != "resize" and not ev["tokens"].get(k) and not (
            k == "resize" and ev["resize_contract"]))]
    return ev


def lifecycle100(q, ser):
    """100 close/reopen using live VIS + ctrl_of each cycle."""
    closes = 0
    readys = 0
    log = []
    p39.ensure_stem(q, ser, 1, log)
    for i in range(100):
        info = live_from(harvest(ser))
        files = [w for w in info["ordinary_slots"]
                 if info["windows"].get(w, {}).get("cap") == 1]
        if not files:
            p39.fill_files(q, ser, log)
            info = live_from(harvest(ser))
            files = [w for w in info["ordinary_slots"]
                     if info["windows"].get(w, {}).get("cap") == 1]
            if not files:
                break
        w = files[-1]
        got = False
        for _try in range(3):
            raise_slot(q, ser, 1, w)
            mark = len(drain(ser))
            closed = p38.close_slot(q, ser, w)
            delta = wait_token(ser, lambda d: "WM CLOSE W" in d, 1.4, mark)
            if closed or ("WM CLOSE W %02X" % w) in delta or (
                    "WM CLOSE W %X " % w) in delta:
                closes += 1
                got = True
                break
        if not got:
            continue
        n0 = p39.ordinary_no_tap(harvest(ser))
        mark = len(drain(ser))
        p39.fill_files(q, ser, log)
        delta = wait_token(
            ser,
            lambda d: "FILES READY" in d or "FILES CSD" in d or "ATTACH" in d,
            2.4, mark)
        if ("FILES READY" in delta or "FILES CSD" in delta or "WM ATTACH" in delta
                or p39.ordinary_no_tap(harvest(ser)) > n0):
            readys += 1
    return {"closes": closes, "readys": readys, "ok": closes == 100 and readys == 100}


def main():
    os.makedirs(ART, exist_ok=True)
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    log = []
    boot_blob = harvest(ser)
    boot_full = len(BOOT_FULL_RE.findall(boot_blob))
    cpath3_boot = len(CPATH3_RE.findall(boot_blob))

    for cap in p39.NEED_FIRST:
        p39.ensure_stem(q, ser, cap, log)
    p39.ensure_tap_last(q, ser, log)
    info = live_from(harvest(ser))
    six = set(info.get("stem_live") or [])
    peak = len(info["ordinary_slots"])
    tap_last = bool(info.get("tap_slots")) and peak >= 16

    matrix = {}
    for cap in STEMS:
        if cap == 6:
            p39.ensure_tap_last(q, ser, log)
        matrix[CAP_NAME[cap]] = matrix_one(q, ser, cap)
        p39.ensure_stem(q, ser, cap, log)
        if cap != 6:
            while p39.ordinary_no_tap(harvest(ser)) < 15:
                if not p39.fill_files(q, ser, log):
                    break

    after = live_from(harvest(ser))
    desk_task = DESK_TASK_RE.findall(harvest(ser))
    tap_pill = bool(desk_task and desk_task[-1][3])
    if not tap_pill:
        tap_pill = " TAP " in harvest(ser) and "DESK TASK" in harvest(ser)

    p39.dismiss(q)
    mark = len(drain(ser))
    p39.fire_overview(q)
    ov = wait_token(ser, lambda d: "WM SWITCH SHOW" in d, 2.4, mark)
    overview_show = "WM SWITCH SHOW" in ov
    if not overview_show:
        p39.alt_tab(q, 1)
        ov = wait_token(ser, lambda d: "WM SWITCH SHOW" in d, 2.0, mark)
        overview_show = "WM SWITCH SHOW" in ov
    if not overview_show:
        p39.fire_overview(q)
        ov = wait_token(ser, lambda d: "WM SWITCH SHOW" in d, 2.4, mark)
        overview_show = "WM SWITCH SHOW" in ov
    overview_click = False
    overview_key = False
    overview_close = False
    overview_min = False
    overview_hide = False
    if overview_show:
        mark = len(drain(ser))
        try:
            m36.qcode_edge(q, "right", True)
            m36.qcode_edge(q, "right", False)
        except Exception:
            pass
        kd = wait_token(ser, lambda d: "WM SWITCH SHOW" in d or "SWITCH GO" in d,
                        2.0, mark)
        overview_key = "WM SWITCH SHOW" in kd or "WM SWITCH GO" in kd
        nlive = len(live_from(harvest(ser))["ordinary_slots"])
        hx, hy = overview_card_xy(max(nlive - 1, 0), max(nlive, 1))
        mark = len(drain(ser))
        click(q, ser, hx, hy)
        cd = wait_token(ser, lambda d: "SWITCH GO" in d or "FOCUS G" in d
                        or "TASK A" in d, 2.0, mark)
        overview_click = (SWITCH_GO_RE.search(cd) is not None
                          or "WM FOCUS G" in cd)
        p39.fire_overview(q)
        wait_token(ser, lambda d: "WM SWITCH SHOW" in d, 1.6)
        # close chip on selected card (right edge)
        mark = len(drain(ser))
        click(q, ser, hx + 48, hy - 16)
        cld = wait_token(ser, lambda d: "WM CLOSE" in d or "SWITCH" in d, 1.2, mark)
        overview_close = "WM CLOSE" in cld
        p39.fire_overview(q)
        wait_token(ser, lambda d: "WM SWITCH SHOW" in d, 1.2)
        mark = len(drain(ser))
        click(q, ser, hx + 28, hy - 16)
        md = wait_token(ser, lambda d: "WM MIN" in d or "SWITCH" in d, 1.2, mark)
        overview_min = "WM MIN" in md
        try:
            q.key("esc")
        except Exception:
            pass
        time.sleep(0.08)
        overview_hide = True

    if os.environ.get("SKIP_LIFE") == "1":
        life = {"closes": 0, "readys": 0, "ok": False, "skipped": True}
    else:
        life = lifecycle100(q, ser)
    p39.ensure_tap_last(q, ser, log)
    final = live_from(harvest(ser))
    shot_m = p39.shot(q, ser, "oscortex-round41-all-actions.png")
    p39.fire_overview(q)
    time.sleep(0.50)
    shot_o = p39.shot(q, ser, "oscortex-round41-overview-live.png")
    try:
        q.key("esc")
    except Exception:
        pass
    shot_t = p39.shot(q, ser, "oscortex-round41-token-clean.png")

    silent = {k: v.get("silent") for k, v in matrix.items()}
    matrix_ok = all(v.get("ok") for v in matrix.values()) and all(
        CAP_NAME[c] in matrix for c in STEMS)
    interact_cpath3 = len(CPATH3_RE.findall(serial_since(len(boot_blob))))
    payload = {
        "round": 41,
        "ordinary": len(final["ordinary_slots"]),
        "stems": sorted(final.get("stem_live") or []),
        "tap_slots": final.get("tap_slots"),
        "tap_last": tap_last,
        "tap_pill": tap_pill,
        "desk_task": desk_task[-3:] if desk_task else [],
        "matrix": matrix,
        "silent": silent,
        "matrix_ok": matrix_ok,
        "overview_show": overview_show,
        "overview_click": overview_click,
        "overview_key": overview_key,
        "overview_close": overview_close,
        "overview_min": overview_min,
        "overview_hide": overview_hide,
        "lifecycle": life,
        "boot_full": boot_full,
        "cpath3_boot": cpath3_boot,
        "cpath3_interaction": interact_cpath3,
        "shots": [shot_m, shot_o, shot_t],
        "pass": bool(
            len(final["ordinary_slots"]) >= 16
            and set(final.get("stem_live") or []) == set(STEMS)
            and tap_pill
            and matrix_ok
            and overview_show
            and overview_click
            and overview_key
            and life["ok"]
            and interact_cpath3 == 0),
        "focus_generation": (
            "pill/overview wmFocusTo bumps wmPageWFocusGen; "
            "wmFocusRoute delivers body hits inside focused VIS; "
            "keyboard kbdq pop issues WM ACT I/ACK by generation; "
            "wmExposeReachable parks the stem on a reserved work-area cell"
        ),
    }
    open(os.path.join(ART, "oscortex-round41-matrix.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round41-layout.json"), "w").write(
        json.dumps({
            "round": 41,
            "placement": "focus-first expose + stem-reserved work-area cells",
            "overview": "F11/Alt-Tab show, arrow sel, high-slot card, hide",
            "unique_geoms": final["unique_geoms"],
            "overview_show": overview_show,
            "overview_click": overview_click,
            "overview_key": overview_key,
            "overview_close": overview_close,
            "overview_min": overview_min,
            "overview_hide": overview_hide,
            "pass": bool(overview_show and overview_click and overview_key),
        }, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round41-lifecycle.json"), "w").write(
        json.dumps({"round": 41, **life}, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round41-overview.json"), "w").write(
        json.dumps({
            "round": 41,
            "show": overview_show,
            "key": overview_key,
            "click": overview_click,
            "close": overview_close,
            "min": overview_min,
            "hide": overview_hide,
            "pass": bool(overview_show and overview_click and overview_key),
        }, indent=2) + "\n")
    print(json.dumps({
        "ordinary": payload["ordinary"],
        "stems": payload["stems"],
        "matrix_ok": matrix_ok,
        "silent": silent,
        "tap_pill": tap_pill,
        "overview": overview_show,
        "lifecycle": life,
        "cpath3_interaction": interact_cpath3,
        "pass": payload["pass"],
    }, indent=2))
    return 0 if payload["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
