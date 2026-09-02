#!/usr/bin/env python3
"""core/tests/conformance/files-fm/make-image.py

FAT16 volume for the FILES file manager, or a raw OSCXPRG1 image for
the no-FAT negative.

    make-image.py <out.img> <files.elf> [--json]
        [--variant=full|empty|raw] [--plant-name=NAME] [--plant-hex=HEX]
        [--plant2-name=NAME] [--plant2-hex=HEX]

    make-image.py --extract=NAME <img>

    full:  FILES.ELF + derived plant(s) + deleted GHOST.DAT + volume label
    empty: FILES.ELF only
    raw:   OSCXPRG1 header so `proc spawn <lba>` works; not a FAT volume
"""

import json
import os
import struct
import sys

SECTOR = 512
BYTES_PER_SECTOR = 512
SECTORS_PER_CLUSTER = 2
RESERVED = 1
NUM_FATS = 2
FAT_SECTORS = 20
ROOT_ENTRIES = 512
DATA_SECTORS = 10000
ROOT_SECTORS = (ROOT_ENTRIES * 32) // BYTES_PER_SECTOR
FAT_START = RESERVED
ROOT_START = RESERVED + NUM_FATS * FAT_SECTORS
DATA_START = ROOT_START + ROOT_SECTORS
TOTAL_SECTORS = DATA_START + DATA_SECTORS
CLUSTER_COUNT = DATA_SECTORS // SECTORS_PER_CLUSTER
CLUSTER_BYTES = SECTORS_PER_CLUSTER * BYTES_PER_SECTOR
MEDIA = 0xF8
FAT_EOC = 0xFFFF
MAGIC = b"OSCXPRG1"
RAW_HDR_LBA = 0x20


def sector_pattern(s):
    b = bytearray((31 * s + 7 * i + 0x21) & 0xFF for i in range(SECTOR))
    label = ("OSCORTEX SECTOR %04X" % (s & 0xFFFF)).encode("ascii")
    b[0:len(label)] = label
    return bytes(b)


def eightthree(name):
    if "." in name:
        stem, ext = name.split(".", 1)
    else:
        stem, ext = name, ""
    if len(stem) > 8 or len(ext) > 3:
        raise SystemExit("make-image: %r is not an 8.3 name" % name)
    return (stem.ljust(8) + ext.ljust(3)).upper().encode("ascii")


def dir_entry(raw11, attr, first_cluster, size):
    e = bytearray(32)
    e[0:11] = raw11
    e[11] = attr
    struct.pack_into("<H", e, 26, first_cluster)
    struct.pack_into("<I", e, 28, size)
    struct.pack_into("<H", e, 22, 0)
    struct.pack_into("<H", e, 24, ((2026 - 1980) << 9) | (1 << 5) | 1)
    struct.pack_into("<H", e, 18, ((2026 - 1980) << 9) | (1 << 5) | 1)
    return bytes(e)


def boot_sector():
    b = bytearray(SECTOR)
    b[0:3] = b"\xEB\x3C\x90"
    b[3:11] = b"OSCORTEX"
    struct.pack_into("<H", b, 11, BYTES_PER_SECTOR)
    b[13] = SECTORS_PER_CLUSTER
    struct.pack_into("<H", b, 14, RESERVED)
    b[16] = NUM_FATS
    struct.pack_into("<H", b, 17, ROOT_ENTRIES)
    struct.pack_into("<H", b, 19, TOTAL_SECTORS)
    b[21] = MEDIA
    struct.pack_into("<H", b, 22, FAT_SECTORS)
    struct.pack_into("<H", b, 24, 63)
    struct.pack_into("<H", b, 26, 16)
    b[36] = 0x80
    b[38] = 0x29
    struct.pack_into("<I", b, 39, 0x05C0FFEE)
    b[43:54] = b"OSCORTEX   "
    b[54:62] = b"FAT16   "
    b[510:512] = b"\x55\xAA"
    return bytes(b)


def cluster_at(cl):
    return (DATA_START + (cl - 2) * SECTORS_PER_CLUSTER) * SECTOR


