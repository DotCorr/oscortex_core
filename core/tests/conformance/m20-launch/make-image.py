#!/usr/bin/env python3
"""core/tests/conformance/m19-argv/make-image.py

Writes the M19 test disk: a REAL FAT16 VOLUME carrying one `wc` built twice and
TWO TEXT FILES WHOSE COUNTS DIFFER IN ALL THREE COLUMNS.

m15-fileio/make-image.py's geometry EXACTLY -- 512-byte sectors, 2 sectors per
cluster, 1 reserved, 2 FATs of 20 sectors, 512 root entries, 10000 data sectors,
5000 clusters -- copied rather than shared for m11-proc's reason: the milestone
that owns a harness owns its inputs, and an image generator edited for one
milestone must not silently relayout another's volume. `fsck_msdos` and macOS's
own `msdos` driver are required to accept what comes out, exactly as at M14.

WHAT IS DIFFERENT FROM M15, AND WHY
---------------------------------------------------------------------------
M15 proved a program can read A file. M19 proves a program can be TOLD WHICH
file, so the volume's job is to make "which" observable:

  * ALPHA.TXT (30246 bytes, 559 newlines, 2799 words) AND BETA.TXT (9510
    bytes, 250 newlines, 877 words) DIFFER IN LINES, IN WORDS AND IN BYTES, and this
    script REFUSES to write an image where any of the three agree. If beta had
    the same line count as alpha, `run WC.ELF -l BETA.TXT` would print the right
    number for the wrong reason and no assertion in run.sh could tell.

  * NEITHER IS A MULTIPLE OF ANYTHING. Their sizes divide neither a sector
    (512) nor a cluster (1024) nor the 173-byte chunk the program reads in, so
    the last read of each file is short and the counting loop has to be right
    about how many bytes it actually got.

  * BOTH CHAINS GO BACKWARDS. Inherited from M15's `scatter`, and re-checked
    here: a `wc` that got the right answer off a sorted chain would be getting
    it for the wrong reason.

  * THE LAST LINE OF ALPHA.TXT HAS NO TRAILING NEWLINE and BETA.TXT's does.
    That is the classic `wc` off-by-one, it is a property of the FILE rather
    than of the program, and derive.py counts the host's bytes the same way the
    program is required to (lines == newline characters), so the two files
    disagree about it on purpose.

  * THERE IS NO FILE CALLED NOSUCH.TXT, and run.sh names one, so the "the
    program was told to open something that is not there" path is produced by a
    boot rather than asserted.

Everything M15's root directory carried for realism is carried here too: a
volume label, a deleted entry with a plausible name, three long-filename
entries, a real zero-length file, one bad cluster and a subdirectory.

Usage:
    make-image.py <out.img> <wc.elf> <wcn.elf> [--json]

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
DATA_SECTORS = 10000

ROOT_SECTORS = (ROOT_ENTRIES * 32) // BYTES_PER_SECTOR      # 32
FAT_START = RESERVED                                         # 1
ROOT_START = RESERVED + NUM_FATS * FAT_SECTORS               # 41
DATA_START = ROOT_START + ROOT_SECTORS                       # 73
TOTAL_SECTORS = DATA_START + DATA_SECTORS                    # 10073
CLUSTER_COUNT = DATA_SECTORS // SECTORS_PER_CLUSTER          # 5000
CLUSTER_BYTES = SECTORS_PER_CLUSTER * BYTES_PER_SECTOR       # 1024

MEDIA = 0xF8
FAT_EOC = 0xFFFF
FAT_BAD = 0xFFF7

SUBDIR_CLUSTER = 4900

ALPHA_LINES = 560
BETA_LINES = 250


def alpha_text():
    """ALPHA.TXT: 560 lines, and THE LAST ONE HAS NO NEWLINE.

    Word counts per line vary with the line number so that "words" is not
    "lines times a constant" -- a `wc` that counted lines and multiplied would
    otherwise pass.
    """
    out = []
    for i in range(ALPHA_LINES):
        n = 1 + (i * 7) % 9
        out.append(" ".join("alpha%d-%d" % (i, k) for k in range(n)))
    return ("\n".join(out)).encode("ascii")   # no trailing newline


def beta_text():
    """BETA.TXT: 250 lines, the last one WITH a newline, and with runs of spaces
    and tabs inside it so that "words" is a run count and not a space count."""
    out = []
    for i in range(BETA_LINES):
        n = 1 + (i * 5) % 6
        sep = "   " if (i % 3) == 0 else "\t"
        out.append(sep.join("beta_%d_%d" % (i, k) for k in range(n)))
    return ("\n".join(out) + "\n").encode("ascii")


SMALL_TEXT = (
    b"oscortex_core M19 -- a program can be told which file to read.\n"
    b"Before this milestone every program on this machine had its input\n"
    b"compiled into it, because _start took no arguments and there was\n"
    b"nowhere for a command line to go. The kernel now builds the System V\n"
    b"initial process stack, and core/user/libc/start.c unpacks it and calls\n"
    b"main(argc, argv) like any other C runtime.\n"
)


def sector_pattern(s):
    """m6-disk's background pattern: depends on the sector AND the offset."""
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


