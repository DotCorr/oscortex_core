#!/usr/bin/env python3
""">=1000 QMP frames. Ground truth is committed WM VIS + generation.

Do not infer AABB from ATTACH/MOVE/MAX. Raw flags must be 0; no FP classes.
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
VIS_RE = re.compile(
    r"WM VIS W ([0-9A-F]+) X ([0-9A-F]+) Y ([0-9A-F]+)"
    r" W ([0-9A-F]+) H ([0-9A-F]+) G ([0-9A-F]+)")
REQ_RE = re.compile(
    r"WM REQ W ([0-9A-F]+) X ([0-9A-F]+) Y ([0-9A-F]+)"
    r" W ([0-9A-F]+) H ([0-9A-F]+) G ([0-9A-F]+)")
PEND_RE = re.compile(
    r"WM PEND W ([0-9A-F]+) X ([0-9A-F]+) Y ([0-9A-F]+)"
    r" W ([0-9A-F]+) H ([0-9A-F]+) G ([0-9A-F]+)")
CLOSE_RE = re.compile(r"WM CLOSE W ([0-9A-F]+)")

SET_XYWH = (464, 40, 320, 280)
WANT = int(os.environ.get("DRIVE_CHIP_FRAMES", "1000"))
BTN_S = 18
BTN_GAP = 8
BTN_PAD_Y = 7


def _blob(serial_path, archive=""):
    try:
        text = open(serial_path).read()
    except OSError:
        text = ""
    return text + "\n" + (archive or "")


def _cap_slot(blob, cap, min_w):
    """Latest live slot for an ATTACH caption code (identity, not geom)."""
    slot = None
    attach_at = -1
    for m in ATTACH_RE.finditer(blob):
        if int(m.group(3), 16) != cap:
            continue
        if int(m.group(6), 16) < min_w:
            continue
        slot = int(m.group(1), 16)
        attach_at = m.end()
    if slot is None or attach_at < 0:
        return None
    for m in CLOSE_RE.finditer(blob, attach_at):
        if int(m.group(1), 16) == slot:
            return None
    return slot


def files_slot(blob):
    """Latest FILES slot from ATTACH identity only (cap 1, w>=240)."""
    return _cap_slot(blob, 1, 240)


def set_slot(blob):
    """Latest SET slot from ATTACH identity only (cap 2)."""
    return _cap_slot(blob, 2, 240)


def _vis_xywh(blob, slot, min_w=240, min_h=200):
    if slot is None:
        return None
    geom = None
    for m in VIS_RE.finditer(blob):
        if int(m.group(1), 16) != slot:
            continue
        w = int(m.group(4), 16)
        h = int(m.group(5), 16)
        if w < min_w or h < min_h:
            # Committed clear (close): do not keep a stale AABB.
            geom = None
            continue
        geom = (
            int(m.group(2), 16),
            int(m.group(3), 16),
            w,
            h,
        )
    return geom


def live_files_xywh(serial_path, archive=""):
    """Committed FILES AABB from the latest WM VIS of the live FILES slot."""
    blob = _blob(serial_path, archive)
    return _vis_xywh(blob, files_slot(blob))


def live_set_xywh(serial_path, archive=""):
    """Committed SET AABB from the latest WM VIS of the live SET slot."""
    blob = _blob(serial_path, archive)
    return _vis_xywh(blob, set_slot(blob), min_w=200, min_h=200)


def vis_count(serial_path, archive=""):
    return len(list(VIS_RE.finditer(_blob(serial_path, archive))))


def txn_trace(serial_path, archive=""):
    blob = _blob(serial_path, archive)
    rows = []
    for name, rx in (("REQ", REQ_RE), ("PEND", PEND_RE), ("VIS", VIS_RE)):
        for m in rx.finditer(blob):
            rows.append({
                "kind": name,
                "slot": int(m.group(1), 16),
                "x": int(m.group(2), 16),
                "y": int(m.group(3), 16),
                "w": int(m.group(4), 16),
                "h": int(m.group(5), 16),
                "gen": int(m.group(6), 16),
                "at": m.start(),
            })
    rows.sort(key=lambda r: r["at"])
    return rows[-48:]


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


def wait_vis(ser, serial_path, n0=None, pred=None, timeout=3.0):
    """Wait for THIS FILES slot's committed VIS, not any sibling token."""
    del n0
    g0 = live_files_xywh(serial_path, ser.archive or "")
    deadline = time.time() + timeout
    while time.time() < deadline:
        ser.read()
        g = live_files_xywh(serial_path, ser.archive or "")
        if pred is not None:
            if g is not None and pred(g):
                return g
        elif g is not None and g != g0:
            return g
        time.sleep(0.02)
    return live_files_xywh(serial_path, ser.archive or "")


