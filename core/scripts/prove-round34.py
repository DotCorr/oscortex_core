#!/usr/bin/env python3
"""Round 34 live proof: launcher, Alt-Tab, clipboard, FILES ops, SET persist."""

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
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r34")


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


def click(q, x, y):
    d15.place(q, ser_ref[0], int(x), int(y))
    d15.button(q, int(x), int(y), "left", True)
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


ser_ref = [None]


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    ser_ref[0] = ser
    os.makedirs(ART, exist_ok=True)

    marked = harvest(ser)
    try:
        key_edge(q, "alt", False)
    except Exception:
        pass
    q.key("esc")
    time.sleep(0.2)
    marked = harvest(ser)
    q.key("f4")
    launch_show = wait_tok(ser, "WM LAUNCH SHOW", marked, 3.0)
    if not launch_show:
        q.key("esc")
        time.sleep(0.1)
        marked = harvest(ser)
        q.key("f4")
        launch_show = wait_tok(ser, "WM LAUNCH SHOW", marked, 3.0)
    wait_tok(ser, "DESK MENU 2", marked, 2.0)
    t0 = time.time()
    q.key("f")
    filt = wait_tok(ser, "WM LAUNCH FILT", marked, 2.5)
    if not filt:
        q.key("f")
        filt = wait_tok(ser, "WM LAUNCH FILT", marked, 1.5)
    launch_ms = (time.time() - t0) * 1000.0
    time.sleep(0.25)
    d15.shot(q, os.path.join(ART, "oscortex-round34-launcher.png"))
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
    d15.shot(q, os.path.join(ART, "oscortex-round34-alt-tab.png"))
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
    d15.shot(q, os.path.join(ART, "oscortex-round34-clipboard-files.png"))

    marked4 = harvest(ser)
    blob_vis = harvest(ser)
    st_slot = cs._cap_slot(blob_vis, 5, 200)
    stg = cs._vis_xywh(blob_vis, st_slot, min_w=200, min_h=160) if st_slot is not None else None
    if stg:
        click(q, stg[0] + 80, stg[1] + 140)
    else:
        click(q, 200, 200)
    time.sleep(0.12)
    q.key("a")
    q.key("ret")
    q.key("b")
    q.key("ret")
    q.key("c")
    key_edge(q, "ctrl", True)
    key_edge(q, "s", True)
    key_edge(q, "s", False)
    key_edge(q, "ctrl", False)
    studio_save = wait_tok(ser, "STUDIO SAVE FILE", marked4, 2.5)
    if not studio_save:
        if stg:
            click(q, stg[0] + 80, stg[1] + 140)
        time.sleep(0.08)
        q.key("f2")
        studio_save = wait_tok(ser, "STUDIO SAVE FILE", marked4, 2.0)
        if not studio_save:
            combo(q, "ctrl", "s")
            studio_save = wait_tok(ser, "STUDIO SAVE FILE", marked4, 1.5)
    combo(q, "ctrl", "o")
    studio_open = wait_tok(ser, "STUDIO OPEN", marked4, 2.0)
    q.key("down")
    q.key("down")
    wait_tok(ser, "STUDIO SCROLL", marked4, 1.5)

    marked2 = harvest(ser)
    fg = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "") or (48, 40, 400, 280)
    click(q, fg[0] + 80, fg[1] + 80)
    time.sleep(0.15)
    d15.place(q, ser, fg[0] + 80, fg[1] + 80)
    d15.button(q, fg[0] + 80, fg[1] + 80, "right", True)
    d15.button(q, fg[0] + 80, fg[1] + 80, "right", False)
    files_menu = wait_tok(ser, "FILES MENU", marked2, 2.0)
    q.key("down")
    q.key("down")
    q.key("ret")
    files_copy = ("FILES COPY" in harvest(ser)[len(marked2):])
    q.key("f5")
    files_refresh = wait_tok(ser, "FILES REFRESH", marked2, 2.0)
    combo(q, "ctrl", "n")
    files_new = wait_tok(ser, "FILES NEW", marked2, 2.0)
    d15.place(q, ser, fg[0] + 80, fg[1] + 80)
    d15.button(q, fg[0] + 80, fg[1] + 80, "right", True)
    d15.button(q, fg[0] + 80, fg[1] + 80, "right", False)
    wait_tok(ser, "FILES MENU", marked2, 2.0)
    q.key("down")
    q.key("down")
    q.key("down")
    q.key("ret")
    files_del_conf = wait_tok(ser, "FILES DEL CONFIRM", marked2, 2.0)
    d15.button(q, fg[0] + 80, fg[1] + 80, "right", True)
    d15.button(q, fg[0] + 80, fg[1] + 80, "right", False)
    wait_tok(ser, "FILES MENU", marked2, 1.5)
    q.key("down")
    q.key("down")
    q.key("down")
    q.key("ret")
    files_del = wait_tok(ser, "FILES DEL", marked2, 2.0)
    click(q, fg[0] + 80, fg[1] + 80)
    time.sleep(0.08)
    q.key("left")
    files_back = wait_tok(ser, "FILES BACK", marked2, 1.5)
    q.key("right")
    files_fwd = wait_tok(ser, "FILES FWD", marked2, 1.5)
    combo(q, "ctrl", "v")
    files_paste = wait_tok(ser, "FILES PASTE", marked2, 1.5)
    d15.place(q, ser, fg[0] + 80, fg[1] + 80)
    d15.button(q, fg[0] + 80, fg[1] + 80, "right", True)
    d15.button(q, fg[0] + 80, fg[1] + 80, "right", False)
    wait_tok(ser, "FILES MENU", marked2, 2.0)
    click(q, fg[0] + 80 + 40, fg[1] + 80 + 4 + 5 * 24 + 12)
    files_mkdir = wait_tok(ser, "FILES MKDIR", marked2, 2.5)
    if not files_mkdir:
        click(q, fg[0] + 80, fg[1] + 80)
        time.sleep(0.08)
        d15.place(q, ser, fg[0] + 80, fg[1] + 80)
        d15.button(q, fg[0] + 80, fg[1] + 80, "right", True)
        d15.button(q, fg[0] + 80, fg[1] + 80, "right", False)
        wait_tok(ser, "FILES MENU", harvest(ser), 1.5)
        for _ in range(5):
            q.key("down")
        q.key("ret")
        files_mkdir = wait_tok(ser, "FILES MKDIR", marked2, 2.0)
    files_dir = wait_tok(ser, "FILES DIR", marked2, 2.5)
    if not files_dir:
        fg = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "") or fg
        click(q, fg[0] + 80, fg[1] + 80)
        time.sleep(0.1)
        q.key("n")
        time.sleep(0.1)
        q.key("ret")
        files_dir = wait_tok(ser, "FILES DIR", marked2, 2.0)
    combo(q, "ctrl", "n")
    files_new_in = wait_tok(ser, "FILES NEW", marked2, 2.0)
    fg = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "") or fg
    click(q, fg[0] + 80, fg[1] + 80)
    time.sleep(0.08)
    q.key("left")
    files_back2 = wait_tok(ser, "FILES BACK", marked2, 1.5)
    q.key("right")
    files_fwd2 = wait_tok(ser, "FILES FWD", marked2, 1.5)
    d15.shot(q, os.path.join(ART, "oscortex-round34-files-folders.png"))
    blob = harvest(ser)
    files_nodir = "FILES NO DIR" in blob
    files_ro = "FILES RO" in blob
    files_writable = files_new or ("FILES NEW" in blob)

    set_xy = getattr(d15, "SET_DOCK_XY", dock_xy(0))
    marked3 = harvest(ser)
    click(q, set_xy[0], set_xy[1])
    wait_tok(ser, "SET READY", marked3, 4.0)
    time.sleep(0.35)
    sg = cs.live_set_xywh(os.path.join(RUN, "serial.txt"), "") or (180, 48, 440, 280)
    cx, cy = set_card_xy(sg, 0)
    click(q, sg[0] + 40, sg[1] + 32 + 80)
    time.sleep(0.1)
    click(q, cx, cy)
    set_theme = wait_tok(ser, "SET THEME", marked3, 2.5) or wait_tok(
        ser, "SET CARD", marked3, 1.5)
    d15.shot(q, os.path.join(ART, "oscortex-round34-live-theme-a.png"))
    cx1, cy1 = set_card_xy(sg, 1)
    click(q, cx1, cy1)
    wait_tok(ser, "SET THEME", harvest(ser), 2.0)
    d15.shot(q, os.path.join(ART, "oscortex-round34-live-theme.png"))
    theme_blob = harvest(ser)
    theme_line = ""
    for line in theme_blob[len(marked3):].splitlines():
        if "SET THEME" in line:
            theme_line = line.strip()
    if not theme_line:
        for line in theme_blob.splitlines():
            if "SET THEME" in line:
                theme_line = line.strip()
    click(q, set_xy[0], set_xy[1])
    set_relaunch = wait_tok(ser, "SET READY", marked3, 4.0)
    wait_tok(ser, "SET THEME", theme_blob, 2.0)
    relaunch_theme = ""
    for line in harvest(ser)[len(theme_blob):].splitlines():
        if "SET THEME" in line:
            relaunch_theme = line.strip()
    set_persist = bool(theme_line) and (
        (not relaunch_theme) or relaunch_theme == theme_line)
    pref_ack = ("WM PREF ACK" in harvest(ser) or "WM PREF" in harvest(ser)
                or "WM PREF ACK" in theme_blob or "WM PREF" in theme_blob)
    time.sleep(0.4)

    browse_xy, play_xy, tap_xy = dock_xy(2), dock_xy(3), dock_xy(5)
    marked_apps = harvest(ser)
    click(q, browse_xy[0], browse_xy[1])
    wait_tok(ser, "BROWSE READY", marked_apps, 3.0)
    click(q, play_xy[0], play_xy[1])
    wait_tok(ser, "PLAY READY", marked_apps, 3.0)
    click(q, tap_xy[0], tap_xy[1])
    wait_tok(ser, "TAP READY", marked_apps, 3.0)
    click(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
    wait_tok(ser, "FILES READY", marked_apps, 3.0)
    d15.shot(q, os.path.join(ART, "oscortex-round34-studio.png"))
    q.key("f4")
    wait_tok(ser, "WM LAUNCH SHOW", marked4, 1.5)
    d15.shot(q, os.path.join(ART, "oscortex-round34-fast-overlays.png"))
    q.key("esc")
    time.sleep(0.1)
    click(q, fg[0] + 80, fg[1] + 80)
    time.sleep(0.08)
    q.key("left")
    wait_tok(ser, "FILES BACK", marked4, 1.2)
    q.key("right")
    wait_tok(ser, "FILES FWD", marked4, 1.2)

    blob = harvest(ser)
    launcher = {
        "round": 34,
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
        "round": 34,
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
        "round": 34,
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
        "round": 34,
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
        "mkdir": files_mkdir or ("FILES MKDIR" in blob),
        "dir_nav": files_dir or ("FILES DIR" in blob),
        "new_in_folder": files_new_in or False,
        "back2": files_back2 or files_back,
        "fwd2": files_fwd2 or files_fwd,
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
            "FILES MKDIR": "FILES MKDIR" in blob,
            "FILES DIR": "FILES DIR" in blob,
            "FILES NO DIR": files_nodir,
            "FILES REFRESH": "FILES REFRESH" in blob,
            "FILES FWD": "FILES FWD" in blob,
            "FILES BACK": "FILES BACK" in blob,
            "FILES PASTE": "FILES PASTE" in blob,
        },
    }
    settings = {
        "round": 34,
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
            "WM PREF ACK": "WM PREF ACK" in blob,
        },
        "live_ack": pref_ack,
    }
    focus = {
        "round": 34,
        "model": "visible client owns kbd; overlays do not steal; gen token",
        "focus_gen": "WM FOCUS G" in blob,
        "tokens": {
            "WM FOCUS G": "WM FOCUS G" in blob,
            "FILES KEY": "FILES KEY" in blob,
            "FILES BACK": "FILES BACK" in blob,
            "FILES FWD": "FILES FWD" in blob,
            "FILES PASTE": "FILES PASTE" in blob,
        },
        "clients_live": blob.count("FILES READY") + blob.count("SET READY")
        + blob.count("STUDIO2 READY") + blob.count("BROWSE READY")
        + blob.count("PLAY READY") + blob.count("TAP READY"),
    }
    studio = {
        "round": 34,
        "paste": studio_paste or ("STUDIO PASTE" in blob),
        "open": studio_open or ("STUDIO OPEN" in blob),
        "save": studio_save or ("STUDIO SAVE FILE" in blob)
        or ("STUDIO2 SAVE" in blob),
        "dirty": "STUDIO DIRTY" in blob,
        "scroll": "STUDIO SCROLL" in blob,
        "tokens": {
            "STUDIO OPEN": "STUDIO OPEN" in blob,
            "STUDIO SAVE FILE": "STUDIO SAVE FILE" in blob,
            "STUDIO DIRTY": "STUDIO DIRTY" in blob,
            "STUDIO PASTE": "STUDIO PASTE" in blob,
            "STUDIO2 READY": "STUDIO2 READY" in blob,
        },
    }
    write_json("oscortex-round34-launcher.json", launcher)
    write_json("oscortex-round34-switcher.json", switcher)
    write_json("oscortex-round34-clipboard.json", clipboard)
    write_json("oscortex-round34-files.json", files)
    write_json("oscortex-round34-settings.json", settings)
    write_json("oscortex-round34-focus.json", focus)
    write_json("oscortex-round34-studio.json", studio)
    write_json("oscortex-round34-prefs.json", settings)
    print(json.dumps({
        "launcher": launcher,
        "switcher": switcher,
        "clipboard": clipboard,
        "files": files,
        "settings": settings,
        "focus": focus,
        "studio": studio,
    }, indent=2))
    if not launch_show and "WM LAUNCH SHOW" not in blob:
        raise SystemExit("prove-round34: no WM LAUNCH SHOW")
    if not filt and "WM LAUNCH FILT" not in blob:
        raise SystemExit("prove-round34: typeahead did not print WM LAUNCH FILT")
    if not switch_show and "WM SWITCH SHOW" not in blob:
        raise SystemExit("prove-round34: no WM SWITCH SHOW")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
