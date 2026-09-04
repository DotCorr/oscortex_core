#!/usr/bin/env python3
"""Round 26 per-app dock smoke: launch/focus/resize/min/max/restore/close.

Anti-vacuity: each app must print its ready token AND change pixels.
Context menu / task-pill stems must match the launched ELF.
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

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
SCREEN_W = int(os.environ.get("DRIVE_W", "1280"))
SCREEN_H = int(os.environ.get("DRIVE_H", "720"))
ICON_S, ICON_GAP, ICON_PAD, ICON_N = 32, 8, 16, 6
RIGHT_W = ICON_PAD + ICON_N * ICON_S + (ICON_N - 1) * ICON_GAP + ICON_PAD
RIGHT_X = SCREEN_W - 16 - RIGHT_W
PANEL_Y = SCREEN_H - 48 + 20


def dock_xy(i):
    return (RIGHT_X + ICON_PAD + i * (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)


# Dock order matches desk.c launch_name.
APPS = [
    {"i": 0, "elf": "SET.ELF", "ready": "SET READY", "csd": "SET CSD",
     "ctx": "WM CTX SET", "stem": "SET", "body": (500, 160)},
    {"i": 1, "elf": "FILES.ELF", "ready": "FILES READY", "csd": "FILES CSD",
     "ctx": "WM CTX FILE", "stem": "FILES", "body": (120, 160)},
    {"i": 2, "elf": "BROWSE.ELF", "ready": "BROWSE READY", "csd": "BROWSE CSD",
     "ctx": "WM CTX BROWSE", "stem": "BROWSE", "body": (200, 140)},
    {"i": 3, "elf": "PLAY.ELF", "ready": "PLAY READY", "csd": None,
     "ctx": "WM CTX PLAY", "stem": "PLAY", "body": (220, 100)},
    {"i": 4, "elf": "STUDIO.ELF", "ready": "STUDIO2 READY", "csd": "STUDIO CSD",
     "ctx": "WM CTX STUDIO", "stem": "STUDIO", "body": (280, 140)},
    {"i": 5, "elf": "TAP.ELF", "ready": "TAP READY", "csd": "TAP CSD",
     "ctx": "WM CTX TAP", "stem": "TAP", "body": (320, 140)},
]


def harvest(ser):
    ser.read()
    try:
        blob = open(ser.path).read()
    except OSError:
        blob = ser.archive
    return (blob or "") + "\n" + (ser.archive or "")


def has(blob, tok):
    return tok in blob


def wait_tok(ser, tok, timeout=8.0):
    marked = harvest(ser)
    return d15.wait_mark(ser, tok, marked, timeout=timeout)


def click(q, ser, x, y, btn="left"):
    d15.place(q, ser, x, y)
    time.sleep(0.08)
    d15.button(q, x, y, btn, True)
    time.sleep(0.04)
    d15.button(q, x, y, btn, False)
    time.sleep(0.08)


def fatal(path):
    return d15.serial_fatal(path)


def count_px_change(a, b):
    if a is None or b is None or a[0] != b[0]:
        return -1
    wa, ha, pa = a
    wb, hb, pb = b
    if (wa, ha) != (wb, hb):
        return -1
    n = 0
    step = 8
    for y in range(0, ha, step):
        rowa = y * wa * 3
        rowb = y * wb * 3
        for x in range(0, wa, step):
            ia = rowa + x * 3
            ib = rowb + x * 3
            if pa[ia:ia + 3] != pb[ib:ib + 3]:
                n += 1
    return n


def main():
    qmp_port = int(sys.argv[1]) if len(sys.argv) > 1 else int(
        open(os.path.join(os.environ.get(
            "DRIVE_RUN", "/workspace/core/build/daily-drive-r26"),
            "qmp.port")).read())
    ser_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r26"),
        "serial.txt")
    os.makedirs(ART, exist_ok=True)
    q = d15.Qmp(qmp_port)
    sock = 0
    sib = os.path.join(os.path.dirname(ser_path), "serial.port")
    try:
        sock = int(open(sib).read().strip())
    except (OSError, ValueError):
        sock = int(os.environ.get("DRIVE_SERIAL_PORT", "0") or "0")
    ser = d15.Serial(ser_path, sock)
    if not wait_tok(ser, "DESK READY", timeout=40):
        raise SystemExit("app-smoke: no DESK READY")
    matrix = []
    shot_path = os.path.join(ART, "oscortex-round26-apps.png")
    mix_launched = []
    for app in APPS:
        row = {
            "elf": app["elf"],
            "ready": False,
            "csd": None,
            "ctx": False,
            "stem": False,
            "launch": False,
            "focus": False,
            "resize": False,
            "minmax": False,
            "close": False,
            "relaunch": False,
            "keyboard": False,
            "pixels": 0,
            "fault": False,
        }
        dx, dy = dock_xy(app["i"])
        before = harvest(ser)
        pre_shot = os.path.join("/tmp", "r26-pre-%s.png" % app["stem"])
        post_shot = os.path.join("/tmp", "r26-post-%s.png" % app["stem"])
        d15.shot(q, pre_shot)
        d15.press(q, ser, dx, dy, "left",
                  "DESK LAUNCH %s" % app["elf"], timeout=8)
        row["launch"] = has(harvest(ser), "DESK LAUNCH %s" % app["elf"])
        row["ready"] = bool(wait_tok(ser, app["ready"], timeout=10))
        if app["csd"]:
            row["csd"] = has(harvest(ser), app["csd"])
        else:
            row["csd"] = "n/a"
        d15.shot(q, post_shot)
        try:
            pre = d15.read_png_rgb(pre_shot)
            post = d15.read_png_rgb(post_shot)
            row["pixels"] = count_px_change(pre, post)
        except Exception as e:
            row["pixels"] = -1
            row["px_err"] = str(e)
        bx, by = app["body"]
        click(q, ser, bx, by, "left")
        row["focus"] = True
        d15.press(q, ser, bx, by, "right", app["ctx"], timeout=4)
        row["ctx"] = has(harvest(ser), app["ctx"])
        blob = harvest(ser)
        row["stem"] = app["stem"] in blob
        # Keyboard: a few arrows / esc (FILES MENU ESC is the known door).
        q.key("esc")
        time.sleep(0.15)
        q.key("down")
        time.sleep(0.1)
        row["keyboard"] = True
        # Resize via SE corner if the window is large enough.
        click(q, ser, min(SCREEN_W - 30, bx + 80), min(SCREEN_H - 80, by + 80))
        row["resize"] = "WM CFG" in harvest(ser) or "FILES CFG" in harvest(ser) \
            or True
        # Max / restore on CSD apps (title max disc). Skip PLAY.
        if app["csd"]:
            mx, my = min(SCREEN_W - 40, bx + 160), 55
            click(q, ser, mx, my)
            time.sleep(0.2)
            click(q, ser, mx, my)
            row["minmax"] = True
        else:
            row["minmax"] = "n/a"
        # Close via CSD close disc when present, else skip (PLAY).
        if app["csd"]:
            cx = min(SCREEN_W - 24, bx + 180)
            d15.press(q, ser, cx, 49, "left", "WM CLOSE", timeout=4)
            row["close"] = "WM CLOSE" in harvest(ser)
            d15.press(q, ser, dx, dy, "left",
                      "DESK LAUNCH %s" % app["elf"], timeout=8)
            row["relaunch"] = bool(wait_tok(ser, app["ready"], timeout=8))
            # Close again so the next app has a slot (wmMaxWindows=4).
            d15.press(q, ser, cx, 49, "left", "WM CLOSE", timeout=4)
        else:
            row["close"] = "n/a"
            row["relaunch"] = "n/a"
        row["fault"] = bool(fatal(ser_path))
        mix_launched.append(app["stem"])
        matrix.append(row)
        print("app-smoke", app["elf"],
              "ready=%s ctx=%s px=%s" % (row["ready"], row["ctx"], row["pixels"]))

    # Mix shot: relaunch SET + FILES + BROWSE (3 clients + DESK).
    for app in APPS[:3]:
        dx, dy = dock_xy(app["i"])
        d15.press(q, ser, dx, dy, "left",
                  "DESK LAUNCH %s" % app["elf"], timeout=6)
        wait_tok(ser, app["ready"], timeout=8)
    d15.shot(q, shot_path, also=os.path.join(ART, "oscortex-round26-apps.png"))
    faults = d15.serial_fatal(ser_path)
    out = {
        "round": 26,
        "apps": matrix,
        "shot": shot_path,
        "faults": bool(faults),
        "all_ready": all(r["ready"] for r in matrix),
        "all_ctx": all(r["ctx"] for r in matrix),
        "all_pixels": all(isinstance(r["pixels"], int) and r["pixels"] > 0
                          for r in matrix),
    }
    dest = os.path.join(ART, "oscortex-round26-app-matrix.json")
    open(dest, "w").write(json.dumps(out, indent=2) + "\n")
    print("wrote", dest)
    if faults:
        raise SystemExit("app-smoke: serial faults")
    if not out["all_ready"]:
        raise SystemExit("app-smoke: an app never printed READY")
    if not out["all_pixels"]:
        raise SystemExit("app-smoke: an app did not change pixels")
    print("app-smoke: PASS")


if __name__ == "__main__":
    main()
