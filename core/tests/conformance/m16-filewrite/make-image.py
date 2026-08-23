#!/usr/bin/env python3
"""core/tests/conformance/m16-filewrite/make-image.py

Writes the M16 test disk: a REAL FAT16 VOLUME WHOSE FREE SPACE IS DELIBERATELY
FRAGMENTED, so that a kernel which allocates clusters by counting rather than by
reading the FAT destroys a file that is already on the volume.

m15-fileio/make-image.py's machinery, with m15's geometry kept and its purpose
inverted: m15 scattered the file the guest READS, and M16 scatters the SPACE the
guest WRITES INTO. Copied rather than shared for m11-proc's reason — the
milestone that owns a harness owns its inputs.

THE ONE IDEA THIS VOLUME IS BUILT AROUND
---------------------------------------------------------------------------
KEEP.BIN occupies EVERY EVEN CLUSTER of a 600-cluster band, and every odd
cluster of the first part of that band is FREE. So the clusters this kernel's
allocator will hand to a new file are 3001, 3003, 3005, ... — and the clusters
BETWEEN them belong to a file that is already there and must still be there
afterwards.

  * A writer that allocated CONTIGUOUSLY from the first free cluster would
    overwrite KEEP.BIN's every other cluster.
  * A writer that updated only one copy of the FAT would leave a volume
    `fsck_msdos` reports as "FATs differ".
  * A writer that got the data-region arithmetic wrong by one cluster would
    write into KEEP.BIN and nowhere else.

Every one of those produces a volume whose FAT is self-consistent and whose new
file reads back correctly THROUGH THIS KERNEL. None of them survives
`fsck_msdos` and a byte-for-byte comparison of KEEP.BIN read back through
macOS's own `msdos` driver, which is why run.sh requires both.

THE FREE SET IS EXPORTED, NOT GUESSED
---------------------------------------------------------------------------
`--json` prints `free_clusters`: exactly which clusters are free, in order.
`derive.py` runs core/kernel/fat.dart's documented allocation policy — first
free at or after a hint, wrapping once — over that list and PREDICTS the chain
every file the guest writes will get. run.sh then reads the chain back out of
the image the guest wrote. Nothing about the allocator is observed and then
declared expected.

THE CHAIN THE GUEST GETS GOES BACKWARDS
---------------------------------------------------------------------------
The free band holds exactly twenty of the odd clusters NEW.BIN needs and NEW.BIN
needs twenty-two, so its chain runs 3005, 3007, ... 3043 and then WRAPS to the
low free clusters at 120 and 121. m15's DATA.BIN went backwards because this
script placed it there; NEW.BIN goes backwards because the ALLOCATOR ran off the
end of the free band, which is a property of the kernel rather than of the
image, and the self-check below refuses to write a volume where the arithmetic
does not produce one.

VARIANTS: DELIBERATELY DIFFICULT VOLUMES
---------------------------------------------------------------------------
    full        The free band is cut to five clusters -- ten once SEED.TXT is
                truncated -- so the guest's write runs out of disk part way
                through. The kernel must report a SHORT
                write and then FILE_ENOSPACE, and the volume must still be
                clean.
    dirfull     Every one of the 512 root-directory entries is in use, so
                creating a new file is refused with nothing changed.
    dirjunk     The entry AFTER the directory's end marker carries a live-looking
                short entry, `JUNK.BIN`. `fsck_msdos` never sees it, because a
                FAT directory ends at its first 0x00 slot -- but the moment the
                guest CONSUMES that slot, the junk becomes the directory's last
                entry unless the kernel re-establishes the marker. This variant
                exists because the mutation that removes `fatDirTerminate`
                SURVIVED the first mutation round without it (GAP-0129).
    seedcycle   SEED.TXT's cluster chain is a cycle, so opening it for WRITING
                is refused — and the volume must come back byte-for-byte
                identical, because a truncate that started before it noticed
                would have freed part of a chain it did not understand.

Usage:
    make-image.py <out.img> <prog.elf> <progn.elf> <verify.elf>
                  [--json] [--variant=NAME]

Exit status: 0 on success, 3 on a self-check failure.
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
DATA_SECTORS = 8400

ROOT_SECTORS = (ROOT_ENTRIES * 32) // BYTES_PER_SECTOR      # 32
FAT_START = RESERVED                                         # 1
ROOT_START = RESERVED + NUM_FATS * FAT_SECTORS               # 41
DATA_START = ROOT_START + ROOT_SECTORS                       # 73
TOTAL_SECTORS = DATA_START + DATA_SECTORS                    # 8473
CLUSTER_COUNT = DATA_SECTORS // SECTORS_PER_CLUSTER          # 4200
CLUSTER_BYTES = SECTORS_PER_CLUSTER * BYTES_PER_SECTOR       # 1024
FIRST_CLUSTER = 2
LAST_CLUSTER = CLUSTER_COUNT + FIRST_CLUSTER - 1             # 4201

MEDIA = 0xF8
FAT_EOC = 0xFFFF

# The band KEEP.BIN fragments, and the two runs of free clusters inside it.
BAND_LO = 3000
BAND_HI = 3600           # exclusive
FREE_ODD_HI = 3045       # exclusive: odd clusters 3001..3043 are free
FREE_LOW_LO = 120
FREE_LOW_HI = 169        # exclusive: 120..168 are free

SEED_BYTES = 5000
SEED_CLUSTERS = (3001, 3005, 3009, 3013, 3017)
KEEP_HEAD = b"M16KEEP\n"
SEED_HEAD = b"M16SEED\n"


def keep_bytes(n):
    """KEEP.BIN: every byte depends on its offset, so a single cluster written
    over it is visible in a byte-for-byte comparison AND in an FNV-1a hash."""
    b = bytearray((((i * 251) ^ (i >> 4) ^ ((i * i) >> 9) ^ 0x3C) & 0xFF)
                  for i in range(n))
    b[0:8] = KEEP_HEAD
    b[n - 8:n] = b"ENDKEEP\n"
    return bytes(b)


def seed_bytes(n):
    """SEED.TXT's ORIGINAL contents — the bytes the guest is about to destroy.

    They exist so that "the file was truncated" is a statement the host can
    check: after the boot, not one of these bytes may be readable through
    SEED.TXT, and the clusters that held them must be free or reused."""
    b = bytearray((((i * 97) + (i >> 2) + 0x11) & 0xFF) for i in range(n))
    b[0:8] = SEED_HEAD
    return bytes(b)


def fill_bytes(n):
    return bytes(((i * 7) ^ 0xC3) & 0xFF for i in range(n))


def sector_pattern(s):
    """m6-disk's background pattern: depends on the sector AND the offset.

    On THIS volume it does a second job. Every free cluster starts out holding
    it, so a file the guest writes that came back with any of these bytes in it
    would be a file whose slack the kernel failed to define — and run.sh
    requires the sector-pattern marker string never to appear inside NEW.BIN."""
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


def lfn_checksum(raw11):
    s = 0
    for c in raw11:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def lfn_entries(long_name, checksum):
    units = long_name.encode("utf-16-le") + b"\x00\x00"
    per = 26
    chunks = [units[i:i + per] for i in range(0, len(units), per)]
    chunks[-1] = chunks[-1] + b"\xFF" * (per - len(chunks[-1]))
    out = []
    for i, chunk in enumerate(reversed(chunks)):
        seq = len(chunks) - i
        b = bytearray(32)
        b[0] = seq | (0x40 if i == 0 else 0)
        b[1:11] = chunk[0:10]
        b[11] = 0x0F
        b[12] = 0
        b[13] = checksum
        b[14:26] = chunk[10:22]
        b[26:28] = b"\x00\x00"
        b[28:32] = chunk[22:26]
        out.append(bytes(b))
    return out


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
    struct.pack_into("<I", b, 28, 0)
    struct.pack_into("<I", b, 32, 0)
    b[36] = 0x80
    b[38] = 0x29
    struct.pack_into("<I", b, 39, 0x16C0FFEE)
    b[43:54] = b"OSCORTEX   "
    b[54:62] = b"FAT16   "
    b[510:512] = b"\x55\xAA"
    return bytes(b)


VARIANTS = ("full", "dirfull", "seedcycle", "dirjunk")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    variant = None
    for a in sys.argv[1:]:
        if a.startswith("--variant="):
            variant = a.split("=", 1)[1]
    if variant is not None and variant not in VARIANTS:
        raise SystemExit("make-image: unknown variant %r (have %s)"
                         % (variant, ", ".join(VARIANTS)))
    if len(args) != 4:
        raise SystemExit("usage: make-image.py <out.img> <prog.elf> <progn.elf> "
                         "<verify.elf>")
    out, p_path, n_path, v_path = args

    progs = {
        "PROG.ELF": open(p_path, "rb").read(),
        "PROGN.ELF": open(n_path, "rb").read(),
        "VERIFY.ELF": open(v_path, "rb").read(),
    }
    if progs["PROG.ELF"] == progs["PROGN.ELF"]:
        raise SystemExit("make-image: the real program and its negative control are "
                         "byte-identical; the control controls for nothing")

    def need(blob):
        return max(1, (len(blob) + CLUSTER_BYTES - 1) // CLUSTER_BYTES)

    # ---- cluster allocation --------------------------------------------
    # The three programs take the low clusters, interleaved with each other so
    # that `run PROG.ELF` is still a statement about following a chain, and so
    # that the free low run (FREE_LOW_LO..FREE_LOW_HI-1) begins above all three.
    taken = set()
    chains = {}
    c = FIRST_CLUSTER
    for name in ("PROG.ELF", "PROGN.ELF", "VERIFY.ELF"):
        chain = []
        step = 3
        while len(chain) < need(progs[name]):
            if c >= FREE_LOW_LO:
                raise SystemExit("make-image: the three programs no longer fit below "
                                 "cluster %d; the free low run has to move" % FREE_LOW_LO)
            if c not in taken:
                chain.append(c)
                taken.add(c)
            c += step
        chains[name] = chain
        c = FIRST_CLUSTER + len(chains)   # start the next one one cluster along
    if max(max(v) for v in chains.values()) >= FREE_LOW_LO:
        raise SystemExit("make-image: a program chain reached the free low run")

    # KEEP.BIN: every EVEN cluster of the band. This is the file the fragmented
    # free space is made of, and it is the file a wrong allocator destroys.
    keep_chain = [k for k in range(BAND_LO, BAND_HI) if k % 2 == 0]
    for k in keep_chain:
        taken.add(k)
    chains["KEEP.BIN"] = keep_chain

    # SEED.TXT: five ODD clusters of the band, spread out, so that truncating it
    # frees a chain that is not a run.
    for k in SEED_CLUSTERS:
        if k % 2 != 1 or not (BAND_LO < k < FREE_ODD_HI):
            raise SystemExit("make-image: SEED.TXT cluster %d is not a free-band odd "
                             "cluster" % k)
        taken.add(k)
    chains["SEED.TXT"] = list(SEED_CLUSTERS)

    # Everything the guest is allowed to allocate.
    free = [k for k in range(BAND_LO + 1, FREE_ODD_HI) if k % 2 == 1]
    free += list(range(FREE_LOW_LO, FREE_LOW_HI))
    free = sorted(set(free) - taken)
    if variant == "full":
        # The low run goes entirely and the band is cut to five clusters: enough
        # for SEED.TXT's rewrite and part of NEW.BIN, and not enough for the
        # whole of it. There is no wrap to be had either, which is deliberate —
        # this variant is about running out, not about running round.
        free = [k for k in free if BAND_LO < k < BAND_LO + 20]
    # SEED.TXT's own clusters become free the moment the guest truncates it, so
    # they belong to the guest's pool too even though they are `taken` now.
    free_after_truncate = sorted(set(free) | set(SEED_CLUSTERS))

    # FILL.BIN takes every cluster that is neither in use nor deliberately free,
    # so the volume has no accidental space anywhere.
    fill_chain = [k for k in range(FIRST_CLUSTER, LAST_CLUSTER + 1)
                  if k not in taken and k not in set(free)]
    # SUB is a real subdirectory, so that create("SUB") being refused with
    # EISDIR is produced by a boot rather than asserted. It takes a cluster off
    # the end of FILL.BIN's run rather than out of the free pool.
    subdir_cluster = fill_chain[-1]
    fill_chain = fill_chain[:-1]
    chains["FILL.BIN"] = fill_chain

    blobs = dict(progs)
    blobs["KEEP.BIN"] = keep_bytes(len(keep_chain) * CLUSTER_BYTES)
    blobs["SEED.TXT"] = seed_bytes(SEED_BYTES)
    blobs["FILL.BIN"] = fill_bytes(len(fill_chain) * CLUSTER_BYTES)

    for name, chain in chains.items():
        if len(chain) != len(set(chain)):
            raise SystemExit("make-image: %s's chain repeats a cluster" % name)
        if need(blobs[name]) != len(chain):
            raise SystemExit("make-image: %s is %d bytes but has %d clusters"
                             % (name, len(blobs[name]), len(chain)))

    # ---- the image -----------------------------------------------------
    img = bytearray()
    for s in range(TOTAL_SECTORS):
        img += sector_pattern(s)
    img[0:SECTOR] = boot_sector()

    fat = bytearray(FAT_SECTORS * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFF00 | MEDIA)
    struct.pack_into("<H", fat, 2, FAT_EOC)
    for name, chain in chains.items():
        for i, k in enumerate(chain):
            nxt = chain[i + 1] if i + 1 < len(chain) else FAT_EOC
            struct.pack_into("<H", fat, k * 2, nxt)
    struct.pack_into("<H", fat, subdir_cluster * 2, FAT_EOC)
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR
        img[at:at + len(fat)] = fat

    # ---- the root directory --------------------------------------------
    root = bytearray()
    entry_offsets = {}
    entry_index = {}

    def add(name, attr, first, size, raw=None):
        entry_offsets[name] = ROOT_START * SECTOR + len(root)
        entry_index[name] = len(root) // 32
        root.extend(dir_entry(raw if raw is not None else eightthree(name),
                              attr, first, size))

    add("OSCORTEX", 0x08, 0, 0, raw=b"OSCORTEX   ")
    add("PROG.ELF", 0x20, chains["PROG.ELF"][0], len(blobs["PROG.ELF"]))
    add("PROGN.ELF", 0x20, chains["PROGN.ELF"][0], len(blobs["PROGN.ELF"]))
    add("VERIFY.ELF", 0x20, chains["VERIFY.ELF"][0], len(blobs["VERIFY.ELF"]))
    # A deleted entry, exactly where a newly created file would like to go: this
    # is what makes "the allocator reuses a 0xE5 slot" a thing the boot does
    # rather than a branch nothing takes.
    ghost = bytearray(dir_entry(eightthree("GHOST.BIN"), 0x20,
                                chains["KEEP.BIN"][0], 4096))
    ghost[0] = 0xE5
    entry_index["GHOST.BIN"] = len(root) // 32
    root += bytes(ghost)
    b11 = eightthree("KEEP.BIN")
    for e in lfn_entries("keep-this-file-exactly-as-it-is.bin", lfn_checksum(b11)):
        root += e
    add("KEEP.BIN", 0x20, chains["KEEP.BIN"][0], len(blobs["KEEP.BIN"]))
    add("SEED.TXT", 0x20, chains["SEED.TXT"][0], len(blobs["SEED.TXT"]))
    add("FILL.BIN", 0x20, chains["FILL.BIN"][0], len(blobs["FILL.BIN"]))
    # A real, legal, zero-length file. M15 proved this kernel refuses to OPEN
    # one; M16 opens it for WRITING, which must work, because a zero-length file
    # is exactly the state `create` leaves a new one in.
    add("EMPTY.TXT", 0x20, 0, 0)
    add("SUB", 0x10, subdir_cluster, 0)
    used_entries = len(root) // 32
    if variant == "dirjunk":
        # One entry PAST the end marker. Everything up to `used_entries` is live,
        # slot `used_entries` is the 0x00 that ends the directory, and this is
        # slot `used_entries + 1`. First cluster 0 and size 0, so that if a
        # reader ever did walk into it, it is a legal zero-length file rather
        # than a cross-link -- the point is that NOTHING should ever see it.
        root += b"\x00" * 32
        root += dir_entry(eightthree("JUNK.BIN"), 0x20, 0, 0)
    if variant == "dirfull":
        # The deleted GHOST.BIN entry is REUSABLE, so a directory that is "full"
        # while it is still there is not full. It is made live here, which is
        # the whole difference between this variant and the base volume as far
        # as `fatDirFreeSlot` is concerned.
        # First cluster 0 and size 0, not the ones the tombstone carried: a
        # LIVE entry pointing at KEEP.BIN's chain would be a cross-link, which
        # `fsck_msdos` rightly refuses, and this variant is supposed to be a
        # clean volume with a full directory rather than a broken one.
        gi = entry_index["GHOST.BIN"]
        root[gi * 32:(gi + 1) * 32] = dir_entry(eightthree("GHOST.BIN"), 0x20, 0, 0)
        while len(root) < ROOT_ENTRIES * 32:
            add("PAD%04d.PAD" % (len(root) // 32), 0x20, 0, 0,
                raw=eightthree("PAD%04d.PAD" % (len(root) // 32)))
    root += b"\x00" * (ROOT_ENTRIES * 32 - len(root))
    if len(root) != ROOT_ENTRIES * 32:
        raise SystemExit("make-image: the root directory overflowed")
    img[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR] = root

    def cluster_at(k):
        return (DATA_START + (k - FIRST_CLUSTER) * SECTORS_PER_CLUSTER) * SECTOR

    sub = bytearray(CLUSTER_BYTES)
    sub[0:32] = dir_entry(b".          ", 0x10, subdir_cluster, 0)
    sub[32:64] = dir_entry(b"..         ", 0x10, 0, 0)
    img[cluster_at(subdir_cluster):cluster_at(subdir_cluster) + CLUSTER_BYTES] = sub

    for name, chain in chains.items():
        blob = blobs[name]
        for i, k in enumerate(chain):
            piece = blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
            piece = piece + b"\0" * (CLUSTER_BYTES - len(piece))
            img[cluster_at(k):cluster_at(k) + CLUSTER_BYTES] = piece

    broke = None
    if variant == "seedcycle":
        chain = chains["SEED.TXT"]
        for n in range(NUM_FATS):
            at = (FAT_START + n * FAT_SECTORS) * SECTOR
            struct.pack_into("<H", img, at + chain[3] * 2, chain[0])
        broke = ("SEED.TXT's chain loops from its fourth cluster back to its "
                 "first, so a walk repeats a cluster it has already seen")
    elif variant == "dirfull":
        broke = ("every one of the %d root-directory entries is in use, so there "
                 "is nowhere to create a file" % ROOT_ENTRIES)
    elif variant == "full":
        broke = ("only %d clusters are free on the whole volume, %d once SEED.TXT "
                 "is truncated" % (len(free), len(free_after_truncate)))
    elif variant == "dirjunk":
        broke = ("a live-looking JUNK.BIN entry sits one slot PAST the "
                 "directory's end marker, at entry %d" % (used_entries + 1))

    with open(out, "wb") as f:
        f.write(bytes(img))

    # ---- self-check ----------------------------------------------------
    backimg = open(out, "rb").read()
    if len(backimg) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(backimg), TOTAL_SECTORS * SECTOR))
    fat_back = backimg[FAT_START * SECTOR:(FAT_START + FAT_SECTORS) * SECTOR]
    fat_back2 = backimg[(FAT_START + FAT_SECTORS) * SECTOR:
                        (FAT_START + 2 * FAT_SECTORS) * SECTOR]
    if fat_back != fat_back2:
        raise SystemExit("make-image: the two FAT copies differ before the guest "
                         "has even booted")
    if variant is None:
        free_seen = [k for k in range(FIRST_CLUSTER, LAST_CLUSTER + 1)
                     if struct.unpack_from("<H", fat_back, k * 2)[0] == 0]
        if free_seen != free:
            raise SystemExit("make-image: the FAT says %d clusters are free and this "
                             "script meant %d" % (len(free_seen), len(free)))
        # The property the whole volume exists for: every free cluster in the
        # band has a KEEP.BIN cluster on at least one side of it.
        # The band's free set AT WRITE TIME includes SEED.TXT's clusters, which
        # the guest frees before it allocates anything.
        band_free = [k for k in free_after_truncate if BAND_LO < k < BAND_HI]
        for k in band_free:
            if (k - 1) not in set(keep_chain) and (k + 1) not in set(keep_chain):
                raise SystemExit("make-image: free cluster %d in the band has no "
                                 "KEEP.BIN cluster beside it, so a contiguous "
                                 "writer would not be caught there" % k)
        if len(band_free) < 20:
            raise SystemExit("make-image: only %d free clusters in the band; the "
                             "wrap this volume exists to force will not happen"
                             % len(band_free))

    layout = {
        "bytes_per_sector": BYTES_PER_SECTOR,
        "sectors_per_cluster": SECTORS_PER_CLUSTER,
        "reserved": RESERVED, "num_fats": NUM_FATS, "fat_sectors": FAT_SECTORS,
        "root_entries": ROOT_ENTRIES, "total_sectors": TOTAL_SECTORS,
        "fat_start": FAT_START, "root_start": ROOT_START,
        "root_sectors": ROOT_SECTORS, "data_start": DATA_START,
        "cluster_count": CLUSTER_COUNT, "cluster_bytes": CLUSTER_BYTES,
        "media": MEDIA, "first_cluster": FIRST_CLUSTER,
        "last_cluster": LAST_CLUSTER,
        "subdir_cluster": subdir_cluster,
        "free_clusters": free,
        "free_after_truncate": free_after_truncate,
        "seed_clusters": list(SEED_CLUSTERS),
        "seed_bytes": SEED_BYTES,
        "used_entries": used_entries,
        "junk_entry": (used_entries + 1) if variant == "dirjunk" else None,
        "ghost_entry": entry_index["GHOST.BIN"],
        "variant": variant, "broke": broke,
        "files": {},
    }
    for name, chain in sorted(chains.items()):
        layout["files"][name] = {
            "chain": chain, "bytes": len(blobs[name]), "clusters": len(chain),
        }

    outdir = os.path.dirname(os.path.abspath(out)) or "."
    base = os.path.basename(out)
    open(os.path.join(outdir, base + ".keep"), "wb").write(blobs["KEEP.BIN"])
    open(os.path.join(outdir, base + ".seed"), "wb").write(blobs["SEED.TXT"])

    if want_json:
        print(json.dumps(layout))
    elif variant is not None:
        print("make-image: %s — VARIANT %s: %s" % (base, variant, broke))
    else:
        print("make-image: %s — %d sectors, %d clusters; KEEP.BIN %d bytes on %d "
              "clusters (every even cluster of %d..%d); SEED.TXT %d bytes on %s; "
              "%d clusters free now and %d once SEED.TXT is truncated, %d of "
              "those inside the band"
              % (base, TOTAL_SECTORS, CLUSTER_COUNT, len(blobs["KEEP.BIN"]),
                 len(keep_chain), BAND_LO, BAND_HI - 1, SEED_BYTES,
                 list(SEED_CLUSTERS), len(free), len(free_after_truncate),
                 len([k for k in free_after_truncate if BAND_LO < k < BAND_HI])))


if __name__ == "__main__":
    main()
