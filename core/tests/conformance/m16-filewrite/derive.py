#!/usr/bin/env python3
"""core/tests/conformance/m16-filewrite/derive.py

Computes, ON THE HOST, every number the boot is required to produce — including
WHICH CLUSTERS the kernel will allocate, in what order, for each file the guest
writes.

m15-fileio/derive.py's shape, with one thing added that no earlier harness could
have: an implementation of core/kernel/fat.dart's allocation policy. M15 derived
what a program would READ from a volume this repo laid out; M16 has to derive
what a volume will LOOK LIKE after the guest has changed it, and the only honest
way to do that is to state the policy independently and require the kernel to
agree.

THE POLICY, RESTATED FROM fat.dart AND NOT COPIED FROM IT
---------------------------------------------------------------------------
  * `fatFindFree` starts at a hint, scans upward, WRAPS ONCE, and returns the
    first cluster whose FAT entry is zero. The hint cannot change WHICH clusters
    are free, only where the scan begins.
  * `fatAlloc` sets the new cluster's entry to 0xFFFF, links the previous last
    cluster to it, and sets the hint to `cluster + 1`.
  * `fatTruncate` frees a whole chain and sets the hint to the chain's FIRST
    cluster — so a file that has just been emptied is the first place the next
    file looks.
  * A descriptor takes a new cluster when its offset reaches the end of what it
    has already allocated, which for an append-only descriptor is every
    cluster-sized step.

If this file and the kernel disagree about any of that, run.sh fails with the
two chains side by side. That is the point: an allocator whose behaviour is
observed and then written down is an allocator with no test.

The output is `key=value`, one per line, for run.sh to grep.
"""

import json
import os
import re
import struct
import sys

FNV_INIT = 0x811C9DC5
FNV_PRIME = 16777619


def fnv1a(b):
    h = FNV_INIT
    for c in b:
        h ^= c
        h = (h * FNV_PRIME) & 0xFFFFFFFF
    return h


def ro_range(path):
    """The R+X PT_LOAD's file bytes, which is what __ro_start/__ro_end bracket."""
    f = open(path, "rb").read()
    phoff = struct.unpack_from("<Q", f, 32)[0]
    phnum = struct.unpack_from("<H", f, 56)[0]
    for i in range(phnum):
        p = phoff + i * 56
        typ, flags = struct.unpack_from("<II", f, p)
        off, = struct.unpack_from("<Q", f, p + 8)
        filesz, = struct.unpack_from("<Q", f, p + 32)
        if typ == 1 and (flags & 1):
            return f[off:off + filesz]
    raise SystemExit("derive: %s has no executable PT_LOAD" % path)


def cconst(src, name):
    m = re.search(r"^#define %s (\d+)" % re.escape(name), src, re.M)
    if not m:
        raise SystemExit("derive: prog.c has no #define %s" % name)
    return int(m.group(1))


def dartconst(src, name):
    m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(name),
                  src, re.M)
    if not m:
        raise SystemExit("derive: no `const int %s` in the kernel sources" % name)
    return int(m.group(1), 0)


# ---------------------------------------------------------------------------
# THE THREE PAYLOAD GENERATORS. Byte for byte prog.c's, written out again here
# rather than shared, because a generator shared between the thing under test
# and the thing testing it proves only that one copy exists.
# ---------------------------------------------------------------------------

def new_byte(i):
    return ((i * 181) ^ (i >> 3) ^ ((i * i) >> 5) ^ 0x7E) & 0xFF


def seed_byte(i):
    return ((i * 211) + (i >> 1) + 0x2D) & 0xFF


def zero_byte(i):
    return (0x61 + (i % 26)) & 0xFF


