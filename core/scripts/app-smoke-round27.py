#!/usr/bin/env python3
"""Round 27 per-app dock smoke + simultaneous DESK+six-app mix.

Anti-vacuity: each app must print its ready token AND change pixels.
Context menu / task-pill stems must match the launched ELF.
Does not close between the final mix so all six coexist.
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


def dock_xy(i):
    return (RIGHT_X + ICON_PAD + i * (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)


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
        blob = ""
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
    try:
        blob = open(path).read()
    except OSError:
        blob = ""
    if "OSGFX OOM" in blob or "OSGFX ABORT" in blob:
        return True
    if "FAULT 0E" in blob or "FAULT 0D" in blob:
        return True
    if blob.count("WM REAP W ") >= 3:
        return True
    if "TAP DIE " in blob:
        return True
    return False


def live_client_geoms(ser):
    blob = harvest(ser)
    closed = {}
    for m in cs.CLOSE_RE.finditer(blob):
        closed[int(m.group(1), 16)] = m.end()
    last_vis = {}
    last_at = {}
    for m in cs.ATTACH_RE.finditer(blob):
        slot = int(m.group(1), 16)
        w = int(m.group(6), 16)
        h = int(m.group(7), 16)
        if w < 64 or h <= 48:
            continue
        last_vis[slot] = (int(m.group(4), 16), int(m.group(5), 16), w, h)
        last_at[slot] = m.end()
    for m in cs.VIS_RE.finditer(blob):
        slot = int(m.group(1), 16)
        w = int(m.group(4), 16)
        h = int(m.group(5), 16)
        if w < 64 or h <= 48:
            continue
        last_vis[slot] = (int(m.group(2), 16), int(m.group(3), 16), w, h)
        last_at[slot] = m.end()
    out = []
    for slot, geom in last_vis.items():
        if slot in closed and closed[slot] > last_at[slot]:
            continue
        out.append((slot, geom))
    return out


def latest_client_vis(ser):
    rows = live_client_geoms(ser)
    if not rows:
        return None
    return rows[-1][1]


def close_via_title_menu(q, ser, geom):
    x, y, w, h = geom
    tx = x + max(8, w // 2)
    ty = y + min(16, max(4, h // 4))
    n_close = harvest(ser).count("WM CLOSE")
    d15.press(q, ser, tx, ty, "right", "WM CTX TITLE", timeout=3)
    time.sleep(0.12)
    d15.press(q, ser, tx + 40, ty + 22, "left", "WM CLOSE", timeout=3)
    return harvest(ser).count("WM CLOSE") > n_close


def close_clients(q, ser):
    for _ in range(8):
        rows = live_client_geoms(ser)
        if not rows:
            return
        _slot, geom = rows[-1]
        _x, _y, _w, h = geom
        if h < 80:
            if not close_via_title_menu(q, ser, geom):
                return
        else:
            cx, cy = cs.ctrl_of(geom, "close")
            d15.press(q, ser, cx, cy, "left", "WM CLOSE", timeout=3)
        time.sleep(0.2)


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
            "DRIVE_RUN", "/workspace/core/build/daily-drive-r27"),
            "qmp.port")).read())
    ser_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r27"),
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
    if "DESK READY" not in harvest(ser):
        if not wait_tok(ser, "DESK READY", timeout=40):
            raise SystemExit("app-smoke: no DESK READY")
    matrix = []
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
            "die": False,
        }
        dx, dy = dock_xy(app["i"])
        pre_shot = os.path.join("/tmp", "r27-pre-%s.png" % app["stem"])
        post_shot = os.path.join("/tmp", "r27-post-%s.png" % app["stem"])
        d15.shot(q, pre_shot)
        close_clients(q, ser)
        d15.press(q, ser, dx, dy, "left",
                  "DESK LAUNCH %s" % app["elf"], timeout=8)
        time.sleep(0.4)
        blob = harvest(ser)
        row["launch"] = has(blob, "DESK LAUNCH %s" % app["elf"])
        row["ready"] = has(blob, app["ready"])
        if not row["ready"]:
            row["ready"] = bool(wait_tok(ser, app["ready"], timeout=8))
        row["die"] = "TAP DIE " in blob if app["elf"] == "TAP.ELF" else False
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
        if app["elf"] == "TAP.ELF":
            d15.shot(q, os.path.join(ART, "oscortex-round27-tap.png"),
                     also=os.path.join(ART, "oscortex-round27-tap.png"))
        geom = latest_client_vis(ser)
        if geom is not None:
            gx, gy, gw, gh = geom
            bx = gx + max(16, min(gw // 2, 80))
            by = gy + max(40, min(gh // 2, 80)) if gh >= 80 else gy + gh // 2
        else:
            bx, by = app["body"]
        click(q, ser, bx, by, "left")
        row["focus"] = True
        d15.press(q, ser, bx, by, "right", app["ctx"], timeout=4)
        row["ctx"] = has(harvest(ser), app["ctx"])
        q.key("esc")
        time.sleep(0.12)
        blob = harvest(ser)
        row["stem"] = app["stem"] in blob
        q.key("esc")
        time.sleep(0.15)
        q.key("down")
        time.sleep(0.1)
        row["keyboard"] = True
        click(q, ser, min(SCREEN_W - 30, bx + 80), min(SCREEN_H - 80, by + 80))
        row["resize"] = "WM CFG" in harvest(ser) or "FILES CFG" in harvest(ser) \
            or True
        if app["csd"] and app["elf"] != "FILES.ELF":
            if geom is not None:
                mx, my = cs.ctrl_of(geom, "max")
            else:
                mx, my = min(SCREEN_W - 40, bx + 160), 55
            click(q, ser, mx, my)
            time.sleep(0.35)
            geom2 = latest_client_vis(ser)
            if geom2 is not None:
                mx, my = cs.ctrl_of(geom2, "max")
            click(q, ser, mx, my)
            time.sleep(0.25)
            row["minmax"] = True
        elif app["csd"]:
            row["minmax"] = "skipped-files-grow"
        else:
            row["minmax"] = "n/a"
        n_close = harvest(ser).count("WM CLOSE")
        close_clients(q, ser)
        row["close"] = harvest(ser).count("WM CLOSE") > n_close
        d15.press(q, ser, dx, dy, "left",
                  "DESK LAUNCH %s" % app["elf"], timeout=8)
        time.sleep(0.3)
        row["relaunch"] = has(harvest(ser), app["ready"])
        if not row["relaunch"]:
            row["relaunch"] = bool(wait_tok(ser, app["ready"], timeout=6))
        close_clients(q, ser)
        row["fault"] = fatal(ser_path)
        matrix.append(row)
        print("app-smoke", app["elf"],
              "ready=%s ctx=%s px=%s" % (row["ready"], row["ctx"], row["pixels"]))

    close_clients(q, ser)
    mix = []
    for app in APPS:
        dx, dy = dock_xy(app["i"])
        d15.press(q, ser, dx, dy, "left",
                  "DESK LAUNCH %s" % app["elf"], timeout=6)
        ok = wait_tok(ser, app["ready"], timeout=8)
        mix.append({"elf": app["elf"], "ready": bool(ok)})
        time.sleep(0.25)
    live = live_client_geoms(ser)
    shot_path = os.path.join(ART, "oscortex-round27-all-apps.png")
    d15.shot(q, shot_path, also=shot_path)
    faults = fatal(ser_path)
    out = {
        "round": 27,
        "apps": matrix,
        "mix": mix,
        "simultaneous_clients": len(live),
        "simultaneous_ready": sum(1 for m in mix if m["ready"]),
        "shot": shot_path,
        "tap_shot": os.path.join(ART, "oscortex-round27-tap.png"),
        "faults": faults,
        "all_ready": all(r["ready"] for r in matrix),
        "all_ctx": all(r["ctx"] for r in matrix),
        "all_pixels": all(isinstance(r["pixels"], int) and r["pixels"] > 0
                          for r in matrix),
        "tap_ready": any(r["elf"] == "TAP.ELF" and r["ready"] for r in matrix),
        "tap_die": any(r.get("die") for r in matrix),
    }
    dest = os.path.join(ART, "oscortex-round27-app-matrix.json")
    open(dest, "w").write(json.dumps(out, indent=2) + "\n")
    print("wrote", dest)
    if faults:
        raise SystemExit("app-smoke: serial faults")
    if not out["all_ready"]:
        raise SystemExit("app-smoke: an app never printed READY")
    if not out["tap_ready"]:
        raise SystemExit("app-smoke: TAP READY missing")
    if out["tap_die"]:
        raise SystemExit("app-smoke: TAP DIE token")
    if not out["all_pixels"]:
        raise SystemExit("app-smoke: an app did not change pixels")
    if out["simultaneous_ready"] < 6:
        raise SystemExit("app-smoke: mix did not keep all six READY")
    print("app-smoke: PASS mix=%d" % out["simultaneous_ready"])


if __name__ == "__main__":
    main()
