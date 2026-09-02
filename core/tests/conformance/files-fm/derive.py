#!/usr/bin/env python3
"""core/tests/conformance/files-fm/derive.py

Host expectations for FILES.ELF. Plant names and bytes come from the
image the harness just wrote, not from files.c. Copy dest is the
source stem plus CPY; move dest is the second plant's stem plus MOV.
"""

import sys


def dest_name(name, ext):
    stem = name.split(".", 1)[0]
    if len(stem) > 8:
        raise SystemExit("derive: stem longer than 8: %r" % name)
    return stem + "." + ext


def main():
    if len(sys.argv) < 3:
        raise SystemExit(
            "usage: derive.py <plant-name> <plant-hex> [other-name] [other-hex] "
            "[move-name] [move-hex]")
    name = sys.argv[1].upper()
    hx = sys.argv[2].upper()
    other_name = sys.argv[3].upper() if len(sys.argv) > 3 else ""
    other_hex = sys.argv[4].upper() if len(sys.argv) > 4 else ""
    move_src = sys.argv[5].upper() if len(sys.argv) > 5 else ""
    move_hex = sys.argv[6].upper() if len(sys.argv) > 6 else ""
    plant = bytes.fromhex(hx)
    if len(plant) < 3:
        raise SystemExit("derive: plant shorter than 3 bytes")
    if name == "FILES.ELF":
        raise SystemExit("derive: plant name must not be FILES.ELF")
    if name == "GHOST.DAT":
        raise SystemExit("derive: plant name must not be the miss probe")
    if not name.endswith(".DAT"):
        raise SystemExit("derive: copy source must be a .DAT")
    print("plant_name=%s" % name)
    print("plant_hex=%s" % hx)
    print("name_line=FILES NAME %s" % name)
    print("self_line=FILES NAME FILES.ELF")
    if move_src:
        print("names_line=FILES NAMES 3")
    else:
        print("names_line=FILES NAMES 2")
    print("empty_names=FILES NAMES 1")
    print("cat_line=FILES CAT %s" % hx)
    print("cat_none=FILES CAT NONE")
    print("miss_line=FILES MISS GHOST.DAT")
    print("ready_line=FILES READY")
    print("list_line=FILES LIST")
    print("open_refused=FILES OPEN REFUSED")
    print("copy_none=FILES COPY NONE")
    print("move_none=FILES MOVE NONE")
    copy_dst = dest_name(name, "CPY")
    print("copy_name=%s" % copy_dst)
    print("copy_line=FILES COPY %s %s" % (copy_dst, hx))
    swatch = ((plant[0] << 16) | (plant[1] << 8) | plant[2]) & 0x00FFFFFF
    if swatch == 0:
        swatch = 0x00010101
    print("swatch=%06X" % swatch)
    if other_name:
        print("other_name=%s" % other_name)
        print("other_hex=%s" % other_hex)
        print("other_name_line=FILES NAME %s" % other_name)
        print("other_cat=FILES CAT %s" % other_hex)
        print("other_copy_name=%s" % dest_name(other_name, "CPY"))
        print("other_copy_line=FILES COPY %s %s" % (dest_name(other_name, "CPY"), other_hex))
        print("other_names=FILES NAMES 2")
    if move_src:
        if move_src in (name, "FILES.ELF", "GHOST.DAT"):
            raise SystemExit("derive: move source collided")
        if not move_src.endswith(".DAT"):
            raise SystemExit("derive: move source must be a .DAT")
        if not move_hex:
            raise SystemExit("derive: move source needs hex")
        move_dst = dest_name(move_src, "MOV")
        print("move_src=%s" % move_src)
        print("move_hex=%s" % move_hex)
        print("move_name=%s" % move_dst)
        print("move_src_line=FILES NAME %s" % move_src)
        print("move_line=FILES MOVE %s %s" % (move_dst, move_hex))


if __name__ == "__main__":
    main()
