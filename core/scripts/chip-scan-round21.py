#!/usr/bin/env python3
"""High-rate QMP dumps after drag/menu. Zero vacated chips across >=1000 frames."""

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

fi_spec = importlib.util.spec_from_file_location(
    "frame_integrity", os.path.join(HERE, "frame-integrity.py"))
fi = importlib.util.module_from_spec(fi_spec)
fi_spec.loader.exec_module(fi)

aa_spec = importlib.util.spec_from_file_location(
    "corner_aa", os.path.join(HERE, "corner-aa.py"))
aa = importlib.util.module_from_spec(aa_spec)
aa_spec.loader.exec_module(aa)

FILES_TITLE = (120, 55)
SET_TITLE = (624, 55)
FILES_XYWH = (48, 40, 400, 280)
SET_XYWH = (464, 40, 320, 280)
WANT = int(os.environ.get("DRIVE_CHIP_FRAMES", "1000"))


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: chip-scan-round21.py <qmp> <serial> <framedir>")
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

    def dump(tag, files_xywh=None):
        nonlocal n
        n += 1
        if files_xywh is None:
            files_xywh = FILES_XYWH
        path = os.path.join(framedir, "c%05d.png" % n)
        d15.shot(q, path)
        rec = fi.inspect_png(path, files_xywh=files_xywh, set_xywh=SET_XYWH)
        aa_rec = aa.inspect_png(path, files_xywh=files_xywh, set_xywh=SET_XYWH)
        rec["tag"] = tag
        rec["aa"] = aa_rec
        rec["files_xywh"] = list(files_xywh)
        # Vacated wallpaper in a live body is a chip. AA at the live
        # origin is a corner tooth. Stale sit-in AABBs are not chips.
        if rec.get("bad") or aa_rec.get("bad"):
            rec["chip"] = True
            bad.append(rec)
        return rec

    # Long drag + menu session, dump every transition step.
    # Inspect the live FILES origin so a vacated strip is not scored
    # against the sit-in AABB after the card has moved.
    win_dx = 0
    while n < WANT:
        d15.place(q, ser, FILES_TITLE[0] + win_dx, FILES_TITLE[1])
        d15.button(q, FILES_TITLE[0] + win_dx, FILES_TITLE[1], "left", True)
        for dx in (0, 16, 32, 48, 64, 80, 64, 48, 32, 16, 0):
            d15.place(q, ser, FILES_TITLE[0] + win_dx + dx, FILES_TITLE[1])
            cur = (FILES_XYWH[0] + win_dx + dx, FILES_XYWH[1],
                   FILES_XYWH[2], FILES_XYWH[3])
            dump("drag-%d" % (win_dx + dx), files_xywh=cur)
            if n >= WANT:
                break
        d15.button(q, FILES_TITLE[0] + win_dx, FILES_TITLE[1], "left", False)
        win_dx = 0
        if n >= WANT:
            break
        try:
            d15.press(q, ser, 200, 180, "right", "WM WIN MENU", timeout=2)
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
        d15.press(q, ser, SET_TITLE[0], SET_TITLE[1], "left", "WM DEFN",
                  timeout=2)
        dump("focus-set")
        d15.press(q, ser, FILES_TITLE[0], FILES_TITLE[1], "left", "WM DEFN",
                  timeout=2)
        dump("focus-files")

    proof = os.path.join(art, "oscortex-round21-no-chips.png")
    d15.shot(q, proof)
    payload = {
        "round": 21,
        "frames": n,
        "chips": len(bad),
        "seconds": round(time.time() - t0, 1),
        "bad": bad[:16],
        "proof": proof,
    }
    out = os.path.join(art, "oscortex-round21-chips.json")
    open(out, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps({k: payload[k] for k in payload if k != "bad"}, indent=2))
    if n < WANT:
        raise SystemExit("chip scan short: %d/%d" % (n, WANT))
    if bad:
        raise SystemExit("chips=%d of %d frames" % (len(bad), n))
    print("chip-scan PASS frames=%d chips=0" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
