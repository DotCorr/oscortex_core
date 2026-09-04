#!/usr/bin/env python3
"""Round 23 visual stress: >=5 min AND >=100 menus AND >=100 focus.

No STRESS+60 early exit. Integrity uses committed WM VIS. Raw flags=0.
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

from artifacts import resolve_artifacts

fi_spec = importlib.util.spec_from_file_location(
    "frame_integrity", os.path.join(HERE, "frame-integrity.py"))
fi = importlib.util.module_from_spec(fi_spec)
fi_spec.loader.exec_module(fi)
inspect_png = fi.inspect_png

aa_spec = importlib.util.spec_from_file_location(
    "corner_aa", os.path.join(HERE, "corner-aa.py"))
aa = importlib.util.module_from_spec(aa_spec)
aa_spec.loader.exec_module(aa)
inspect_aa = aa.inspect_png

cs_spec = importlib.util.spec_from_file_location(
    "chip23", os.path.join(HERE, "chip-scan-round23.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)

STRESS_SECS = float(os.environ.get("DRIVE_STRESS_SECS", "300"))
MENU_FLOOR = int(os.environ.get("DRIVE_MENU_FLOOR", "100"))
FOCUS_FLOOR = int(os.environ.get("DRIVE_FOCUS_FLOOR", "100"))
BURST = int(os.environ.get("DRIVE_BURST", "2"))
SET_XYWH = (464, 40, 320, 280)
SET_TITLE = (464 + 72, 40 + 15)
SET_CARD0 = (464 + 132 + 44, 40 + 84 + 16)


def burst_shots(q, folder, tag, files_xywh, set_xywh):
    recs = []
    for i in range(BURST):
        path = os.path.join(folder, "%s-%02d.png" % (tag, i))
        d15.shot(q, path)
        use_set = set_xywh
        if files_xywh and set_xywh:
            fx, fy, fw, fh = files_xywh
            sx, sy, sw, sh = set_xywh
            if fx <= sx and fy <= sy and (fx + fw) >= (sx + sw) and (
                    fy + fh) >= (sy + sh):
                use_set = ()
        rec = inspect_png(path, files_xywh=files_xywh, set_xywh=use_set)
        aa_rec = inspect_aa(path, files_xywh=files_xywh, set_xywh=use_set)
        rec["tag"] = tag
        rec["i"] = i
        rec["aa"] = aa_rec
        if aa_rec.get("bad"):
            rec["bad"] = True
            rec["why"] = list(rec.get("why") or []) + ["corner_teeth"]
        recs.append(rec)
    return recs


def main():
    if len(sys.argv) < 4:
        raise SystemExit(
            "usage: visual-stress-round23.py <qmp> <serial> <outdir>")
    port, serial_path, outdir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    art, _warn = resolve_artifacts()
    os.makedirs(outdir, exist_ok=True)
    frames_dir = os.path.join(outdir, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    q = d15.Qmp(port)
    sock = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
    if sock <= 0:
        sib = os.path.join(os.path.dirname(serial_path), "serial.port")
        try:
            sock = int(open(sib).read().strip())
        except (OSError, ValueError):
            sock = 0
        if str(serial_path).isdigit():
            sock = int(serial_path)
            serial_path = os.environ.get(
                "DRIVE_SERIAL_FILE",
                "/workspace/core/build/daily-drive-r23/serial.txt")
    ser = d15.Serial(serial_path, sock)
    skip = os.environ.get("DRIVE_SKIP_BOOT", "0") == "1"
    if not skip:
        deadline = time.time() + 40
        while time.time() < deadline and "M1 END" not in ser.read():
            time.sleep(0.2)
        time.sleep(1.2)
        for cmd, wait in (("fb", 1.5), ("wm on", 2.5), ("wm gfx", 1.0),
                          ("wm de", 1.0), ("wm pace", 0.5), ("vtab", 0.4),
                          ("proc spawn desk.elf", 2.0)):
            q.type_line(cmd)
            time.sleep(wait)
        d15.wait_mark(ser, "DESK READY", ser.read(), 12)
        time.sleep(0.6)
        d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                  "left", "FILES CSD", timeout=8)
        d15.wait_mark(ser, "FILES READY", ser.read(), 8)
        d15.press(q, ser, d15.SET_DOCK_XY[0], d15.SET_DOCK_XY[1],
                  "left", "SET CSD", timeout=8)
        d15.wait_mark(ser, "SET READY", ser.read(), 8)
        time.sleep(0.3)

    files_xywh = cs.live_files_xywh(serial_path, ser.archive or "")
    set_xywh = cs.live_set_xywh(serial_path, ser.archive or "") or SET_XYWH
    all_recs = []
    bad = []
    menus = 0
    focuses = 0
    faults = []
    life_reaps = 0
    seq_gaps = 0

    def live():
        nonlocal files_xywh, set_xywh
        g = cs.live_files_xywh(serial_path, ser.archive or "")
        if g is not None:
            files_xywh = g
        sg = cs.live_set_xywh(serial_path, ser.archive or "")
        if sg is not None:
            set_xywh = sg
        return files_xywh

    def take(tag):
        recs = burst_shots(q, frames_dir, tag, live(), set_xywh)
        all_recs.extend(recs)
        for r in recs:
            if r["bad"]:
                bad.append(r)
        return True

    take("settle")
    d15.press(q, ser, SET_TITLE[0], SET_TITLE[1], "left", "WM DEFN", timeout=3)
    focuses += 1
    take("set-focus")
    d15.press(q, ser, SET_CARD0[0], SET_CARD0[1], "left", "SET CARD", timeout=2)
    take("set-card")

    t0 = time.time()
    n = 0
    # Meet duration AND menu/focus floors. No +60 cap.
    while True:
        elapsed = time.time() - t0
        if elapsed >= STRESS_SECS and menus >= MENU_FLOOR and focuses >= FOCUS_FLOOR:
            break
        n += 1
        geom = live()
        if geom is None:
            n0 = cs.vis_count(serial_path, ser.archive or "")
            d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                      "left", "FILES CSD", timeout=3)
            cs.wait_vis(ser, serial_path, n0=n0, timeout=4)
            geom = live()
            if geom is None:
                faults.append("files missing loop %d" % n)
                continue
        ftx, fty = cs.title_of(geom)
        d15.press(q, ser, ftx, fty, "left", "WM DEFN", timeout=2)
        focuses += 1
        d15.press(q, ser, SET_TITLE[0], SET_TITLE[1], "left", "WM DEFN",
                  timeout=2)
        focuses += 1
        try:
            d15.press(q, ser, 90, 400, "right", "WM WALL MENU", timeout=2)
            menus += 1
            q.key("esc")
        except Exception as e:
            faults.append("wall menu %s" % e)
        try:
            d15.press(q, ser, 70, 380, "right", "WM WALL MENU", timeout=2)
            menus += 1
            q.key("esc")
        except Exception as e:
            faults.append("wall menu2 %s" % e)
        d15.place(q, ser, ftx, fty)
        d15.button(q, ftx, fty, "left", True)
        for dx in (0, 8, 16, 8, 0):
            n0 = cs.vis_count(serial_path, ser.archive or "")
            d15.place(q, ser, ftx + dx, fty)
            if dx:
                cs.wait_vis(ser, serial_path, n0=n0, timeout=0.8)
        d15.button(q, ftx + 0, fty, "left", False)
        if n % 6 == 0:
            geom = live()
            if geom is not None:
                mx, my = cs.ctrl_of(geom, "max")
                try:
                    n0 = cs.vis_count(serial_path, ser.archive or "")
                    d15.press(q, ser, mx, my, "left", "WM REQ", timeout=2)
                    cs.wait_vis(ser, serial_path, n0=n0,
                                pred=lambda gg: gg[2] >= 1000, timeout=4)
                    geom = live()
                    if geom is not None and geom[2] >= 1000:
                        take("loop-max")
                        rx, ry = cs.ctrl_of(geom, "max")
                        n1 = cs.vis_count(serial_path, ser.archive or "")
                        d15.press(q, ser, rx, ry, "left", "WM REQ", timeout=2)
                        cs.wait_vis(ser, serial_path, n0=n1,
                                    pred=lambda gg: gg[2] < 1000, timeout=4)
                        geom = live()
                        if geom is not None and geom[2] >= 1000:
                            rx, ry = cs.ctrl_of(geom, "max")
                            d15.press(q, ser, rx, ry, "left", "WM REQ",
                                      timeout=2)
                            cs.wait_vis(ser, serial_path,
                                        pred=lambda gg: gg[2] < 1000,
                                        timeout=4)
                            geom = live()
                        if geom is not None and geom[2] < 1000:
                            take("loop-rest")
                except Exception as e:
                    faults.append("max/rest %s" % e)
        if n <= 3 or n % 8 == 0:
            take("loop-%d" % n)
        blob = ""
        try:
            blob = open(serial_path).read()
        except OSError:
            pass
        if "FAULT" in blob[-8000:]:
            faults.append("FAULT")
        if "OOM" in blob[-4000:]:
            faults.append("OOM")

    shots = {
        "menu": os.path.join(art, "oscortex-round23-fast-menu-focus.png"),
        "drag": os.path.join(art, "oscortex-round23-smooth-drag.png"),
    }
    d15.press(q, ser, 90, 400, "right", "WM WALL MENU", timeout=3)
    d15.shot(q, shots["menu"], os.path.join(outdir, "fast-menu-focus.png"))
    try:
        q.key("esc")
    except Exception:
        pass
    geom = live()
    ftx, fty = cs.title_of(geom or (48, 40, 320, 280))
    d15.place(q, ser, ftx, fty)
    d15.button(q, ftx, fty, "left", True)
    n0 = cs.vis_count(serial_path, ser.archive or "")
    d15.place(q, ser, ftx + 40, fty)
    cs.wait_vis(ser, serial_path, n0=n0, timeout=1.2)
    d15.shot(q, shots["drag"], os.path.join(outdir, "smooth-drag.png"))
    d15.button(q, ftx + 40, fty, "left", False)

    final_aa = inspect_aa(shots["menu"], files_xywh=files_xywh, set_xywh=set_xywh)
    final_int = inspect_png(shots["menu"], files_xywh=files_xywh,
                            set_xywh=set_xywh)
    if final_aa.get("bad"):
        bad.append(final_aa)
    if final_int.get("bad"):
        bad.append(final_int)

    q.type_line("wm dmg")
    time.sleep(0.3)

    payload = {
        "round": 23,
        "frames": len(all_recs),
        "bad": len(bad),
        "stress_secs": round(time.time() - t0, 1),
        "loops": n,
        "menus": menus,
        "focuses": focuses,
        "menu_floor": MENU_FLOOR,
        "focus_floor": FOCUS_FLOOR,
        "duration_floor": STRESS_SECS,
        "faults": faults,
        "reaps": life_reaps,
        "seq_gaps": seq_gaps,
        "files_xywh": list(files_xywh) if files_xywh else None,
        "bad_frames": bad[:12],
        "corner_aa": final_aa,
        "integrity": final_int,
        "aa_teeth": final_aa.get("teeth"),
        "geom_source": "WM VIS committed generation",
    }
    os.makedirs(art, exist_ok=True)
    open(os.path.join(art, "oscortex-round23-stress.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    open(os.path.join(art, "oscortex-round23-frame-integrity.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    open(os.path.join(outdir, "frame-integrity.json"), "w").write(
        json.dumps(payload, indent=2) + "\n")
    print(json.dumps({k: payload[k] for k in payload if k != "bad_frames"},
                     indent=2))
    if payload["stress_secs"] < STRESS_SECS:
        raise SystemExit("visual stress ended early at %.1fs" % payload["stress_secs"])
    if menus < MENU_FLOOR or focuses < FOCUS_FLOOR:
        raise SystemExit("floors missed menus=%d/%d focus=%d/%d"
                         % (menus, MENU_FLOOR, focuses, FOCUS_FLOOR))
    if payload["bad"]:
        raise SystemExit("stress integrity flags=%d" % payload["bad"])
    if faults:
        raise SystemExit("stress faults=%s" % faults[:8])
    print("visual stress PASS %.1fs frames=%d bad=0 menus=%d focus=%d"
          % (payload["stress_secs"], payload["frames"], menus, focuses))
    return 0


if __name__ == "__main__":
    sys.exit(main())