def extract_file(img_path, name):
    data = open(img_path, "rb").read()
    raw11 = eightthree(name)
    root = data[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR]
    fat = data[FAT_START * SECTOR:FAT_START * SECTOR + FAT_SECTORS * SECTOR]
    for i in range(ROOT_ENTRIES):
        e = root[i * 32:(i + 1) * 32]
        if e[0] in (0x00, 0xE5):
            continue
        if e[11] & 0x08:
            continue
        if e[0:11] != raw11:
            continue
        cluster = struct.unpack_from("<H", e, 26)[0]
        size = struct.unpack_from("<I", e, 28)[0]
        blob = b""
        cl = cluster
        seen = set()
        while cl >= 2 and cl < 0xFFF8 and cl not in seen and len(blob) < size:
            seen.add(cl)
            off = cluster_at(cl)
            blob += data[off:off + CLUSTER_BYTES]
            cl = struct.unpack_from("<H", fat, cl * 2)[0]
        return blob[:size]
    return None


def write_raw(out, elf):
    blob = open(elf, "rb").read()
    sectors = 512
    img = bytearray()
    for s in range(sectors):
        img += sector_pattern(s)
    hdr_lba = RAW_HDR_LBA
    image_lba = hdr_lba + 1
    nsec = (len(blob) + SECTOR - 1) // SECTOR
    header = bytearray(SECTOR)
    header[0:8] = MAGIC
    header[8:16] = len(blob).to_bytes(8, "little")
    header[16:24] = image_lba.to_bytes(8, "little")
    img[hdr_lba * SECTOR:(hdr_lba + 1) * SECTOR] = header
    padded = blob + b"\x00" * (nsec * SECTOR - len(blob))
    img[image_lba * SECTOR:(image_lba + nsec) * SECTOR] = padded
    with open(out, "wb") as f:
        f.write(bytes(img))
    return {
        "variant": "raw",
        "header_lba": hdr_lba,
        "files": {"FILES.ELF": {"bytes": len(blob)}},
    }


