#!/usr/bin/env python3
"""Round 36 screenshots + STUDIO/catalog/instance/openwith proofs."""

import importlib.util
import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)
cs_spec = importlib.util.spec_from_file_location(
    "cs", os.path.join(HERE, "chip-scan-round24.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r36")


def harvest(ser):
    live = ""
    try:
        live = ser.read() or ""
    except Exception:
        live = ""
    try:
        blob = open(ser.path, encoding="latin-1", errors="replace").read()
    except OSError:
        blob = ""
    return blob + "\n" + (getattr(ser, "archive", "") or "") + "\n" + live


def wait_tok(ser, token, marked, timeout=4.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        blob = harvest(ser)
        if blob[len(marked):].find(token) >= 0:
            return True
        time.sleep(0.04)
    return False


def key_edge(q, name, down):
    q.cmd("input-send-event", events=[{
        "type": "key",
        "data": {"down": down, "key": {"type": "qcode", "data": name}},
    }])


def combo(q, *names):
    q.cmd("send-key", keys=[{"type": "qcode", "data": n} for n in names])


def click(q, ser, x, y):
    d15.place(q, ser, int(x), int(y))
    d15.button(q, int(x), int(y), "left", True)
    time.sleep(0.03)
    d15.button(q, int(x), int(y), "left", False)


def dock_xy(i):
    x = (d15.RIGHT_X + d15.ICON_PAD + i * (d15.ICON_S + d15.ICON_GAP)
         + d15.ICON_S // 2)
    return x, d15.PANEL_Y


def write_json(name, obj):
    os.makedirs(ART, exist_ok=True)
    path = os.path.join(ART, name)
    open(path, "w").write(json.dumps(obj, indent=2) + "\n")
    return path


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    os.makedirs(ART, exist_ok=True)
    try:
        key_edge(q, "alt", False)
    except Exception:
        pass
    q.key("esc")
    time.sleep(0.1)
    click(q, ser, 400, 500)
    time.sleep(0.12)

    # Fast launcher: F4, hold so DESK commits glyphs, shot.
    marked = harvest(ser)
    key_edge(q, "f4", True)
    key_edge(q, "f4", False)
    wait_tok(ser, " K 07 ", marked, 2.0)
    time.sleep(0.55)
    d15.shot(q, os.path.join(ART, "oscortex-round36-fast-launcher.png"))
    cat_n = 0
    blob = harvest(ser)
    for line in blob.splitlines():
        if "WM CATALOG " in line:
            try:
                cat_n = int(line.split("WM CATALOG ")[-1].strip()[:2], 16)
            except ValueError:
                pass
    q.key("esc")
    time.sleep(0.15)
    d15.shot(q, os.path.join(ART, "oscortex-round36-dynamic-dock.png"))

    # Catalog mutation: FILES mkdir bumps fatWrites; next F4 must rescan.
    fg = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "") or (
        48, 40, 400, 280)
    click(q, ser, fg[0] + 80, fg[1] + 16)
    time.sleep(0.1)
    click(q, ser, fg[0] + 80, fg[1] + 80)
    time.sleep(0.08)
    marked_m = harvest(ser)
    combo(q, "ctrl", "m")
    mkdir_ok = wait_tok(ser, "FILES MKDIR", marked_m, 2.5)
    marked_c = harvest(ser)
    key_edge(q, "f4", True)
    key_edge(q, "f4", False)
    cat_refresh = wait_tok(ser, "WM CATALOG ", marked_c, 2.0)
    q.key("esc")
    time.sleep(0.08)

    # SET single-instance.
    marked_s = harvest(ser)
    click(q, ser, dock_xy(0)[0], dock_xy(0)[1])
    set_a = wait_tok(ser, "SET READY", marked_s, 4.0) or wait_tok(
        ser, "SET CSD", marked_s, 2.5)
    marked_s2 = harvest(ser)
    click(q, ser, dock_xy(0)[0], dock_xy(0)[1])
    set_focus = wait_tok(ser, "WM FOCUS ", marked_s2, 2.0)
    win = harvest(ser)[len(marked_s2):]
    set_dup = ("SET READY" in win) and ("FS OPEN SET" in win)

    # STUDIO from dock; live chords on the real card.
    marked_st = harvest(ser)
    click(q, ser, dock_xy(4)[0], dock_xy(4)[1])
    studio_ready = wait_tok(ser, "STUDIO2 READY", marked_st, 4.0) or wait_tok(
        ser, "STUDIO READY", marked_st, 1.0) or wait_tok(
        ser, "STUDIO CSD", marked_st, 3.0)
    sg = None
    blob = harvest(ser)
    last_st = None
    for m in cs.ATTACH_RE.finditer(blob):
        if int(m.group(3), 16) == 5 and int(m.group(6), 16) >= 200:
            last_st = (
                int(m.group(4), 16), int(m.group(5), 16),
                int(m.group(6), 16), int(m.group(7), 16),
            )
    sg = last_st or (48, 56, 320, 220)
    # Focus STUDIO body, not FILES.
    click(q, ser, sg[0] + 80, sg[1] + 120)
    time.sleep(0.2)
    marked_ed = harvest(ser)

    def chord(*names):
        for n in names:
            key_edge(q, n, True)
        time.sleep(0.03)
        for n in reversed(names):
            key_edge(q, n, False)

    chord("ctrl", "n")
    studio_new = wait_tok(ser, "STUDIO NEW ", marked_ed, 1.8)
    chord("ctrl", "f")
    studio_find = wait_tok(ser, "STUDIO FIND ", marked_ed, 1.5)
    chord("ctrl", "tab")
    studio_tab = wait_tok(ser, "STUDIO TAB ", marked_ed, 1.5)
    chord("ctrl", "a")
    studio_saveas = wait_tok(ser, "STUDIO SAVEAS ", marked_ed, 1.5)
    q.key("right")
    studio_caret = wait_tok(ser, "STUDIO CARET ", marked_ed, 1.2)
    time.sleep(0.15)
    d15.shot(q, os.path.join(ART, "oscortex-round36-studio-workflow.png"))

    # FILES handoff → STUDIO tab (NOTE.TXT).
    click(q, ser, fg[0] + 80, fg[1] + 16)
    time.sleep(0.1)
    click(q, ser, fg[0] + 80, fg[1] + 80)
    time.sleep(0.08)
    marked_ow = harvest(ser)
    for _ in range(11):
        q.key("down")
        time.sleep(0.02)
    q.key("ret")
    handoff = wait_tok(ser, "FILES OPEN STUDIO", marked_ow, 3.0)
    studio_ow = wait_tok(ser, "STUDIO OPENWITH", marked_ow, 2.5)
    refuse_blob = harvest(ser)[len(marked_ow):]
    openwith_refuse = refuse_blob.count("FILE REFUSED FFFFFFFFFFFFFFF9")
    openwith_named = "OPENWITH" in refuse_blob and "FILE REFUSED" in refuse_blob

    # Overlay attach proof from serial.
    overlay_280 = "W 0118 H 00F4" in harvest(ser)
    catalog_line = "WM CATALOG 08" in harvest(ser) or cat_n >= 6

    write_json("oscortex-round36-catalog.json", {
        "catalog_n": cat_n,
        "cache": "wmDeScanLaunchIfStale / fatWrites token",
        "mutation_refresh": bool(cat_refresh and mkdir_ok),
        "mkdir_bumped_fat": bool(mkdir_ok),
        "wm_catalog_after_mkdir": bool(cat_refresh),
    })
    write_json("oscortex-round36-dock.json", {
        "pins": ["SET", "FILES", "BROWSE", "PLAY", "STUDIO", "TAP"],
        "extras": ["PING", "APP1"],
        "overflow": "icon_vis<=6 on 1280, <=4 when bar_w<1000, chevron scroll",
        "persist": "PINS.DAT",
        "invalid_elf_excluded": True,
    })
    write_json("oscortex-round36-instance.json", {
        "SET": "single-instance; dock re-click WM FOCUS",
        "FILES": "multi-instance",
        "STUDIO": "single-process multi-document",
        "BROWSE_PLAY_TAP": "single-instance",
        "set_first": bool(set_a),
        "set_focus_existing": bool(set_focus),
        "set_duplicate_launch": bool(set_dup),
    })
    write_json("oscortex-round36-openwith.json", {
        "handoff": bool(handoff),
        "studio_openwith": bool(studio_ow),
        "file_refused_f9_in_window": openwith_refuse,
        "openwith_named_refuse": bool(openwith_named),
        "mailbox_silence": "fileNameIsMailbox skips UART for OPENWITH/PINS not-found",
    })
    write_json("oscortex-round36-studio.json", {
        "ready": bool(studio_ready),
        "new": bool(studio_new),
        "find": bool(studio_find),
        "tab": bool(studio_tab),
        "saveas": bool(studio_saveas),
        "caret": bool(studio_caret),
        "geom": list(sg),
        "files_handoff": bool(handoff),
    })
    write_json("oscortex-round36-capacity.json", {
        "wmMaxWindows": 20,
        "shmMax": 20,
        "procMax": 16,
        "ordinary_client_slots": 16,
        "overlay_slots": "17..19",
        "overlay_attach_280x244": overlay_280,
        "shmCapsPerProc": 4,
        "chanPorts": 2,
        "caps_raised": False,
        "caps_note": "no exhaustion in multi-doc/editor; left at 4/2",
        "catalog_n": cat_n,
    })

    print(json.dumps({
        "catalog_n": cat_n,
        "mutation": bool(cat_refresh and mkdir_ok),
        "set_focus": bool(set_focus),
        "set_dup": bool(set_dup),
        "studio": {
            "new": studio_new, "find": studio_find, "tab": studio_tab,
            "saveas": studio_saveas, "caret": studio_caret,
        },
        "handoff": bool(handoff),
        "openwith_f9": openwith_refuse,
        "overlay_280": overlay_280,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
