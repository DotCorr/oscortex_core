#!/usr/bin/env python3
"""Round 40: full per-app action matrix, task pills, overview, lifecycle.

Silent/missed tokens fail. Live VIS/control formula each close.
TAP pill must be present. No full-app claim if any stem action is silent.
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
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r40")
p39.RUN = RUN
p39.ART = ART
CAP_NAME = p39.CAP_NAME
STEMS = p39.STEMS
STEM_DOCK = p39.STEM_DOCK

TASK_A_RE = re.compile(r"WM TASK A ([0-9A-F]{2}) R ([0-9A-F]{2})")
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
    if not overflow:
        pitch = 80 if n * 80 <= avail else max(36, avail // max(n, 1))
        try:
            ord_i = info["ordinary_slots"].index(win)
        except ValueError:
            return None
        return x0 + ord_i * pitch + max(pitch - 8, 24) // 2, 720 - 48 + 4 + 6 + 14
    pitch = 56
    vis = max(1, (avail - 32) // pitch)
    vis_s = vis - 1 if tap is not None and vis else vis
    if win == tap:
        return x0 + 16 + vis_s * pitch + 24, 720 - 48 + 4 + 6 + 14
    if win not in ordinary:
        return None
    idx = ordinary.index(win)
    if idx >= vis_s:
        return None
    return x0 + 16 + idx * pitch + 24, 720 - 48 + 4 + 6 + 14


def wait_token(ser, pred, timeout=2.0, mark=None):
    if mark is None:
        mark = len(serial_text())
    t1 = time.time()
    while time.time() - t1 < timeout:
        delta = serial_since(mark)
        if pred(delta):
            return delta
        time.sleep(0.04)
    return serial_since(mark)


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
        return ev
    w = slots[0]
    ev["slot"] = w
    g = info["windows"][w]
    p39.wallpaper_park(q, ser)
    time.sleep(0.04)
    pill = pill_xy(info, w)
    mark = len(serial_text())
    if pill:
        click(q, ser, pill[0], pill[1])
    else:
        hx = g["x"] + 10
        if cap == 6:
            hx = g["x"] + max(g["ww"], 80) - 36
        click(q, ser, hx, g["y"] + 8)
    delta = wait_token(ser, lambda d: "WM TASK A" in d or "WM FOCUS" in d, 1.2, mark)
    hexw = "%02X" % w
    ev["focus"] = (
        TASK_A_RE.search(delta) is not None
        or re.search(r"WM FOCUS G [0-9A-F]+ W %s\b" % hexw, delta) is not None
        or re.search(r"WM FOCUS  ?%s\b" % hexw, delta) is not None
        or "WM FOCUS G" in delta)
    ev["tokens"]["focus"] = [ln for ln in delta.splitlines()
                             if "FOCUS" in ln or "TASK A" in ln][:6]

    info = live_from(harvest(ser))
    g = info["windows"].get(w) or g
    mark = len(serial_text())
    try:
        m36.qcode_edge(q, "t", True)
        m36.qcode_edge(q, "t", False)
        time.sleep(0.06)
        m36.qcode_edge(q, "down", True)
        m36.qcode_edge(q, "down", False)
    except Exception:
        try:
            q.key("t")
        except Exception:
            pass
    delta = wait_token(ser, lambda d: any(s in d for s in (
        "WM KEY ", "TAP HIT", "FILES KEY", "FILES SEL", "FILES NAME",
        "SET ", "PLAY ", "STUDIO ", "BROWSE ", "WM COMMIT W ")), 1.0, mark)
    ev["key"] = bool(delta.strip()) and (
        "WM KEY " in delta
        or "TAP HIT" in delta
        or "FILES " in delta
        or "SET " in delta
        or "PLAY " in delta
        or "STUDIO " in delta
        or "BROWSE " in delta
        or "WM COMMIT W " in delta)
    ev["tokens"]["key"] = [ln for ln in delta.splitlines() if ln.strip()][:6]

    info = live_from(harvest(ser))
    g = info["windows"].get(w) or g
    x, y, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
    mark = len(serial_text())
    p38.right_click(q, ser, x + 10 if cap != 6 else x + max(ww, 80) - 36, y + 8)
    delta = wait_token(ser, lambda d: "CTX" in d or "MENU" in d or "TASK A" in d, 1.2, mark)
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

    info = live_from(harvest(ser))
    g = info["windows"].get(w) or g
    x, y, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
    mark = len(serial_text())
    nx, ny = min(x + 48, 1100), min(y + 36, 400)
    p38.drag(q, ser, x + 10, y + 8, nx, ny, steps=8)
    time.sleep(0.10)
    after = live_from(harvest(ser))
    g2 = after["windows"].get(w) or g
    delta = serial_since(mark)
    ev["move"] = (
        abs(g2.get("x", x) - x) >= 4
        or abs(g2.get("y", y) - y) >= 4
        or "WM MOVE" in delta
        or "WM VIS W %s" % hexw in delta
        or "WM DRAGEND" in delta)
    ev["tokens"]["move"] = [ln for ln in delta.splitlines() if ln.startswith("WM ")][:6]

    info = live_from(harvest(ser))
    g = info["windows"].get(w) or g2
    x, y, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
    if ev["resize_contract"]:
        ev["resize"] = True
        ev["tokens"]["resize"] = ["contract-fixed-size"]
    else:
        mark = len(serial_text())
        p38.drag(q, ser, x + max(ww, 8) - 4, y + max(hh, 8) - 4,
                 x + max(ww, 8) + 20, y + max(hh, 8) + 16, steps=6)
        time.sleep(0.10)
        delta = serial_since(mark)
        ev["resize"] = (
            re.search(r"WM REQ W %s\b" % hexw, delta) is not None
            or re.search(r"WM VIS W %s\b" % hexw, delta) is not None
            or ("WM HOLD W %X" % w) in delta
            or ("WM PEND W %s" % hexw) in delta)
        ev["tokens"]["resize"] = [ln for ln in delta.splitlines()
                                  if ln.startswith("WM ")][:6]

    info = live_from(harvest(ser))
    g = info["windows"].get(w)
    if g:
        mx, my = ctrl_of((g["x"], g["y"], g["ww"], g["hh"]), "min")
        mark = len(serial_text())
        click(q, ser, mx, my)
        delta = wait_token(ser, lambda d: "WM MIN W" in d, 1.2, mark)
        ev["min"] = MIN_RE.search(delta) is not None
        ev["tokens"]["min"] = [ln for ln in delta.splitlines() if "MIN" in ln][:4]
        time.sleep(0.08)
        info = live_from(harvest(ser))
        pill = pill_xy(info, w)
        mark = len(serial_text())
        if pill:
            click(q, ser, pill[0], pill[1])
        else:
            p39.dock_click(q, ser, STEM_DOCK.get(cap, 1))
        delta = wait_token(ser, lambda d: "WM REST" in d or "WM TASK A" in d, 1.2, mark)
        ev["rest"] = REST_RE.search(delta) is not None or "WM TASK A" in delta
        ev["tokens"]["rest"] = [ln for ln in delta.splitlines()
                                if "REST" in ln or "TASK A" in ln][:4]

    info = live_from(harvest(ser))
    g = info["windows"].get(w)
    if g and g.get("live"):
        cx, cy = ctrl_of((g["x"], g["y"], g["ww"], g["hh"]), "close")
        mark = len(serial_text())
        click(q, ser, cx, cy)
        delta = wait_token(ser, lambda d: "WM CLOSE W" in d, 1.4, mark)
        ev["close"] = (
            ("WM CLOSE W %02X" % w) in delta
            or ("WM CLOSE W %X " % w) in delta)
        ev["tokens"]["close"] = [ln for ln in delta.splitlines() if "CLOSE" in ln][:4]
    n0 = p39.ordinary_n(harvest(ser))
    mark = len(serial_text())
    p39.ensure_stem(q, ser, cap, [])
    delta = wait_token(ser, lambda d: "READY" in d or "ATTACH" in d, 2.0, mark)
    ev["relaunch"] = (
        cap in p39.stems_present(live_from(harvest(ser)))
        and (READY_RE.search(delta) is not None or "WM ATTACH" in delta
             or p39.ordinary_n(harvest(ser)) >= n0))
    ev["tokens"]["relaunch"] = [ln for ln in delta.splitlines()
                                if "READY" in ln or "ATTACH" in ln][:4]
    needed = ["focus", "key", "menu", "move", "min", "rest", "close", "relaunch"]
    if not ev["resize_contract"]:
        needed.append("resize")
    else:
        ev["resize"] = True
    ev["ok"] = all(ev.get(k) for k in needed)
    ev["silent"] = [k for k in needed if not ev.get(k)]
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
        g = info["windows"][w]
        cx, cy = ctrl_of((g["x"], g["y"], g["ww"], g["hh"]), "close")
        mark = len(serial_text())
        click(q, ser, cx, cy)
        delta = wait_token(ser, lambda d: "WM CLOSE W" in d, 1.2, mark)
        if ("WM CLOSE W %02X" % w) in delta or ("WM CLOSE W %X " % w) in delta:
            closes += 1
        n0 = p39.ordinary_no_tap(harvest(ser))
        mark = len(serial_text())
        p39.fill_files(q, ser, log)
        delta = wait_token(ser, lambda d: "FILES READY" in d or "WM ATTACH" in d, 1.6, mark)
        if "FILES READY" in delta or "WM ATTACH" in delta or p39.ordinary_no_tap(harvest(ser)) > n0:
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
        matrix[CAP_NAME[cap]] = matrix_one(q, ser, cap)
        p39.ensure_stem(q, ser, cap, log)
        if cap != 6:
            while p39.ordinary_no_tap(harvest(ser)) < 15:
                if not p39.fill_files(q, ser, log):
                    break
        else:
            if not live_from(harvest(ser)).get("tap_slots"):
                p39.ensure_tap_last(q, ser, log)

    after = live_from(harvest(ser))
    desk_task = DESK_TASK_RE.findall(harvest(ser))
    tap_pill = bool(desk_task and desk_task[-1][3])
    if not tap_pill:
        tap_pill = " TAP " in harvest(ser) and "DESK TASK" in harvest(ser)

    p39.dismiss(q)
    mark = len(serial_text())
    p39.fire_overview(q)
    ov = wait_token(ser, lambda d: "WM SWITCH SHOW" in d or "DESK SWITCH" in d, 2.0, mark)
    overview_show = "WM SWITCH SHOW" in ov or "DESK SWITCH" in ov
    if not overview_show:
        p39.alt_tab(q, 1)
        ov = wait_token(ser, lambda d: "WM SWITCH SHOW" in d, 1.5, mark)
        overview_show = "WM SWITCH SHOW" in ov
    overview_click = False
    overview_key = False
    if overview_show:
        mark = len(serial_text())
        try:
            m36.qcode_edge(q, "right", True)
            m36.qcode_edge(q, "right", False)
        except Exception:
            pass
        kd = wait_token(ser, lambda d: "WM SWITCH SHOW" in d, 0.8, mark)
        overview_key = "WM SWITCH SHOW" in kd
        # click first card body (not chips)
        sx = 16 + 8
        sy = 80 + 20 + 24
        mark = len(serial_text())
        click(q, ser, 200, 160)
        cd = wait_token(ser, lambda d: "SWITCH GO" in d or "FOCUS" in d or "TASK A" in d, 1.2, mark)
        overview_click = SWITCH_GO_RE.search(cd) is not None or "WM FOCUS" in cd
        try:
            q.key("esc")
        except Exception:
            pass

    life = lifecycle100(q, ser)
    p39.ensure_tap_last(q, ser, log)
    final = live_from(harvest(ser))
    shot_m = p39.shot(q, ser, "oscortex-round40-app-matrix.png")
    p39.fire_overview(q)
    time.sleep(0.2)
    shot_o = p39.shot(q, ser, "oscortex-round40-overview-actions.png")
    try:
        q.key("esc")
    except Exception:
        pass
    shot_t = p39.shot(q, ser, "oscortex-round40-task-pills.png")

    silent = {k: v.get("silent") for k, v in matrix.items()}
    matrix_ok = all(v.get("ok") for v in matrix.values()) and all(
        CAP_NAME[c] in matrix for c in STEMS)
    interact_cpath3 = len(CPATH3_RE.findall(serial_since(len(boot_blob))))
    payload = {
        "round": 40,
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
            and life["ok"]
            and interact_cpath3 == 0),
    }
    open(os.path.join(ART, "oscortex-round40-matrix.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round40-layout.json"), "w").write(
        json.dumps({
            "round": 40,
            "placement": "occupancy cascade + TAP at >=960 past FILES 520+400",
            "overview": "4x4 click/close/min + arrow nav",
            "unique_geoms": final["unique_geoms"],
            "overview_show": overview_show,
            "overview_click": overview_click,
            "overview_key": overview_key,
            "pass": bool(overview_show and overview_click),
        }, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round40-lifecycle.json"), "w").write(
        json.dumps({"round": 40, **life}, indent=2) + "\n")
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
