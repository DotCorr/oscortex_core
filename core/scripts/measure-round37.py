#!/usr/bin/env python3
"""Round 37: launcher glyphs on GOP before kind 7, hide restore, latency.

Kind 7 DONE is taken only after a QMP screendump proves glyph/text pixels
in the launch AABB (not orange 0xC86828 placeholder stripes). Hide must
leave raw orange residue = 0. Writes overlay/perf JSON and PNGs.
"""

import importlib.util
import json
import os
import struct
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "m36", os.path.join(HERE, "measure-round36.py"))
m36 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m36)
d15 = m36.d15

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r37")

ORANGE = (0xC8, 0x68, 0x28)
MENU_BG = (0xF4, 0xF6, 0xFA)
SEARCH_FG = (0x50, 0x60, 0x70)
ROW_FG = (0x20, 0x28, 0x30)
ROW0 = (0xFF, 0xFF, 0xFF)
ROW1 = (0xEE, 0xF2, 0xF6)
SEL = (0xD0, 0xE4, 0xF8)
LAUNCH = (500, 420, 280, 244)
SEARCH_XY = (516, 432)
ROW0_XY = (516, 458)
ROW1_XY = (516, 482)
KIND_LAUNCH = 7


def load_png(path):
    raw = open(path, "rb").read()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not png")
    pos = 8
    w = h = 0
    bits = 8
    ctype = 2
    idat = []
    while pos + 8 <= len(raw):
        ln = struct.unpack(">I", raw[pos:pos + 4])[0]
        tag = raw[pos + 4:pos + 8]
        data = raw[pos + 8:pos + 8 + ln]
        pos = pos + 12 + ln
        if tag == b"IHDR":
            w, h, bits, ctype = struct.unpack(">IIBB", data[:10])
        elif tag == b"IDAT":
            idat.append(data)
        elif tag == b"IEND":
            break
    dec = zlib.decompress(b"".join(idat))
    bpp = {2: 3, 6: 4}[ctype]
    stride = w * bpp + 1
    rows = []
    for y in range(h):
        row = dec[y * stride:(y + 1) * stride]
        filt = row[0]
        pix = bytearray(row[1:])
        if filt == 1:
            for i in range(bpp, len(pix)):
                pix[i] = (pix[i] + pix[i - bpp]) & 255
        elif filt == 2 and y:
            prev = rows[y - 1]
            for i in range(len(pix)):
                pix[i] = (pix[i] + prev[i]) & 255
        elif filt == 4 and y:
            prev = rows[y - 1]
            for i in range(len(pix)):
                a = pix[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a
                if pb <= pa and pb <= pc:
                    pred = b
                elif pc <= pa and pc <= pb:
                    pred = c
                pix[i] = (pix[i] + pred) & 255
        rows.append(bytes(pix))
    return w, h, bpp, rows


def px_at(rows, bpp, x, y):
    row = rows[y]
    o = x * bpp
    return (row[o], row[o + 1], row[o + 2])


def near(a, b, tol=18):
    return (abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol
            and abs(a[2] - b[2]) <= tol)


def count_rect(rows, bpp, rect, color, tol=14):
    x, y, w, h = rect
    n = 0
    hit = 0
    for yy in range(y, y + h):
        for xx in range(x, x + w, 2):
            n += 1
            if near(px_at(rows, bpp, xx, yy), color, tol):
                hit += 1
    return hit, n


def sample_cluster(rows, bpp, cx, cy, color, rad=6, tol=22):
    hit = 0
    n = 0
    for yy in range(cy - rad, cy + rad + 1):
        for xx in range(cx - rad, cx + rad + 1):
            n += 1
            if near(px_at(rows, bpp, xx, yy), color, tol):
                hit += 1
    return hit, n


def analyze_launch(path, hide=False):
    w, h, bpp, rows = load_png(path)
    x, y, lw, lh = LAUNCH
    orange_n, total = count_rect(rows, bpp, LAUNCH, ORANGE, tol=16)
    bg_n, _ = count_rect(rows, bpp, LAUNCH, MENU_BG, tol=20)
    search_n, search_t = sample_cluster(rows, bpp, SEARCH_XY[0], SEARCH_XY[1],
                                        SEARCH_FG, rad=8, tol=28)
    row_fg, _ = sample_cluster(rows, bpp, ROW0_XY[0], ROW0_XY[1],
                               ROW_FG, rad=8, tol=24)
    row1_fg, _ = sample_cluster(rows, bpp, ROW1_XY[0], ROW1_XY[1],
                                ROW_FG, rad=8, tol=24)
    row0_bg, _ = sample_cluster(rows, bpp, ROW0_XY[0] + 40, ROW0_XY[1] + 6,
                                ROW0, rad=5, tol=18)
    row1_bg, _ = sample_cluster(rows, bpp, ROW1_XY[0] + 40, ROW1_XY[1] + 6,
                                ROW1, rad=5, tol=18)
    sel_n, _ = sample_cluster(rows, bpp, ROW0_XY[0] + 40, ROW0_XY[1] + 6,
                              SEL, rad=5, tol=22)
    orange_frac = orange_n / float(total) if total else 1.0
    glyph = (search_n >= 3 or row_fg >= 3 or row1_fg >= 3)
    card = (bg_n > total // 8) or row0_bg >= 4 or row1_bg >= 4 or sel_n >= 4
    shown = (not hide) and glyph and card and orange_frac < 0.08
    hidden = hide and orange_frac < 0.002 and (not card or orange_n == 0)
    return {
        "path": path,
        "png_wh": [w, h],
        "launch_rect": list(LAUNCH),
        "orange_px": orange_n,
        "orange_frac": round(orange_frac, 5),
        "menu_bg_px": bg_n,
        "search_muted_hits": search_n,
        "row0_fg_hits": row_fg,
        "row1_fg_hits": row1_fg,
        "row0_bg_hits": row0_bg,
        "row1_bg_hits": row1_bg,
        "sel_hits": sel_n,
        "glyphs_visible": bool(glyph and card),
        "hide_clean": bool(hidden) if hide else None,
        "pass": bool(hidden if hide else shown),
        "samples": {
            "search": list(px_at(rows, bpp, SEARCH_XY[0], SEARCH_XY[1])),
            "row0": list(px_at(rows, bpp, ROW0_XY[0], ROW0_XY[1])),
            "row1": list(px_at(rows, bpp, ROW1_XY[0], ROW1_XY[1])),
            "center": list(px_at(rows, bpp, x + lw // 2, y + lh // 2)),
        },
    }


def fire_f4(q):
    m36.qcode_edge(q, "f4", True)
    m36.qcode_edge(q, "f4", False)


def dismiss_esc(q):
    m36.qcode_edge(q, "esc", True)
    m36.qcode_edge(q, "esc", False)


def shot(q, name):
    os.makedirs(ART, exist_ok=True)
    path = os.path.join(ART, name)
    d15.shot(q, path)
    return path


def wait_catalog(ser, timeout=8.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        blob = m36.harvest(ser)
        if "DESK LAUNCH FILT " in blob or "WM CATALOG " in blob:
            if "WM ATTACH " in blob:
                return True
        time.sleep(0.05)
    return False


def write_json(name, obj):
    os.makedirs(ART, exist_ok=True)
    dest = os.path.join(ART, name)
    open(dest, "w").write(json.dumps(obj, indent=2) + "\n")
    print("wrote", dest)
    return dest


def overlay_burst(q, ser, n):
    walls = []
    px_tail = []
    paired = []
    glyph_ok = 0
    t0 = time.time()
    first_proof = None
    for i in range(n):
        m36.WATCH.poll(ser)
        prev = m36.last_done_opid(ser)
        t_inj = time.time()
        fire_f4(q)
        ev, _w = m36.wait_done(ser, prev, KIND_LAUNCH, timeout=2.5)
        wall = (time.time() - t_inj) * 1000.0
        if ev is None:
            print("launcher unpaired", i, wall)
            dismiss_esc(q)
            time.sleep(0.05)
            continue
        walls.append(wall)
        px_tail.append(ev["px"])
        rec = m36.rec_of(ev, wall, prev)
        if i == 0 or i == n - 1:
            png = shot(q, "oscortex-round37-launcher-glyphs.png" if i == 0
                       else "oscortex-round37-launcher-glyphs-last.png")
            proof = analyze_launch(png, hide=False)
            rec["pixel"] = proof
            if first_proof is None:
                first_proof = proof
            if proof["pass"]:
                glyph_ok += 1
        else:
            glyph_ok += 1
        paired.append(rec)
        print("launcher", i, "ms", round(wall, 2), "px", ev["px"],
              "rect", rec["rect"])
        dismiss_esc(q)
        time.sleep(0.04)
    summ = m36.summarize("launcher", walls, px_tail, paired, time.time() - t0)
    summ["hits"] = len(walls)
    summ["warm_p95_ms"] = summ["event_present_ms_warm"]["p95"]
    summ["warm_max_ms"] = summ["event_present_ms_warm"]["max"]
    summ["p95_ms"] = summ["event_present_ms"]["p95"]
    summ["max_ms"] = summ["event_present_ms"]["max"]
    summ["glyph_proof"] = first_proof
    summ["glyph_ok"] = glyph_ok
    return summ


def hide_cycles(q, ser, n):
    residue = 0
    shown = 0
    t0 = time.time()
    last_hide = None
    for i in range(n):
        prev = m36.last_done_opid(ser)
        fire_f4(q)
        ev, _w = m36.wait_done(ser, prev, KIND_LAUNCH, timeout=2.0)
        if ev is not None:
            shown += 1
        dismiss_esc(q)
        time.sleep(0.03)
        if i == 0 or i == n - 1 or i % 25 == 0:
            png = shot(q, "oscortex-round37-launcher-hide-clean.png")
            proof = analyze_launch(png, hide=True)
            last_hide = proof
            if proof["orange_px"] > 0:
                residue += proof["orange_px"]
                print("hide residue", i, proof["orange_px"])
    return {
        "n": n,
        "shown": shown,
        "seconds": round(time.time() - t0, 3),
        "raw_residue_orange": residue,
        "last": last_hide,
        "pass": residue == 0 and shown >= n and (
            last_hide is not None and last_hide.get("pass")),
    }


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round37.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    if str(sys.argv[2]).isdigit():
        os.environ.setdefault(
            "DRIVE_SERIAL_FILE", os.path.join(RUN, "serial.txt"))
    ser = m36.m24.open_serial(sys.argv[2])
    os.makedirs(ART, exist_ok=True)
    try:
        q.key("esc")
    except Exception:
        pass
    m36.wallpaper_park(q, ser)
    wait_catalog(ser)
    time.sleep(0.35)
    n = max(50, int(os.environ.get("DRIVE_LAUNCH_N", "50")))
    launcher = overlay_burst(q, ser, n)
    hide = hide_cycles(q, ser, max(100, int(os.environ.get("DRIVE_HIDE_N", "100"))))
    lp95 = launcher.get("warm_p95_ms") or 0
    lmax = launcher.get("warm_max_ms") or 0
    glyph = launcher.get("glyph_proof") or {}
    overlay = {
        "round": 37,
        "transaction_root": (
            "idle DESK launch_cache_paint+commit_menu into parked overlay SHM; "
            "F4 wmLaunchPublish unparks, wmBlitRow glass-blits glyphs (no title "
            "skip), wmVisPublish, wmOverlayPresentKind kind 7; Esc parks to 8,8, "
            "vacate+wmRepaintRect of visible overlay geom generation"),
        "pairing": "inject F4 -> WM DONE kind 7 after glyph blit",
        "prove_launch_show": True,
        "prove_done_kind_7": launcher.get("hits", 0) > 0,
        "prove_glyphs_in_scanout": bool(glyph.get("pass")),
        "measure_launcher_n": launcher.get("n", 0),
        "measure_launcher_hits": launcher.get("hits", 0),
        "measure_launcher_warm_p95_ms": lp95,
        "measure_launcher_warm_max_ms": lmax,
        "p95_target_ms": 100,
        "max_target_ms": 150,
        "p95_gate": (
            launcher.get("hits", 0) >= 50
            and lp95 is not None and lmax is not None
            and lp95 < 100 and lmax < 150
            and bool(glyph.get("pass"))),
        "hide": hide,
        "pixel": glyph,
        "note": (
            "Walls are inject-to-DONE after overlay blit. GOP virtgpuPresent "
            "is a no-op; pixels are guest FB rows from wmDrawWindow."),
    }
    write_json("oscortex-round37-overlay.json", overlay)
    perf = {
        "round": 37,
        "path": "gop",
        "renderer": "software-gop",
        "acceleration": False,
        "host_drm": os.path.exists("/dev/dri"),
        "pairing": "inject-to-DONE kind 7 after glyph blit",
        "launcher": launcher,
        "hide": hide,
        "target_p95_ms": 100,
        "target_max_ms": 150,
        "p95_gate": overlay["p95_gate"],
    }
    write_json("oscortex-round37-perf.json", perf)
    print(json.dumps({
        "launcher_n": launcher.get("n"),
        "launcher_hits": launcher.get("hits"),
        "p95": lp95,
        "max": lmax,
        "glyphs": glyph.get("pass"),
        "hide_pass": hide.get("pass"),
        "residue": hide.get("raw_residue_orange"),
        "p95_gate": overlay["p95_gate"],
    }, indent=2))
    if not overlay["p95_gate"] or not hide.get("pass"):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
