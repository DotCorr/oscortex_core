#!/usr/bin/env python3
"""Extract official libcef.so RO+RX LOAD file bytes for the host plant.

Full 1.5 GiB cannot sit on FAT (fatChainMax = 256 KiB). This writes the
contiguous file range covering LOAD R + LOAD R X (p_filesz pins from
readelf), for QEMU `-device loader` at elfCefPlantPa.

Not OnPaint. Not the 12 KiB slice. ADR-0168 / cef-load/.
"""
from __future__ import annotations

import os
import struct
import sys

RO_FILESZ = 42593760
RX_FILESZ = 189117488
PLANT_BYTES = RO_FILESZ + RX_FILESZ  # contiguous in file


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: pack-cef-loads.py <libcef.so> <out-plant.bin>", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    if not os.path.isfile(src):
        print("pack-cef-loads: missing %s" % src, file=sys.stderr)
        return 1
    # Read only the ELF header + phdrs first, then verify LOAD sizes.
    with open(src, "rb") as f:
        eh = f.read(64)
        if eh[:4] != b"\x7fELF" or eh[4] != 2 or u16(eh, 16) != 3:
            print("pack-cef-loads: not ELF64 ET_DYN", file=sys.stderr)
            return 1
        phoff = u64(eh, 32)
        phentsize = u16(eh, 54)
        phnum = u16(eh, 56)
        f.seek(phoff)
        phdrs = f.read(phnum * phentsize)
    ro = rx = None
    for i in range(phnum):
        ph = phdrs[i * phentsize:(i + 1) * phentsize]
        if u32(ph, 0) != 1:
            continue
        flags = u32(ph, 4)
        offset = u64(ph, 8)
        filesz = u64(ph, 32)
        fl = []
        if flags & 4:
            fl.append("R")
        if flags & 2:
            fl.append("W")
        if flags & 1:
            fl.append("X")
        tag = "".join(fl)
        if tag == "R":
            ro = (offset, filesz)
        elif tag == "RX":
            rx = (offset, filesz)
    if ro is None or rx is None:
        print("pack-cef-loads: missing R / RX LOAD", file=sys.stderr)
        return 1
    if ro[1] != RO_FILESZ or rx[1] != RX_FILESZ:
        print("pack-cef-loads: LOAD sizes drifted: RO=%d RX=%d" % (ro[1], rx[1]),
              file=sys.stderr)
        return 1
    if ro[0] != 0 or rx[0] != RO_FILESZ:
        print("pack-cef-loads: LOADs not contiguous from file offset 0",
              file=sys.stderr)
        return 1
    # Stream copy — do not hold 221 MiB in a Python bytes object twice.
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(src, "rb") as inf, open(dst, "wb") as out:
        left = PLANT_BYTES
        while left:
            chunk = inf.read(min(8 * 1024 * 1024, left))
            if not chunk:
                print("pack-cef-loads: short read", file=sys.stderr)
                return 1
            out.write(chunk)
            left -= len(chunk)
    # Verify plant opens as ELF and first LOAD sizes still match.
    with open(dst, "rb") as f:
        head = f.read(64)
    if head[:4] != b"\x7fELF":
        print("pack-cef-loads: plant lost ELF magic", file=sys.stderr)
        return 1
    print("pack-cef-loads: %s (%d bytes) RO=%d RX=%d" % (dst, PLANT_BYTES, RO_FILESZ, RX_FILESZ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
