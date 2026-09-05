#!/usr/bin/env python3
"""Derive m11 PMM BASE / FX / CAP from ELF+map. Update goldens only if they match."""

import json
import os
import re
import subprocess
import sys

CORE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
MAP = os.path.join(CORE, "build", "kernel.map")
KMAIN = os.path.join(CORE, "build", "kmain.o")
SERIAL_SRC = os.environ.get("M11_SERIAL", "/tmp/m11-last-serial.txt")
SCREEN_SRC = os.environ.get("M11_SCREEN", "/tmp/m11-last-screen.txt")
EXPECTED = os.path.join(CORE, "tests/conformance/m11-proc/expected.txt")
EXPECTED_SCREEN = os.path.join(CORE, "tests/conformance/m11-proc/expected-screen.txt")


def dartconst(name, path):
    blob = open(path, encoding="utf-8").read()
    m = re.search(r"^const int %s = ([0-9]+);" % name, blob, re.M)
    if not m:
        raise SystemExit("missing %s in %s" % (name, path))
    return int(m.group(1))


def kmain_bss_base(path):
    for line in open(path, encoding="latin-1", errors="replace"):
        parts = line.split()
        if len(parts) >= 4 and parts[0] == ".bss" and parts[-1].endswith("kmain.o"):
            return int(parts[1], 16)
    raise SystemExit("kmain.o .bss VMA missing from %s" % path)


def obj_off_size(obj, name):
    out = subprocess.check_output(
        ["x86_64-elf-readelf", "-sW", obj], text=True, errors="replace")
    for line in out.splitlines():
        if not line.strip():
            continue
        cols = line.split()
        if len(cols) >= 8 and cols[3] == "OBJECT" and cols[7] == name:
            return int(cols[1], 16), int(cols[2], 10)
    raise SystemExit("%s not in %s" % (name, obj))


def main():
    proc_max = dartconst("procMax", os.path.join(CORE, "kernel/proc.dart"))
    proc_store_bytes = dartconst("procStoreBytes", os.path.join(CORE, "kernel/proc.dart"))
    proc_fx_off = dartconst("procFxOffset", os.path.join(CORE, "kernel/proc.dart"))
    proc_fx_bytes = dartconst("procFxBytes", os.path.join(CORE, "kernel/proc.dart"))
    pmm_store_bytes = dartconst("pmmStoreBytes", os.path.join(CORE, "kernel/pmm.dart"))
    bss = kmain_bss_base(MAP)
    pmm_off, pmm_sz = obj_off_size(KMAIN, "pmmStore")
    proc_off, proc_sz = obj_off_size(KMAIN, "procStore")
    pmm_base = bss + pmm_off
    proc_base = bss + proc_off
    fx0 = proc_base + proc_fx_off
    fx1 = fx0 + proc_fx_bytes
    serial = open(SERIAL_SRC, encoding="latin-1", errors="replace").read()
    old = open(EXPECTED, encoding="latin-1", errors="replace").read()
    m_pmm = re.search(r"PMM BASE ([0-9A-F]{16})", serial)
    m_cap = re.search(r"PROC CAP ([0-9A-F]{8})", serial)
    m_fx = re.search(r"FX ([0-9A-F]{16})", serial)
    m_used = re.search(r"PMM MANAGED [0-9A-F]+ FREE ([0-9A-F]+) USED ([0-9A-F]+)", serial)
    old_pmm = re.search(r"PMM BASE ([0-9A-F]{16})", old)
    old_cap = re.search(r"PROC CAP ([0-9A-F]{8})", old)
    old_fx = re.search(r"FX ([0-9A-F]{16})", old)
    old_used = re.search(r"PMM MANAGED [0-9A-F]+ FREE ([0-9A-F]+) USED ([0-9A-F]+)", old)
    printed_pmm = int(m_pmm.group(1), 16)
    printed_cap = int(m_cap.group(1), 16)
    printed_fx = int(m_fx.group(1), 16)
    old_pmm_v = int(old_pmm.group(1), 16)
    old_cap_v = int(old_cap.group(1), 16)
    old_fx_v = int(old_fx.group(1), 16)
    used_delta_frames = int(old_used.group(2), 16) - int(m_used.group(2), 16)
    slot10 = "PROC SLOT 10 " in serial
    checks = {
        "pmm_base_elf": pmm_base,
        "pmm_base_serial": printed_pmm,
        "pmm_base_match": pmm_base == printed_pmm,
        "pmm_store_bytes_elf": pmm_sz,
        "pmm_store_bytes_dart": pmm_store_bytes,
        "proc_store_elf": proc_sz,
        "proc_store_dart": proc_store_bytes,
        "proc_base": proc_base,
        "fx0_elf": fx0,
        "fx0_serial": printed_fx,
        "fx0_match": fx0 == printed_fx,
        "fx1_elf": fx1,
        "cap_dart": proc_max,
        "cap_serial": printed_cap,
        "cap_match": printed_cap == proc_max,
        "slot10_present": slot10,
        "old_pmm": old_pmm_v,
        "old_cap": old_cap_v,
        "old_fx": old_fx_v,
        "old_pmm_rejected": old_pmm_v != printed_pmm,
        "old_cap_rejected": old_cap_v != printed_cap,
        "old_fx_rejected": old_fx_v != printed_fx,
        "old_slot10_absent": "PROC SLOT 10 " not in old,
        "used_delta_frames": used_delta_frames,
        "used_delta_bytes": used_delta_frames * 4096,
        "pmm_base_delta": old_pmm_v - pmm_base,
        "kmain_bss_vma": bss,
        "pmmStore_off": pmm_off,
        "procStore_off": proc_off,
        "formula": "PMM BASE = kmain.o .bss VMA + pmmStore object offset; "
                   "FX0 = that VMA + procStore offset + procFxOffset; "
                   "CAP = procMax; first CR3/PD frames move by "
                   "(old USED - new USED) * 4096",
    }
    ok = (
        checks["pmm_base_match"]
        and checks["fx0_match"]
        and checks["cap_match"]
        and checks["slot10_present"]
        and checks["old_pmm_rejected"]
        and checks["old_cap_rejected"]
        and checks["old_fx_rejected"]
        and checks["old_slot10_absent"]
        and pmm_sz == pmm_store_bytes
        and proc_sz == proc_store_bytes
        and proc_max == 17
    )
    wrote = False
    if ok:
        open(EXPECTED, "w", encoding="latin-1").write(serial)
        if os.path.isfile(SCREEN_SRC):
            open(EXPECTED_SCREEN, "w", encoding="latin-1").write(
                open(SCREEN_SRC, encoding="latin-1", errors="replace").read())
        wrote = True
    dest = os.path.join(ART, "oscortex-round37-m11.json")
    os.makedirs(ART, exist_ok=True)
    payload = {
        "round": 37,
        "blind_regen": False,
        "updated_expected": wrote,
        "pass_derivation": ok,
        "checks": {k: (hex(v) if isinstance(v, int) and v > 32 else v)
                   for k, v in checks.items()},
    }
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