def main():
    extract_name = None
    for a in sys.argv[1:]:
        if a.startswith("--extract="):
            extract_name = a.split("=", 1)[1]
    if extract_name:
        img = None
        for a in sys.argv[1:]:
            if not a.startswith("--"):
                img = a
                break
        if not img:
            raise SystemExit("usage: make-image.py --extract=NAME <img>")
        blob = extract_file(img, extract_name)
        if blob is None:
            raise SystemExit("make-image: %s is not on %s" % (extract_name, img))
        print(blob.hex().upper())
        return

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    variant = "full"
    plant_name = None
    plant_hex = None
    plant2_name = None
    plant2_hex = None
    for a in sys.argv[1:]:
        if a.startswith("--variant="):
            variant = a.split("=", 1)[1]
        elif a.startswith("--plant-name="):
            plant_name = a.split("=", 1)[1]
        elif a.startswith("--plant-hex="):
            plant_hex = a.split("=", 1)[1]
        elif a.startswith("--plant2-name="):
            plant2_name = a.split("=", 1)[1]
        elif a.startswith("--plant2-hex="):
            plant2_hex = a.split("=", 1)[1]
    if len(args) != 2:
        raise SystemExit(
            "usage: make-image.py <out.img> <files.elf> [--variant=full|empty|raw]")
    out, elf = args
    if variant not in ("full", "empty", "raw"):
        raise SystemExit("make-image: unknown variant %r" % variant)

    if variant == "raw":
        layout = write_raw(out, elf)
        if want_json:
            print(json.dumps(layout))
        else:
            print("make-image: %s — raw OSCXPRG1 FILES.ELF %d"
                  % (os.path.basename(out), layout["files"]["FILES.ELF"]["bytes"]))
        return

    blobs = {"FILES.ELF": open(elf, "rb").read()}
    if variant == "full":
        if not plant_name or not plant_hex:
            raise SystemExit("make-image: full variant needs --plant-name and --plant-hex")
        plant = bytes.fromhex(plant_hex)
        if len(plant) < 3:
            raise SystemExit("make-image: plant must be at least 3 bytes")
        blobs[plant_name.upper()] = plant
        if plant2_name or plant2_hex:
            if not plant2_name or not plant2_hex:
                raise SystemExit("make-image: plant2 needs both --plant2-name and --plant2-hex")
            plant2 = bytes.fromhex(plant2_hex)
            if len(plant2) < 3:
                raise SystemExit("make-image: plant2 must be at least 3 bytes")
            if plant2_name.upper() == plant_name.upper():
                raise SystemExit("make-image: plant2 name collides with plant")
            blobs[plant2_name.upper()] = plant2

    taken = set()
    chains = {}
    c = 2
    order = ["FILES.ELF"]
    if variant == "full":
        order.append(plant_name.upper())
        if plant2_name:
            order.append(plant2_name.upper())
    for name in order:
        need = max(1, (len(blobs[name]) + CLUSTER_BYTES - 1) // CLUSTER_BYTES)
        chain = []
        while len(chain) < need:
            if c >= CLUSTER_COUNT + 2:
                raise SystemExit("make-image: ran out of clusters placing %s" % name)
            if c not in taken:
                chain.append(c)
                taken.add(c)
            c += 1
        chains[name] = chain

    img = bytearray()
    for s in range(TOTAL_SECTORS):
        img += sector_pattern(s)
    img[0:SECTOR] = boot_sector()

    fat = bytearray(FAT_SECTORS * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFF00 | MEDIA)
    struct.pack_into("<H", fat, 2, FAT_EOC)
    for name, chain in chains.items():
        for i, cl in enumerate(chain):
            nxt = chain[i + 1] if i + 1 < len(chain) else FAT_EOC
            struct.pack_into("<H", fat, cl * 2, nxt)
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR
        img[at:at + len(fat)] = fat

    root = bytearray()

    def add(raw11, attr, first, size):
        root.extend(dir_entry(raw11, attr, first, size))

    add(b"OSCORTEX   ", 0x08, 0, 0)
    add(eightthree("FILES.ELF"), 0x20, chains["FILES.ELF"][0],
        len(blobs["FILES.ELF"]))
    if variant == "full":
        add(eightthree(plant_name), 0x20, chains[plant_name.upper()][0],
            len(blobs[plant_name.upper()]))
        if plant2_name:
            add(eightthree(plant2_name), 0x20, chains[plant2_name.upper()][0],
                len(blobs[plant2_name.upper()]))
        ghost = bytearray(dir_entry(eightthree("GHOST.DAT"), 0x20, 2, 16))
        ghost[0] = 0xE5
        root.extend(ghost)
    root += b"\x00" * (ROOT_ENTRIES * 32 - len(root))
    img[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR] = root

    for name, chain in chains.items():
        blob = blobs[name]
        for i, cl in enumerate(chain):
            piece = blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
            piece = piece + b"\0" * (CLUSTER_BYTES - len(piece))
            img[cluster_at(cl):cluster_at(cl) + CLUSTER_BYTES] = piece

    with open(out, "wb") as f:
        f.write(bytes(img))

    back = open(out, "rb").read()
    if len(back) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(back), TOTAL_SECTORS * SECTOR))
    for name, chain in chains.items():
        joined = b"".join(back[cluster_at(cl):cluster_at(cl) + CLUSTER_BYTES]
                          for cl in chain)
        if joined[:len(blobs[name])] != blobs[name]:
            raise SystemExit("make-image: %s does not read back" % name)

    layout = {
        "variant": variant,
        "files": {n: {"bytes": len(blobs[n]), "clusters": len(chains[n])}
                  for n in blobs},
    }
    if variant == "full":
        layout["plant_name"] = plant_name.upper()
        layout["plant_hex"] = plant_hex.upper()
        if plant2_name:
            layout["plant2_name"] = plant2_name.upper()
            layout["plant2_hex"] = plant2_hex.upper()
    if want_json:
        print(json.dumps(layout))
    else:
        extra = ""
        if variant == "full":
            extra = " plant %s %s" % (plant_name.upper(), plant_hex.upper())
        print("make-image: %s — FILES.ELF %d%s"
              % (os.path.basename(out), len(blobs["FILES.ELF"]), extra))


if __name__ == "__main__":
    main()
