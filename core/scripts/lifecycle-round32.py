#!/usr/bin/env python3
"""Round 32: >=50 FILES close/reopen cycles. Fail on black body or CPATH 3.

Each cycle interacts (body, drag, menu; max/restore every 5th) then
closes and reopens in the reused slot.
"""

import importlib.util
import json
import os
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "m31", os.path.join(HERE, "measure-round31.py"))
m31 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m31)
d15 = m31.d15
cs = m31.cs

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r32")
N = int(os.environ.get("DRIVE_LIFE_N", "50"))
QMP = int(open(os.path.join(RUN, "qmp.port")).read())


def _px(im, x, y):
    return im.getpixel((min(1279, max(0, x)), min(719, max(0, y))))


def body_is_hole(path, geom):
    """Black OR wallpaper-through-body (vacated card)."""
    im = Image.open(path).convert("RGB")
    x, y, w, h = geom
    desk = _px(im, 16, 200)
    samples = [
        _px(im, x + w // 2, y + 80),
        _px(im, x + 48, y + 100),
        _px(im, x + w - 48, y + 120),
        _px(im, x + w // 2, y + h // 2),
    ]
    holes = 0
    rgb = samples[0]
    for r, g, b in samples:
        if (r + g + b) < 48:
            holes += 1
            continue
        if (abs(r - desk[0]) + abs(g - desk[1]) + abs(b - desk[2])) < 36:
            holes += 1
    return holes >= 3, rgb, desk, holes


def click(q, x, y):
    d15.button(q, x, y, "left", True)
    d15.button(q, x, y, "left", False)


def interact(q, ser, geom, i):
    """Body / drag / menu; max+restore on every 5th cycle."""
    bx = geom[0] + 40
    by = geom[1] + 80
    d15.place(q, ser, bx, by)
    click(q, bx, by)
    tx, ty = cs.title_of(geom)
    d15.place(q, ser, tx, ty)
    d15.button(q, tx, ty, "left", True)
    d15.place(q, ser, tx + 10, ty)
    d15.button(q, tx + 10, ty, "left", False)
    time.sleep(0.04)
    d15.place(q, ser, 48, 520)
    d15.button(q, 48, 520, "right", True)
    d15.button(q, 48, 520, "right", False)
    time.sleep(0.05)
    try:
        q.key("esc")
    except Exception:
        pass
    if (i % 5) != 0:
        return
    mx, my = cs.ctrl_of(geom, "max")
    d15.place(q, ser, mx, my)
    click(q, mx, my)
    t0 = time.time()
    while time.time() - t0 < 2.0:
        g2 = m31.files_geom(ser)
        if g2[2] > 800:
            break
        time.sleep(0.04)
    g2 = m31.files_geom(ser)
    rx, ry = cs.ctrl_of(g2, "max")
    d15.place(q, ser, rx, ry)
    click(q, rx, ry)
    t1 = time.time()
    while time.time() - t1 < 2.0:
        g3 = m31.files_geom(ser)
        if g3[2] < 600:
            break
        time.sleep(0.04)


def main():
    os.makedirs(ART, exist_ok=True)
    q = d15.Qmp(QMP)
    ser = m31.m24.open_serial(os.path.join(RUN, "serial.txt"))
    holes = 0
    cycles = []
    t0 = time.time()
    for i in range(N):
        geom = m31.files_geom(ser)
        interact(q, ser, geom, i)
        geom = m31.files_geom(ser)
        cx, cy = cs.ctrl_of(geom, "close")
        d15.place(q, ser, cx, cy)
        click(q, cx, cy)
        t1 = time.time()
        gone = False
        while time.time() - t1 < 2.5:
            if cs.files_slot(m31.harvest(ser)) is None:
                gone = True
                break
            time.sleep(0.03)
        blob0 = m31.harvest(ser)
        n_ready = blob0.count("USER WRITE FILES READY")
        n_csd = blob0.count("USER WRITE FILES CSD")
        n_attach = blob0.count("WM ATTACH W ")
        d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
        click(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
        t2 = time.time()
        ready = False
        while time.time() - t2 < 4.0:
            blob = m31.harvest(ser)
            if blob.count("WM ATTACH W ") <= n_attach:
                time.sleep(0.04)
                continue
            if blob.count("USER WRITE FILES READY") > n_ready:
                ready = True
                break
            if blob.count("USER WRITE FILES CSD") > n_csd:
                # CSD is first commit; wait the READY that follows.
                if blob.count("USER WRITE FILES READY") > n_ready:
                    ready = True
                    break
            time.sleep(0.04)
        # One full body COMMIT after READY so the list is on scanout.
        t3 = time.time()
        while time.time() - t3 < 1.2:
            blob = m31.harvest(ser)
            if blob.count("USER WRITE FILES READY") > n_ready:
                if "WM COMMIT W " in blob[max(0, len(blob) - 2500):]:
                    break
            time.sleep(0.04)
        time.sleep(0.15)
        geom = m31.files_geom(ser)
        shot = os.path.join("/tmp", "r32-life-%03d.png" % i)
        d15.shot(q, shot)
        black, rgb, desk, nmatch = body_is_hole(shot, geom)
        if black:
            holes += 1
        cycles.append({
            "i": i, "gone": gone, "ready": ready, "black": black,
            "rgb": list(rgb), "desk": list(desk), "nmatch": nmatch,
            "geom": list(geom),
        })
        print("life", i, "gone", gone, "ready", ready, "hole", black,
              "rgb", rgb, "desk", desk, "nmatch", nmatch, "geom", geom)
        if i == N - 1:
            d15.shot(q, os.path.join(ART, "oscortex-round32-reopen-clean.png"))
    blob = open(os.path.join(RUN, "serial.txt"), encoding="latin-1",
                errors="replace").read()
    after = blob.split("DESK READY", 1)[-1] if "DESK READY" in blob else blob
    reasons = [ln for ln in after.splitlines() if ln.startswith("WM CPATH 3")]
    cpath3 = len(reasons)
    frames = after.count("WM FRAME N ")
    out = {
        "round": 32,
        "n": N,
        "seconds": round(time.time() - t0, 3),
        "holes": holes,
        "cpath3": cpath3,
        "cpath3_reasons": reasons[-12:],
        "frames": frames,
        "closes": after.count("WM CLOSE W "),
        "cycles": cycles[-8:],
        "gates": {
            "n": N >= 50,
            "zero_holes": holes == 0,
            "zero_cpath3": cpath3 == 0,
            "frames": frames >= 50,
        },
    }
    dest = os.path.join(ART, "oscortex-round32-lifecycle.json")
    open(dest, "w").write(json.dumps(out, indent=2) + "\n")
    cpath_dest = os.path.join(ART, "oscortex-round32-cpath.json")
    open(cpath_dest, "w").write(json.dumps({
        "round": 32,
        "source": "lifecycle",
        "cpath3": cpath3,
        "reasons": reasons,
        "legitimate": "boot/mode switch only (HAVE=0, why=1)",
    }, indent=2) + "\n")
    print(json.dumps({k: out[k] for k in out if k != "cycles"}, indent=2))
    print("wrote", dest)
    if holes or cpath3:
        raise SystemExit("lifecycle: holes=%d cpath3=%d" % (holes, cpath3))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
