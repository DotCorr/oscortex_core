#!/usr/bin/env python3
"""Open FILES context menu, send Escape, require FILES MENU ESC + pixels."""

import importlib.util
import json
import os
import sys
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)
cs_spec = importlib.util.spec_from_file_location(
    "chip23", os.path.join(HERE, "chip-scan-round24.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)


def region_diff(a_path, b_path, box):
    """Return (changed_px, total_px) inside box=(x0,y0,x1,y1)."""
    a = Image.open(a_path).convert("RGB")
    b = Image.open(b_path).convert("RGB")
    x0, y0, x1, y1 = box
    x1 = min(x1, a.size[0], b.size[0])
    y1 = min(y1, a.size[1], b.size[1])
    x0 = max(0, x0)
    y0 = max(0, y0)
    pa = a.crop((x0, y0, x1, y1)).tobytes()
    pb = b.crop((x0, y0, x1, y1)).tobytes()
    changed = 0
    total = (x1 - x0) * (y1 - y0)
    if total <= 0:
        return 0, 0
    step = 3
    for i in range(0, len(pa), step):
        if pa[i:i + step] != pb[i:i + step]:
            changed += 1
    return changed, total


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: prove-files-menu-esc.py <qmp> <serial>")
    port = int(sys.argv[1])
    serial_path = sys.argv[2]
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)
    sock = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
    if sock <= 0:
        sib = os.path.join(os.path.dirname(serial_path), "serial.port")
        try:
            sock = int(open(sib).read().strip())
        except (OSError, ValueError):
            sock = 0
    q = d15.Qmp(port)
    ser = d15.Serial(serial_path, sock)
    geom = cs.live_files_xywh(serial_path, ser.archive or "")
    if geom is None or geom[2] >= 1000:
        n0 = cs.vis_count(serial_path, ser.archive or "")
        d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                  "left", "FILES CSD", timeout=6)
        cs.wait_vis(ser, serial_path, n0=n0,
                    pred=lambda g: g[2] < 1000, timeout=6)
        geom = cs.live_files_xywh(serial_path, ser.archive or "")
    if geom is None:
        raise SystemExit("no tiled FILES for MENU ESC")
    if geom[2] >= 1000:
        rx, ry = cs.ctrl_of(geom, "max")
        d15.press(q, ser, rx, ry, "left", "WM REQ", timeout=2)
        cs.wait_vis(ser, serial_path, pred=lambda g: g[2] < 1000, timeout=5)
        geom = cs.live_files_xywh(serial_path, ser.archive or "") or geom
    tx, ty = cs.title_of(geom)
    d15.press(q, ser, tx, ty, "left", "WM DEFN", timeout=2)
    time.sleep(0.2)
    shot_rest = os.path.join(art, "oscortex-round25-files-menu-esc-rest.png")
    d15.shot(q, shot_rest)
    bx, by = geom[0] + 90, geom[1] + 140
    marked = open(serial_path).read()
    d15.press(q, ser, bx, by, "right", "FILES MENU", timeout=3)
    after_menu = open(serial_path).read()
    if "FILES MENU" not in after_menu[len(marked):]:
        raise SystemExit("FILES MENU token missing after body right-click")
    time.sleep(0.2)
    shot_on = os.path.join(art, "oscortex-round25-files-menu-esc.png")
    d15.shot(q, shot_on)
    box = (bx - 20, by - 20, bx + 180, by + 80)
    appear, total = region_diff(shot_rest, shot_on, box)
    if total < 100 or appear < max(40, total // 40):
        raise SystemExit(
            "menu open did not change pixels in the click box "
            "(%d/%d) — vacuous token" % (appear, total))
    before_esc = open(serial_path).read()
    q.key("esc")
    deadline = time.time() + 3.0
    token = False
    while time.time() < deadline:
        blob = open(serial_path).read()
        if "FILES MENU ESC" in blob[len(before_esc):]:
            token = True
            break
        time.sleep(0.05)
    if not token:
        raise SystemExit("Escape did not emit FILES MENU ESC (client key path)")
    time.sleep(0.2)
    shot_off = os.path.join(art, "oscortex-round25-files-menu-esc-off.png")
    d15.shot(q, shot_off)
    dismissed, _ = region_diff(shot_on, shot_off, box)
    restored, _ = region_diff(shot_rest, shot_off, box)
    if dismissed < max(40, total // 40):
        raise SystemExit(
            "Escape token without pixel dismissal (%d changed vs menu)" %
            dismissed)
    if restored >= appear:
        raise SystemExit(
            "after-ESC pixels are not closer to pre-menu than to the open "
            "menu (restored=%d appear=%d) — no restoration" %
            (restored, appear))
    payload = {
        "round": 25,
        "token": "FILES MENU ESC",
        "token_seen": True,
        "geom": list(geom),
        "menu_at": [bx, by],
        "pixel_box": list(box),
        "pixels_appear": appear,
        "pixels_dismissed": dismissed,
        "pixels_vs_rest": restored,
        "pixel_total": total,
        "shot_rest": shot_rest,
        "shot_menu": shot_on,
        "shot_after": shot_off,
        "routing": "kbdevent SCAN_ESC in files_on_key, not compositor-only",
        "pixel_restore": True,
    }
    open(os.path.join(art, "oscortex-round25-files-menu-esc.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    print("FILES MENU ESC PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
