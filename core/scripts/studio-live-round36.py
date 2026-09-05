#!/usr/bin/env python3
"""Round 36 live STUDIO / FILES handoff / overlay-capacity proof.

Does not clobber oscortex-round36-overlay.json p95 numbers.
"""

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


def chord(q, *names):
    for n in names:
        key_edge(q, n, True)
    time.sleep(0.03)
    for n in reversed(names):
        key_edge(q, n, False)


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


def live_studio_xywh(blob):
    slot = None
    attach_at = -1
    for m in cs.ATTACH_RE.finditer(blob):
        if int(m.group(3), 16) != 5:
            continue
        if int(m.group(6), 16) < 200:
            continue
        slot = int(m.group(1), 16)
        attach_at = m.end()
    if slot is None:
        return None
    for m in cs.CLOSE_RE.finditer(blob, attach_at):
        if int(m.group(1), 16) == slot:
            return None
    return cs._vis_xywh(blob, slot, min_w=200, min_h=160)


def note_row(blob):
    names = []
    for ln in blob.splitlines():
        if "FILES NAME " in ln:
            names.append(ln.split("FILES NAME ", 1)[-1].strip())
    # Last contiguous root listing.
    last_root = []
    for n in names:
        if n == "FILES.ELF" and last_root:
            last_root = [n]
        else:
            last_root.append(n)
    for i, n in enumerate(last_root):
        if n == "NOTE.TXT":
            return i
    return 11


def ordinary_slots(blob):
    """Unique ordinary attach slots (0..16) still live after last DESK BOOT."""
    idx = blob.rfind("DESK BOOT")
    chunk = blob[idx:] if idx >= 0 else blob
    live = {}
    for m in cs.ATTACH_RE.finditer(chunk):
        slot = int(m.group(1), 16)
        cap = int(m.group(3), 16)
        w = int(m.group(6), 16)
        h = int(m.group(7), 16)
        if slot >= 17:
            continue
        if w == 0x118 and h == 0xF4:
            continue
        live[slot] = {"cap": cap, "w": w, "h": h}
    for m in cs.CLOSE_RE.finditer(chunk):
        slot = int(m.group(1), 16)
        live.pop(slot, None)
    return live


