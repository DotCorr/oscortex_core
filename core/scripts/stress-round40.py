#!/usr/bin/env python3
"""Round 40 integrity: 5 min, no CPATH 3 after DESK READY, >=1000 frames."""

import importlib.util
import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r40")
SECS = float(os.environ.get("DRIVE_STRESS_SECS", "300"))


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    t0 = time.time()
    n = 0
    # Sixteen ordinary FILES plus DESK. Sit-in already has one FILES.
    for _i in range(15):
        d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
        d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", True)
        time.sleep(0.03)
        d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                   "left", False)
        time.sleep(0.12)
    # Dock extras that still fit (SET is single-instance).
    for i in range(6):
        x = (d15.RIGHT_X + d15.ICON_PAD + i * (d15.ICON_S + d15.ICON_GAP)
             + d15.ICON_S // 2)
        d15.place(q, ser, x, d15.PANEL_Y)
        d15.button(q, x, d15.PANEL_Y, "left", True)
        time.sleep(0.03)
        d15.button(q, x, d15.PANEL_Y, "left", False)
        time.sleep(0.12)
    # 100 close/reopen cycles use live VIS + ctrl_of (prove-round40).
    import importlib.util as _ilu
    _ps = _ilu.spec_from_file_location("p40", os.path.join(HERE, "prove-round40.py"))
    p40 = _ilu.module_from_spec(_ps)
    # avoid running main
    p40_path = os.path.join(HERE, "prove-round40.py")
    cs = _ilu.spec_from_file_location("cs24", os.path.join(HERE, "chip-scan-round24.py"))
    cs24 = _ilu.module_from_spec(cs)
    cs.loader.exec_module(cs24)
    p39s = _ilu.spec_from_file_location("p39", os.path.join(HERE, "prove-round39.py"))
    p39 = _ilu.module_from_spec(p39s)
    p39s.loader.exec_module(p39)
    p39.RUN = RUN
    for i in range(100):
        info = p39.live_from(p39.harvest(ser))
        files = [w for w in info["ordinary_slots"]
                 if info["windows"].get(w, {}).get("cap") == 1]
        if files:
            g = info["windows"][files[-1]]
            cx, cy = cs24.ctrl_of((g["x"], g["y"], g["ww"], g["hh"]), "close")
            d15.place(q, ser, cx, cy)
            d15.button(q, cx, cy, "left", True)
            time.sleep(0.02)
            d15.button(q, cx, cy, "left", False)
            time.sleep(0.06)
        d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
        d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                   "left", True)
        time.sleep(0.02)
        d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                   "left", False)
        time.sleep(0.06)
    while time.time() - t0 < SECS:
        d15.place(q, ser, 90 + (n * 19) % 360, 70 + (n * 7) % 40)
        if n % 4 == 0:
            d15.button(q, 90 + (n * 19) % 360, 70, "left", True)
            d15.place(q, ser, 140 + (n * 11) % 200, 70)
            d15.button(q, 140 + (n * 11) % 200, 70, "left", False)
        if n % 6 == 0:
            d15.button(q, 120, 180, "left", True)
            d15.button(q, 120, 180, "left", False)
        if n % 9 == 0:
            d15.button(q, 48, 520, "right", True)
            d15.button(q, 48, 520, "right", False)
            try:
                q.key("esc")
            except Exception:
                pass
        if n % 20 == 0:
            try:
                q.key("f4")
                time.sleep(0.05)
                q.key("esc")
            except Exception:
                pass
        n += 1
        time.sleep(0.05)
    blob = open(os.path.join(RUN, "serial.txt"), encoding="latin-1",
                errors="replace").read()
    after = blob.split("DESK READY", 1)[-1] if "DESK READY" in blob else blob
    reasons = []
    for line in after.splitlines():
        if line.startswith("WM CPATH 3"):
            reasons.append(line)
    out = {
        "round": 39,
        "secs": round(time.time() - t0, 1),
        "cycles": n,
        "fault": ("FAULT 0E" in blob) or ("FAULT 0D" in blob)
                 or ("FAULT 06" in blob),
        "reap": blob.count("WM REAP W "),
        "oom": ("DESK READY" in blob) and (
            "OSGFX OOM" in after),
        "qtimeout": "VIRTIO QTIMEOUT" in blob,
        "abort": "OSGFX ABORT" in blob,
        "tap_die": "TAP DIE " in blob,
        "attach_refuse": "WM RET " in blob or "FILE REFUSED" in blob and blob.count("FILE REFUSED") > 200,
        "close_reopen": 100,
        "cpath_compose": after.count("WM CPATH 3"),
        "cpath3_reasons": reasons[-12:],
        "done_n": after.count("WM DONE "),
        "frames": after.count("WM FRAME N "),
        "closes": after.count("WM CLOSE W "),
        "pref_ack": "WM PREF ACK" in blob,
        "mkdir": "FILES MKDIR" in blob,
        "focus_g": "WM FOCUS G" in blob,
    }
    try:
        import importlib.util
        ts = importlib.util.spec_from_file_location(
            "vis39", os.path.join(HERE, "vis-tokens.py"))
        tmod = importlib.util.module_from_spec(ts)
        ts.loader.exec_module(tmod)
        _ok, rejected = tmod.harvest_vis(after)
        out["token_rejected"] = rejected
        out["token_parse_error"] = (
            rejected.get("malformed", 0) + rejected.get("checksum", 0)
            + rejected.get("interleaved", 0))
    except Exception as e:
        out["token_parse_error"] = -1
        out["token_err"] = str(e)
    dest = os.path.join(ART, "oscortex-round40-integrity.json")
    open(dest, "w").write(json.dumps(out, indent=2) + "\n")
    open(os.path.join(ART, "oscortex-round40-cpath.json"), "w").write(
        json.dumps({
            "round": 39,
            "source": "stress",
            "cpath3": out["cpath_compose"],
            "reasons": reasons,
            "legitimate": "first DESK chrome is WM BOOT FULL, not CPATH 3",
        }, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    if out["fault"] or out["oom"] or out["abort"] or out["reap"] >= 3:
        raise SystemExit("stress: faults")
    if out["tap_die"]:
        raise SystemExit("stress: TAP DIE")
    if out["qtimeout"]:
        raise SystemExit("stress: QTIMEOUT")
    if out["cpath_compose"]:
        raise SystemExit("stress: CPATH 3 during interaction")
    if out.get("token_parse_error", 0) not in (0,):
        raise SystemExit("stress: token parse error")
    if out["frames"] < 1000 and SECS >= 300:
        raise SystemExit("stress: fewer than 1000 transition frames")
    print("stress: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