def wait_files_gone(ser, serial_path, timeout=2.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        ser.read()
        if live_files_xywh(serial_path, ser.archive or "") is None:
            return True
        time.sleep(0.02)
    return live_files_xywh(serial_path, ser.archive or "") is None


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: chip-scan-round23.py <qmp> <serial> <framedir>")
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
    t0 = time.time()

    def dump(tag):
        nonlocal n
        n += 1
        geom = live_files_xywh(serial_path, ser.archive or "")
        set_geom = live_set_xywh(serial_path, ser.archive or "") or SET_XYWH
        if geom is not None and set_geom is not None:
            fx, fy, fw, fh = geom
            sx, sy, sw, sh = set_geom
            if fx <= sx and fy <= sy and (fx + fw) >= (sx + sw) and (
                    fy + fh) >= (sy + sh):
                # Committed FILES VIS covers SET; SET is not on scanout.
                set_geom = ()
        path = os.path.join(framedir, "c%05d.png" % n)
        d15.shot(q, path)
        rec = fi.inspect_png(path, files_xywh=geom, set_xywh=set_geom)
        aa_rec = aa.inspect_png(path, files_xywh=geom, set_xywh=set_geom)
        rec["tag"] = tag
        rec["aa"] = aa_rec
        rec["files_xywh"] = list(geom) if geom else None
        rec["geom_source"] = "WM VIS committed generation"
        open(path + ".geom", "w").write("%s %s\n" % (
            " ".join(str(x) for x in (geom or ())), tag))
        if rec.get("bad") or aa_rec.get("bad"):
            rec["chip"] = True
            bad.append(rec)
        return rec

    def geom_now():
        return live_files_xywh(serial_path, ser.archive or "")

    def ensure_files():
        g = geom_now()
        if g is not None:
            return g
        n0 = vis_count(serial_path, ser.archive or "")
        d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                  "left", "FILES CSD", timeout=3)
        return wait_vis(ser, serial_path, n0=n0,
                        pred=lambda gg: gg[2] < 1000, timeout=6)

    def ensure_restored(g):
        if g is None:
            return None
        tries = 0
        while g is not None and g[2] >= 1000 and tries < 3:
            rx, ry = ctrl_of(g, "max")
            d15.press(q, ser, rx, ry, "left", "WM REQ", timeout=2)
            g = wait_vis(ser, serial_path,
                         pred=lambda gg: gg[2] < 1000, timeout=4) or g
            tries += 1
        return g

    cycle = 0
    while n < WANT:
        geom = ensure_files()
        if geom is None:
            dump("relaunch-wait")
            continue
        geom = ensure_restored(geom)
        if geom is None or geom[2] >= 1000:
            dump("max-hold")
            continue
        tx, ty = title_of(geom)
        d15.place(q, ser, tx, ty)
        d15.button(q, tx, ty, "left", True)
        # Stay in the 16px FILES↔SET gap. Overlap samples SET's committed
        # AABB through FILES (z-order), which is not a HOLD token lag.
        for dx in (0, 8, 16, 8, 0, -8, -16, -8, 0):
            n0 = vis_count(serial_path, ser.archive or "")
            d15.place(q, ser, tx + dx, ty)
            if dx != 0:
                wait_vis(ser, serial_path, n0=n0, timeout=1.2)
            dump("drag-%d" % dx)
            if n >= WANT:
                break
        d15.button(q, tx, ty, "left", False)
        if n >= WANT:
            break
        geom = ensure_restored(geom_now() or geom)
        try:
            d15.press(q, ser, 90, 400, "right", "WM WALL MENU", timeout=2)
            dump("menu-wall")
            q.key("esc")
            dump("menu-off")
        except Exception:
            dump("menu-miss")
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
            n0 = vis_count(serial_path, ser.archive or "")
            d15.press(q, ser, mx, my, "left", "WM REQ", timeout=2)
            wait_vis(ser, serial_path, n0=n0,
                     pred=lambda gg: gg[2] >= 1000, timeout=4)
            dump("max")
            geom = geom_now()
            if geom is not None and geom[2] >= 1000:
                rx, ry = ctrl_of(geom, "max")
                n1 = vis_count(serial_path, ser.archive or "")
                d15.press(q, ser, rx, ry, "left", "WM REQ", timeout=2)
                wait_vis(ser, serial_path, n0=n1,
                         pred=lambda gg: gg[2] < 1000, timeout=4)
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
                wait_files_gone(ser, serial_path, timeout=2.5)
                dump("close")
                n0 = vis_count(serial_path, ser.archive or "")
                d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                          "left", "FILES CSD", timeout=3)
                wait_vis(ser, serial_path, n0=n0,
                         pred=lambda gg: gg[2] < 1000, timeout=6)
                dump("relaunch")

    proof = os.path.join(art, "oscortex-round23-zero-flags.png")
    d15.shot(q, proof)
    txn_png = os.path.join(art, "oscortex-round23-transactional-geom.png")
    d15.shot(q, txn_png)
    payload = {
        "round": 23,
        "frames": n,
        "chips": len(bad),
        "seconds": round(time.time() - t0, 1),
        "bad": bad[:16],
        "proof": proof,
        "transactional_geom": txn_png,
        "geom_source": "WM VIS committed generation",
        "wallpaper": "corner-aa G±8 / frame-integrity teal band",
        "transaction": txn_trace(serial_path, ser.archive or ""),
    }
    out = os.path.join(art, "oscortex-round23-integrity.json")
    open(out, "w").write(json.dumps(payload, indent=2) + "\n")
    txn_out = os.path.join(art, "oscortex-round23-transaction.json")
    open(txn_out, "w").write(json.dumps({
        "round": 23,
        "geom_source": "WM VIS committed generation",
        "tokens": payload["transaction"],
        "frames": n,
        "chips": len(bad),
    }, indent=2) + "\n")
    print(json.dumps({k: payload[k] for k in payload if k not in ("bad", "transaction")},
                     indent=2))
    if n < WANT:
        raise SystemExit("chip scan short: %d/%d" % (n, WANT))
    if bad:
        raise SystemExit("chips=%d of %d frames (raw flags, no FP exemptions)"
                         % (len(bad), n))
    print("chip-scan PASS frames=%d chips=0 raw_flags=0" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