def lfn_checksum(raw11):
    s = 0
    for c in raw11:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


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
    struct.pack_into("<I", b, 39, 0x05C0FFEE)
    b[43:54] = b"OSCORTEX   "
    b[54:62] = b"FAT16   "
    b[510:512] = b"\x55\xAA"
    return bytes(b)


def scatter(count, taken, lo, hi, step, start):
    """m15-fileio's deterministic, DELIBERATELY NON-MONOTONIC cluster run."""
    span = hi - lo
    out = []
    c = start
    while len(out) < count:
        v = lo + (c % span)
        if v not in taken and v not in out:
            out.append(v)
        c += step
    return out


def backlinks(chain):
    return sum(1 for i in range(len(chain) - 1) if chain[i + 1] < chain[i])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_json = "--json" in sys.argv
    if len(args) != 3:
        raise SystemExit("usage: make-image.py <out.img> <wc.elf> <wcn.elf>")
    out, p_path, n_path = args

    alpha = alpha_text()
    beta = beta_text()

    blobs = {
        "WC.ELF": open(p_path, "rb").read(),
        "WCN.ELF": open(n_path, "rb").read(),
        "ALPHA.TXT": alpha,
        "BETA.TXT": beta,
        "SMALL.TXT": SMALL_TEXT,
    }
    if blobs["WC.ELF"] == blobs["WCN.ELF"]:
        raise SystemExit("make-image: the real program and its negative control are "
                         "byte-identical; the control controls for nothing")

    # THE TWO FILES MUST DIFFER IN ALL THREE COLUMNS. This is the property the
    # whole harness rests on: same binary, different argument, DIFFERENT answer.
    def counts(blob):
        text = blob.decode("ascii")
        lines = text.count("\n")
        words = len(text.split())
        return lines, words, len(blob)

    ca, cb = counts(alpha), counts(beta)
    for i, col in enumerate(("lines", "words", "chars")):
        if ca[i] == cb[i]:
            raise SystemExit("make-image: ALPHA.TXT and BETA.TXT have the same %s "
                             "count (%d); this volume cannot tell an argument that "
                             "was used from one that was ignored" % (col, ca[i]))
    for name, blob in (("ALPHA.TXT", alpha), ("BETA.TXT", beta)):
        for div in (512, 1024, 173):
            if len(blob) % div == 0:
                raise SystemExit("make-image: %s is %d bytes, a multiple of %d; the "
                                 "last read would not be short" % (name, len(blob), div))
    if alpha.endswith(b"\n"):
        raise SystemExit("make-image: ALPHA.TXT ends in a newline; it must not, so "
                         "that the two files disagree about the last-line case")
    if not beta.endswith(b"\n"):
        raise SystemExit("make-image: BETA.TXT does not end in a newline; it must")

    def need(blob):
        return max(1, (len(blob) + CLUSTER_BYTES - 1) // CLUSTER_BYTES)

    # ---- cluster allocation --------------------------------------------
    taken = {SUBDIR_CLUSTER}
    chains = {}
    chains["ALPHA.TXT"] = scatter(need(alpha), taken, 1500, 3500, 1497, 0)
    taken |= set(chains["ALPHA.TXT"])
    chains["BETA.TXT"] = scatter(need(beta), taken, 1500, 3500, 1097, 313)
    taken |= set(chains["BETA.TXT"])
    chains["SMALL.TXT"] = scatter(need(SMALL_TEXT), taken, 4000, 4500, 97, 41)
    taken |= set(chains["SMALL.TXT"])
    for name, start in (("WC.ELF", 3), ("WCN.ELF", 4)):
        chain = []
        c = start
        while len(chain) < need(blobs[name]):
            if c >= CLUSTER_COUNT + 2:
                raise SystemExit("make-image: ran out of clusters placing %s" % name)
            if c not in taken:
                chain.append(c)
                taken.add(c)
            c += 2
        chains[name] = chain

    for name, chain in chains.items():
        if len(chain) != len(set(chain)):
            raise SystemExit("make-image: %s's chain repeats a cluster" % name)
        if len(chain) > 1 and chain == list(range(chain[0], chain[0] + len(chain))):
            raise SystemExit("make-image: %s came out CONTIGUOUS (%s)" % (name, chain))

    back = backlinks(chains["ALPHA.TXT"]) + backlinks(chains["BETA.TXT"])
    if back < 4:
        raise SystemExit("make-image: the two text files' chains only go backwards "
                         "%d times between them; this image exists so that a driver "
                         "which SORTED a chain would be wrong" % back)

    # ---- the image -----------------------------------------------------
    img = bytearray()
    for s in range(TOTAL_SECTORS):
        img += sector_pattern(s)
    img[0:SECTOR] = boot_sector()

    fat = bytearray(FAT_SECTORS * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFF00 | MEDIA)
    struct.pack_into("<H", fat, 2, FAT_EOC)
    for name, chain in chains.items():
        for i, c in enumerate(chain):
            nxt = chain[i + 1] if i + 1 < len(chain) else FAT_EOC
            struct.pack_into("<H", fat, c * 2, nxt)
    struct.pack_into("<H", fat, SUBDIR_CLUSTER * 2, FAT_EOC)
    struct.pack_into("<H", fat, 4999 * 2, FAT_BAD)   # one real bad cluster
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR
        img[at:at + len(fat)] = fat

    # ---- the root directory --------------------------------------------
    root = bytearray()
    entry_offsets = {}

    def add(name, attr, first, size, raw=None):
        entry_offsets[name] = ROOT_START * SECTOR + len(root)
        root.extend(dir_entry(raw if raw is not None else eightthree(name),
                              attr, first, size))

    add("OSCORTEX", 0x08, 0, 0, raw=b"OSCORTEX   ")
    add("ALPHA.TXT", 0x20, chains["ALPHA.TXT"][0], len(alpha))
    add("WC.ELF", 0x20, chains["WC.ELF"][0], len(blobs["WC.ELF"]))
    ghost = bytearray(dir_entry(eightthree("GHOST.BIN"), 0x20,
                                chains["ALPHA.TXT"][0], 4096))
    ghost[0] = 0xE5
    root += bytes(ghost)
    b11 = eightthree("BETA.TXT")
    for e in lfn_entries("beta-the-second-text-file.txt", lfn_checksum(b11)):
        root += e
    add("BETA.TXT", 0x20, chains["BETA.TXT"][0], len(beta))
    add("SMALL.TXT", 0x20, chains["SMALL.TXT"][0], len(SMALL_TEXT))
    add("EMPTY.TXT", 0x20, 0, 0)
    add("WCN.ELF", 0x20, chains["WCN.ELF"][0], len(blobs["WCN.ELF"]))
    add("SUB", 0x10, SUBDIR_CLUSTER, 0)
    root += b"\x00" * (ROOT_ENTRIES * 32 - len(root))
    img[ROOT_START * SECTOR:(ROOT_START + ROOT_SECTORS) * SECTOR] = root

    def cluster_at(c):
        return (DATA_START + (c - 2) * SECTORS_PER_CLUSTER) * SECTOR

    sub = bytearray(CLUSTER_BYTES)
    sub[0:32] = dir_entry(b".          ", 0x10, SUBDIR_CLUSTER, 0)
    sub[32:64] = dir_entry(b"..         ", 0x10, 0, 0)
    img[cluster_at(SUBDIR_CLUSTER):cluster_at(SUBDIR_CLUSTER) + CLUSTER_BYTES] = sub

    for name, chain in chains.items():
        blob = blobs[name]
        for i, c in enumerate(chain):
            piece = blob[i * CLUSTER_BYTES:(i + 1) * CLUSTER_BYTES]
            piece = piece + b"\0" * (CLUSTER_BYTES - len(piece))
            img[cluster_at(c):cluster_at(c) + CLUSTER_BYTES] = piece

    with open(out, "wb") as f:
        f.write(bytes(img))

    # ---- self-check: read it back the way the kernel will ---------------
    backimg = open(out, "rb").read()
    if len(backimg) != TOTAL_SECTORS * SECTOR:
        raise SystemExit("make-image: wrote %d bytes, expected %d"
                         % (len(backimg), TOTAL_SECTORS * SECTOR))
    fat_back = backimg[FAT_START * SECTOR:(FAT_START + FAT_SECTORS) * SECTOR]

    def walk(first, size):
        got, c = [], first
        while True:
            got.append(c)
            nxt = struct.unpack_from("<H", fat_back, c * 2)[0]
            if nxt >= 0xFFF8:
                break
            if len(got) > 4096:
                raise SystemExit("make-image: chain from %d does not terminate" % first)
            c = nxt
        want = max(1, (size + CLUSTER_BYTES - 1) // CLUSTER_BYTES)
        if len(got) != want:
            raise SystemExit("make-image: chain from %d is %d clusters, size says %d"
                             % (first, len(got), want))
        return got

    layout = {
        "bytes_per_sector": BYTES_PER_SECTOR, "sectors_per_cluster": SECTORS_PER_CLUSTER,
        "reserved": RESERVED, "num_fats": NUM_FATS, "fat_sectors": FAT_SECTORS,
        "root_entries": ROOT_ENTRIES, "total_sectors": TOTAL_SECTORS,
        "fat_start": FAT_START, "root_start": ROOT_START, "root_sectors": ROOT_SECTORS,
        "data_start": DATA_START, "cluster_count": CLUSTER_COUNT,
        "cluster_bytes": CLUSTER_BYTES, "media": MEDIA,
        "subdir_cluster": SUBDIR_CLUSTER, "backward_links": back,
        "files": {},
    }
    for name, chain in sorted(chains.items()):
        blob = blobs[name]
        if walk(chain[0], len(blob)) != chain:
            raise SystemExit("make-image: %s's chain does not read back" % name)
        joined = b"".join(backimg[cluster_at(c):cluster_at(c) + CLUSTER_BYTES]
                          for c in chain)
        if joined[:len(blob)] != blob:
            raise SystemExit("make-image: %s does not read back byte-for-byte along "
                             "its chain" % name)
        contiguous = b"".join(
            backimg[cluster_at(chain[0] + i):cluster_at(chain[0] + i) + CLUSTER_BYTES]
            for i in range(len(chain)))
        if len(chain) > 1 and contiguous[:len(blob)] == blob:
            raise SystemExit("make-image: %s reads back correctly CONTIGUOUSLY too, so "
                             "this image cannot tell a chain-follower from a "
                             "contiguous reader" % name)
        layout["files"][name] = {
            "chain": chain, "bytes": len(blob), "clusters": len(chain),
            "first_sector": DATA_START + (chain[0] - 2) * SECTORS_PER_CLUSTER,
        }

    outdir = os.path.dirname(os.path.abspath(out)) or "."
    base = os.path.basename(out)
    open(os.path.join(outdir, base + ".alpha"), "wb").write(alpha)
    open(os.path.join(outdir, base + ".beta"), "wb").write(beta)
    open(os.path.join(outdir, base + ".small"), "wb").write(SMALL_TEXT)

    if want_json:
        print(json.dumps(layout))
    else:
        print("make-image: %s — %d sectors, %d clusters; ALPHA.TXT %d bytes on %d "
              "clusters, BETA.TXT %d on %d, %d backward links between them"
              % (base, TOTAL_SECTORS, CLUSTER_COUNT, len(alpha),
                 len(chains["ALPHA.TXT"]), len(beta), len(chains["BETA.TXT"]), back))


if __name__ == "__main__":
    main()
