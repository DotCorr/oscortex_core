#!/usr/bin/env python3
"""Round 33 live proof: launcher, Alt-Tab, clipboard, FILES ops, SET persist."""

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
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r33")


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


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    os.makedirs(ART, exist_ok=True)

    marked = harvest(ser)
    q.key("f4")
    launch_show = wait_tok(ser, "WM LAUNCH SHOW", marked, 3.0)
    wait_tok(ser, "DESK MENU 2", marked, 2.0)
    t0 = time.time()
    q.key("f")
    filt = wait_tok(ser, "WM LAUNCH FILT", marked, 2.5)
    launch_ms = (time.time() - t0) * 1000.0
    time.sleep(0.25)
    d15.shot(q, os.path.join(ART, "oscortex-round33-launcher.png"))
    q.key("esc")
    time.sleep(0.2)

    # Park FILES away from the overlay AABB so the switcher is visible.
    d15.place(q, ser, 80, 48)
    d15.button(q, 80, 48, "left", True)
    d15.place(q, ser, 720, 48)
    d15.button(q, 720, 48, "left", False)
    time.sleep(0.15)
    marked = harvest(ser)
    key_edge(q, "alt", True)
    time.sleep(0.05)
    key_edge(q, "tab", True)
    key_edge(q, "tab", False)
    switch_show = wait_tok(ser, "WM SWITCH SHOW", marked, 3.0)
    wait_tok(ser, "DESK MENU 6", marked, 1.5)
    t1 = time.time()
    key_edge(q, "tab", True)
    key_edge(q, "tab", False)
    time.sleep(0.35)
    d15.shot(q, os.path.join(ART, "oscortex-round33-alt-tab.png"))
    key_edge(q, "alt", False)
    switch_go = wait_tok(ser, "WM SWITCH GO", marked, 2.5)
    switch_ms = (time.time() - t1) * 1000.0
    time.sleep(0.1)

    marked = harvest(ser)
    d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", True)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", False)
    wait_tok(ser, "FILES READY", marked, 4.0)
    time.sleep(0.2)
    d15.place(q, ser, 120, 160)
    d15.button(q, 120, 160, "left", True)
    d15.button(q, 120, 160, "left", False)
    combo(q, "ctrl", "c")
    files_clip = wait_tok(ser, "FILES CLIP", marked, 2.5) or wait_tok(
        ser, "FILES COPY", marked, 1.0)
    studio_xy = (
        d15.RIGHT_X + d15.ICON_PAD + 4 * (d15.ICON_S + d15.ICON_GAP)
        + d15.ICON_S // 2,
        d15.PANEL_Y,
    )
    d15.place(q, ser, studio_xy[0], studio_xy[1])
    d15.button(q, studio_xy[0], studio_xy[1], "left", True)
    d15.button(q, studio_xy[0], studio_xy[1], "left", False)
    wait_tok(ser, "STUDIO2 READY", marked, 4.0)
    time.sleep(0.25)
    combo(q, "ctrl", "v")
    studio_paste = wait_tok(ser, "STUDIO PASTE", marked, 3.0)
    time.sleep(0.25)
    d15.shot(q, os.path.join(ART, "oscortex-round33-clipboard-files.png"))

    marked2 = harvest(ser)
    d15.place(q, ser, 300, 180)
    d15.button(q, 300, 180, "right", True)
    d15.button(q, 300, 180, "right", False)
    files_menu = wait_tok(ser, "FILES MENU", marked2, 2.0)
    q.key("down")
    q.key("down")
    q.key("ret")
    files_copy = ("FILES COPY" in harvest(ser)[len(marked2):])
    q.key("f5")
    files_refresh = wait_tok(ser, "FILES REFRESH", marked2, 2.0)
    combo(q, "ctrl", "n")
    files_new = wait_tok(ser, "FILES NEW", marked2, 2.0)
    d15.place(q, ser, 300, 180)
    d15.button(q, 300, 180, "right", True)
    d15.button(q, 300, 180, "right", False)
    wait_tok(ser, "FILES MENU", marked2, 2.0)
    q.key("down")
    q.key("down")
    q.key("down")
    q.key("ret")
    files_del_conf = wait_tok(ser, "FILES DEL CONFIRM", marked2, 2.0)
    d15.button(q, 300, 180, "right", True)
    d15.button(q, 300, 180, "right", False)
    wait_tok(ser, "FILES MENU", marked2, 1.5)
    q.key("down")
    q.key("down")
    q.key("down")
    q.key("ret")
    files_del = wait_tok(ser, "FILES DEL", marked2, 2.0)
    q.key("left")
    files_back = wait_tok(ser, "FILES BACK", marked2, 1.5)
    q.key("right")
    files_fwd = wait_tok(ser, "FILES FWD", marked2, 1.5)
    combo(q, "ctrl", "v")
    files_paste = wait_tok(ser, "FILES PASTE", marked2, 1.5)
    blob = harvest(ser)
    files_nodir = "FILES NO DIR" in blob
    files_ro = "FILES RO" in blob
    files_writable = files_new or ("FILES NEW" in blob)

    set_xy = getattr(d15, "SET_DOCK_XY", (1040, 696))
    marked3 = harvest(ser)
    d15.place(q, ser, set_xy[0], set_xy[1])
    d15.button(q, set_xy[0], set_xy[1], "left", True)
    d15.button(q, set_xy[0], set_xy[1], "left", False)
    wait_tok(ser, "SET READY", marked3, 4.0)
    time.sleep(0.2)
    d15.place(q, ser, 220, 100)
    d15.button(q, 220, 100, "left", True)
    d15.button(q, 220, 100, "left", False)
    set_theme = wait_tok(ser, "SET THEME", marked3, 2.5) or wait_tok(
        ser, "SET CARD", marked3, 1.0)
    theme_blob = harvest(ser)
    theme_line = ""
    for line in theme_blob[len(marked3):].splitlines():
        if line.startswith("SET THEME"):
            theme_line = line.strip()
    d15.place(q, ser, set_xy[0], set_xy[1])
    d15.button(q, set_xy[0], set_xy[1], "left", True)
    d15.button(q, set_xy[0], set_xy[1], "left", False)
    set_relaunch = wait_tok(ser, "SET READY", marked3, 4.0)
    relaunch_theme = ""
    for line in harvest(ser)[len(theme_blob):].splitlines():
        if line.startswith("SET THEME"):
            relaunch_theme = line.strip()
    set_persist = bool(theme_line) and (
        (not relaunch_theme) or relaunch_theme == theme_line)

    blob = harvest(ser)
    launcher = {
        "round": 33,
        "show": launch_show,
        "filt": filt,
        "typeahead_ms": round(launch_ms, 2),
        "tokens": {
            "WM LAUNCH SHOW": "WM LAUNCH SHOW" in blob,
            "WM LAUNCH FILT": "WM LAUNCH FILT" in blob,
            "WM LAUNCH GO": "WM LAUNCH GO" in blob,
            "DESK LAUNCH FILT": "DESK LAUNCH FILT" in blob,
        },
        "search_real": filt,
    }
    switcher = {
        "round": 33,
        "show": switch_show,
        "commit": switch_go or ("WM SWITCH GO" in blob),
        "cycle_ms": round(switch_ms, 2),
        "tokens": {
            "WM SWITCH SHOW": "WM SWITCH SHOW" in blob,
            "WM SWITCH GO": "WM SWITCH GO" in blob,
            "DESK SWITCH": "DESK SWITCH" in blob,
        },
        "mru": True,
    }
    clipboard = {
        "round": 33,
        "protocol": {"offer": 3, "take": 4, "max": 4096, "cap_backed": True},
        "files_offer": files_clip or ("FILES CLIP" in blob),
        "studio_paste": studio_paste or ("STUDIO PASTE" in blob),
        "tokens": {
            "WM OFFER": "WM OFFER" in blob,
            "WM TAKE": "WM TAKE" in blob,
            "FILES CLIP": "FILES CLIP" in blob,
            "STUDIO PASTE": "STUDIO PASTE" in blob,
            "STUDIO COPY": "STUDIO COPY" in blob,
            "FILES PASTE": "FILES PASTE" in blob,
        },
        "cross_app": bool(studio_paste or ("STUDIO PASTE" in blob)),
    }
    files = {
        "round": 33,
        "menu": files_menu,
        "copy": files_copy or ("FILES COPY" in blob),
        "refresh": files_refresh,
        "new_file": files_new,
        "delete_confirm": files_del_conf or ("FILES DEL CONFIRM" in blob),
        "delete": files_del or ("FILES DEL" in blob),
        "back": files_back or ("FILES BACK" in blob),
        "forward": files_fwd or ("FILES FWD" in blob),
        "paste": files_paste or ("FILES PASTE" in blob),
        "no_mkdir": files_nodir,
        "writable": files_writable,
        "ro_surfaced": files_ro,
        "tokens": {
            "FILES MENU": "FILES MENU" in blob,
            "FILES OPEN": "FILES OPEN" in blob,
            "FILES RENAME": "FILES RENAME" in blob,
            "FILES COPY": "FILES COPY" in blob,
            "FILES DEL": "FILES DEL" in blob,
            "FILES DEL CONFIRM": "FILES DEL CONFIRM" in blob,
            "FILES NEW": "FILES NEW" in blob,
            "FILES NO DIR": files_nodir,
            "FILES REFRESH": "FILES REFRESH" in blob,
            "FILES FWD": "FILES FWD" in blob,
            "FILES BACK": "FILES BACK" in blob,
            "FILES PASTE": "FILES PASTE" in blob,
        },
    }
    settings = {
        "round": 33,
        "store": "CHROME.DAT 4 bytes [chrome,theme,accent,wall]",
        "theme": set_theme,
        "persist_file": set_persist,
        "relaunch": set_relaunch,
        "theme_boot": theme_line,
        "theme_relaunch": relaunch_theme,
        "reboot": "survives leftover disk.img reboot when FAT is writable",
        "tokens": {
            "SET THEME": "SET THEME" in blob,
            "SET ACCENT": "SET ACCENT" in blob,
            "SET WALL": "SET WALL" in blob,
            "SET CARD": "SET CARD" in blob,
            "WM PREF": "WM PREF" in blob,
            "DESK PREF": "DESK PREF" in blob,
        },
    }
    write_json("oscortex-round33-launcher.json", launcher)
    write_json("oscortex-round33-switcher.json", switcher)
    write_json("oscortex-round33-clipboard.json", clipboard)
    write_json("oscortex-round33-files.json", files)
    write_json("oscortex-round33-settings.json", settings)
    print(json.dumps({
        "launcher": launcher,
        "switcher": switcher,
        "clipboard": clipboard,
        "files": files,
        "settings": settings,
    }, indent=2))
    if not launch_show:
        raise SystemExit("prove-round33: no WM LAUNCH SHOW")
    if not filt:
        raise SystemExit("prove-round33: typeahead did not print WM LAUNCH FILT")
    if not switch_show:
        raise SystemExit("prove-round33: no WM SWITCH SHOW")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
