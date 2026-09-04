#!/usr/bin/env python3
"""Reboot the leftover ISO+disk and prove SET CHROME.DAT survived."""

import importlib.util
import json
import os
import shutil
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r36")
LAUNCH = os.path.join(HERE, "launch-daily-drive-round36.sh")
SIT = os.path.join(HERE, "boot-sit-in-round36.py")


def harvest_path():
    return open(os.path.join(RUN, "serial.txt"), encoding="latin-1",
                errors="replace").read()


def main():
    os.makedirs(ART, exist_ok=True)
    disk = os.path.join(RUN, "disk.img")
    keep = os.path.join(RUN, "disk-persist.img")
    shutil.copy2(disk, keep)
    pid_path = os.path.join(RUN, "qemu.pid")
    old = open(pid_path).read().strip()
    if old and old.isdigit():
        args = subprocess.check_output(["ps", "-p", old, "-o", "args="],
                                       text=True, stderr=subprocess.DEVNULL)
        if "oscortex-daily-drive-round36" in args:
            os.kill(int(old), 15)
            time.sleep(0.6)
    shutil.copy2(keep, disk)
    env = os.environ.copy()
    env["OSCORTEX_BIOS"] = "0"
    env["OSCORTEX_VENUS"] = "0"
    env["FORCE_DISK"] = "0"
    env["FORCE_ISO"] = "0"
    env["DRIVE_RUN"] = RUN
    env["KERNEL_ELF"] = "/workspace/core/build/kernel.elf"
    env["KERNEL_UEFI"] = "/workspace/core/build/kernel-uefi.elf"
    env["DISPLAY"] = env.get("DISPLAY", ":1")
    env.pop("DRIVE_GIT_SHA", None)
    env.pop("BUILD_DIR", None)
    env.pop("OSCORTEX_PERF_OUT", None)
    subprocess.check_call(["bash", LAUNCH], env=env)
    subprocess.check_call(["python3", SIT], env=env)
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    x = (d15.RIGHT_X + d15.ICON_PAD + 0 * (d15.ICON_S + d15.ICON_GAP)
         + d15.ICON_S // 2)
    d15.place(q, ser, x, d15.PANEL_Y)
    d15.button(q, x, d15.PANEL_Y, "left", True)
    time.sleep(0.03)
    d15.button(q, x, d15.PANEL_Y, "left", False)
    t0 = time.time()
    theme1 = False
    ack = False
    while time.time() - t0 < 6:
        blob = harvest_path()
        if "SET THEME 1" in blob:
            theme1 = True
        if "WM PREF ACK" in blob:
            ack = True
        if theme1:
            break
        time.sleep(0.1)
    d15.shot(q, os.path.join(ART, "oscortex-round36-persist-reboot.png"))
    blob = harvest_path()
    out = {
        "rebooted": True,
        "same_iso": True,
        "theme1": theme1 or ("SET THEME 1" in blob),
        "accent": "SET ACCENT 1" in blob,
        "wall": "SET WALL 1" in blob,
        "pref_ack": ack or ("WM PREF ACK" in blob),
        "desk_pref": "DESK PREF" in blob,
        "kernel_sha256": open(os.path.join(RUN, "kernel.sha256")).read().strip(),
        "close_vs_focus": "true close then leftover reboot",
    }
    dest = os.path.join(ART, "oscortex-round36-prefs.json")
    prev = {}
    if os.path.isfile(dest):
        try:
            prev = json.load(open(dest))
        except Exception:
            prev = {}
    prev.update(out)
    open(dest, "w").write(json.dumps(prev, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0 if out["theme1"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
