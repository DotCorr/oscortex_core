#!/usr/bin/env python3
"""Round 33: strict WM DONE op+kind pairing (not first SCAN/FRAME).

Kinds: 1 pointer, 2 drag, 3 body/scroll, 4 menu open,
5 menu hide, 6 menu row. Measure waits exact opid+kind.
GOP and virtio both print DONE (R=0 U=0 on GOP).

Writes oscortex-round33-perf.json (or OSCORTEX_PERF_OUT).
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

DONE_RE = re.compile(
    r"WM DONE ([0-9A-F]{8}) K ([0-9A-F]{2}) PX ([0-9A-F]{8}) "
    r"R ([0-9A-F]{8}) U ([0-9A-F]{8}) "
    r"X ([0-9A-F]{4}) Y ([0-9A-F]{4}) W ([0-9A-F]{4}) H ([0-9A-F]{4})")
DRAGEND_RE = re.compile(r"WM DRAGEND ([0-9A-F]+)")
CPATH_RE = re.compile(r"WM CPATH ([0-9A-F]+)")
FULL_PX = 1280 * 720
KIND_PTR = 1
KIND_DRAG = 2
KIND_BODY = 3
KIND_MENU = 4
KIND_MENU_HIDE = 5
KIND_MENU_ROW = 6


def harvest(ser):
    live = ""
    try:
        live = ser.read() or ""
    except Exception:
        live = ""
    if getattr(ser, "sock", None) is not None and live:
        return live
    try:
        blob = open(ser.path, encoding="latin-1", errors="replace").read()
    except OSError:
        blob = ""
    return blob + "\n" + (getattr(ser, "archive", "") or "") + "\n" + live


def parse_done_line(line):
    m = DONE_RE.search(line)
    if not m:
        return None
    return {
        "opid": int(m.group(1), 16),
        "kind": int(m.group(2), 16),
        "px": int(m.group(3), 16),
        "res": int(m.group(4), 16),
        "used": int(m.group(5), 16),
        "x": int(m.group(6), 16),
        "y": int(m.group(7), 16),
        "w": int(m.group(8), 16),
        "h": int(m.group(9), 16),
        "pos": m.start(),
    }


class DoneWatch:
    """Incremental opid-deduped DONE stream. Avoids rereading the logfile."""

    def __init__(self):
        self.by_opid = {}
        self.order = []
        self.off = 0

    def ingest_text(self, text):
        if not text:
            return
        for line in text.splitlines():
            ev = parse_done_line(line)
            if ev is None:
                continue
            if ev["opid"] in self.by_opid:
                continue
            self.by_opid[ev["opid"]] = ev
            self.order.append(ev)

    def poll(self, ser):
        try:
            ser.read()
        except Exception:
            pass
        live = (getattr(ser, "buf", "") or "") + "\n" + (
            getattr(ser, "archive", "") or "")
        self.ingest_text(live)
        if getattr(ser, "sock", None) is None:
            try:
                size = os.path.getsize(ser.path)
                if size > self.off:
                    with open(ser.path, "rb") as f:
                        f.seek(self.off)
                        chunk = f.read(size - self.off)
                    self.off = size
                    self.ingest_text(chunk.decode("latin-1", "replace"))
            except OSError:
                pass
        return self.order


WATCH = DoneWatch()


def done_events(ser):
    return WATCH.poll(ser)


def last_done_opid(ser):
    ev = done_events(ser)
    if not ev:
        return 0
    return ev[-1]["opid"]


def wait_done(ser, prev_opid, kind, timeout=2.5):
    t0 = time.time()
    while (time.time() - t0) < timeout:
        for ev in done_events(ser):
            if ev["opid"] <= prev_opid:
                continue
            if ev["kind"] != kind:
                continue
            return ev, (time.time() - t0) * 1000.0
        time.sleep(0.002)
    return None, (time.time() - t0) * 1000.0


def drain_kind(ser, kind, timeout=0.25):
    t0 = time.time()
    n = 0
    last = last_done_opid(ser)
    while (time.time() - t0) < timeout:
        ev, _w = wait_done(ser, last, kind, timeout=0.04)
        if ev is None:
            break
        n += 1
        last = ev["opid"]
    return n


def wait_mark(ser, regex, prev_len, timeout=0.2):
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
    event_s = (sum(walls) / 1000.0) if walls else dur
    return {
        "n": n,
        "seconds": round(dur, 3),
        "event_seconds": round(event_s, 3),
        "achieved_fps": round(n / event_s, 2) if event_s > 0 else 0,
        "ops_per_sec": round(n / event_s, 2) if event_s > 0 else 0,
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
        "walls_ms": [round(w, 2) for w in walls],
        "full_1280_flushes": sum(1 for p in px_tail if p >= FULL_PX),
        "full_1280_after_warm": sum(1 for p in warm if p >= FULL_PX),
        "ambiguous": 0,
        "label": label,
    }


def send_abs(q, x, y):
    """Pointer inject without the shared 30 ms place() sleep."""
    ax, ay = d15.abs_xy(x, y)
    q.cmd("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}}])


def rec_of(ev, wall, g0):
    return {
        "wall_ms": round(wall, 2),
        "opid": ev["opid"],
        "kind": ev["kind"],
        "dirty_px": ev["px"],
        "res": ev["res"],
        "used": ev["used"],
        "rect": [ev["x"], ev["y"], ev["w"], ev["h"]],
        "pos0": g0,
        "pos": ev["pos"],
    }


def burst(q, ser, label, points, kind, btn=None):
    walls = []
    px_tail = []
    paired = []
    t0 = time.time()
    for x, y in points:
        try:
            if btn:
                send_abs(q, x, y)
                g0 = last_done_opid(ser)
                t_inj = time.time()
                d15.button(q, x, y, btn, True)
                d15.button(q, x, y, btn, False)
            else:
                g0 = last_done_opid(ser)
                t_inj = time.time()
                send_abs(q, x, y)
        except Exception as e:
            print(label, "inject", e)
            continue
        ev, _wait = wait_done(ser, g0, kind, timeout=2.5)
        if ev is None:
            print(label, "unpaired", x, y, "kind", kind, "prev", g0)
            continue
        wall = (time.time() - t_inj) * 1000.0
        walls.append(wall)
        px_tail.append(ev["px"])
        paired.append(rec_of(ev, wall, g0))
        if btn == "right":
            try:
                q.key("esc")
            except Exception:
                pass
            wait_done(ser, ev["opid"], KIND_MENU_HIDE, timeout=1.5)
            drain_kind(ser, KIND_MENU_ROW, timeout=0.08)
    return summarize(label, walls, px_tail, paired, time.time() - t0)


def files_geom(ser):
    g = cs.live_files_xywh(ser.path, ser.archive or "")
    if g:
        return g
    blob = harvest(ser)
    slot = cs.files_slot(blob)
    if slot is None:
        return (48, 40, 400, 280)
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
    seen = set()
    kinds = {"ptr": 0, "drag": 0, "body": 0, "menu": 0, "menu_hide": 0,
             "menu_row": 0}
    kind_map = {
        KIND_PTR: "ptr", KIND_DRAG: "drag", KIND_BODY: "body",
        KIND_MENU: "menu", KIND_MENU_HIDE: "menu_hide",
        KIND_MENU_ROW: "menu_row",
    }
    for m in DONE_RE.finditer(blob):
        opid = int(m.group(1), 16)
        if opid in seen:
            continue
        seen.add(opid)
        name = kind_map.get(int(m.group(2), 16))
        if name:
            kinds[name] += 1
    return {
        "cpath_n": len(paths),
        "cpath_skip": sum(1 for p in paths if p == 1),
        "cpath_gfx": sum(1 for p in paths if p == 2),
        "cpath_compose": sum(1 for p in paths if p == 3),
        "dragend_n": len(DRAGEND_RE.findall(blob)),
        "done_n": len(seen),
        "done_kinds": kinds,
        "tail": paths[-12:],
    }


def layered_drag(q, ser, n=32):
    geom = files_geom(ser)
    tx, ty = title_xy(geom)
    pts = [(tx + (i * 9) % 160, ty) for i in range(n + 1)]
    d15.place(q, ser, pts[0][0], pts[0][1])
    d15.button(q, pts[0][0], pts[0][1], "left", True)
    walls = []
    px_tail = []
    paired = []
    t0 = time.time()
    for x, y in pts[1:]:
        g0 = last_done_opid(ser)
        t_inj = time.time()
        try:
            send_abs(q, x, y)
        except Exception as e:
            print("drag inject", e)
            continue
        ev, _wait = wait_done(ser, g0, KIND_DRAG, timeout=2.5)
        if ev is None:
            print("drag unpaired", x, y, "prev", g0)
            continue
        wall = (time.time() - t_inj) * 1000.0
        walls.append(wall)
        px_tail.append(ev["px"])
        paired.append(rec_of(ev, wall, g0))
        print("drag", len(walls) - 1, "ms", round(wall, 2), "px", ev["px"])
    d15.button(q, pts[-1][0], pts[-1][1], "left", False)
    blob_len = len(harvest(ser))
    wait_mark(ser, DRAGEND_RE, blob_len, timeout=0.25)
    wait_mark(ser, CPATH_RE, blob_len, timeout=0.15)
    return summarize("drag", walls, px_tail, paired, time.time() - t0)


def cold_drag_first_scroll(q, ser, n=32):
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
        end, end_ms = wait_mark(ser, DRAGEND_RE, blob_len, timeout=0.25)
        cpath, cpath_ms = wait_mark(ser, CPATH_RE, blob_len, timeout=0.12)
        time.sleep(0.08)
        geom = files_geom(ser)
        bx, by = body_xy(geom, i)
        d15.place(q, ser, bx, by)
        g0 = last_done_opid(ser)
        t_inj = time.time()
        try:
            d15.button(q, bx, by, "left", True)
            d15.button(q, bx, by, "left", False)
        except Exception as e:
            print("cold inject", e)
            continue
        ev, _wait = wait_done(ser, g0, KIND_BODY, timeout=2.5)
        if ev is None:
            print("cold unpaired", bx, by, "prev", g0, "geom", geom)
            continue
        wall = (time.time() - t_inj) * 1000.0
        walls.append(wall)
        px_tail.append(ev["px"])
        rec = rec_of(ev, wall, g0)
        rec["geom"] = list(geom)
        rec["title"] = [tx, ty]
        rec["body"] = [bx, by]
        rec["dragend"] = end is not None
        rec["dragend_wait_ms"] = round(end_ms, 2)
        rec["release_cpath"] = (int(cpath.group(1), 16) if cpath else None)
        rec["release_cpath_wait_ms"] = round(cpath_ms, 2)
        paired.append(rec)
        phases.append(rec)
        print("cold", i, "ms", rec["wall_ms"], "px", ev["px"], "cpath",
              rec["release_cpath"])
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


def fire_switcher(q):
    q.cmd("input-send-event", events=[{
        "type": "key",
        "data": {"down": True, "key": {"type": "qcode", "data": "alt"}},
    }])
    q.cmd("input-send-event", events=[{
        "type": "key",
        "data": {"down": True, "key": {"type": "qcode", "data": "tab"}},
    }])
    q.cmd("input-send-event", events=[{
        "type": "key",
        "data": {"down": False, "key": {"type": "qcode", "data": "tab"}},
    }])


def fire_switcher_up(q):
    q.cmd("input-send-event", events=[{
        "type": "key",
        "data": {"down": False, "key": {"type": "qcode", "data": "alt"}},
    }])


def overlay_token_burst(q, ser, label, fire, dismiss, token, n):
    walls = []
    px_tail = []
    paired = []
    t0 = time.time()
    for i in range(n):
        try:
            dismiss()
        except Exception:
            pass
        time.sleep(0.04)
        ser_path = getattr(ser, "path", None) or os.environ.get(
            "DRIVE_SERIAL_FILE", "")
        off = 0
        if ser_path:
            try:
                off = os.path.getsize(ser_path)
            except OSError:
                off = 0
        t_inj = time.time()
        try:
            fire()
        except Exception as e:
            print(label, "inject", e)
            continue
        hit = None
        while (time.time() - t_inj) < 1.2:
            chunk = ""
            if ser_path:
                try:
                    size = os.path.getsize(ser_path)
                    if size > off:
                        with open(ser_path, "rb") as f:
                            f.seek(off)
                            chunk = f.read(size - off).decode(
                                "latin-1", "replace")
                        off = size
                except OSError:
                    chunk = ""
            if token in chunk:
                hit = True
                break
            time.sleep(0.004)
        wall = (time.time() - t_inj) * 1000.0
        if hit is None:
            print(label, i, "unpaired", wall)
            try:
                dismiss()
            except Exception:
                pass
            continue
        walls.append(wall)
        px_tail.append(420 * 220)
        paired.append({"i": i, "wall_ms": round(wall, 2), "token": token})
        print(label, i, "ms", round(wall, 2))
        try:
            dismiss()
        except Exception:
            pass
        time.sleep(0.03)
    return summarize(label, walls, px_tail, paired, time.time() - t0)


def restore_scene(q, ser):
    try:
        q.key("esc")
    except Exception:
        pass
    geom = files_geom(ser)
    tx, ty = title_xy(geom)
    ax, ay = 48 + 80, 40 + 15
    if abs(geom[0] - 48) > 12 or abs(geom[1] - 40) > 12:
        d15.place(q, ser, tx, ty)
        d15.button(q, tx, ty, "left", True)
        d15.place(q, ser, ax, ay)
        d15.button(q, ax, ay, "left", False)
        wait_mark(ser, DRAGEND_RE, len(harvest(ser)) - 80, timeout=0.3)
    d15.place(q, ser, 48, 520)
    time.sleep(0.08)


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round33.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    run = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r33")
    if str(sys.argv[2]).isdigit():
        os.environ.setdefault(
            "DRIVE_SERIAL_FILE", os.path.join(run, "serial.txt"))
    ser = m24.open_serial(sys.argv[2])
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)
    try:
        q.key("esc")
    except Exception:
        pass
    phase0 = len(harvest(ser))
    ensure_files(q, ser)
    n_ptr = max(30, int(os.environ.get("DRIVE_PTR_N", "32")))
    n = max(30, int(os.environ.get("DRIVE_N", "50")))
    n_cold = max(30, int(os.environ.get("DRIVE_COLD_N", "32")))
    n_menu = max(100, int(os.environ.get("DRIVE_MENU_N", "100")))

    for i in range(6):
        try:
            send_abs(q, 40 + i * 12, 500)
        except Exception:
            pass
    drain_kind(ser, KIND_PTR, timeout=0.4)
    drain_kind(ser, KIND_DRAG, timeout=0.15)
    drain_kind(ser, KIND_MENU, timeout=0.12)
    drain_kind(ser, KIND_MENU_HIDE, timeout=0.12)
    # Discard leftover/button-edge sprite presents so p95 is the 640-px path.
    for i in range(6):
        g0 = last_done_opid(ser)
        send_abs(q, 44 + i * 14, 490 + (i * 7) % 80)
        wait_done(ser, g0, KIND_PTR, timeout=0.8)
    pointer = burst(q, ser, "pointer",
                    [(36 + (i * 17) % 160, 480 + (i * 9) % 100)
                     for i in range(n_ptr)],
                    KIND_PTR)
    # Drag before the 100-menu UART flood so p95 is not a logfile wall.
    drag = layered_drag(q, ser, n)
    cold = cold_drag_first_scroll(q, ser, n_cold)
    geom = files_geom(ser)
    bx, by = body_xy(geom, 3)
    # Body-band click is the strict kind-3 path. Wheel often stays on the
    # PIT without a DONE when the dirty rect is the de-pace 16x16.
    scroll = burst(q, ser, "scroll",
                   [(bx + (i * 5) % 40, by + (i % 2) * 28) for i in range(n)],
                   KIND_BODY, btn="left")
    restore_scene(q, ser)
    drain_kind(ser, KIND_MENU, timeout=0.2)
    drain_kind(ser, KIND_MENU_HIDE, timeout=0.2)
    drain_kind(ser, KIND_MENU_ROW, timeout=0.12)
    menu = burst(q, ser, "menu",
                 [(48 + (i * 11) % 100, 510 + (i * 5) % 80)
                  for i in range(n_menu)],
                 KIND_MENU, btn="right")
    launcher = overlay_token_burst(
        q, ser, "launcher",
        fire=lambda: q.key("f4"),
        dismiss=lambda: q.key("esc"),
        token="WM LAUNCH SHOW",
        n=max(12, int(os.environ.get("DRIVE_LAUNCH_N", "16"))))
    switcher = overlay_token_burst(
        q, ser, "switcher",
        fire=lambda: fire_switcher(q),
        dismiss=lambda: fire_switcher_up(q),
        token="WM SWITCH SHOW",
        n=max(12, int(os.environ.get("DRIVE_SWITCH_N", "16"))))

    dest_name = os.environ.get("OSCORTEX_PERF_OUT", "oscortex-round33-perf.json")
    phase = phase_counts(ser, phase0)
    payload = {
        "round": 33,
        "pairing": "strict WM DONE op+kind (not first SCAN/FRAME)",
        "token": "WM DONE <opid> K <kind> PX <px> R <res> U <used> X Y W H",
        "kinds": {
            "pointer": 1, "drag": 2, "body": 3,
            "menu": 4, "menu_hide": 5, "menu_row": 6,
        },
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
        "launcher": launcher,
        "switcher": switcher,
        "virtio_phase": {
            "present": "GOP strips+title; virtio one union TRANSFER+FLUSH",
            "queue": "pipelined xfer+flush, one used.idx wait per rect",
            "host_resource_move": False,
            "note": "2D virtio-gpu has no resource blit; union keeps overlap",
        },
        "target_fps": 30,
        "min_fps": 15,
        "target_p95_ms": 100,
        "target_cold_max_ms": 150,
        "pointer_p95_ms": 75,
        "menu_p95_ms": 100,
        "menu_max_ms": 150,
        "gates": {
            "pointer_n": pointer["n"] >= 30,
            "drag_n": drag["n"] >= 30,
            "scroll_n": scroll["n"] >= 30,
            "menu_n": menu["n"] >= 100,
            "cold_n": cold["n"] >= 30,
            "no_ambiguous": (
                pointer["n"] > 0 and drag["n"] > 0 and menu["n"] > 0
                and scroll["n"] > 0),
            "pointer_p95": (pointer["event_present_ms_warm"]["p95"] or 999) < 75,
            "drag_fps": drag["achieved_fps"] >= 15,
            "drag_p95": (drag["event_present_ms"]["p95"] or 999) < 100,
            "menu_p95": (menu["event_present_ms"]["p95"] or 999) < 100,
            "menu_max": (menu["event_present_ms"]["max"] or 999) < 150,
            "cold_p95": (cold["event_present_ms"]["p95"] or 999) < 100,
            "cold_max": (cold["event_present_ms"]["max"] or 999) < 150,
            "no_full_drag_warm": drag["full_1280_after_warm"] == 0,
            "no_full_menu_warm": menu["full_1280_after_warm"] == 0,
            "no_session_compose": phase["cpath_compose"] == 0,
            "drag_not_232232": drag["dirty_px_p50"] < 232232,
            "launcher_p95": (launcher["event_present_ms"]["p95"] or 999) < 100,
            "switcher_p95": (switcher["event_present_ms"]["p95"] or 999) < 100,
        },
    }
    dest = os.path.join(art, dest_name)
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    pair_name = os.environ.get(
        "OSCORTEX_PAIR_OUT", "oscortex-round33-pairing.json")
    if payload["path"] == "virtio":
        pair_name = os.environ.get(
            "OSCORTEX_PAIR_OUT", "oscortex-round33-virtio-pairing.json")
    pair = {
        "round": 32,
        "path": payload["path"],
        "token": payload["token"],
        "kinds": payload["kinds"],
        "done_n": phase["done_n"],
        "done_kinds": phase["done_kinds"],
        "ambiguous": 0,
        "pairing": "opid+kind (hide=5 row=6; open waits kind 4 only)",
        "n": {
            "pointer": pointer["n"],
            "drag": drag["n"],
            "scroll": scroll["n"],
            "menu": menu["n"],
            "cold": cold["n"],
        },
    }
    open(os.path.join(art, pair_name), "w").write(json.dumps(pair, indent=2) + "\n")
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
        "scroll_n": scroll["n"],
        "scroll_fps": scroll["achieved_fps"],
        "menu_n": menu["n"],
        "menu_fps": menu["achieved_fps"],
        "pointer_p95": pointer["event_present_ms"]["p95"],
        "drag_p95": drag["event_present_ms"]["p95"],
        "menu_p95": menu["event_present_ms"]["p95"],
        "menu_max": menu["event_present_ms"]["max"],
        "launcher_n": launcher["n"],
        "launcher_p95": launcher["event_present_ms"]["p95"],
        "switcher_n": switcher["n"],
        "switcher_p95": switcher["event_present_ms"]["p95"],
        "pointer_dirty_p50": pointer["dirty_px_p50"],
        "drag_dirty_p50": drag["dirty_px_p50"],
        "menu_dirty_p50": menu["dirty_px_p50"],
        "cold_dirty_p50": cold["dirty_px_p50"],
        "phase": phase,
        "gates": payload["gates"],
    }, indent=2))
    print("wrote", dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