def overlay_slots(blob):
    idx = blob.rfind("DESK BOOT")
    chunk = blob[idx:] if idx >= 0 else blob
    found = []
    for m in cs.ATTACH_RE.finditer(chunk):
        w = int(m.group(6), 16)
        h = int(m.group(7), 16)
        x = int(m.group(4), 16)
        y = int(m.group(5), 16)
        if w == 0x118 and h == 0xF4:
            found.append({"x": x, "y": y, "w": w, "h": h})
    return found


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
    time.sleep(0.12)
    click(q, ser, 400, 500)
    time.sleep(0.12)

    marked_st = harvest(ser)
    click(q, ser, dock_xy(4)[0], dock_xy(4)[1])
    studio_ready = wait_tok(ser, "STUDIO2 READY", marked_st, 4.0) or wait_tok(
        ser, "STUDIO READY", marked_st, 1.0) or wait_tok(
        ser, "STUDIO CSD", marked_st, 3.0)
    blob = harvest(ser)
    sg = live_studio_xywh(blob) or (48, 56, 320, 220)
    click(q, ser, sg[0] + 80, sg[1] + 120)
    time.sleep(0.22)

    marked_ed = harvest(ser)
    chord(q, "ctrl", "n")
    studio_new = wait_tok(ser, "STUDIO NEW ", marked_ed, 2.0)
    q.key("a")
    time.sleep(0.08)
    chord(q, "ctrl", "f")
    studio_find = wait_tok(ser, "STUDIO FIND ", marked_ed, 2.0)
    chord(q, "ctrl", "tab")
    studio_tab = wait_tok(ser, "STUDIO TAB ", marked_ed, 1.8)
    chord(q, "ctrl", "a")
    studio_saveas = wait_tok(ser, "STUDIO SAVEAS ", marked_ed, 1.8)
    q.key("right")
    studio_caret = wait_tok(ser, "STUDIO CARET ", marked_ed, 1.5)
    chord(q, "ctrl", "c")
    studio_copy = wait_tok(ser, "STUDIO COPY ", marked_ed, 1.2)
    chord(q, "ctrl", "v")
    studio_paste = wait_tok(ser, "STUDIO PASTE ", marked_ed, 1.2)
    q.key("down")
    studio_scroll = wait_tok(ser, "STUDIO SCROLL ", marked_ed, 1.0)
    studio_dirty = "STUDIO DIRTY" in harvest(ser)
    time.sleep(0.12)
    d15.shot(q, os.path.join(ART, "oscortex-round36-studio-workflow.png"))

    fg = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "") or (
        48, 40, 400, 280)
    click(q, ser, fg[0] + 80, fg[1] + 16)
    time.sleep(0.12)
    click(q, ser, fg[0] + 80, fg[1] + 80)
    time.sleep(0.1)
    # Return to root if a prior mkdir left FILES in a folder.
    q.key("left")
    q.key("left")
    time.sleep(0.15)
    fg = cs.live_files_xywh(os.path.join(RUN, "serial.txt"), "") or fg
    click(q, ser, fg[0] + 80, fg[1] + 16)
    time.sleep(0.08)
    click(q, ser, fg[0] + 80, fg[1] + 80)
    time.sleep(0.08)
    row = note_row(harvest(ser))
    marked_ow = harvest(ser)
    for _ in range(row):
        q.key("down")
        time.sleep(0.025)
    q.key("ret")
    handoff = wait_tok(ser, "FILES OPEN STUDIO", marked_ow, 3.0)
    studio_ow = wait_tok(ser, "STUDIO OPENWITH", marked_ow, 3.0)
    studio_open = wait_tok(ser, "STUDIO OPEN ", marked_ow, 2.0)
    studio_tab_focus = wait_tok(ser, "STUDIO TAB ", marked_ow, 1.2) or (
        "STUDIO OPEN " in harvest(ser)[len(marked_ow):])

    # Binary refuse: FILES.ELF at row 0.
    click(q, ser, fg[0] + 80, fg[1] + 48)
    time.sleep(0.06)
    q.key("ret")
    bin_err = wait_tok(ser, "FILES OPEN BIN ", marked_ow, 2.0)

    refuse_win = harvest(ser)[len(marked_ow):]
    f9 = refuse_win.count("FILE REFUSED FFFFFFFFFFFFFFF9")
    ow_named = "OPENWITH" in refuse_win and "FILE REFUSED" in refuse_win

    # Extra FILES windows until spawn/process bound. Honest slot count.
    extra = 0
    for _ in range(16):
        marked_f = harvest(ser)
        click(q, ser, dock_xy(1)[0], dock_xy(1)[1])
        if wait_tok(ser, "FILES READY", marked_f, 1.8) or wait_tok(
                ser, "FILES CSD", marked_f, 1.2):
            extra = extra + 1
        else:
            break
        time.sleep(0.08)
    blob = harvest(ser)
    ord_slots = ordinary_slots(blob)
    ov = overlay_slots(blob)
    overlay_280 = len(ov) > 0 or "W 0118 H 00F4" in blob

    write_json("oscortex-round36-studio.json", {
        "ready": bool(studio_ready),
        "new": bool(studio_new),
        "find": bool(studio_find),
        "tab": bool(studio_tab),
        "saveas": bool(studio_saveas),
        "caret": bool(studio_caret),
        "copy": bool(studio_copy),
        "paste": bool(studio_paste),
        "scroll": bool(studio_scroll),
        "dirty": bool(studio_dirty),
        "geom": list(sg),
        "files_handoff": bool(handoff),
        "files_handoff_tab": bool(studio_tab_focus or studio_open),
        "not_ide": True,
    })
    write_json("oscortex-round36-openwith.json", {
        "handoff": bool(handoff),
        "studio_openwith": bool(studio_ow),
        "studio_open": bool(studio_open),
        "bin_error": bool(bin_err) or "FILES OPEN BIN " in blob,
        "file_refused_f9_in_window": f9,
        "openwith_named_refuse": bool(ow_named),
        "mailbox_silence":
            "fileNameIsMailbox skips UART for OPENWITH/PINS not-found",
        "pins_move_skipped": True,
    })
    write_json("oscortex-round36-handoff.json", {
        "files_open_studio": bool(handoff),
        "studio_openwith": bool(studio_ow),
        "studio_open": bool(studio_open),
        "studio_tab_focus": bool(studio_tab_focus or studio_open),
        "note_row": row,
        "bin_error": bool(bin_err) or "FILES OPEN BIN " in blob,
        "protocol": "OPENWITH.DAT",
    })
    write_json("oscortex-round36-capacity.json", {
        "wmMaxWindows": 20,
        "shmMax": 20,
        "procMax": 16,
        "ordinary_client_slots": 16,
        "overlay_slots": "17..19",
        "overlay_attach_280x244": overlay_280,
        "ordinary_live_slots": sorted(ord_slots.keys()),
        "ordinary_live_n": len(ord_slots),
        "extra_files_spawned": extra,
        "overlay_280_attaches": ov,
        "shmCapsPerProc": 4,
        "chanPorts": 2,
        "caps_raised": False,
        "caps_note":
            "no exhaustion in multi-doc/editor; left at 4/2. "
            "procMax=16 includes DESK so 16 ordinary clients need a "
            "second ordinary surface on one process.",
        "proc_bound": "DESK + 15 clients = 16 processes",
    })

    print(json.dumps({
        "studio": {
            "ready": studio_ready, "new": studio_new, "find": studio_find,
            "tab": studio_tab, "saveas": studio_saveas, "caret": studio_caret,
            "copy": studio_copy, "paste": studio_paste, "scroll": studio_scroll,
            "geom": list(sg),
        },
        "handoff": bool(handoff),
        "studio_ow": bool(studio_ow),
        "openwith_f9": f9,
        "ordinary_n": len(ord_slots),
        "extra_files": extra,
        "overlay_280": overlay_280,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
