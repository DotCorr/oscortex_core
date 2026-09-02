#!/usr/bin/env python3
"""core/tests/conformance/frame1/derive.py

Host-side expectations for ABITST.ELF: magic, version, length and FNV-1a
of the planted FRAME.H bytes. Nothing is read back out of the kernel.
"""

import os
import re
import sys

FNV_INIT = 0x811C9DC5
FNV_PRIME = 16777619


def fnv1a(b):
    h = FNV_INIT
    for c in b:
        h ^= c
        h = (h * FNV_PRIME) & 0xFFFFFFFF
    return h


def parse_header(path):
    text = open(path, "r", encoding="utf-8").read()
    m = re.search(r"^/\* OSFRAME (\d+)", text, re.M)
    if not m:
        raise SystemExit("derive: no /* OSFRAME <ver> on the first line of %s" % path)
    magic = re.search(r"^#define OSFRAME_MAGIC (0x[0-9A-Fa-f]+)UL", text, re.M)
    ver = re.search(r"^#define OSFRAME_VERSION (\d+)", text, re.M)
    if not magic or not ver:
        raise SystemExit("derive: OSFRAME_MAGIC / OSFRAME_VERSION missing")
    rows = re.findall(r"^#define SYS_([A-Z0-9_]+) (\d+)\s*$", text, re.M)
    return {
        "tag_ver": int(m.group(1)),
        "magic": int(magic.group(1), 0),
        "version": int(ver.group(1)),
        "rows": rows,
        "text": text,
        "bytes": text.encode("utf-8"),
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: derive.py <osframe.h> <planted.frame>")
    hdr_path, planted_path = sys.argv[1:3]
    hdr = parse_header(hdr_path)
    planted = open(planted_path, "rb").read()
    if hdr["tag_ver"] != hdr["version"]:
        raise SystemExit("derive: first-line OSFRAME %d != OSFRAME_VERSION %d"
                         % (hdr["tag_ver"], hdr["version"]))
    names = {n.lower() for n, _ in hdr["rows"]}
    need = {"exit", "write", "yield", "sbrk", "open", "read", "close", "seek",
            "fdwrite", "shmcreate", "shmgrant", "shmmap", "shmdrop",
            "mouse", "wmsurface", "kbdevent", "wmevent"}
    missing = sorted(need - names)
    if missing:
        raise SystemExit("derive: osframe.h is missing SYS_* for %s" % missing)
    if len(set(int(n) for _, n in hdr["rows"])) < 2:
        raise SystemExit("derive: fewer than two distinct syscall numbers")

    out = {}
    out["magic"] = hdr["magic"]
    out["version"] = hdr["version"]
    out["len"] = len(planted)
    out["fnv"] = fnv1a(planted)
    out["exit"] = (out["fnv"] ^ out["len"]) & 0xFF
    out["sys_rows"] = len(hdr["rows"])
    # Truncated plant: one fewer SYS_ row, different hash.
    trunc_text = planted.decode("utf-8")
    # If this sidecar is already truncated, still report its own hash.
    out["planted_is_full"] = 1 if planted == hdr["bytes"] else 0

    for k in sorted(out):
        v = out[k]
        if isinstance(v, int):
            print("%s=%d" % (k, v))
        else:
            print("%s=%s" % (k, v))
    print("magic_hex=%08x" % out["magic"])
    print("len_hex=%08x" % out["len"])
    print("fnv_hex=%08x" % out["fnv"])
    print("line=FRAME1 MAGIC %08x VER %d TAG 1 FILEVER %d LEN %08x FNV %08x"
          % (out["magic"], out["version"], out["version"], out["len"], out["fnv"]))


if __name__ == "__main__":
    main()
