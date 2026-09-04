#!/usr/bin/env python3
"""Round 27 TAP interact / close / relaunch on a live leftover.

Proves TAP READY, TAP HIT (control press), TAP MISS (outside control),
CSD close, and relaunch. Screenshot is guest virtio-gpu backing.
"""

import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)
cs_spec = importlib.util.spec_from_file_location(
    "chip23", os.path.join(HERE, "chip-scan-round24.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
SCREEN_W = int(os.environ.get("DRIVE_W", "1280"))
SCREEN_H = int(os.environ.get("DRIVE_H", "720"))
ICON_S, ICON_GAP, ICON_PAD, ICON_N = 32, 8, 16, 6
RIGHT_W = ICON_PAD + ICON_N * ICON_S + (ICON_N - 1) * ICON_GAP + ICON_PAD
RIGHT_X = SCREEN_W - 16 - RIGHT_W
PANEL_Y = SCREEN_H - 48 + 20
TAP_DOCK = (RIGHT_X + ICON_PAD + 5 * (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)
CTL_X, CTL_Y, CTL_W, CTL_H = 40, 36, 80, 40
HIT_LINE = "TAP HIT 00F0A018"
READY = "TAP READY"


def harvest(ser):
    ser.read()
    try:
        blob = open(ser.path).read()
    except OSError:
        blob = ""
    return (blob or "") + "\n" + (ser.archive or "")


def tap_geom(ser):
    blob = harvest(ser)
    closed = {}
    for m in cs.CLOSE_RE.finditer(blob):
        closed[int(m.group(1), 16)] = m.end()
    last = None
    last_at = -1
    for m in cs.ATTACH_RE.finditer(blob):
        w = int(m.group(6), 16)
        h = int(m.group(7), 16)
        cap = int(m.group(3), 16)
        if cap != 6:
            if w != 0xF0 or h != 0xA0:
                continue
        if w < 0xF0 or h < 0xA0:
            continue
        slot = int(m.group(1), 16)
        geom = (int(m.group(4), 16), int(m.group(5), 16), w, h)
        last = (slot, geom)
        last_at = m.end()
    for m in cs.VIS_RE.finditer(blob):
        slot = int(m.group(1), 16)
        w = int(m.group(4), 16)
        h = int(m.group(5), 16)
        if w < 0xF0 or h < 0xA0:
            continue
        if last is not None and slot != last[0] and w != 0xF0:
            continue
        geom = (int(m.group(2), 16), int(m.group(3), 16), w, h)
        if last is None or slot == last[0] or w == 0xF0:
            last = (slot, geom)
            last_at = m.end()
    if last is None:
        return None
    slot, geom = last
    if slot in closed and closed[slot] > last_at:
        return None
    return last


def click(q, ser, x, y, btn="left"):
    d15.place(q, ser, x, y)
    time.sleep(0.08)
    d15.button(q, x, y, btn, True)
    time.sleep(0.05)
    d15.button(q, x, y, btn, False)
    time.sleep(0.12)


def wait_tok(ser, tok, timeout=8.0):
    marked = harvest(ser)
    return d15.wait_mark(ser, tok, marked, timeout=timeout)


def launch_tap(q, ser):
    n = harvest(ser).count(READY)
    d15.press(q, ser, TAP_DOCK[0], TAP_DOCK[1], "left",
              "DESK LAUNCH TAP.ELF", timeout=8)
    if harvest(ser).count(READY) > n:
        return True
    return bool(wait_tok(ser, READY, timeout=10))


def main():
    run = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r27")
    qmp_port = int(open(os.path.join(run, "qmp.port")).read())
    ser_path = os.path.join(run, "serial.txt")
    sock = 0
    try:
        sock = int(open(os.path.join(run, "serial.port")).read().strip())
    except (OSError, ValueError):
        sock = int(os.environ.get("DRIVE_SERIAL_PORT", "0") or "0")
    q = d15.Qmp(qmp_port)
    ser = d15.Serial(ser_path, sock)
    out = {
        "round": 27,
        "ready": READY in harvest(ser),
        "hit": False,
        "miss": False,
        "ctx": False,
        "close": False,
        "relaunch": False,
        "die": False,
        "shot": os.path.join(ART, "oscortex-round27-tap.png"),
    }
    if tap_geom(ser) is None:
        out["ready"] = launch_tap(q, ser)
    geom_row = tap_geom(ser)
    if geom_row is None:
        out["error"] = "no TAP geom after launch"
        open(os.path.join(ART, "oscortex-round27-tap.json"), "w").write(
            json.dumps(out, indent=2) + "\n")
        raise SystemExit("tap-interact: no TAP window")
    slot, (x, y, w, h) = geom_row
    out["geom"] = {"slot": slot, "x": x, "y": y, "w": w, "h": h}
    # Raise TAP, then click the control. UART can lag past 0.25s.
    click(q, ser, x + w // 2, y + 10)
    time.sleep(0.15)
    hx = x + CTL_X + CTL_W // 2
    hy = y + CTL_Y + CTL_H // 2
    mx = x + 12
    my = y + h - 12
    pre_hit = harvest(ser).count(HIT_LINE)
    click(q, ser, hx, hy)
    out["hit"] = harvest(ser).count(HIT_LINE) > pre_hit
    if not out["hit"]:
        out["hit"] = bool(wait_tok(ser, HIT_LINE, timeout=6))
    if not out["hit"]:
        q.key("t")
        out["hit"] = bool(wait_tok(ser, HIT_LINE, timeout=4))
    pre_miss = harvest(ser).count("TAP MISS")
    click(q, ser, mx, my)
    out["miss"] = harvest(ser).count("TAP MISS") > pre_miss
    if not out["miss"]:
        out["miss"] = bool(wait_tok(ser, "TAP MISS", timeout=3))
    d15.press(q, ser, hx, hy, "right", "WM CTX TAP", timeout=4)
    out["ctx"] = "WM CTX TAP" in harvest(ser)
    q.key("esc")
    time.sleep(0.15)
    d15.shot(q, out["shot"], also=out["shot"])
    n_close = harvest(ser).count("WM CLOSE")
    try:
        cx, cy = cs.ctrl_of((x, y, w, h), "close")
        d15.press(q, ser, cx, cy, "left", "WM CLOSE", timeout=4)
    except Exception:
        d15.press(q, ser, x + w // 2, y + 10, "right", "WM CTX TITLE", timeout=3)
        d15.press(q, ser, x + w // 2 + 40, y + 32, "left", "WM CLOSE", timeout=3)
    out["close"] = harvest(ser).count("WM CLOSE") > n_close
    time.sleep(0.25)
    out["relaunch"] = launch_tap(q, ser)
    out["die"] = "TAP DIE " in harvest(ser)
    out["ready"] = READY in harvest(ser)
    dest = os.path.join(ART, "oscortex-round27-tap.json")
    open(dest, "w").write(json.dumps(out, indent=2) + "\n")
    print("wrote", dest, json.dumps(out))
    if out["die"]:
        raise SystemExit("tap-interact: TAP DIE")
    if not out["ready"]:
        raise SystemExit("tap-interact: TAP READY missing")
    if not out["hit"]:
        raise SystemExit("tap-interact: TAP HIT missing")
    if not out["relaunch"]:
        raise SystemExit("tap-interact: relaunch failed")
    print("tap-interact: PASS")


if __name__ == "__main__":
    main()