def ro_file_bytes(n):
    """RO.TXT's contents. GAP-0152.

    A SECOND, INDEPENDENT IMPLEMENTATION of make-image.py's `ro_bytes`, written
    out here rather than imported, for the reason the three generators above
    are: the file this predicts must equal the file that was written, and two
    copies of one function cannot disagree while one copy and itself always
    agree. run.sh hashes make-image.py's own output as well and requires the
    two numbers to be the same, so a drift between them is a failure rather
    than a silent agreement about the wrong bytes."""
    b = bytearray((((i * 149) ^ (i >> 5) ^ 0x5B) & 0xFF) for i in range(n))
    b[0:8] = b"M16RO\n\n\n"
    b[n - 6:n] = b"ENDRO\n"
    return bytes(b)


# ---------------------------------------------------------------------------
# THE ALLOCATOR.
# ---------------------------------------------------------------------------

class Volume(object):
    """Just enough of a FAT to run core/kernel/fat.dart's allocation policy."""

    def __init__(self, layout):
        self.first = layout["first_cluster"]
        self.last = layout["last_cluster"]
        self.count = layout["cluster_count"]
        self.cluster_bytes = layout["cluster_bytes"]
        self.free = set(layout["free_clusters"])
        self.chains = {n: list(f["chain"]) for n, f in layout["files"].items()}
        self.hint = 0

    def find_free(self):
        """fatFindFree: first free at or after the hint, wrapping once.

        Returns the cluster, or None when the volume is full."""
        span = self.count
        hint = self.hint
        if hint < self.first or hint >= self.first + span:
            hint = self.first
        for k in range(span):
            c = hint + k
            if c >= self.first + span:
                c -= span
            if c in self.free:
                return c
        return None

    def alloc(self):
        """fatAlloc, minus the linking — the caller keeps the chain."""
        c = self.find_free()
        if c is None:
            return None
        self.free.discard(c)
        self.hint = c + 1
        return c

    def truncate(self, name):
        """fatTruncate: free the whole chain and aim the hint at its head."""
        chain = self.chains.get(name) or []
        if not chain:
            return 0
        for c in chain:
            self.free.add(c)
        self.hint = chain[0]
        self.chains[name] = []
        return len(chain)

    def write(self, name, nbytes):
        """One append-only file, written from empty. Returns (chain, bytes).

        The byte count is what the KERNEL would report across the whole write:
        every cluster it managed to allocate, times the cluster size, capped at
        what was asked for."""
        chain = []
        got = 0
        while got < nbytes:
            c = self.alloc()
            if c is None:
                break
            chain.append(c)
            got = min(nbytes, got + self.cluster_bytes)
        self.chains[name] = chain
        return chain, got


