#!/usr/bin/env python3
"""Round 24: 20 launch→drag→close + pointer/menu latency. VIS geom only."""

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

cs_spec = importlib.util.spec_from_file_location(
    "chip23", os.path.join(HERE, "chip-scan-round24.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)

CSDHIT_RE = re.compile(
    r"WM CSDHIT T ([0-9A-F]+) HIT ([0-9A-F]+) GH ([0-9A-F]+)"
    r" X ([0-9A-F]+) Y ([0-9A-F]+) W ([0-9A-F]+) H ([0-9A-F]+)"
    r" CX ([0-9A-F]+) CY ([0-9A-F]+) PX ([0-9A-F]+) PY ([0-9A-F]+)"
    r" D ([0-9A-F]+) K ([0-9A-F]+)")
LIFE_RE = re.compile(
    r"WM LIFE\s+LV ([0-9A-F]+) SHM ([0-9A-F]+) CH ([0-9A-F]+)"
    r" R ([0-9A-F]+) C ([0-9A-F]+)")
CLOSE_RE = re.compile(r"WM CLOSE W ([0-9A-F]+)")
ATTACH_RE = cs.ATTACH_RE


def open_serial(serial_arg):
    port = 0
    path = serial_arg
    if str(serial_arg).isdigit():
        port = int(serial_arg)
        path = os.environ.get(
            "DRIVE_SERIAL_FILE",
            "/workspace/core/build/daily-drive-r24/serial.txt")
    else:
        envp = os.environ.get("DRIVE_SERIAL_PORT", "0")
        if str(envp).isdigit() and int(envp) > 0:
            port = int(envp)
        else:
            sib = os.path.join(os.path.dirname(path), "serial.port")
            try:
                port = int(open(sib).read().strip())
            except (OSError, ValueError):
                port = 0
    last = None
    for _try in range(20):
        ser = d15.Serial(path, port)
        if ser.sock is not None:
            return ser
        last = "no socket"
        time.sleep(0.2)
    print("WARN: serial socket not connected after retries (%s)" % last)
    return d15.Serial(path, port)


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return round(s[max(0, int(len(s) * p) - 1)], 1)


def harvest(ser):
    ser.read()
    try:
        blob = open(ser.path).read()
    except OSError:
        blob = ser.archive
    return blob + "\n" + (ser.archive or "")


def parse_life(blob):
    rows = []
    for m in LIFE_RE.finditer(blob):
        rows.append({
            "live": int(m.group(1), 16),
            "shm": int(m.group(2), 16),
            "chrome": int(m.group(3), 16),
            "reaps": int(m.group(4), 16),
            "closes": int(m.group(5), 16),
        })
    return rows


def parse_csdhits(blob):
    out = []
    for m in CSDHIT_RE.finditer(blob):
        out.append({
            "top": int(m.group(1), 16),
            "hit": int(m.group(2), 16),
            "geom_hit": int(m.group(3), 16),
            "x": int(m.group(4), 16),
            "y": int(m.group(5), 16),
            "w": int(m.group(6), 16),
            "h": int(m.group(7), 16),
        })
    return out


def vis_gen(ser):
    blob = harvest(ser)
    gen = 0
    for m in cs.VIS_RE.finditer(blob):
        gen = int(m.group(6), 16)
    return gen


def collect(q, ser, label, points, btn=None, want_opid=True):
    """Pair each inject to OPID→PRES (same seq) or sprite present.

    n is successful paired samples only. n=0 is not a pass.
    """
    walls = []
    presents = []
    gens = []
    paired = []
    t0 = time.time()
    for x, y in points:
        g0 = vis_gen(ser)
        try:
            if btn:
                wall = d15.timed_click(q, ser, x, y, btn,
                                       timeout=3.0, want_opid=want_opid,
                                       label=label)
                if wall is None and want_opid:
                    wall = d15.timed_click(q, ser, x, y, btn,
                                           timeout=2.0, want_opid=False,
                                           label=label + "_spr")
                if btn == "right":
                    try:
                        q.key("esc")
                    except Exception:
                        pass
                    time.sleep(0.05)
            else:
                ax, ay = d15.abs_xy(x, y)
                wall = d15.pair_inject(q, ser, [
                    {"type": "abs", "data": {"axis": "x", "value": ax}},
                    {"type": "abs", "data": {"axis": "y", "value": ay}},
                ], 2.0, want_opid=want_opid, label=label)
                if wall is None:
                    wall = d15.pair_inject(q, ser, [
                        {"type": "abs", "data": {"axis": "x", "value": ax}},
                        {"type": "abs", "data": {"axis": "y", "value": ay}},
                    ], 1.5, want_opid=False, label=label + "_spr")
            if wall is None:
                print(label, "unpaired", x, y)
                continue
            walls.append(wall)
            rec = d15.PHASE_TIMELINES[-1] if d15.PHASE_TIMELINES else {}
            if rec.get("present_ms") is not None:
                presents.append(rec["present_ms"])
            g1 = vis_gen(ser)
            gens.append(g1)
            paired.append({
                "host_op": rec.get("host_op"),
                "opid": rec.get("opid"),
                "wall_ms": wall,
                "vis_gen": g1,
                "vis_gen0": g0,
            })
        except Exception as e:
            print(label, "miss", e)
    dur = time.time() - t0
    n = len(walls)
    return {
        "n": n,
        "seconds": round(dur, 3),
        "ops_per_sec": round(n / dur, 2) if dur > 0 else 0,
        "vis_gen_tail": gens[-8:],
        "paired_tail": paired[-8:],
        "event_present_ms": {
            "n": n,
            "p50": pct(walls, 0.50),
            "p95": pct(walls, 0.95),
            "max": round(max(walls), 1) if walls else None,
            "samples": [round(x, 1) for x in walls],
        },
        "guest_present_ms": {
            "n": len(presents),
            "p50": pct(presents, 0.50),
            "p95": pct(presents, 0.95),
            "max": round(max(presents), 1) if presents else None,
        },
    }


def launch_files(q, ser):
    fx, fy = d15.FILES_DOCK_XY
    for _try in range(4):
        before = harvest(ser)
        n_att = len([m for m in ATTACH_RE.finditer(before)
                     if int(m.group(3), 16) == 1 and int(m.group(6), 16) >= 240])
        n0 = cs.vis_count(ser.path, ser.archive or "")
        d15.press(q, ser, fx, fy, "left", "DESK LAUNCH", timeout=1.2)
        deadline = time.time() + 6
        while time.time() < deadline:
            blob = harvest(ser)
            n2 = len([m for m in ATTACH_RE.finditer(blob)
                      if int(m.group(3), 16) == 1 and int(m.group(6), 16) >= 240])
            vis = cs.live_files_xywh(ser.path, ser.archive or "")
            if n2 > n_att and vis is not None:
                return True
            time.sleep(0.08)
        cs.wait_vis(ser, ser.path, n0=n0, timeout=2)
        time.sleep(0.15)
    return False


def close_geom(q, ser, geom, token="WM CLOSE"):
    cx, cy = cs.ctrl_of(geom, "close")
    return bool(d15.press(q, ser, cx, cy, "left", token, timeout=3.0))


def first_drag(q, ser, geom):
    tx, ty = cs.title_of(geom)
    d15.place(q, ser, tx, ty)
    time.sleep(0.08)
    marked = ser.read()
    d15.button(q, tx, ty, "left", True)
    d15.wait_mark(ser, "WM DEFN COMMIT", marked, 1.5)
    time.sleep(0.05)
    nx, ny = tx - 28, ty
    ax, ay = d15.abs_xy(nx, ny)
    n0 = cs.vis_count(ser.path, ser.archive or "")
    wall = d15.pair_inject(q, ser, [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ], 3.0, want_opid=True, label="first_drag")
    cs.wait_vis(ser, ser.path, n0=n0, timeout=1.5)
    d15.button(q, nx, ny, "left", False)
    time.sleep(0.05)
    d15.button(q, nx, ny, "left", False)
    live = cs.live_files_xywh(ser.path, ser.archive or "")
    return wall, live or (geom[0] - 28, geom[1], geom[2], geom[3])


def cycles(q, ser, n=20):
    walls = []
    presents = []
    fresh = 0
    closed = 0
    geoms = []
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    for i in range(n):
        if not launch_files(q, ser):
            print("relaunch miss", i)
            continue
        fresh += 1
        time.sleep(0.2)
        geom = cs.live_files_xywh(ser.path, ser.archive or "")
        if geom is None:
            print("no FILES VIS", i)
            continue
        geoms.append({"geom": list(geom), "i": i})
        wall, moved = first_drag(q, ser, geom)
        time.sleep(0.08)
        live = cs.live_files_xywh(ser.path, ser.archive or "")
        if live is not None:
            moved = live
        if wall is not None:
            walls.append(wall)
        if d15.PHASE_TIMELINES:
            rec = d15.PHASE_TIMELINES[-1]
            if rec.get("present_ms") is not None:
                presents.append(rec["present_ms"])
        print("first_drag", i, "fresh", fresh, "geom", geom, "moved", moved,
              wall)
        if i == 0:
            try:
                d15.shot(q, os.path.join(art, "oscortex-round24-csd-close.png"))
            except Exception as e:
                print("csd-close shot", e)
        if close_geom(q, ser, moved):
            closed += 1
        else:
            print("close miss", i, "at", cs.ctrl_of(moved), "live", moved)
            live3 = cs.live_files_xywh(ser.path, ser.archive or "")
            if live3 is not None and close_geom(q, ser, live3):
                closed += 1
        if i == 1:
            try:
                d15.shot(q, os.path.join(
                    art, "oscortex-round24-20-lifecycles.png"))
            except Exception as e:
                print("lifecycle shot", e)
        time.sleep(0.08)
    return {
        "n": len(walls),
        "fresh_relaunches": fresh,
        "closed": closed,
        "geoms": geoms[-8:],
        "event_present_ms": {
            "n": len(walls),
            "p50": pct(walls, 0.50),
            "p95": pct(walls, 0.95),
            "max": round(max(walls), 1) if walls else None,
            "samples": [round(x, 1) for x in walls],
        },
        "guest_present_ms": {
            "n": len(presents),
            "p50": pct(presents, 0.50),
            "p95": pct(presents, 0.95),
            "max": round(max(presents), 1) if presents else None,
        },
    }


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: measure-round24.py <qmp> <serial>")
    q = d15.Qmp(int(sys.argv[1]))
    ser = open_serial(sys.argv[2])
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    os.makedirs(art, exist_ok=True)
    d15.PHASE_TIMELINES.clear()

    sit = cs.live_files_xywh(ser.path, ser.archive or "")
    if sit is not None:
        print("sitin FILES VIS", sit, "close", cs.ctrl_of(sit))
        close_geom(q, ser, sit)
        time.sleep(0.25)
    # Wallpaper-only. SET sits at (465,40,320,280); taskbar is y>=688.
    # Left-lower strip stays off FILES/SET so menu is WM WALL, not FILES CFG.
    try:
        q.key("esc")
    except Exception:
        pass
    d15.place(q, ser, 48, 520)
    time.sleep(0.15)
    ser.read()

    ptr_n = max(100, int(os.environ.get("DRIVE_PTR_N", "100")))
    menu_n = max(100, int(os.environ.get("DRIVE_MENU_N", "100")))
    pointer_pts = [(36 + (i * 13) % 120, 500 + (i * 7) % 90)
                   for i in range(ptr_n)]
    menu_pts = [(48 + (i * 11) % 100, 510 + (i * 5) % 80)
                for i in range(menu_n)]
    pointer = collect(q, ser, "pointer", pointer_pts, want_opid=True)
    menu = collect(q, ser, "menu", menu_pts, btn="right", want_opid=True)
    if pointer["n"] < 100 or menu["n"] < 100:
        raise SystemExit("latency n=0 or short pointer=%d menu=%d (need >=100)"
                         % (pointer["n"], menu["n"]))
    life = cycles(q, ser, max(20, int(os.environ.get("DRIVE_LIFE_N", "20"))))

    blob = harvest(ser)
    hits = parse_csdhits(blob)
    lives = parse_life(blob)
    shm = [r["shm"] for r in lives]
    try:
        d15.shot(q, os.path.join(art, "oscortex-round24-latency-proof.png"))
    except Exception as e:
        print("latency-proof shot", e)

    payload = {
        "round": 24,
        "same_cold_boot": True,
        "daily_drive_claim": False,
        "geom_source": "WM VIS committed generation",
        "lifecycle": life,
        "pointer": pointer,
        "menu": menu,
        "csdhit_n": len(hits),
        "csdhit_tail": hits[-8:],
        "life_tail": lives[-8:],
        "shm_pages": {
            "n": len(shm),
            "high_water": max(shm) if shm else None,
            "last": shm[-1] if shm else None,
            "reclaimed_closes": lives[-1]["closes"] if lives else None,
            "reaps": lives[-1]["reaps"] if lives else None,
        },
        "gates": {
            "fresh20": life["fresh_relaunches"] >= 20,
            "closed20": life["closed"] >= 20,
            "first_drag_p95": (life["event_present_ms"]["p95"] or 999) < 100,
            "first_drag_max": (life["event_present_ms"]["max"] or 999) < 150,
            "pointer_n100": pointer["n"] >= 100,
            "menu_n100": menu["n"] >= 100,
            "pointer_p95": (pointer["event_present_ms"]["p95"] or 999) < 75,
            "menu_p95": (menu["event_present_ms"]["p95"] or 999) < 100,
            "menu_max": (menu["event_present_ms"]["max"] or 999) < 150,
        },
    }
    open(os.path.join(art, "oscortex-round24-lifecycle.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    open(os.path.join(art, "oscortex-round24-latency.json"), "w").write(
        json.dumps({
            "round": 24,
            "first_drag": life["event_present_ms"],
            "pointer": pointer["event_present_ms"],
            "menu": menu["event_present_ms"],
            "pointer_n": pointer["n"],
            "menu_n": menu["n"],
            "gates": payload["gates"],
        }, indent=2) + "\n")
    print(json.dumps({"lifecycle": life["event_present_ms"],
                      "pointer": pointer["event_present_ms"],
                      "menu": menu["event_present_ms"],
                      "pointer_n": pointer["n"],
                      "menu_n": menu["n"],
                      "gates": payload["gates"],
                      "shm": payload["shm_pages"]}, indent=2))
    if not all(payload["gates"].values()):
        raise SystemExit("measure gates failed: %s" % payload["gates"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
