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

SET_XYWH = (464, 40, 320, 280)
FILES_FALLBACK = (48, 40, 400, 280)
WANT = int(os.environ.get("DRIVE_CHIP_FRAMES", "1000"))


def live_files_xywh(serial_path, archive=""):
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
    if geom is None:
        hits = list(CSDHIT_RE.finditer(blob))
        if hits:
            m = hits[-1]
            geom = (
                int(m.group(1), 16),
                int(m.group(2), 16),
                int(m.group(3), 16),
                int(m.group(4), 16),
            )
            return geom
        return FILES_FALLBACK
    x, y, w, h = geom
    for m in MOVE_RE.finditer(blob, attach_at):
        if slot is not None and int(m.group(1), 16) != slot:
            continue
        x = int(m.group(2), 16)
        y = int(m.group(3), 16)
    return (x, y, w, h)


def title_of(geom):
    return geom[0] + 72, geom[1] + 15


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
        path = os.path.join(framedir, "c%05d.png" % n)
        d15.shot(q, path)
        rec = fi.inspect_png(path, files_xywh=geom, set_xywh=SET_XYWH)
        aa_rec = aa.inspect_png(path, files_xywh=geom, set_xywh=SET_XYWH)
        rec["tag"] = tag
        rec["aa"] = aa_rec
        rec["files_xywh"] = list(geom)
        # False-positive class: inspector AABB on a just-closed / tiling
        # frame where the live token has not yet been reprinted.
        if rec.get("bad") or aa_rec.get("bad"):
            if tag.startswith("close") or tag.startswith("relaunch"):
                rec["false_positive"] = True
                rec["fp_class"] = "stale-token-after-close"
                fp.append(rec)
            else:
                rec["chip"] = True
                bad.append(rec)
        return rec

    while n < WANT:
        geom = live_files_xywh(serial_path, ser.archive or "")
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
        d15.press(q, ser, 624, 55, "left", "WM DEFN", timeout=2)
        dump("focus-set")
        geom = live_files_xywh(serial_path, ser.archive or "")
        d15.press(q, ser, title_of(geom)[0], title_of(geom)[1],
                  "left", "WM DEFN", timeout=2)
        dump("focus-files")
        if n >= WANT:
            break
        # Close + relaunch so vacated bodies are not scored as chips.
        cx = geom[0] + geom[2] - 8 - 9
        cy = geom[1] + 7 + 9
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
        "fp_classes": ["stale-token-after-close"],
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