def main():
    if len(sys.argv) != 7:
        raise SystemExit("usage: derive.py <layout.json> <fulllayout.json> "
                         "<prog.elf> <progn.elf> <verify.elf> <kernel-dir>")
    layout = json.load(open(sys.argv[1]))
    full_layout = json.load(open(sys.argv[2]))
    prog_elf, progn_elf, verify_elf, kdir = sys.argv[3:7]

    here = os.path.dirname(os.path.abspath(__file__))
    progsrc = open(os.path.join(here, "prog.c")).read()
    chunk = cconst(progsrc, "CHUNK")
    new_bytes = cconst(progsrc, "NEW_BYTES")
    seed_new = cconst(progsrc, "SEED_NEW")
    zero_new = cconst(progsrc, "ZERO_NEW")
    ro_bytes = cconst(progsrc, "RO_BYTES")
    rofile_bytes = cconst(progsrc, "ROFILE_BYTES")

    filesrc = open(os.path.join(kdir, "file.dart")).read()
    fatsrc = open(os.path.join(kdir, "fat.dart")).read()
    write_max = dartconst(filesrc, "fileWriteMax")
    read_max = dartconst(filesrc, "fileReadMax")
    if chunk >= write_max:
        raise SystemExit("derive: prog.c's CHUNK is not below fileWriteMax")

    out = {}
    out["chunk"] = chunk
    out["new_bytes"] = new_bytes
    out["seed_new"] = seed_new
    out["zero_new"] = zero_new
    out["ro_bytes"] = ro_bytes
    # GAP-0152. RO.TXT's size is stated in THREE places and all three must
    # agree: prog.c's ROFILE_BYTES, the directory entry make-image.py wrote,
    # and the cluster it was given. A harness that read the size out of the
    # image would still pass if the guest had truncated the file.
    if rofile_bytes != layout["ro_bytes"]:
        raise SystemExit("derive: prog.c says RO.TXT is %d bytes and the image "
                         "generator wrote %d" % (rofile_bytes, layout["ro_bytes"]))
    out["rofile_bytes"] = rofile_bytes
    out["rofile_fnv_hex"] = "%x" % fnv1a(ro_file_bytes(rofile_bytes))
    # Decimal, because run.sh formats them into the kernel's own uppercase
    # `ls` line with printf. The refusal values above are lowercase hex because
    # the PROGRAM prints those, through an oslibc printf whose %x is lowercase.
    out["ro_cluster"] = layout["ro_cluster"]
    out["ro_entry"] = layout["ro_entry"]
    out["ro_attr"] = layout["ro_attr"]
    out["write_max"] = write_max
    out["read_max"] = read_max

    cb = layout["cluster_bytes"]
    if chunk % 512 == 0 or 512 % chunk == 0 or cb % chunk == 0:
        raise SystemExit("derive: CHUNK divides a sector or a cluster; this "
                         "harness exists to make it not")
    if new_bytes % chunk == 0:
        raise SystemExit("derive: NEW_BYTES is a whole number of chunks, so the "
                         "last write is not short")

    # ---- the payloads, and the hashes the guest must produce ------------
    new_payload = bytes(new_byte(i) for i in range(new_bytes))
    seed_payload = bytes(seed_byte(i) for i in range(seed_new))
    zero_payload = bytes(zero_byte(i) for i in range(zero_new))
    # `%x` AND NOT `%08x`, EVERYWHERE BELOW. The PROGRAM prints these with
    # oslibc's printf, which has no width modifiers at all (ADR-0017 §5), so a
    # hash whose top nibble happens to be zero comes out SEVEN digits long.
    # Zero-padding here would make this harness fail one time in sixteen for
    # reasons that have nothing to do with the kernel — which is exactly what
    # m14-fat did the first time M16 changed a byte of core/user/libc. GAP-0131.
    out["new_fnv_hex"] = "%x" % fnv1a(new_payload)
    out["seed_fnv_hex"] = "%x" % fnv1a(seed_payload)
    out["zero_fnv_hex"] = "%x" % fnv1a(zero_payload)
    out["status"] = fnv1a(new_payload) & 0xFF
    out["status_hex"] = "%016x" % (fnv1a(new_payload) & 0xFF)

    # SCRATCH.BIN gets the first RO_BYTES of the program's own R+X segment.
    ro = ro_range(prog_elf)
    out["self_fnv_hex"] = "%x" % fnv1a(ro)
    out["self_bytes"] = len(ro)
    out["scratch_fnv_hex"] = "%x" % fnv1a(ro[:ro_bytes])
    ro_n = ro_range(progn_elf)
    out["neg_self_fnv_hex"] = "%x" % fnv1a(ro_n)
    out["neg_scratch_fnv_hex"] = "%x" % fnv1a(ro_n[:ro_bytes])

    # ---- how many syscalls, reads and writes -------------------------
    def calls(n):
        return (n + chunk - 1) // chunk

    w_calls = calls(seed_new) + calls(new_bytes) + calls(zero_new) + calls(ro_bytes)
    out["write_calls"] = w_calls
    out["write_bytes"] = seed_new + new_bytes + zero_new + ro_bytes
    # THE READ THAT RETURNS ZERO IS NOT COUNTED, and that is a property of the
    # kernel rather than an approximation here: `fileSysRead` returns 0 from its
    # `pos >= size` branch WITHOUT bumping the counter, so a program that reads
    # to end of file performs one more `read` syscall than the kernel's line
    # reports. Getting this wrong by four — one per file — is exactly the kind
    # of off-by-a-branch a `> 0` assertion would never have found.
    # GAP-0152 adds one more file the program reads back: RO.TXT, which it was
    # REFUSED permission to empty and must still be able to read.
    r_calls = (calls(seed_new) + calls(new_bytes) + calls(zero_new) +
               calls(ro_bytes) + calls(rofile_bytes))
    out["read_calls"] = r_calls
    out["read_bytes"] = (seed_new + new_bytes + zero_new + ro_bytes
                         + rofile_bytes)

    def sector_writes(nbytes):
        """How many 512-byte sectors the kernel writes for a file of `nbytes`
        written in `chunk`-byte pieces.

        A write of n bytes at offset off touches every sector between
        off and off+n-1, and the NEXT write starts inside the last of them —
        so a sector that a chunk boundary falls inside is written twice. That
        double write is not waste, it is the read-modify-write M16's
        `fileWriteChunk` performs, and counting it here is what makes the
        kernel's `SECTORS` figure a claim rather than a tally."""
        off = 0
        total = 0
        while off < nbytes:
            n = min(chunk, nbytes - off)
            total += (off + n - 1) // 512 - off // 512 + 1
            off += n
        return total

    out["data_sectors"] = (sector_writes(seed_new) + sector_writes(new_bytes) +
                           sector_writes(zero_new) + sector_writes(ro_bytes))

    # ---- the clusters ---------------------------------------------------
    # prog.c's operation order, exactly:
    #   1. create SEED.TXT  -> truncate its five clusters, hint = its first
    #   2. write SEED_NEW bytes
    #   3. create NEW.BIN   -> a directory entry, no cluster
    #   4. write NEW_BYTES bytes
    #   5. create EMPTY2.TX -> a directory entry, no cluster, no write
    #   6. create EMPTY.TXT -> already zero-length, so nothing to truncate and
    #                          THE HINT DOES NOT MOVE
    #   7. write ZERO_NEW bytes
    #   8. create SCRATCH.BIN, then write RO_BYTES bytes of .rodata
    def simulate(lay, nbytes):
        v = Volume(lay)
        freed = v.truncate("SEED.TXT")
        seed_chain, seed_got = v.write("SEED.TXT", seed_new)
        new_chain, new_got = v.write("NEW.BIN", nbytes)
        zero_chain, zero_got = v.write("EMPTY.TXT", zero_new)
        scratch_chain, scratch_got = v.write("SCRATCH.BIN", ro_bytes)
        return {
            "freed": freed,
            "seed": (seed_chain, seed_got),
            "new": (new_chain, new_got),
            "zero": (zero_chain, zero_got),
            "scratch": (scratch_chain, scratch_got),
            "left": len(v.free),
        }

    sim = simulate(layout, new_bytes)
    out["seed_chain"] = ",".join(str(c) for c in sim["seed"][0])
    out["new_chain"] = ",".join(str(c) for c in sim["new"][0])
    out["zero_chain"] = ",".join(str(c) for c in sim["zero"][0])
    out["scratch_chain"] = ",".join(str(c) for c in sim["scratch"][0])
    out["seed_freed"] = sim["freed"]
    out["clusters_allocated"] = (len(sim["seed"][0]) + len(sim["new"][0]) +
                                 len(sim["zero"][0]) + len(sim["scratch"][0]))
    out["clusters_left"] = sim["left"]

    # ---- how many sectors reach the drive, in total --------------------
    #
    # Data sectors, plus every copy of every FAT sector a link changed, plus
    # every directory sector. `NUM_FATS` is 2 on this volume, so a kernel that
    # updated ONE copy of the FAT would produce a number 53 lower — which is
    # what makes this figure the check for the rule fat.dart's `fatSetEntry`
    # exists to keep.
    nfats = layout["num_fats"]
    fat_entry_writes = sim["freed"]
    for key in ("seed", "new", "zero", "scratch"):
        k = len(sim[key][0])
        if k:
            fat_entry_writes += k + (k - 1)
    #   two `fatDirWrite`s from the two truncating opens (SEED.TXT, EMPTY.TXT),
    #   three `fatDirCreate`s (NEW.BIN, EMPTY2.TX, SCRATCH.BIN),
    #   five flushes at `close`.
    dir_writes = 2 + 3 + 5
    out["fat_entry_writes"] = fat_entry_writes
    out["dir_writes"] = dir_writes
    out["disk_writes"] = out["data_sectors"] + fat_entry_writes * nfats + dir_writes
    out["allocs"] = out["clusters_allocated"]
    out["frees"] = sim["freed"]
    out["creates"] = 3
    out["truncs"] = 2
    out["flushes"] = 5

    nc = sim["new"][0]
    back = sum(1 for i in range(len(nc) - 1) if nc[i + 1] < nc[i])
    out["new_backward_links"] = back
    if back < 1:
        raise SystemExit("derive: NEW.BIN's predicted chain never goes backwards, "
                         "so this volume cannot tell a chain-follower from a "
                         "monotonic reader")
    if nc == list(range(nc[0], nc[0] + len(nc))):
        raise SystemExit("derive: NEW.BIN's predicted chain is CONTIGUOUS")

    # The bytes a CONTIGUOUS writer would have produced in NEW.BIN's place, so
    # run.sh can require the hash of THOSE never to appear.
    out["contig_first"] = nc[0]

    # ---- the `full` variant --------------------------------------------
    simf = simulate(full_layout, new_bytes)
    full_got = simf["new"][1]
    out["full_new_bytes"] = full_got
    out["full_new_chain"] = ",".join(str(c) for c in simf["new"][0])
    # The last write the kernel accepts is SHORT: it fills the last cluster and
    # stops. Which call that is, and how many bytes it delivers, both follow.
    out["full_short_call"] = full_got // chunk + 1
    out["full_short_n"] = full_got % chunk
    # The NEGATIVE CONTROL adds what it asked for rather than what it got, so it
    # over-counts by exactly the tail of the short write.
    neg_total = (full_got // chunk) * chunk + chunk
    out["full_neg_bytes"] = neg_total
    if neg_total == full_got:
        raise SystemExit("derive: on the `full` volume the negative control "
                         "reports the same byte count as the real program, so it "
                         "controls for nothing")
    full_payload = new_payload[:full_got]
    out["full_new_fnv_hex"] = "%x" % fnv1a(full_payload)
    out["full_status"] = fnv1a(full_payload) & 0xFF
    out["full_status_hex"] = "%016x" % (fnv1a(full_payload) & 0xFF)
    if out["full_status"] == out["status"]:
        raise SystemExit("derive: the `full` volume produces the same exit status "
                         "as the whole file")

    # ---- the kernel's own refusal values -------------------------------
    for label, name in (("ebadfd", "fileRetBadFd"), ("ebadptr", "fileRetBadPtr"),
                        ("ebadlen", "fileRetBadLen"), ("enoslot", "fileRetNoSlot"),
                        ("ebadname", "fileRetBadName"),
                        ("enotfound", "fileRetNotFound"),
                        ("eisdir", "fileRetIsDir"), ("eempty", "fileRetEmpty"),
                        ("eio", "fileRetIo"), ("ebadseek", "fileRetBadSeek"),
                        ("enoowner", "fileRetNoOwner"),
                        ("ebadmode", "fileRetBadMode"),
                        ("enospace", "fileRetNoSpace"),
                        ("ereadonly", "fileRetReadOnly")):
        out[label] = "%04x" % (dartconst(filesrc, name) & 0xFFFF)
    out["fat_badname"] = "%02x" % dartconst(fatsrc, "fatErrBadName")
    out["fat_isdir"] = "%02x" % dartconst(fatsrc, "fatErrIsDir")
    out["fat_full"] = "%02x" % dartconst(fatsrc, "fatErrFull")
    out["fat_nodirslot"] = "%02x" % dartconst(fatsrc, "fatErrNoDirSlot")
    out["fat_chaincycle"] = "%02x" % dartconst(fatsrc, "fatErrChainCycle")
    out["fat_readonly"] = "%02x" % dartconst(fatsrc, "fatErrReadOnly")

    for k in sorted(out):
        print("%s=%s" % (k, out[k]))


if __name__ == "__main__":
    main()
