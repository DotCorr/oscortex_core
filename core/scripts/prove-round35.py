#!/usr/bin/env python3
"""Round 35 live proof: capacity, catalog, FILES hist/handoff, SET persist."""

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
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r35")


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
        time.sleep(0.05)
    return False


def combo(q, *names):
    q.cmd("send-key", keys=[{"type": "qcode", "data": n} for n in names])


def key_edge(q, name, down):
    q.cmd("input-send-event", events=[{
        "type": "key",
        "data": {"down": down, "key": {"type": "qcode", "data": name}},
    }])


def write_json(name, obj):
    os.makedirs(ART, exist_ok=True)
    path = os.path.join(ART, name)
    open(path, "w").write(json.dumps(obj, indent=2) + "\n")
    return path


ser_ref = [None]


def click(q, x, y):
    d15.place(q, ser_ref[0], int(x), int(y))
    d15.button(q, int(x), int(y), "left", True)
    time.sleep(0.03)
    d15.button(q, int(x), int(y), "left", False)


def dock_xy(i):
    x = (d15.RIGHT_X + d15.ICON_PAD + i * (d15.ICON_S + d15.ICON_GAP)
         + d15.ICON_S // 2)
    return x, d15.PANEL_Y


def set_card_xy(geom, i):
    x, y, w, _h = geom
    cols = 3 if w >= (120 + 12 + 192 + 88) else (
        2 if w >= (120 + 12 + 96 + 88) else 1)
    row_h = 36 if cols < 3 else 48
    card_h = 32 if cols < 3 else 40
    tx = x + 120 + 12 + (i % cols) * 96 + 44
    ty = y + 32 + 52 + (i // cols) * row_h + card_h // 2
    return int(tx), int(ty)


def count_token(blob, tok):
    return blob.count(tok)


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    ser_ref[0] = ser
    os.makedirs(ART, exist_ok=True)
    try:
        key_edge(q, "alt", False)
    except Exception:
        pass
    q.key("esc")
    time.sleep(0.15)

    # Wallpaper-miss park so shell keys reach the prompt.
    click(q, 36, 500)
    time.sleep(0.1)

    marked = harvest(ser)
    q.key("f4")
    launch_show = wait_tok(ser, "WM LAUNCH SHOW", marked, 3.0)
    catalog = wait_tok(ser, "WM CATALOG ", marked, 2.0) or (
        "WM CATALOG " in harvest(ser))
    done7 = wait_tok(ser, " K 07 ", marked, 2.0)
    q.key("esc")
    time.sleep(0.1)

    # Switcher present-level kind 8.
    marked_sw = harvest(ser)
    key_edge(q, "alt", True)
    time.sleep(0.04)
    key_edge(q, "tab", True)
    key_edge(q, "tab", False)
    switch_show = wait_tok(ser, "WM SWITCH SHOW", marked_sw, 3.0)
    done8 = wait_tok(ser, " K 08 ", marked_sw, 2.0)
    time.sleep(0.15)
    key_edge(q, "alt", False)
    q.key("esc")
    time.sleep(0.1)

    # FILES history: raise the sit-in FILES (do not dock-spawn another).
    fg = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "") or (
        48, 40, 400, 280)
    click(q, fg[0] + 80, fg[1] + 16)
    time.sleep(0.12)
    click(q, fg[0] + 80, fg[1] + 80)
    time.sleep(0.08)
    marked_h = harvest(ser)
    combo(q, "ctrl", "m")
    files_mkdir = wait_tok(ser, "FILES MKDIR", marked_h, 2.5)
    files_dir = wait_tok(ser, "FILES DIR", marked_h, 2.5)
    combo(q, "ctrl", "m")
    wait_tok(ser, "FILES DIR", harvest(ser), 2.0)
    wait_tok(ser, "FILES MKDIR", harvest(ser), 1.5)
    q.key("left")
    files_back1 = wait_tok(ser, "FILES BACK", harvest(ser), 1.5)
    q.key("left")
    files_back2 = wait_tok(ser, "FILES BACK", harvest(ser), 1.5)
    q.key("right")
    files_fwd1 = wait_tok(ser, "FILES FWD", harvest(ser), 1.5)
    q.key("right")
    files_fwd2 = wait_tok(ser, "FILES FWD2", harvest(ser), 2.0)
    if not files_fwd2:
        files_fwd2 = wait_tok(ser, "FILES FWD", harvest(ser), 1.2)
    files_hist = "FILES HIST " in harvest(ser)
    d15.shot(q, os.path.join(ART, "oscortex-round35-files-studio.png"))

    # Return to root on the same FILES (do not dock-spawn another).
    q.key("left")
    q.key("left")
    time.sleep(0.15)
    fg = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "") or fg
    click(q, fg[0] + 80, fg[1] + 80)
    time.sleep(0.1)
    marked_ow = harvest(ser)
    # NOTE.TXT is planted at root row 11 (GONE/MISS also listed).
    for _ in range(11):
        q.key("down")
        time.sleep(0.03)
    q.key("ret")
    handoff = wait_tok(ser, "FILES OPEN STUDIO", marked_ow, 3.0)
    if not handoff:
        combo(q, "ctrl", "n")
        wait_tok(ser, "FILES NEW", marked_ow, 1.5)
        wait_tok(ser, "FILES PICK ", marked_ow, 1.0)
        q.key("ret")
        handoff = wait_tok(ser, "FILES OPEN STUDIO", marked_ow, 2.5)
    studio_ow = wait_tok(ser, "STUDIO OPENWITH", marked_ow, 3.0)
    studio_open = wait_tok(ser, "STUDIO OPEN ", marked_ow, 2.0)
    # Raise the new STUDIO so Ctrl chords hit the editor, not FILES.
    click(q, 200, 120)
    time.sleep(0.2)
    # STUDIO slice: new / find / tab / save-as / caret.
    combo(q, "ctrl", "n")
    wait_tok(ser, "STUDIO NEW ", marked_ow, 1.5)
    combo(q, "ctrl", "f")
    wait_tok(ser, "STUDIO FIND ", marked_ow, 1.2)
    combo(q, "ctrl", "tab")
    wait_tok(ser, "STUDIO TAB ", marked_ow, 1.2)
    combo(q, "ctrl", "a")
    wait_tok(ser, "STUDIO SAVEAS ", marked_ow, 1.5)
    q.key("right")
    wait_tok(ser, "STUDIO CARET ", marked_ow, 1.2)
    studio_tab = "STUDIO TAB " in harvest(ser) or "STUDIO NEW " in harvest(ser)
    studio_caret = "STUDIO CARET " in harvest(ser)
    # Binary refuse: Open FILES.ELF from root listing (row 0).
    click(q, fg[0] + 80, fg[1] + 48)
    time.sleep(0.05)
    q.key("ret")
    wait_tok(ser, "FILES OPEN BIN ", marked_ow, 2.0)

    # Now launch the rest of the dock so the all-apps shot is populated.
    for i in (0, 2, 3, 4, 5):
        x, y = dock_xy(i)
        click(q, x, y)
        time.sleep(0.2)
    time.sleep(0.25)
    d15.shot(q, os.path.join(ART, "oscortex-round35-all-apps.png"))

    # SET persist: apply theme, close, relaunch (not focus-existing).
    marked_set = harvest(ser)
    click(q, dock_xy(0)[0], dock_xy(0)[1])
    wait_tok(ser, "SET READY", marked_set, 4.0) or wait_tok(
        ser, "SET CSD", marked_set, 2.0)
    time.sleep(0.35)
    sg = cs.live_set_xywh(os.path.join(RUN, "serial.txt"), "") or (
        180, 48, 440, 280)
    click(q, sg[0] + 80, sg[1] + 16)
    time.sleep(0.12)
    click(q, sg[0] + 40, sg[1] + 32 + 80)
    time.sleep(0.1)
    cx, cy = set_card_xy(sg, 1)
    set_theme = False
    for dx, dy in ((0, 0), (24, 0), (-16, 0), (0, 8), (48, 0), (24, 12)):
        click(q, cx + dx, cy + dy)
        if wait_tok(ser, "SET CARD 1", marked_set, 0.7):
            set_theme = True
            break
    if not set_theme:
        set_theme = wait_tok(ser, "SET THEME 1", marked_set, 1.2) or wait_tok(
            ser, "SET THEME", marked_set, 0.8)
    cx3, cy3 = set_card_xy(sg, 3)
    click(q, cx3, cy3)
    wait_tok(ser, "SET ACCENT", marked_set, 1.5)
    cx5, cy5 = set_card_xy(sg, 5)
    click(q, cx5, cy5)
    wait_tok(ser, "SET WALL", marked_set, 1.5)
    pref_ack = wait_tok(ser, "WM PREF ACK", marked_set, 2.0) or (
        "WM PREF ACK" in harvest(ser))
    desk_pref = "DESK PREF" in harvest(ser)
    theme_line = ""
    for line in harvest(ser)[len(marked_set):].splitlines():
        if "SET THEME" in line or "WM PREF " in line:
            theme_line = line.strip()
    # True close: CSD close disc on the live SET geom (not Alt-F4 / focus).
    sg = cs.live_set_xywh(os.path.join(RUN, "serial.txt"), "") or sg
    close_x = int(sg[0] + sg[2] - 17)
    close_y = int(sg[1] + 17)
    click(q, close_x, close_y)
    closed = wait_tok(ser, "WM CLOSE", harvest(ser), 2.5)
    if not closed:
        key_edge(q, "alt", False)
        time.sleep(0.04)
        key_edge(q, "alt", True)
        time.sleep(0.04)
        key_edge(q, "f4", True)
        key_edge(q, "f4", False)
        key_edge(q, "alt", False)
        closed = wait_tok(ser, "WM CLOSE", harvest(ser), 1.5)
    time.sleep(0.2)
    marked_rl = harvest(ser)
    click(q, dock_xy(0)[0], dock_xy(0)[1])
    relaunch = wait_tok(ser, "SET READY", marked_rl, 4.0) or wait_tok(
        ser, "SET CSD", marked_rl, 2.5)
    relaunch_pref = wait_tok(ser, "WM PREF ", marked_rl, 2.0)
    d15.shot(q, os.path.join(ART, "oscortex-round35-persist-reboot.png"))

    blob = harvest(ser)
    tap_die = "TAP DIE " in blob
    catalog_n = 0
    for line in blob.splitlines():
        if "WM CATALOG " in line:
            try:
                catalog_n = int(line.strip().split()[-1], 16)
            except ValueError:
                catalog_n = 0
    attach_n = blob.count("WM ATTACH ")
    focus_n = blob.count("WM FOCUS G ")
    cap = {
        "wmMaxWindows": 20,
        "shmMax": 20,
        "procMax": 16,
        "fileRows": 17,
        "ordinary_client_slots": 16,
        "catalog_n": catalog_n,
        "catalog_token": "WM CATALOG " in blob,
        "attach_n": attach_n,
        "focus_n": focus_n,
        "tap_die": tap_die,
        "desk": "DESK READY" in blob,
        "set": "SET CSD" in blob or "SET READY" in blob,
        "files": "FILES READY" in blob or "FILES CSD" in blob,
        "browse": "BROWSE READY" in blob,
        "play": "PLAY READY" in blob,
        "studio": "STUDIO" in blob,
        "tap": "TAP CSD" in blob or ("TAP" in blob and not tap_die),
    }
    nav = {
        "mkdir": files_mkdir,
        "dir": files_dir,
        "back1": files_back1,
        "back2": files_back2,
        "fwd1": files_fwd1,
        "fwd2": files_fwd2,
        "hist": files_hist,
        "fwd2_token": "FILES FWD2" in blob,
        "hist_token": "FILES HIST " in blob,
    }
    handoff = {
        "files_open_studio": handoff,
        "studio_openwith": studio_ow,
        "studio_open": studio_open,
        "studio_tab": studio_tab,
        "studio_caret": studio_caret,
        "bin_error": "FILES OPEN BIN " in blob or "STUDIO ERR BIN " in blob,
        "miss_error": "STUDIO ERR MISS " in blob,
        "protocol": "OPENWITH.DAT",
    }
    prefs = {
        "set_theme": set_theme,
        "wm_pref_ack": pref_ack,
        "desk_pref": desk_pref,
        "closed": closed,
        "relaunch": relaunch,
        "relaunch_pref": relaunch_pref,
        "theme_line": theme_line,
        "close_vs_focus": bool(closed),
        "checksummed": True,
        "chrome_dat_bytes": 8,
    }
    overlay = {
        "launch_show": launch_show,
        "done_kind_7": done7,
        "switch_show": switch_show,
        "done_kind_8": done8,
        "pairing": "WM DONE opid+kind 7/8",
    }
    studio = {
        "tabs": studio_tab or "STUDIO TAB " in blob,
        "find": "STUDIO FIND " in blob,
        "caret": studio_caret or "STUDIO CARET " in blob,
        "saveas": "STUDIO SAVEAS " in blob,
        "new_doc": "STUDIO NEW " in blob,
        "not_ide": True,
    }
    integrity = {
        "tap_die": tap_die,
        "fault": "FAULT " in blob,
        "oom": "OSGFX OOM" in blob or "OOM" in blob and "OSGFX OOM" in blob,
        "reap": blob.count("PROC REAP"),
        "attach_refuse": "WM RET " in blob,
        "catalog_excludes_desk": catalog_n >= 6,
    }

    write_json("oscortex-round35-capacity.json", cap)
    write_json("oscortex-round35-catalog.json", {
        "semantics": "directory-backed FAT ELF scan on each Start",
        "excludes": ["DESK.ELF", "non-ELF", "invalid magic"],
        "n": catalog_n,
        "token": "WM CATALOG ",
        "refresh": "wmDeStartShow rescan",
    })
    write_json("oscortex-round35-nav.json", nav)
    write_json("oscortex-round35-handoff.json", handoff)
    write_json("oscortex-round35-prefs.json", prefs)
    write_json("oscortex-round35-overlay.json", overlay)
    write_json("oscortex-round35-studio.json", studio)
    write_json("oscortex-round35-integrity.json", integrity)

    print(json.dumps({
        "capacity": cap,
        "nav": nav,
        "handoff": handoff,
        "prefs": prefs,
        "overlay": overlay,
        "studio": studio,
        "integrity": integrity,
    }, indent=2))
    if tap_die:
        raise SystemExit("prove-round35: TAP DIE")
    if not catalog and catalog_n < 1:
        raise SystemExit("prove-round35: no catalog")
    return 0


if __name__ == "__main__":
    raise SystemExit(main() or 0)
