#!/usr/bin/env python3
"""Round 30: cold drag→first-scroll + chronological SCAN/FRAME pairing.

Pairs each inject to the first new VIRTIO SCAN or WM FRAME after the
inject by log file offset (SCAN gen ≠ FRAME N). Drag skips 640-px
pointer frames so the layer blit is the pair.

Writes oscortex-round30-perf.json (or OSCORTEX_PERF_OUT).
"""

import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "m24", os.path.join(HERE, "measure-round24.py"))
m24 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m24)
d15 = m24.d15

cs_spec = importlib.util.spec_from_file_location(
    "cs", os.path.join(HERE, "chip-scan-round24.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)

SCAN_RE = re.compile(
    r"VIRTIO SCAN ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+)")
FRAME_RE = re.compile(
    r"WM FRAME N ([0-9A-F]+) PX ([0-9A-F]+)")
CPATH_RE = re.compile(r"WM CPATH ([0-9A-F]+)")
DRAGEND_RE = re.compile(r"WM DRAGEND ([0-9A-F]+)")
COMMIT_RE = re.compile(r"WM COMMIT W ([0-9A-F]+)")
FULL_PX = 1280 * 720


def harvest(ser):
    ser.read()
    try:
        blob = open(ser.path, encoding="latin-1", errors="replace").read()
    except OSError:
        blob = ""
    return (blob or "") + "\n" + (ser.archive or "")


def events(ser):
    """Chronological (pos, kind, gen, px, w, h). SCAN gen ≠ FRAME N."""
    blob = harvest(ser)
    rows = []
    for m in SCAN_RE.finditer(blob):
        w = int(m.group(3), 16)
        h = int(m.group(4), 16)
        rows.append((m.start(), "scan", int(m.group(5), 16), w * h, w, h))
    for m in FRAME_RE.finditer(blob):
        px = int(m.group(2), 16)
        rows.append((m.start(), "frame", int(m.group(1), 16), px, 0, 0))
    rows.sort(key=lambda r: r[0])
    return rows


def last_pos(ser):
    ev = events(ser)
    if not ev:
        return -1
    return ev[-1][0]


def first_after(ser, prev_pos, want_kind=None):
    for pos, kind, gen, px, w, h in events(ser):
        if pos <= prev_pos:
            continue
        if want_kind and kind != want_kind:
            continue
        return pos, kind, gen, px, w, h
    return None


def wait_pair(ser, prev, timeout=3.0, skip_ptr=False, skip_full=False,
              prefer_scan=False, skip_layer=False):
    t0 = time.time()
    while (time.time() - t0) < timeout:
        got = first_after(ser, prev, want_kind=("scan" if prefer_scan else None))
        if got is None and not prefer_scan:
            got = first_after(ser, prev)
        if got is not None:
            pos, kind, gen, px, w, h = got
            if skip_ptr and px <= 640 and px > 0:
                prev = pos
                continue
            if skip_full and px >= FULL_PX:
                prev = pos
                continue
            # Drag old∪new AABB (2×406×286) is not the first body click.
            if skip_layer and px == 232232:
                prev = pos
                continue
            return kind, gen, px, w, h, (time.time() - t0) * 1000.0
        time.sleep(0.005)
    return None


def wait_mark(ser, regex, prev_len, timeout=0.2):
    """Wait for a new regex match after prev_len in the harvested blob."""
    t0 = time.time()
    while (time.time() - t0) < timeout:
        blob = harvest(ser)
        m = None
        for hit in regex.finditer(blob):
            if hit.start() >= prev_len:
                m = hit
        if m is not None:
            return m, (time.time() - t0) * 1000.0
        time.sleep(0.005)
    return None, (time.time() - t0) * 1000.0


def pct_of(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    i = min(len(xs) - 1, int(round((p / 100.0) * (len(xs) - 1))))
    return round(xs[i], 2)


def summarize(label, walls, px_tail, paired, dur):
    n = len(walls)
    walls_sorted = sorted(walls)
    warm = px_tail[2:] if len(px_tail) > 2 else px_tail
    warm_walls = sorted(walls[2:]) if len(walls) > 2 else walls_sorted
    return {
        "n": n,
        "seconds": round(dur, 3),
        "achieved_fps": round(n / dur, 2) if dur > 0 else 0,
        "ops_per_sec": round(n / dur, 2) if dur > 0 else 0,
        "dirty_px_tail": px_tail[-8:],
        "dirty_px_p50": (sorted(px_tail)[len(px_tail) // 2] if px_tail else 0),
        "dirty_px_max": max(px_tail) if px_tail else 0,
        "paired_tail": paired[-8:],
        "event_present_ms": {
            "n": n,
            "p50": pct_of(walls_sorted, 50),
            "p95": pct_of(walls_sorted, 95),
            "max": round(walls_sorted[-1], 2) if walls_sorted else None,
        },
        "event_present_ms_warm": {
            "n": len(warm_walls),
            "p50": pct_of(warm_walls, 50),
            "p95": pct_of(warm_walls, 95),
            "max": round(warm_walls[-1], 2) if warm_walls else None,
        },
        "full_1280_flushes": sum(1 for p in px_tail if p >= FULL_PX),
        "full_1280_after_warm": sum(1 for p in warm if p >= FULL_PX),
        "label": label,
    }


def burst(q, ser, label, points, btn=None, skip_ptr=False, prefer_scan=False):
    walls = []
    px_tail = []
    paired = []
    t0 = time.time()
    for x, y in points:
        g0 = last_pos(ser)
        t_inj = time.time()
        try:
            if btn:
                d15.place(q, ser, x, y)
                d15.button(q, x, y, btn, True)
                d15.button(q, x, y, btn, False)
                if btn == "right":
                    try:
                        q.key("esc")
                    except Exception:
                        pass
            else:
                d15.place(q, ser, x, y)
        except Exception as e:
            print(label, "inject", e)
            continue
        got = wait_pair(ser, g0, timeout=2.5, skip_ptr=skip_ptr,
                        prefer_scan=prefer_scan)
        if got is None:
            print(label, "unpaired", x, y, "prev", g0)
            continue
        kind, gen, px, w, h, _wait = got
        wall = (time.time() - t_inj) * 1000.0
        walls.append(wall)
        px_tail.append(px)
        paired.append({
            "wall_ms": round(wall, 2),
            "kind": kind,
            "gen": gen,
            "pos0": g0,
            "dirty_px": px,
            "scan_w": w,
            "scan_h": h,
        })
    return summarize(label, walls, px_tail, paired, time.time() - t0)


def files_geom(ser):
    g = cs.live_files_xywh(ser.path, ser.archive or "")
    if g:
        return g
    blob = harvest(ser)
    slot = cs.files_slot(blob)
    if slot is None:
        return (48, 40, 400, 280)
    # Fresh leftover: VIS may lag one attach; fall back to ATTACH AABB.
    last = None
    for m in cs.ATTACH_RE.finditer(blob):
        if int(m.group(1), 16) != slot:
            continue
        last = (
            int(m.group(4), 16),
            int(m.group(5), 16),
            int(m.group(6), 16),
            int(m.group(7), 16),
        )
    return last or (48, 40, 400, 280)


def title_xy(geom):
    return cs.title_of(geom)


def body_xy(geom, i=0):
    x, y, w, h = geom
    # Stay on the first visible rows so sel union is 1–2 bands, not a
    # 6-row commit that is not the cold hitch under test.
    bx = x + 40 + (i * 11) % max(8, w - 80)
    by = y + 80 + (i % 2) * 28
    return bx, by


def ensure_files(q, ser):
    blob = harvest(ser)
    if cs.files_slot(blob) is not None:
        return
    d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
    time.sleep(0.05)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", True)
    time.sleep(0.04)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", False)
    t0 = time.time()
    while time.time() - t0 < 3.0:
        if cs.files_slot(harvest(ser)) is not None:
            break
        time.sleep(0.05)
    d15.place(q, ser, 48, 520)
    time.sleep(0.08)


def phase_counts(ser, after=0):
    blob = harvest(ser)[after:]
    paths = [int(m.group(1), 16) for m in CPATH_RE.finditer(blob)]
    return {
        "cpath_n": len(paths),
        "cpath_skip": sum(1 for p in paths if p == 1),
        "cpath_gfx": sum(1 for p in paths if p == 2),
        "cpath_compose": sum(1 for p in paths if p == 3),
        "dragend_n": len(DRAGEND_RE.findall(blob)),
        "commit_n": len(COMMIT_RE.findall(blob)),
        "tail": paths[-12:],
    }


def cold_drag_first_scroll(q, ser, n=32):
    """Each cycle: title drag, release, wait drag-end, first body click."""
    walls = []
    px_tail = []
    paired = []
    phases = []
    t0 = time.time()
    for i in range(n):
        geom = files_geom(ser)
        tx, ty = title_xy(geom)
        dx = 18 + (i % 7) * 6
        d15.place(q, ser, tx, ty)
        d15.button(q, tx, ty, "left", True)
        for step in range(3):
            d15.place(q, ser, tx + dx + step * 4, ty)
        blob_len = len(harvest(ser))
        d15.button(q, tx + dx + 8, ty, "left", False)
        # Retain/complete drag-end configure before the first body hit.
        end, end_ms = wait_mark(ser, DRAGEND_RE, blob_len, timeout=0.25)
        cpath, cpath_ms = wait_mark(ser, CPATH_RE, blob_len, timeout=0.12)
        # Drain a leftover session FRAME so the click pair is the body.
        settle = last_pos(ser)
        t_settle = time.time()
        while (time.time() - t_settle) < 0.10:
            got = first_after(ser, settle)
            if got is None:
                time.sleep(0.004)
                continue
            settle = got[0]
        geom = files_geom(ser)
        bx, by = body_xy(geom, i)
        d15.place(q, ser, bx, by)
        g0 = last_pos(ser)
        t_inj = time.time()
        try:
            d15.button(q, bx, by, "left", True)
            d15.button(q, bx, by, "left", False)
        except Exception as e:
            print("cold", "inject", e)
            continue
        # Body rect (~99200), not the 640 sprite and not a leftover
        # 1.1 Mpx session FRAME that crossed the inject.
        got = wait_pair(ser, g0, timeout=2.5, skip_ptr=True, skip_full=True,
                        skip_layer=True)
        if got is None:
            print("cold unpaired", bx, by, "prev", g0, "geom", geom)
            continue
        kind, gen, px, w, h, _wait = got
        wall = (time.time() - t_inj) * 1000.0
        walls.append(wall)
        px_tail.append(px)
        rec = {
            "wall_ms": round(wall, 2),
            "kind": kind,
            "gen": gen,
            "pos0": g0,
            "dirty_px": px,
            "scan_w": w,
            "scan_h": h,
            "geom": list(geom),
            "title": [tx, ty],
            "body": [bx, by],
            "dragend": end is not None,
            "dragend_wait_ms": round(end_ms, 2),
            "release_cpath": (int(cpath.group(1), 16) if cpath else None),
            "release_cpath_wait_ms": round(cpath_ms, 2),
        }
        paired.append(rec)
        phases.append(rec)
        print("cold", i, "ms", rec["wall_ms"], "px", px, "cpath",
              rec["release_cpath"], "path", kind)
        # Walk back before the clamp so the next title grab stays live.
        if geom[0] > 360:
            d15.place(q, ser, tx, ty)
            d15.button(q, tx, ty, "left", True)
            d15.place(q, ser, max(60, tx - 80), ty)
            d15.button(q, max(60, tx - 80), ty, "left", False)
            wait_mark(ser, DRAGEND_RE, len(harvest(ser)) - 80, timeout=0.2)
    out = summarize("cold_first_scroll", walls, px_tail, paired,
                    time.time() - t0)
    out["cycles"] = phases
    return out


def layered_drag(q, ser, n=32):
    geom = files_geom(ser)
    tx, ty = title_xy(geom)
    pts = [(tx + (i * 9) % 160, ty) for i in range(n)]
    d15.place(q, ser, pts[0][0], pts[0][1])
    d15.button(q, pts[0][0], pts[0][1], "left", True)
    prefer = os.environ.get("OSCORTEX_PREFER_SCAN",
                            "1" if "venus" in os.environ.get(
                                "OSCORTEX_PERF_PATH", "") else "0") == "1"
    drag = burst(q, ser, "drag", pts[1:], skip_ptr=True, prefer_scan=prefer)
    d15.button(q, pts[-1][0], pts[-1][1], "left", False)
    blob_len = len(harvest(ser))
    wait_mark(ser, DRAGEND_RE, blob_len, timeout=0.25)
    wait_mark(ser, CPATH_RE, blob_len, timeout=0.15)
    return drag


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round30.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    ser = m24.open_serial(sys.argv[2])
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)
    try:
        q.key("esc")
    except Exception:
        pass
    phase0 = len(harvest(ser))
    ensure_files(q, ser)
    n_ptr = max(100, int(os.environ.get("DRIVE_PTR_N", "100")))
    n = max(30, int(os.environ.get("DRIVE_N", "32")))
    n_cold = max(30, int(os.environ.get("DRIVE_COLD_N", "32")))
    prefer_scan = os.environ.get("OSCORTEX_PREFER_SCAN",
                                 "1" if "venus" in os.environ.get(
                                     "OSCORTEX_PERF_PATH", "") else "0") == "1"

    for i in range(6):
        try:
            d15.place(q, ser, 40 + i * 12, 500)
        except Exception:
            pass
    pointer = burst(q, ser, "pointer",
                    [(36 + (i * 17) % 160, 480 + (i * 9) % 100)
                     for i in range(n_ptr)])
    drag = layered_drag(q, ser, n)
    cold = cold_drag_first_scroll(q, ser, n_cold)
    geom = files_geom(ser)
    bx, by = body_xy(geom, 3)
    scroll = burst(q, ser, "scroll",
                   [(bx, by + (i * 11) % 60) for i in range(n)],
                   btn="wheel-down")
    menu = burst(q, ser, "menu",
                 [(48 + (i * 11) % 100, 510 + (i * 5) % 80)
                  for i in range(n)],
                 btn="right")

    dest_name = os.environ.get("OSCORTEX_PERF_OUT", "oscortex-round30-perf.json")
    phase = phase_counts(ser, phase0)
    payload = {
        "round": 30,
        "pairing": "first new VIRTIO SCAN or WM FRAME by log offset",
        "path": os.environ.get("OSCORTEX_PERF_PATH", "gop"),
        "renderer": os.environ.get("OSCORTEX_RENDERER", "software-gop"),
        "acceleration": False,
        "host_drm": os.path.exists("/dev/dri"),
        "phase": phase,
        "pointer": pointer,
        "drag": drag,
        "cold_first_scroll": cold,
        "scroll": scroll,
        "menu": menu,
        "target_fps": 30,
        "min_fps": 15,
        "target_p95_ms": 100,
        "target_cold_max_ms": 150,
        "pointer_p95_ms": 75,
        "gates": {
            "pointer_n": pointer["n"] >= 30,
            "drag_n": drag["n"] >= 30,
            "menu_n": menu["n"] >= 30,
            "cold_n": cold["n"] >= 30,
            "pointer_dirty_640": pointer["dirty_px_p50"] == 640,
            "menu_dirty_16182": menu["dirty_px_p50"] == 16182,
            "drag_fps": drag["achieved_fps"] >= 15,
            "pointer_p95": (pointer["event_present_ms"]["p95"] or 999) < 75,
            "drag_p95": (drag["event_present_ms"]["p95"] or 999) < 150,
            "menu_p95": (menu["event_present_ms"]["p95"] or 999) < 100,
            "cold_p95": (cold["event_present_ms"]["p95"] or 999) < 100,
            "cold_max": (cold["event_present_ms"]["max"] or 999) < 150,
            "no_full_drag_warm": drag["full_1280_after_warm"] == 0,
            "no_full_menu_warm": menu["full_1280_after_warm"] == 0,
            "no_full_cold": cold["full_1280_flushes"] == 0,
            "no_session_compose": phase["cpath_compose"] == 0,
        },
    }
    dest = os.path.join(art, dest_name)
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps({
        "path": payload["path"],
        "pointer_n": pointer["n"],
        "pointer_fps": pointer["achieved_fps"],
        "drag_n": drag["n"],
        "drag_fps": drag["achieved_fps"],
        "cold_n": cold["n"],
        "cold_p50": cold["event_present_ms"]["p50"],
        "cold_p95": cold["event_present_ms"]["p95"],
        "cold_max": cold["event_present_ms"]["max"],
        "scroll_fps": scroll["achieved_fps"],
        "menu_fps": menu["achieved_fps"],
        "pointer_p95": pointer["event_present_ms"]["p95"],
        "drag_p95": drag["event_present_ms"]["p95"],
        "menu_p95": menu["event_present_ms"]["p95"],
        "pointer_dirty_p50": pointer["dirty_px_p50"],
        "drag_dirty_p50": drag["dirty_px_p50"],
        "menu_dirty_p50": menu["dirty_px_p50"],
        "cold_dirty_p50": cold["dirty_px_p50"],
        "drag_full_1280": drag["full_1280_flushes"],
        "drag_full_1280_warm": drag["full_1280_after_warm"],
        "phase": phase,
        "gates": payload["gates"],
    }, indent=2))
    print("wrote", dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
