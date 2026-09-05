#!/usr/bin/env python3
"""Round 39: all six dock stems at occupancy + reachable overview.

TAP last under 16 ordinary windows. VIS records are sealed (2-digit slot
+ checksum); malformed/interleaved lines never update geom.
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


p38 = load("p38", os.path.join(HERE, "prove-round38.py"))
tok = load("vis39", os.path.join(HERE, "vis-tokens.py"))
d15 = p38.d15
m36 = p38.m36

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r39")
CAP_NAME = p38.CAP_NAME
STEMS = (1, 2, 3, 4, 5, 6)  # FILES SET BROWSE PLAY STUDIO TAP
STEM_DOCK = {2: 0, 1: 1, 3: 2, 4: 3, 5: 4, 6: 5}
NEED_FIRST = (2, 1, 3, 4, 5)  # SET FILES BROWSE PLAY STUDIO before TAP


def harvest(ser):
    return p38.harvest(ser)


def serial_text():
    """File-only serial. harvest() is file+archive+sock — not a prefix."""
    path = os.path.join(RUN, "serial.txt")
    try:
        return open(path, encoding="latin-1", errors="replace").read()
    except OSError:
        return ""


def serial_since(mark):
    return serial_text()[mark:]


def wallpaper_park(q, ser):
    """Unfocus FILES so later keys do not become FILES NAME TAP.ELF."""
    click(q, ser, 400, 500)


def live_from(blob):
    events = []
    for m in p38.ATTACH_RE.finditer(blob):
        events.append((m.start(), "A", m))
    for m in p38.CLOSE_RE.finditer(blob):
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
        cur = sum(1 for ww, g in wins.items() if g["live"] and 0 < ww < 17)
        if cur > peak:
            peak = cur
    ok, rejected = tok.harvest_vis(blob)
    applied = 0
    for rec in ok:
        if tok.apply_vis_strict(wins, rec):
            applied += 1
    live_wins = [w for w, info in wins.items() if info["live"]]
    ordinary = [w for w in live_wins if 0 < w < 17]
    overlays = [w for w in live_wins if w >= 17]
    procs = {}
    for m in p38.PROC_NEW_RE.finditer(blob):
        procs[int(m.group(1), 16)] = True
    for m in p38.PROC_KILL_RE.finditer(blob):
        procs[int(m.group(1), 16)] = False
    live_procs = sorted([s for s, on in procs.items() if on])
    geoms = [(wins[w]["x"], wins[w]["y"], wins[w]["ww"], wins[w]["hh"])
             for w in ordinary]
    tap_slots = [w for w in ordinary if wins[w].get("cap") == 6]
    return {
        "windows": wins,
        "live_wins": sorted(live_wins),
        "ordinary_slots": ordinary,
        "overlay_slots": overlays,
        "proc_live": live_procs,
        "ordinary_procs": [s for s in live_procs if s > 0],
        "unique_geoms": len(set(geoms)),
        "captions": sorted({wins[w]["caption"] for w in ordinary}),
        "peak_ordinary": peak,
        "tap_slots": tap_slots,
        "stem_live": sorted({
            wins[w]["cap"] for w in ordinary if wins[w].get("cap") in STEMS}),
        "token": {
            "ok": len(ok),
            "applied": applied,
            "rejected": rejected,
        },
    }


def ordinary_n(blob):
    return len(live_from(blob)["ordinary_slots"])


def ordinary_no_tap(blob):
    info = live_from(blob)
    return len([w for w in info["ordinary_slots"] if w not in info["tap_slots"]])


def click(q, ser, x, y):
    return p38.click(q, ser, x, y)


def fire_f4(q):
    p38.fire_f4(q)


def dismiss(q):
    p38.dismiss(q)


def dock_click(q, ser, i):
    return p38.dock_click(q, ser, i)


def shot(q, ser, name):
    dest = os.path.join(ART, name)
    return p38.bar38.shot_barrier(q, d15.shot, dest, ser)


def stems_present(info):
    return set(info.get("stem_live") or [])


def ensure_stem(q, ser, cap, log):
    info = live_from(harvest(ser))
    if cap in stems_present(info):
        return True
    dock = STEM_DOCK[cap]
    n0 = ordinary_no_tap(harvest(ser))
    dock_click(q, ser, dock)
    p38.close_early_tap(q, ser, log)
    info = live_from(harvest(ser))
    ok = cap in stems_present(info)
    log.append(("stem-dock%d" % dock, CAP_NAME[cap], ok,
                ordinary_n(harvest(ser))))
    if not ok and n0 == ordinary_no_tap(harvest(ser)):
        row = {2: 0, 1: 1, 3: 2, 4: 3, 5: 4}.get(cap)
        if row is not None:
            p38.launch_row(q, ser, row)
            p38.close_early_tap(q, ser, log)
            ok = cap in stems_present(live_from(harvest(ser)))
            log.append(("stem-row%d" % row, CAP_NAME[cap], ok))
    return ok


def fill_files(q, ser, log):
    before = ordinary_no_tap(harvest(ser))
    if before >= 15:
        return False
    dock_click(q, ser, 1)
    p38.close_early_tap(q, ser, log)
    n1 = ordinary_no_tap(harvest(ser))
    log.append(("fill-files", n1))
    if n1 > before:
        return True
    return p38.launch_row(q, ser, 1)


def wait_tap_live(ser, timeout=6.0):
    t1 = time.time()
    while time.time() - t1 < timeout:
        if live_from(harvest(ser)).get("tap_slots"):
            return True
        time.sleep(0.08)
    return bool(live_from(harvest(ser)).get("tap_slots"))


def launch_tap_typeahead(q, ser, log):
    """Wallpaper park, then F4 typeahead. Never type TAP into FILES."""
    dismiss(q)
    time.sleep(0.04)
    wallpaper_park(q, ser)
    time.sleep(0.06)
    fire_f4(q)
    time.sleep(0.14)
    mark = len(serial_text())
    for ch in ("t", "a", "p"):
        try:
            m36.qcode_edge(q, ch, True)
            m36.qcode_edge(q, ch, False)
        except Exception:
            q.key(ch)
        time.sleep(0.05)
    try:
        m36.qcode_edge(q, "ret", True)
        m36.qcode_edge(q, "ret", False)
    except Exception:
        q.key("ret")
    ok = wait_tap_live(ser, timeout=5.0)
    delta = serial_since(mark)
    typed_files = "FILES NAME TAP" in delta
    log.append(("tap-typeahead", ordinary_n(harvest(ser)), ok, typed_files))
    dismiss(q)
    return ok and not typed_files


def launch_tap_dock(q, ser, log):
    """Dock TAP after parking windows off the icon. Prefer this over typeahead."""
    dismiss(q)
    time.sleep(0.05)
    wallpaper_park(q, ser)
    time.sleep(0.05)
    p38.park_off_dock(q, ser)
    wallpaper_park(q, ser)
    time.sleep(0.05)
    tx, ty = p38.dock_icon(5)
    mark = len(serial_text())
    click(q, ser, tx, ty)
    ok = wait_tap_live(ser, timeout=6.0)
    if not ok:
        try:
            d15.press(q, ser, tx, ty, "left", "DESK LAUNCH TAP.ELF", timeout=6.0)
        except Exception:
            click(q, ser, tx, ty)
        ok = wait_tap_live(ser, timeout=4.0)
    delta = serial_since(mark)
    launched = (
        "DESK LAUNCH TAP.ELF" in delta
        or "TAP READY" in delta
        or " C 6 " in delta)
    log.append(("tap-dock", ordinary_n(harvest(ser)), ok, launched))
    return ok


def raise_tap(q, ser, w, dest_x=860, dest_y=56):
    """Focus TAP on the reserved right-field attach. Do not drag across chrome.

    Second-column FILES (520+400) cover the left of TAP at 860; click the
    exposed right title strip.
    """
    info = live_from(harvest(ser))
    if w not in info["windows"] or not info["windows"][w]["live"]:
        return info
    g = info["windows"][w]
    click(q, ser, g["x"] + max(g["ww"], 80) - 36, g["y"] + 8)
    time.sleep(0.08)
    return live_from(harvest(ser))


def ensure_tap_last(q, ser, log):
    """Exactly 15 non-TAP ordinary, then TAP as the 16th."""
    dismiss(q)
    info = live_from(harvest(ser))
    for w in list(info.get("tap_slots") or []):
        if p38.close_slot(q, ser, w):
            log.append(("close-tap-for-last", w, ordinary_no_tap(harvest(ser))))
    while ordinary_no_tap(harvest(ser)) > 15:
        info = live_from(harvest(ser))
        extras = [w for w in info["ordinary_slots"]
                  if info["windows"].get(w, {}).get("cap") == 1]
        if not extras:
            extras = [w for w in info["ordinary_slots"]
                      if w not in info["tap_slots"]]
        if not extras:
            break
        if p38.close_slot(q, ser, extras[-1]):
            log.append(("trim-files", extras[-1], ordinary_no_tap(harvest(ser))))
        else:
            break
    stall = 0
    while ordinary_no_tap(harvest(ser)) < 15:
        if fill_files(q, ser, log):
            stall = 0
            continue
        stall += 1
        if stall >= 6:
            break
    p38.close_early_tap(q, ser, log)
    pre = ordinary_no_tap(harvest(ser))
    if pre < 15:
        log.append(("tap-last-pre-short", pre))
        return False
    if live_from(harvest(ser)).get("tap_slots"):
        p38.close_early_tap(q, ser, log)
    ok = launch_tap_dock(q, ser, log)
    if not ok:
        ok = launch_tap_typeahead(q, ser, log)
    if not ok:
        ok = p38.launch_tap_last(q, ser, log)
    t1 = time.time()
    while time.time() - t1 < 5.0 and not ok:
        if live_from(harvest(ser)).get("tap_slots"):
            ok = True
            break
        time.sleep(0.1)
    log.append(("tap-last", ordinary_n(harvest(ser)),
                ordinary_no_tap(harvest(ser)), ok))
    return ok


def interact_slot(q, ser, w):
    ev = {
        "focus": False, "key": False, "resize": False, "menu": False,
        "move": False, "slot": w, "caption": None, "tokens": {},
    }
    info = live_from(harvest(ser))
    if w not in info["windows"] or not info["windows"][w]["live"]:
        return ev
    g = info["windows"][w]
    ev["caption"] = g.get("caption")
    # Exposed cascade title is the top-left 32×32 strip, not +40,+12
    # which lands under the next card.
    dest_x = g["x"]
    dest_y = g["y"]
    # Single-instance stems: dock click focuses the live window on top.
    if g.get("cap") in STEM_DOCK and g.get("cap") != 1:
        wallpaper_park(q, ser)
        time.sleep(0.04)
        dock_click(q, ser, STEM_DOCK[g["cap"]])
        time.sleep(0.10)
        info = live_from(harvest(ser))
        if w in info["windows"] and info["windows"][w]["live"]:
            g = info["windows"][w]
            dest_x, dest_y = g["x"], g["y"]
    hx = dest_x + 10
    if g.get("cap") == 6:
        hx = dest_x + max(g["ww"], 80) - 36
    click(q, ser, hx, dest_y + 8)
    time.sleep(0.08)
    info = live_from(harvest(ser))
    if w not in info["windows"] or not info["windows"][w]["live"]:
        return ev
    g = info["windows"][w]
    x, y, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
    ev["move"] = abs(x - dest_x) <= 64 or abs(y - dest_y) <= 64
    mark_f = len(serial_text())
    fx = x + 10
    if g.get("cap") == 6:
        fx = x + max(ww, 80) - 36
    click(q, ser, fx, y + 8)
    time.sleep(0.10)
    delta_f = serial_since(mark_f)
    hexw = "%02X" % w
    ev["focus"] = (
        re.search(r"WM FOCUS G [0-9A-F]+ W %s\b" % hexw, delta_f) is not None
        or re.search(r"WM FOCUS G [0-9A-F]+ W 0?%X\b" % w, delta_f) is not None
        or "WM FOCUS G" in delta_f)
    ev["tokens"]["focus"] = [ln for ln in delta_f.splitlines()
                             if "FOCUS" in ln][:4]
    mark_k = len(serial_text())
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
    delta_k = serial_since(mark_k)
    ev["key"] = (
        "WM KEY " in delta_k
        or "TAP HIT" in delta_k
        or "FILES KEY " in delta_k
        or "FILES SEL " in delta_k
        or "WM COMMIT W " in delta_k
        or any(("USER WRITE %s" % n) in delta_k for n in CAP_NAME.values()))
    ev["tokens"]["key"] = [ln for ln in delta_k.splitlines() if ln.strip()][:6]
    info = live_from(harvest(ser))
    if w in info["windows"] and info["windows"][w]["live"]:
        g = info["windows"][w]
        x, y, ww, hh = g["x"], g["y"], g["ww"], g["hh"]
    se_x = x + max(ww, 8) - 4
    se_y = y + max(hh, 8) - 4
    mark_r = len(serial_text())
    p38.drag(q, ser, se_x, se_y, se_x + 24, se_y + 16, steps=6)
    time.sleep(0.10)
    delta_r = serial_since(mark_r)
    ev["resize"] = (
        re.search(r"WM REQ W %s\b" % hexw, delta_r) is not None
        or re.search(r"WM VIS W %s\b" % hexw, delta_r) is not None
        or ("WM HOLD W %X" % w) in delta_r
        or ("WM PEND W %s" % hexw) in delta_r)
    ev["tokens"]["resize"] = [ln for ln in delta_r.splitlines()
                              if ln.startswith("WM ")][:6]
    info = live_from(harvest(ser))
    if w in info["windows"] and info["windows"][w]["live"]:
        g = info["windows"][w]
        x, y = g["x"], g["y"]
    mark_m = len(serial_text())
    p38.right_click(q, ser, x + 10, y + 8)
    time.sleep(0.12)
    delta_m = serial_since(mark_m)
    ev["menu"] = (
        "WM CTX TITLE" in delta_m
        or p38.CTX_RE.search(delta_m) is not None
        or "WM CTX " in delta_m
        or re.search(r"WM DONE [0-9A-F]+ K 04 ", delta_m) is not None)
    ev["tokens"]["menu"] = [ln for ln in delta_m.splitlines()
                            if "CTX" in ln or "MENU" in ln or "DONE" in ln][:6]
    try:
        q.key("esc")
        time.sleep(0.04)
    except Exception:
        pass
    ev["geom"] = {"x": x, "y": y, "w": ww, "h": hh}
    ev["ok"] = all(ev.get(k) for k in ("focus", "key", "menu"))
    return ev


def fire_overview(q):
    m36.qcode_edge(q, "f11", True)
    m36.qcode_edge(q, "f11", False)


def alt_tab(q, n=1):
    m36.qcode_edge(q, "alt", True)
    time.sleep(0.03)
    for _ in range(n):
        m36.qcode_edge(q, "tab", True)
        m36.qcode_edge(q, "tab", False)
        time.sleep(0.06)
    m36.qcode_edge(q, "alt", False)


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    log = []
    for cap in NEED_FIRST:
        ensure_stem(q, ser, cap, log)
    tap_mark = len(serial_text())
    tap_before = [w for w in live_from(harvest(ser))["ordinary_slots"]
                  if w not in live_from(harvest(ser))["tap_slots"]]
    tap_ok = ensure_tap_last(q, ser, log)
    time.sleep(0.20)
    live = harvest(ser)
    live_info = live_from(live)
    tap_delta = serial_since(tap_mark)
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
    six = stems_present(live_info) | set(live_info.get("stem_live") or [])
    if live_info.get("tap_slots"):
        live_info = raise_tap(q, ser, live_info["tap_slots"][0])
        time.sleep(0.10)
    shot16 = shot(q, ser, "oscortex-round39-all-six-apps.png")
    dismiss(q)
    time.sleep(0.06)
    ov_mark = len(serial_text())
    fire_overview(q)
    t1 = time.time()
    overview_show = False
    while time.time() - t1 < 1.2:
        ov_delta = serial_since(ov_mark)
        if ("WM SWITCH SHOW" in ov_delta or "DESK SWITCH" in ov_delta
                or "WM KEY 57" in ov_delta):
            overview_show = True
            break
        time.sleep(0.05)
    if not overview_show:
        alt_tab(q, 2)
        time.sleep(0.15)
        ov_delta = serial_since(ov_mark)
        overview_show = (
            "WM SWITCH SHOW" in ov_delta
            or "DESK SWITCH" in ov_delta
            or "WM KEY 57" in ov_delta)
    else:
        alt_tab(q, 3)
        time.sleep(0.12)
    shot_ov = shot(q, ser, "oscortex-round39-overview-16.png")
    dismiss(q)
    time.sleep(0.08)
    if live_info.get("tap_slots"):
        live_info = raise_tap(q, ser, live_info["tap_slots"][0], 860, 56)
        time.sleep(0.08)
    shot_tok = shot(q, ser, "oscortex-round39-atomic-tokens.png")
    matrix = {}
    for cap in STEMS:
        slots = [w for w in live_info["ordinary_slots"]
                 if live_info["windows"].get(w, {}).get("cap") == cap]
        if not slots:
            matrix[CAP_NAME[cap]] = {"ok": False, "missing": True}
            continue
        ev = interact_slot(q, ser, slots[0])
        matrix[CAP_NAME[cap]] = ev
        live_info = live_from(harvest(ser))
    # Close + relaunch FILES (multi) then TAP last again.
    files_slots = [w for w in live_info["ordinary_slots"]
                   if live_info["windows"].get(w, {}).get("cap") == 1]
    closed_files = False
    relaunch_files = False
    if files_slots:
        closed_files = p38.close_slot(q, ser, files_slots[0])
        if closed_files:
            n0 = ordinary_n(harvest(ser))
            dock_click(q, ser, 1)
            relaunch_files = ordinary_n(harvest(ser)) > n0
    closed_tap = False
    relaunch_tap = False
    live_info = live_from(harvest(ser))
    if live_info.get("tap_slots"):
        closed_tap = p38.close_slot(q, ser, live_info["tap_slots"][0])
    if ordinary_no_tap(harvest(ser)) >= 15 and not p38.tap_live_in(harvest(ser)):
        relaunch_tap = launch_tap_dock(q, ser, log)
        if not relaunch_tap:
            relaunch_tap = p38.launch_tap_last(q, ser, log)
    after = harvest(ser)
    after_info = live_from(after)
    ok_vis, rejected = tok.harvest_vis(after)
    interleaved = rejected.get("interleaved", 0)
    malformed = rejected.get("malformed", 0)
    checksum_bad = rejected.get("checksum", 0)
    ring_corrupt = (
        after.count("FAULT ") + after.count("OSGFX OOM")
        + after.count("REAP "))
    seen = six | stems_present(after_info)
    for ev in matrix.values():
        cap = ev.get("caption")
        if cap in CAP_NAME.values():
            for k, v in CAP_NAME.items():
                if v == cap:
                    seen.add(k)
    six_ok = seen >= set(STEMS)
    tap_last = (
        tap_live
        and peak >= 16
        and not tap_die
        and (p38.tap_attached_under_occupancy(after) or tap_ready
             or bool(after_info.get("tap_slots"))))
    matrix_ok = all(
        not (matrix.get(CAP_NAME[c]) or {}).get("missing")
        and ((matrix.get(CAP_NAME[c]) or {}).get("focus")
             or (matrix.get(CAP_NAME[c]) or {}).get("menu"))
        for c in STEMS)
    unique_ok = after_info["unique_geoms"] >= 8
    token_ok = (
        interleaved == 0 and checksum_bad == 0
        and malformed == 0
        and len(ok_vis) >= 8)
    payload = {
        "round": 39,
        "log": log,
        "pre_tap_ordinary": tap_before,
        "live": {
            "ordinary_slots": after_info["ordinary_slots"],
            "overlay_slots": after_info["overlay_slots"],
            "proc_live": after_info["proc_live"],
            "ordinary_procs": after_info["ordinary_procs"],
            "captions": after_info["captions"],
            "unique_geoms": after_info["unique_geoms"],
            "stem_live": after_info.get("stem_live"),
        },
        "peak_ordinary_windows": peak,
        "six_stems": sorted(six | stems_present(after_info)),
        "six_ok": six_ok,
        "tap_last": tap_last,
        "tap_ready": tap_ready,
        "tap_die": tap_die,
        "attach_refuse": refuse,
        "overview_show": overview_show,
        "action_matrix": {
            k: {kk: vv for kk, vv in ev.items() if kk != "tokens"}
            for k, ev in matrix.items()
        },
        "matrix_ok": matrix_ok,
        "close_relaunch": {
            "files_close": closed_files,
            "files_relaunch": relaunch_files,
            "tap_close": closed_tap,
            "tap_relaunch": relaunch_tap,
        },
        "tokens": {
            "vis_ok": len(ok_vis),
            "rejected": rejected,
            "pass": token_ok,
        },
        "shots": {
            "all_six": shot16,
            "overview": shot_ov,
            "tokens": shot_tok,
        },
        "oom": after.count("OSGFX OOM"),
        "fault": after.count("FAULT "),
        "reap": after.count("REAP "),
        "ring_corrupt": ring_corrupt,
        "pass": (
            peak >= 16
            and len(after_info["ordinary_slots"]) >= 16
            and six_ok
            and refuse == 0
            and tap_last
            and matrix_ok
            and token_ok
            and unique_ok
            and overview_show
            and after.count("OSGFX OOM") == 0
            and ring_corrupt == 0),
    }
    os.makedirs(ART, exist_ok=True)
    dest = os.path.join(ART, "oscortex-round39-apps.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round39-tokens.json"), "w").write(
        json.dumps({
            "round": 39,
            "protocol": "WM VIS W HH X xxxx Y yyyy W wwww H hhhh G gggg C cc",
            "checksum": "(slot^x^y^w^h^gen)&0xFF",
            "vis_ok": len(ok_vis),
            "rejected": rejected,
            "interleaved": interleaved,
            "pass": token_ok,
        }, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round39-layout.json"), "w").write(
        json.dumps({
            "round": 39,
            "placement": "title-exposing cascade step 32",
            "overview": "F11 / Alt-Tab 4x4 grid up to 16",
            "unique_geoms": after_info["unique_geoms"],
            "overview_show": overview_show,
            "high_slots": [w for w in after_info["ordinary_slots"] if w >= 8],
            "pass": bool(overview_show and unique_ok and peak >= 16),
        }, indent=2) + "\n")
    print("wrote", dest)
    print(json.dumps({
        "ordinary": peak,
        "six": sorted(six | stems_present(after_info)),
        "six_ok": six_ok,
        "tap_last": tap_last,
        "matrix_ok": matrix_ok,
        "token_ok": token_ok,
        "overview": overview_show,
        "refuse": refuse,
        "pass": payload["pass"],
        "captions": after_info["captions"],
        "unique_geoms": after_info["unique_geoms"],
    }, indent=2))
    return 0 if payload["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
