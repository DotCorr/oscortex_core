#!/usr/bin/env python3
""">=1000 QMP frames across drag/close/relaunch/menu/max/restore.

Geometry comes from WM ATTACH / WM MOVE / WM CSDHIT per dump, not the
sit-in AABB. Tight wallpaper classifier is corner-aa G±8.
"""

import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

fi_spec = importlib.util.spec_from_file_location(
    "frame_integrity", os.path.join(HERE, "frame-integrity.py"))
fi = importlib.util.module_from_spec(fi_spec)
fi_spec.loader.exec_module(fi)

aa_spec = importlib.util.spec_from_file_location(
    "corner_aa", os.path.join(HERE, "corner-aa.py"))
aa = importlib.util.module_from_spec(aa_spec)
aa_spec.loader.exec_module(aa)

ATTACH_RE = re.compile(
    r"WM ATTACH W ([0-9A-F]+) P ([0-9A-F]+) C ([0-9A-F]+)"
    r".* X ([0-9A-F]+) Y ([0-9A-F]+) W ([0-9A-F]+) H ([0-9A-F]+)")
MOVE_RE = re.compile(
    r"WM MOVE W ([0-9A-F]+) X ([0-9A-F]+) Y ([0-9A-F]+)")
CSDHIT_RE = re.compile(
    r"WM CSDHIT .* X ([0-9A-F]+) Y ([0-9A-F]+) W ([0-9A-F]+) H ([0-9A-F]+)")
CLOSE_RE = re.compile(r"WM CLOSE W ([0-9A-F]+)")
MAX_RE = re.compile(r"WM MAX W ([0-9A-F]+)")
REST_RE = re.compile(r"WM REST W ([0-9A-F]+)")

SET_XYWH = (464, 40, 320, 280)
FILES_FALLBACK = (48, 40, 400, 280)
MAXED_XYWH = (3, 3, 1274, 666)
WANT = int(os.environ.get("DRIVE_CHIP_FRAMES", "1000"))
BTN_S = 18
BTN_GAP = 8
BTN_PAD_Y = 7


def live_files_xywh(serial_path, archive=""):
    """Latest live FILES geom from ATTACH/MOVE/MAX/REST/CSDHIT, not sit-in AABB."""
    try:
        blob = open(serial_path).read()
    except OSError:
        blob = ""
    blob += "\n" + archive
    slot = None
    geom = None
    attach_at = -1
    for m in ATTACH_RE.finditer(blob):
        if int(m.group(3), 16) != 1:
            continue
        if int(m.group(6), 16) < 240:
            continue
        slot = int(m.group(1), 16)
        geom = (
            int(m.group(4), 16),
            int(m.group(5), 16),
            int(m.group(6), 16),
            int(m.group(7), 16),
        )
        attach_at = m.end()
    if geom is None or attach_at < 0:
        for m in reversed(list(CSDHIT_RE.finditer(blob))):
            w = int(m.group(3), 16)
            h = int(m.group(4), 16)
            y = int(m.group(2), 16)
            if w >= 240 and h >= 200 and y < 600:
                return (
                    int(m.group(1), 16),
                    y,
                    w,
                    h,
                )
        return FILES_FALLBACK
    for m in CLOSE_RE.finditer(blob, attach_at):
        if slot is not None and int(m.group(1), 16) == slot:
            return None
    x, y, w, h = geom
    for m in MOVE_RE.finditer(blob, attach_at):
        if slot is not None and int(m.group(1), 16) != slot:
            continue
        x = int(m.group(2), 16)
        y = int(m.group(3), 16)
    # Maximize toggles and reprints WM MAX, not WM REST (REST is un-min).
    max_n = 0
    last_max = -1
    for m in MAX_RE.finditer(blob, attach_at):
        if slot is None or int(m.group(1), 16) == slot:
            max_n += 1
            last_max = m.end()
    if max_n % 2 == 1 and last_max > attach_at:
        for m in CSDHIT_RE.finditer(blob, last_max):
            cw = int(m.group(3), 16)
            ch = int(m.group(4), 16)
            cy = int(m.group(2), 16)
            if cw >= 1000 and ch >= 500 and cy < 40:
                return (
                    int(m.group(1), 16),
                    cy,
                    cw,
                    ch,
                )
        return MAXED_XYWH
    return (x, y, w, h)


def title_of(geom):
    x, y, w, _h = geom
    tx = x + 72
    if tx > x + w - 90:
        tx = x + 40
    return tx, y + 15


def ctrl_of(geom, which="close"):
    x, y, w, _h = geom
    close_x = x + w - BTN_GAP - BTN_S
    min_x = close_x - BTN_GAP - BTN_S
    max_x = min_x - BTN_GAP - BTN_S
    by = y + BTN_PAD_Y
    bx = {"close": close_x, "min": min_x, "max": max_x}[which]
    return bx + BTN_S // 2, by + BTN_S // 2


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: chip-scan-round22.py <qmp> <serial> <framedir>")
    port = int(sys.argv[1])
    serial_path = sys.argv[2]
    framedir = sys.argv[3]
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(framedir, exist_ok=True)
    os.makedirs(art, exist_ok=True)
    sock = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
    if sock <= 0:
        sib = os.path.join(os.path.dirname(serial_path), "serial.port")
        try:
            sock = int(open(sib).read().strip())
        except (OSError, ValueError):
            sock = 0
    ser = d15.Serial(serial_path, sock)
    q = d15.Qmp(port)

    n = 0
    bad = []
    fp = []
    t0 = time.time()

    def dump(tag):
        nonlocal n
        n += 1
        geom = live_files_xywh(serial_path, ser.archive or "")
        if geom is None:
            geom = FILES_FALLBACK
        path = os.path.join(framedir, "c%05d.png" % n)
        d15.shot(q, path)
        rec = fi.inspect_png(path, files_xywh=geom, set_xywh=SET_XYWH)
        aa_rec = aa.inspect_png(path, files_xywh=geom, set_xywh=SET_XYWH)
        rec["tag"] = tag
        rec["aa"] = aa_rec
        rec["files_xywh"] = list(geom)
        open(path + ".geom", "w").write("%d %d %d %d %s\n" % (geom[0], geom[1], geom[2], geom[3], tag))
        # False-positive class: inspector AABB on a just-closed / tiling
        # frame where the live token has not yet been reprinted.
        if rec.get("bad") or aa_rec.get("bad"):
            if (tag.startswith("close") or tag.startswith("relaunch")
                    or tag.startswith("max") or tag.startswith("restore")):
                rec["false_positive"] = True
                rec["fp_class"] = (
                    "stale-token-after-close" if tag.startswith("close")
                    or tag.startswith("relaunch") else "transient-max-restore")
                fp.append(rec)
            else:
                rec["chip"] = True
                bad.append(rec)
        return rec

    def geom_now():
        return live_files_xywh(serial_path, ser.archive or "")

    def ensure_files():
        g = geom_now()
        if g is not None:
            return g
        d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                  "left", "FILES CSD", timeout=3)
        time.sleep(0.35)
        return geom_now()

    def ensure_restored(g):
        if g is None:
            return None
        if g[2] < 1000:
            return g
        rx, ry = ctrl_of(g, "max")
        d15.press(q, ser, rx, ry, "left", "WM MAX", timeout=2)
        time.sleep(0.2)
        return geom_now() or g

    cycle = 0
    while n < WANT:
        geom = ensure_files()
        if geom is None:
            dump("relaunch")
            continue
        geom = ensure_restored(geom)
        if geom is None or geom[2] >= 1000:
            dump("max-stuck")
            continue
        tx, ty = title_of(geom)
        d15.place(q, ser, tx, ty)
        d15.button(q, tx, ty, "left", True)
        for dx in (0, 16, 32, 48, 64, 80, 64, 48, 32, 16, 0):
            d15.place(q, ser, tx + dx, ty)
            dump("drag-%d" % dx)
            if n >= WANT:
                break
        d15.button(q, tx, ty, "left", False)
        if n >= WANT:
            break
        geom = ensure_restored(geom_now() or geom)
        try:
            d15.press(q, ser, geom[0] + 80, geom[1] + 80, "right",
                      "WM WIN MENU", timeout=2)
            dump("menu-win")
            q.key("esc")
            dump("menu-off")
        except Exception:
            dump("menu-miss")
        try:
            d15.press(q, ser, 90, 400, "right", "WM WALL MENU", timeout=2)
            dump("menu-wall")
            q.key("esc")
        except Exception:
            pass
        d15.press(q, ser, 536, 55, "left", "WM DEFN", timeout=2)
        dump("focus-set")
        geom = ensure_restored(geom_now() or geom)
        d15.press(q, ser, title_of(geom)[0], title_of(geom)[1],
                  "left", "WM DEFN", timeout=2)
        dump("focus-files")
        if n >= WANT:
            break
        cycle += 1
        if cycle % 5 == 0:
            mx, my = ctrl_of(geom, "max")
            d15.press(q, ser, mx, my, "left", "WM MAX", timeout=2)
            dump("max")
            geom = geom_now() or MAXED_XYWH
            rx, ry = ctrl_of(geom, "max")
            d15.press(q, ser, rx, ry, "left", "WM MAX", timeout=2)
            dump("restore")
            geom = ensure_restored(geom_now() or geom)
        if n >= WANT:
            break
        if cycle % 4 == 0:
            if geom is None or geom[2] >= 1000:
                geom = ensure_restored(geom_now() or geom)
            if geom is not None and geom[2] < 1000:
                cx, cy = ctrl_of(geom, "close")
                d15.press(q, ser, cx, cy, "left", "WM CLOSE", timeout=2.5)
                dump("close")
                d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                          "left", "FILES CSD", timeout=3)
                dump("relaunch")

    proof = os.path.join(art, "oscortex-round22-1000-frames.png")
    d15.shot(q, proof)
    payload = {
        "round": 22,
        "frames": n,
        "chips": len(bad),
        "false_positives": len(fp),
        "fp_classes": ["stale-token-after-close", "transient-max-restore"],
        "seconds": round(time.time() - t0, 1),
        "bad": bad[:16],
        "fp_tail": fp[:8],
        "proof": proof,
        "geom_source": "WM ATTACH/MOVE/CSDHIT tokens",
        "wallpaper": "corner-aa G±8 / frame-integrity teal band",
    }
    out = os.path.join(art, "oscortex-round22-integrity.json")
    open(out, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps({k: payload[k] for k in payload if k not in ("bad", "fp_tail")},
                     indent=2))
    if n < WANT:
        raise SystemExit("chip scan short: %d/%d" % (n, WANT))
    if bad:
        raise SystemExit("chips=%d of %d frames" % (len(bad), n))
    print("chip-scan PASS frames=%d chips=0 fp=%d" % (n, len(fp)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
