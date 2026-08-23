#!/usr/bin/env bash
# core/tests/conformance/m16-filewrite/run.sh
#
# Mechanical check of ROADMAP.md's M16 exit criterion: A C PROGRAM RUNNING IN
# RING 3 ON THIS OPERATING SYSTEM CREATES A FILE, WRITES 21801 BYTES TO IT IN
# 127 PIECES, CLOSES IT — AND `fsck_msdos` PRONOUNCES THE VOLUME CLEAN AND
# macOS's OWN `msdos` DRIVER READS THE FILE BACK BYTE-FOR-BYTE.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Every harness before this one asserted, three separate ways, that this kernel
# could not write: no ATA opcode, no write function, no open mode. They were
# right and they are now obsolete. m14-fat and m15-fileio do not simply drop
# those greps — they assert something STRONGER in their place, that their own
# boots leave the image they were given BYTE-FOR-BYTE IDENTICAL, which is a
# claim about what ran rather than about what is spellable.
#
#   * THE HOST TOOLS ARE THE JUDGE, NOT THIS KERNEL. A filesystem driver that
#     is wrong in a self-consistent way reads back everything it wrote. So
#     after the guest writes, `fsck_msdos` is run over the image and required
#     to exit 0, and the image is MOUNTED with macOS's own `msdos` driver and
#     every file the guest wrote is compared against bytes this harness
#     generated independently. Neither of those can be satisfied by a volume
#     only oscortex can read.
#
#   * A FILE THAT WAS ALREADY THERE MUST STILL BE THERE. KEEP.BIN occupies
#     every EVEN cluster of the band the allocator writes into, and the odd
#     ones between them are what NEW.BIN gets. A writer that allocated
#     contiguously, or that got the data-region arithmetic wrong by one
#     cluster, destroys KEEP.BIN and nothing else — and this harness compares
#     KEEP.BIN's 307200 bytes, read through the host's driver, against the
#     bytes make-image.py wrote.
#
#   * THE CLUSTER CHAIN IS PREDICTED, NOT OBSERVED. derive.py implements
#     fat.dart's allocation policy independently and computes which cluster
#     each file will get. NEW.BIN's chain runs 3005, 3007, ... 3043 and then
#     WRAPS BACKWARDS to 120 — a link that goes down by 2923 — because the
#     allocator ran off the end of the free band. run.sh reads the chain back
#     out of the image afterwards and requires it to be that.
#
#   * BOTH COPIES OF THE FAT ARE WRITTEN. The two are compared byte-for-byte
#     after the boot, and the kernel's own count of sectors written is derived:
#     a driver that updated one copy would write 53 fewer.
#
#   * THE BYTES SURVIVE THE MACHINE BEING SWITCHED OFF. A SECOND BOOT against
#     the image the first one wrote runs VERIFY.ELF — a build of the same
#     source with no `fdwrite` and no `create` in it, checked by
#     build-progs.sh — and it finds every file with the hash the host computed.
#
#   * RUNNING OUT OF DISK IS A REFUSAL AND NOT A CORRUPTION. On the `full`
#     variant the guest's write goes SHORT and then FILE_ENOSPACE, the byte
#     count is derived, and `fsck_msdos` still pronounces the volume clean.
#
#   * TWO VOLUMES ON WHICH THE WRITE MUST NOT HAPPEN AT ALL come back
#     BYTE-FOR-BYTE IDENTICAL: a full root directory, and a SEED.TXT whose
#     chain is a cycle. A truncate that started before it noticed would have
#     freed part of a chain it did not understand.
#
#   * A DIRECTORY WITH SOMETHING PAST ITS END MARKER is REPAIRED by the guest
#     doing the right thing. `fsck_msdos` refuses the volume as built and calls
#     it clean afterwards. That boot exists because a mutation survived without
#     it -- GAP-0129.
#
#   * A WRITE OUT OF `.rodata` SUCCEEDS. `read` demands USER and WRITABLE of
#     its destination; `fdwrite` demands only USER of its source, and the
#     program writes 64 bytes of its own read-only segment into SCRATCH.BIN
#     which the host then compares against the ELF.
#
#   * THE NEGATIVE CONTROL IS A SECOND BUILD OF THE SAME SOURCE, run on the
#     `full` volume where its one difference matters: it counts what it ASKED
#     for instead of what fdwrite RETURNED, reports a byte count the disk does
#     not have, and the host proves the KERNEL right and the PROGRAM wrong.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * NO WRITING AT AN OFFSET. A write descriptor is append-only and starts
#     empty; `seek` on one is refused. GAP-0127 item 1.
#   * NO DELETE, NO RENAME, NO mkdir, NO TIMESTAMPS. GAP-0127.
#   * NOTHING HERE IS CRASH-CONSISTENT IN THE SENSE A JOURNAL WOULD BE.
#     GAP-0127 item 7 states exactly which interruptions lose what.
#
# Usage:
#   core/tests/conformance/m16-filewrite/run.sh
#   ... --regen    rewrite the goldens from this run
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "M16-filewrite: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M16-filewrite: FAIL — $1" >&2; exit 2; }

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m16.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
MOUNTPOINT="$WORKDIR/mnt"
ATTACHED=""
cleanup() {
  [[ -n "$ATTACHED" ]] && hdiutil detach "$ATTACHED" -force >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
[[ -f "$M1_EXPECTED" ]] || setup_error "m1-interrupts/expected.txt not found"
[[ -d "$LIBC_DIR" ]] || setup_error "no C library at $LIBC_DIR"

# ---------------------------------------------------------------------------
# Step 1 — build the kernel.
# ---------------------------------------------------------------------------
BUILD_OUT="$(bash "$CORE_DIR/scripts/build-kernel.sh" 2>&1)"
BUILD_STATUS=$?
echo "$BUILD_OUT"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
[[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

cdefine() {
  python3 - "$LIBC_DIR/oslibc.h" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^#define %s (0x[0-9A-Fa-f]+UL|\d+UL|\d+)\b" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1).rstrip("UL"), 0) if m else "")
PY
}

symsize() {
  x86_64-elf-readelf -sW "$1" | awk -v n="$2" '$8==n {print $3; exit}'
}

# ---------------------------------------------------------------------------
# Step 2 — structural checks. Everything that can be established without
# booting is established without booting.
# ---------------------------------------------------------------------------

# 2a. THE DONATED BLOCK, AND THE FOUR REGIONS INSIDE IT.
#
# 12768 -> 14048, and the 2560 is `file_store`: M16 doubled the metadata,
# doubled a descriptor and added a second sector buffer. The region offsets in
# file.dart are multiplied out against the block's own size here, because a
# region that ran past the end would corrupt whatever `.bss` follows and would
# do it silently.
# ---------------------------------------------------------------------------
# M17 (docs/decisions/0021-mutable-statics-and-the-end-of-donated-bss.md):
# WHERE THE MUTABLE STORAGE LIVES NOW. This check did not change what it
# asserts; it changed where it reads it from, and it is written out here rather
# than only in a commit message because an accounting assertion that moves is
# exactly the kind of thing that must never move quietly.
#
# Until M17 every mutable byte in this kernel was hand-donated `.bss` in
# core/boot/kdata.S, because DCDart had no mutable static data (GAP-0053).
# DCDart ADR-0051 landed `@bss`, so the blocks are now DCDart mutable statics
# declared in the subsystem that owns them, and they land in `kmain.o`'s `.bss`.
# FIVE WORDS DID NOT MOVE and never will: `cpu_info`, `shell_resume_rsp`,
# `shell_resume_ok`, `user_resume_rsp` and `user_resume_ok` are written by
# assembly itself (isr.S), and a `@bss` symbol is LOCAL, so assembly cannot
# name one. Those 96 bytes are still in kdata.o.
#
# So the total is a SUM OF TWO OBJECTS, and every historical number below is
# reproduced by it byte for byte: 16 at M2, 304 at M3, 392 at M4, 424 at M5/M6,
# 5096 at M7, 5224 at M8, 5368 at M9, 5496 at M10, 9664 at M11-M13, 11488 at
# M14, 14048 at M16, and 9728/11552/14112 at M18 -- M18 (ADR-0022) grew procStore by 64 bytes -- six scheduler header words and two per-slot counters, in the block the process table already owns rather than in a second one -- so every total below moves by exactly 64. `DART_BSS` is the DCDart half, `ASM_BSS` the assembly
# half; offset arithmetic ("bytes from this block to the end") is done inside
# DART_BSS, because every block a later milestone added is in that half.
bssfield() {   # bssfield <readelf column> <symbol> -- kmain.o first, then kdata.o
  local f="$1" n="$2" o v
  for o in kmain.o kdata.o; do
    v=$(x86_64-elf-readelf -sW "$CORE_DIR/build/$o" \
          | awk -v s="$n" -v f="$f" '$4=="OBJECT" && $8==s {print $f; exit}')
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  done
  return 1
}
bssaddr() {    # bssaddr <symbol> -- the LINKED address of a @bss block.
  # A `@bss` symbol is LOCAL to kmain.o and kernel.ld's OUTPUT_FORMAT(elf32-i386)
  # container keeps no local symbols, so kernel.elf's symbol table cannot answer
  # this. The LINK MAP can, and it is the linker's own statement of where it put
  # kmain.o's `.bss`; the block's offset inside that section comes from kmain.o.
  local n="$1" base off
  base=$(awk '$1==".bss" && $4 ~ /kmain\.o$/ {print $2; exit}' "$CORE_DIR/build/kernel.map")
  [[ -n "$base" ]] || return 1
  off=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
          | awk -v s="$n" '$4=="OBJECT" && $8==s {print $2; exit}')
  [[ -n "$off" ]] || return 1
  printf '%x\n' $(( 16#${base#0x} + 16#$off ))
}
bsssize() { bssfield 3 "$1"; }
bssoff()  { bssfield 2 "$1"; }
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section — the five assembly-written words are gone"
ASM_BSS=$((16#$ASM_BSS_HEX))
[[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o still donates $ASM_BSS bytes of .bss, expected exactly 96 — cpu_info (64) plus the four resume words. Anything else in there is storage that ADR-0021 says should be a @bss mutable static in the subsystem that owns it."
KDATA_BSS=$DART_BSS
KDATA_BSS=$(( KDATA_BSS + ASM_BSS ))   # M17 (ADR-0021): the DCDart half plus the 96 assembly-owned bytes
[[ "$KDATA_BSS" -eq 14112 ]] || fail "the kernel's mutable static storage is $KDATA_BSS bytes, expected 14112 — 11552 through M14 (11488, plus M18's 64-byte scheduler header, ADR-0022) plus file_store's 2560. If that changed, it changed deliberately and this number and docs/known-gaps.md GAP-0053's running total both move with it."
FILE_STORE_SIZE=$(bsssize fileStore)
[[ "$FILE_STORE_SIZE" == "2560" ]] || fail "kdata.o's file_store is ${FILE_STORE_SIZE:-missing} bytes, expected 2560"
[[ $(( KDATA_BSS - FILE_STORE_SIZE )) -eq 11552 ]] || fail "the .bss outside file_store is $(( KDATA_BSS - FILE_STORE_SIZE )), not M14's 11488 plus M18's 64 — M16 moved storage it does not own"
FAT_STORE_SIZE=$(bsssize fatStore)
[[ "$FAT_STORE_SIZE" == "1824" ]] || fail "kdata.o's fat_store is ${FAT_STORE_SIZE:-missing} bytes, expected 1824 — M16 added a write path to the FAT driver and it was supposed to cost that driver NO new storage at all"

META_OFF=$(dartconst fileMetaOffset file.dart)
TABLE_OFF=$(dartconst fileTableOffset file.dart)
BUF_OFF=$(dartconst fileBufOffset file.dart)
SEC_OFF=$(dartconst fileSecOffset file.dart)
STORE_BYTES=$(dartconst fileStoreBytes file.dart)
META_WORDS=$(dartconst fileMetaWords file.dart)
FD_WORDS=$(dartconst fileFdWords file.dart)
ROW_WORDS=$(dartconst fileRowWords file.dart)
MAX_FDS=$(dartconst fileMaxFds file.dart)
ROWS=$(dartconst fileRows file.dart)
RUN_ROW=$(dartconst fileRunRow file.dart)
PROC_MAX=$(dartconst procMax proc.dart)
READ_MAX=$(dartconst fileReadMax file.dart)
WRITE_MAX=$(dartconst fileWriteMax file.dart)
[[ "$STORE_BYTES" -eq "$FILE_STORE_SIZE" ]] || fail "file.dart says fileStoreBytes=$STORE_BYTES and kdata.S donates $FILE_STORE_SIZE"
[[ "$META_OFF" -eq 0 ]] || fail "fileMetaOffset is $META_OFF, expected 0"
[[ $(( META_OFF + META_WORDS * 8 )) -eq "$TABLE_OFF" ]] \
  || fail "the metadata region ($META_WORDS words at $META_OFF) does not end where the table begins ($TABLE_OFF)"
[[ $(( ROW_WORDS )) -eq $(( MAX_FDS * FD_WORDS )) ]] \
  || fail "fileRowWords ($ROW_WORDS) is not fileMaxFds * fileFdWords ($MAX_FDS * $FD_WORDS)"
[[ $(( TABLE_OFF + ROWS * ROW_WORDS * 8 )) -eq "$BUF_OFF" ]] \
  || fail "the descriptor table ($ROWS rows of $ROW_WORDS words at $TABLE_OFF) does not end where the bounce buffer begins ($BUF_OFF)"
[[ $(( BUF_OFF + READ_MAX )) -eq "$SEC_OFF" ]] \
  || fail "the bounce buffer ($READ_MAX bytes at $BUF_OFF) does not end where M16's read-modify-write sector begins ($SEC_OFF)"
[[ $(( SEC_OFF + WRITE_MAX )) -eq "$STORE_BYTES" ]] \
  || fail "the read-modify-write sector ($WRITE_MAX bytes at $SEC_OFF) does not end at the block's end ($STORE_BYTES)"
[[ "$READ_MAX" -eq 512 && "$WRITE_MAX" -eq 512 ]] \
  || fail "fileReadMax=$READ_MAX and fileWriteMax=$WRITE_MAX; both must be one sector or the two buffers do not tile the block"
[[ "$RUN_ROW" -eq "$PROC_MAX" ]] \
  || fail "fileRunRow is $RUN_ROW and proc.dart's procMax is $PROC_MAX"
[[ "$ROWS" -eq $(( PROC_MAX + 1 )) ]] || fail "fileRows is $ROWS, expected procMax + 1 = $(( PROC_MAX + 1 ))"
echo "STRUCTURAL: pass  kdata.o donates 14048 bytes of .bss, 2560 of them file_store: $META_WORDS metadata words at $META_OFF, $ROWS x $MAX_FDS x $FD_WORDS descriptor words at $TABLE_OFF, a ${READ_MAX}-byte bounce buffer at $BUF_OFF and a ${WRITE_MAX}-byte read-modify-write sector at $SEC_OFF, ending exactly at $STORE_BYTES; fat_store did not move from 1824"

# 2b. THE STORAGE SEAM: ONE ACCESSOR, FOUR CALL SITES, ONE FILE (ADR-0011 §0).
CODE=$(grep -v '^[[:space:]]*//' "$CORE_DIR/kernel/file.dart")
SEAM=$(printf '%s\n' "$CODE" | grep -c "return Bss[.]addressOf(fileStore)")
[[ "$SEAM" -eq 4 ]] || fail "core/kernel/file.dart has $SEAM call sites of Bss.addressOf(fileStore), expected exactly 4 (fileMetaBase, fileTableBase, fileBufBase, fileSecBase). A fifth turns the migration to DCDart mutable statics into an audit — ADR-0011 §0."
OTHERS=$(grep -l "fileStore" "$CORE_DIR/kernel/"*.dart | grep -v "file.dart" | wc -l | tr -d ' ')
[[ "$OTHERS" -eq 0 ]] || fail "fileStore is named in $OTHERS kernel files other than file.dart"
FATSEAM=$(grep -v '^[[:space:]]*//' "$CORE_DIR/kernel/fat.dart" | grep -c "return Bss[.]addressOf(fatStore)")
[[ "$FATSEAM" -eq 4 ]] || fail "core/kernel/fat.dart has $FATSEAM call sites of Bss.addressOf(fatStore), expected exactly 4 — M16's write path was supposed to reuse the four regions that were already there"
echo "STRUCTURAL: pass  the storage seam is exactly 4 call sites of Bss.addressOf(fileStore) in file.dart and none anywhere else, and fat.dart's four are unchanged"

# 2c. THE TWO POINTER VALIDATORS, AND THE ONE BIT BETWEEN THEM.
#
# This is the check M16 exists to get right, and it is the same shape as M15's
# with a second half. `fileOwnsWrite` gates the ONE store to a caller-supplied
# address and requires the page to be USER and WRITABLE. `fileOwnsRead` gates
# the ONE load from one and requires USER and NOT writable — because the source
# of a write is very often `.rodata`, and a validator that demanded WRITABLE
# would refuse the most ordinary call there is.
#
# Both must bound the pointer BEFORE doing arithmetic on it: DCDart traps on
# overflow with a real `ud2`, so `fdwrite(fd, 0xFFFFFFFFFFFFFFFF, 512)` must be
# refused by a comparison and never by an addition.
python3 - "$CORE_DIR/kernel/file.dart" <<'PY' || fail "the two ring-3 pointer validators are not the two functions this milestone requires"
import re, sys
src = open(sys.argv[1]).read()


def body(name):
    m = re.search(r"^u64 %s\(u64 ptr, u64 len\) \{\n(.*?)^\}" % name, src, re.M | re.S)
    if not m:
        print("    - core/kernel/file.dart has no `u64 %s(u64 ptr, u64 len)`" % name,
              file=sys.stderr)
        sys.exit(1)
    return m.group(1)


bad = []
for name, needs_writable in (("fileOwnsWrite", True), ("fileOwnsRead", False)):
    b = body(name)
    lines = [l.strip() for l in b.splitlines() if l.strip()]
    # The FIRST thing the function does must be a comparison on `ptr`, not an
    # addition.
    if not lines[0].startswith("if (ptr <"):
        bad.append("%s does not bound `ptr` on its first line (%r)" % (name, lines[0]))
    first_add = next((i for i, l in enumerate(lines) if "ptr + len" in l), None)
    first_bound = next((i for i, l in enumerate(lines) if "ptr >= u64(vmProgEnd)" in l), None)
    if first_add is None or first_bound is None or first_bound > first_add:
        bad.append("%s does arithmetic on `ptr` before bounding it" % name)
    if "while (a <= last)" not in b:
        bad.append("%s does not walk the range page by page" % name)
    if "vmEffective(a)" not in b:
        bad.append("%s does not ask vmEffective for the page's real permissions" % name)
    if "(e & u64(2)) < u64(1)" not in b:
        bad.append("%s does not require the USER bit" % name)
    has_writable = "(e & u64(4)) < u64(1)" in b
    if has_writable != needs_writable:
        bad.append("%s %s the WRITABLE bit and must %s"
                   % (name, "requires" if has_writable else "does not require",
                      "require it" if needs_writable else "not"))

# The bounds each one uses. `read` is capped by fileReadMax and `fdwrite` by
# fileWriteMax; a validator that used `userWriteMax` (128, the console write's
# limit) would silently cap every file operation at 128 bytes.
if "len > u64(fileReadMax)" not in body("fileOwnsWrite"):
    bad.append("fileOwnsWrite does not bound len by fileReadMax")
if "len > u64(fileWriteMax)" not in body("fileOwnsRead"):
    bad.append("fileOwnsRead does not bound len by fileWriteMax")

# THE ONE STORE AND THE ONE LOAD, each behind its own validator.
#
# `fileCopyOut` is the only function that writes to an address ring 3 chose and
# `fileCopyIn` the only one that reads from one. Each is defined once, called
# once, and its one caller runs the matching validator BEFORE the call — which
# is the ordering, not just the presence, that makes the check a gate.
for copier, validator, caller in (("fileCopyOut", "fileOwnsWrite", "fileSysRead"),
                                  ("fileCopyIn", "fileOwnsRead", "fileSysWrite")):
    if len(re.findall(r"^void %s\(" % copier, src, re.M)) != 1:
        bad.append("%s is not defined exactly once" % copier)
    calls = [m for m in re.finditer(r"(?<!void )%s\(" % copier, src)
             if not src[:m.start()].rstrip().endswith("void")]
    if len(calls) != 1:
        bad.append("%s has %d call sites, expected 1" % (copier, len(calls)))
        continue
    cm = re.search(r"^void %s\(u64 frame\) \{\n(.*?)^\}" % caller, src, re.M | re.S)
    if not cm:
        bad.append("file.dart has no `void %s(u64 frame)`" % caller)
        continue
    b = cm.group(1)
    if copier + "(" not in b:
        bad.append("%s's one call site is not in %s" % (copier, caller))
        continue
    if validator + "(" not in b:
        bad.append("%s does not run %s" % (caller, validator))
        continue
    if b.index(validator + "(") > b.index(copier + "("):
        bad.append("%s calls %s BEFORE it runs %s" % (caller, copier, validator))

for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  fileOwnsWrite and fileOwnsRead both bound the pointer before touching it and both walk the range page by page; the write-side one requires USER and WRITABLE, the read-side one requires USER and NOT writable, and they are bounded by fileReadMax and fileWriteMax respectively"

# 2d. THE WRITE PATH IS REACHABLE ONLY THROUGH ONE FUNCTION.
#
# This REPLACES m14-fat's and m15-fileio's "there is no write opcode anywhere"
# assertion, which was correct for two milestones and is now false. What it
# asserts instead is the property that made the old one worth having: a kernel
# in which a sector can be written from many places is a kernel in which "does
# this code path write?" is not answerable.
python3 - "$CORE_DIR/kernel" <<'PY' || fail "the ATA write path is reachable from somewhere other than fatWriteSector"
import glob, os, re, sys
bad = []
kdir = sys.argv[1]
sources = {os.path.basename(p): open(p).read() for p in sorted(glob.glob(os.path.join(kdir, "*.dart")))}
code = {n: "\n".join(l for l in s.splitlines() if not l.strip().startswith("//"))
        for n, s in sources.items()}

# `ataWriteFrom` is defined once and called once.
defs = sum(len(re.findall(r"^u64 ataWriteFrom\(", s, re.M)) for s in code.values())
if defs != 1:
    bad.append("ataWriteFrom is defined %d times, expected 1" % defs)
callers = []
for name, s in code.items():
    for m in re.finditer(r"ataWriteFrom\(", s):
        line = s[:m.start()].count("\n")
        if re.search(r"^u64 ataWriteFrom\(", s.splitlines()[line] if line < len(s.splitlines()) else "", re.M):
            continue
        callers.append((name, s.splitlines()[line].strip()))
callers = [c for c in callers if not c[1].startswith("u64 ataWriteFrom(")]
if len(callers) != 1:
    bad.append("ataWriteFrom has %d call sites: %s" % (len(callers), callers))
elif callers[0][0] != "fat.dart":
    bad.append("ataWriteFrom is called from %s, not fat.dart" % callers[0][0])

# ... and that one call site is inside fatWriteSector.
m = re.search(r"^u64 fatWriteSector\(u64 lba, u64 src\) \{\n(.*?)^\}", code["fat.dart"], re.M | re.S)
if not m:
    bad.append("fat.dart has no `u64 fatWriteSector(u64 lba, u64 src)`")
elif "ataWriteFrom(lba, src)" not in m.group(1):
    bad.append("fatWriteSector does not call ataWriteFrom(lba, src)")

# `port_outw` sites: the framebuffer's VBE pair, and ONE aimed at the ATA data
# register, inside ataWriteFrom.
sites = []
for name, s in code.items():
    for mm in re.finditer(r"port_outw\(u64\((\w+)\)", s):
        sites.append((name, mm.group(1)))
allowed = {("fb.dart", "vbeIndexPort"), ("fb.dart", "vbeDataPort"),
           ("ata.dart", "ataRegData")}
for site in sites:
    if site not in allowed:
        bad.append("%s calls port_outw with %s" % site)
data_sites = [s for s in sites if s == ("ata.dart", "ataRegData")]
if len(data_sites) != 1:
    bad.append("there are %d port_outw calls aimed at the ATA data register, expected exactly 1"
               % len(data_sites))
mw = re.search(r"^u64 ataWriteFrom\(u64 lba, u64 dst?\w*\) \{\n(.*?)^\}", code["ata.dart"], re.M | re.S)
mw = mw or re.search(r"^u64 ataWriteFrom\(.*?\) \{\n(.*?)^\}", code["ata.dart"], re.M | re.S)
if not mw:
    bad.append("could not find ataWriteFrom's body in ata.dart")
else:
    b = mw.group(1)
    if "port_outw(u64(ataRegData)" not in b:
        bad.append("ataWriteFrom does not write the data register")
    if "ataCmdWriteSectors" not in b:
        bad.append("ataWriteFrom does not issue WRITE SECTORS")
    # THE FLUSH. ATA/ATAPI-6 allows a write to complete into a volatile cache.
    if not b.rstrip().rstrip("}").rstrip().endswith("return ataFlushCache();"):
        bad.append("ataWriteFrom does not END with ataFlushCache(); a write that "
                   "returned before the flush would be reporting the drive's "
                   "cache rather than its medium")
    # Every wait bounded, and the same status discipline as the read path.
    for want in ("ataSelect(lba)", "ataWait(u64(ataStRdy))", "ataSettle()",
                 "ataWait(u64(ataStDrq))", "ataAbsent(", "ataFailed("):
        if want not in b:
            bad.append("ataWriteFrom does not use %s — the write path's status "
                       "discipline is not the read path's" % want)

mf = re.search(r"^u64 ataFlushCache\(\) \{\n(.*?)^\}", code["ata.dart"], re.M | re.S)
if not mf:
    bad.append("ata.dart has no ataFlushCache()")
elif "ataCmdCacheFlush" not in mf.group(1) or "ataWait(" not in mf.group(1):
    bad.append("ataFlushCache does not issue FLUSH CACHE and wait for it")

# RULE 2's ORDERING, WHICH NO BOOT ON AN EMULATOR CAN SEE.
#
# `fatAlloc` must mark the new cluster end-of-chain BEFORE linking the previous
# last cluster to it. Get it the other way round and the window between the two
# writes contains a chain whose last link points at a cluster still marked FREE
# — which the next allocation hands to a second file. Nothing that can happen
# inside QEMU distinguishes the two orders, because nothing here loses power
# between two `out` instructions, so this is checked by READING. It is here
# because the mutation that swaps them SURVIVED the first round.
ma = re.search(r"^u64 fatAlloc\(u64 last\) \{\n(.*?)^\}", code["fat.dart"], re.M | re.S)
if not ma:
    bad.append("fat.dart has no `u64 fatAlloc(u64 last)`")
else:
    b = ma.group(1)
    eoc = b.find("fatSetEntry(c, u64(0xFFFF))")
    link = b.find("fatSetEntry(last, c)")
    if eoc < 0 or link < 0:
        bad.append("fatAlloc does not both mark the new cluster end-of-chain and "
                   "link the previous last cluster to it")
    elif eoc > link:
        bad.append("fatAlloc LINKS the new cluster before marking it end-of-chain. "
                   "A failure between the two writes then leaves a chain whose last "
                   "link points at a cluster marked FREE, which the next allocation "
                   "gives to a second file -- ADR-0020 section 3 rule 2.")

# BOTH copies of the FAT, in the one function that changes an entry.
me = re.search(r"^u64 fatSetEntry\(u64 c, u64 v\) \{\n(.*?)^\}", code["fat.dart"], re.M | re.S)
if not me:
    bad.append("fat.dart has no `u64 fatSetEntry(u64 c, u64 v)`")
else:
    b = me.group(1)
    if "fatMetaNumFats" not in b or "while (f < copies)" not in b:
        bad.append("fatSetEntry does not loop over BPB_NumFATs copies of the FAT; "
                   "a volume with one copy updated is one fsck_msdos reports as "
                   "'FATs differ'")
setters = []
for name, s in code.items():
    for mm in re.finditer(r"fatSetEntry\(", s):
        setters.append(name)
if setters.count("fat.dart") != len(setters):
    bad.append("fatSetEntry is called from outside fat.dart")

for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  ataWriteFrom is defined once and called from exactly one place (fatWriteSector), it ends with FLUSH CACHE and keeps the read path's status discipline, the only port_outw aimed at 0x1F0 is the one inside it, fatAlloc marks a new cluster end-of-chain BEFORE linking it, and fatSetEntry — the only function that changes a FAT entry — writes every copy of the FAT"

# 2e. THE C LIBRARY AND THE KERNEL AGREE ABOUT EVERY NUMBER.
#
# m13-libc's and m15-fileio's check, extended: five syscall numbers, five
# bounds, thirteen refusal values and the two open modes, every one of them read
# back out of core/kernel/ and compared against core/user/libc/oslibc.h. A
# library that disagreed with the kernel about what a refusal LOOKS LIKE would
# treat one as a byte count.
declare -a PAIRS=(
  "SYS_OPEN:fileSysOpenNo:file.dart"
  "SYS_READ:fileSysReadNo:file.dart"
  "SYS_CLOSE:fileSysCloseNo:file.dart"
  "SYS_SEEK:fileSysSeekNo:file.dart"
  "SYS_FDWRITE:fileSysWriteNo:file.dart"
  "READ_MAX:fileReadMax:file.dart"
  "WRITE_FILE_MAX:fileWriteMax:file.dart"
  "FILE_MAX_FDS:fileMaxFds:file.dart"
  "FILE_NAME_MAX:fileNameMax:file.dart"
  "FILE_ERR_FLOOR:fileRetFloor:file.dart"
  "FILE_EBADFD:fileRetBadFd:file.dart"
  "FILE_EBADPTR:fileRetBadPtr:file.dart"
  "FILE_EBADLEN:fileRetBadLen:file.dart"
  "FILE_ENOSLOT:fileRetNoSlot:file.dart"
  "FILE_EBADNAME:fileRetBadName:file.dart"
  "FILE_ENOTFOUND:fileRetNotFound:file.dart"
  "FILE_EISDIR:fileRetIsDir:file.dart"
  "FILE_EEMPTY:fileRetEmpty:file.dart"
  "FILE_EIO:fileRetIo:file.dart"
  "FILE_EBADSEEK:fileRetBadSeek:file.dart"
  "FILE_ENOOWNER:fileRetNoOwner:file.dart"
  "FILE_EBADMODE:fileRetBadMode:file.dart"
  "FILE_ENOSPACE:fileRetNoSpace:file.dart"
  "O_READ:fileOpenRead:file.dart"
  "O_WRITE:fileOpenWrite:file.dart"
)
for pair in "${PAIRS[@]}"; do
  IFS=: read -r cname dname dfile <<<"$pair"
  cval=$(cdefine "$cname")
  dval=$(dartconst "$dname" "$dfile")
  [[ -n "$cval" ]] || fail "oslibc.h has no #define $cname"
  [[ -n "$dval" ]] || fail "core/kernel/$dfile has no const int $dname"
  [[ "$cval" -eq "$dval" ]] \
    || fail "oslibc.h's $cname is $cval and core/kernel/$dfile's $dname is $dval"
done
# THIRTEEN DISTINCT REFUSAL VALUES, ALL ABOVE ONE FLOOR. The floor is what makes
# "is this a result or a refusal" one comparison.
python3 - "$CORE_DIR/kernel/file.dart" <<'PY' || fail "the refusal values are not thirteen distinct values above one floor"
import re, sys
src = open(sys.argv[1]).read()
floor = int(re.search(r"^const int fileRetFloor = (0x[0-9A-Fa-f]+);", src, re.M).group(1), 0)
vals = {}
for m in re.finditer(r"^const int (fileRet\w+) = (0x[0-9A-Fa-f]+);", src, re.M):
    if m.group(1) == "fileRetFloor":
        continue
    vals[m.group(1)] = int(m.group(2), 0)
bad = []
if len(vals) != 13:
    bad.append("there are %d fileRet* refusals, expected 13: %s" % (len(vals), sorted(vals)))
if len(set(vals.values())) != len(vals):
    bad.append("two refusals share a value: %s" % sorted(vals.items(), key=lambda kv: kv[1]))
for n, v in vals.items():
    if v < floor:
        bad.append("%s (%#x) is below the floor %#x" % (n, v, floor))
# Every one of them must be REACHABLE: named somewhere other than the line that
# declares it. A refusal nothing returns is a refusal no boot can produce.
for n in vals:
    uses = len(re.findall(r"\b%s\b" % n, src)) - \
        len(re.findall(r"^const int %s = " % n, src, re.M))
    if uses < 1:
        bad.append("%s is declared and documented but never returned" % n)
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  all 25 of oslibc.h's file numbers read back out of core/kernel/file.dart, with thirteen distinct refusal VALUES above one floor and every one of them reachable"

# 2f. THE HELP TEXT DID NOT MOVE.
#
# 2147 bytes, exactly as at M14 and M15. M16 added NO SHELL COMMAND — writing is
# something a program does, not something a user types — so this number does not
# move and neither does any golden that contains it. If a later milestone adds
# `write` or `rm` to the shell, this is where the budget is.
HELP_SIZE=$(symsize "$CORE_DIR/build/kmain.o" shellStrHelp)
[[ "$HELP_SIZE" == "2147" ]] || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2147 — M16 was not supposed to add a shell command, and every harness that asserts a help-text golden moves with this number"
echo "STRUCTURAL: pass  shellStrHelp is unchanged at 2147 bytes — M16 adds no shell command, so no help-text golden moves"

# 2g. EVERY @rodata TABLE EQUALS THE STRING ITS DOC COMMENT RECORDS.
#
# m14-fat's check, over fat.dart and file.dart, extended to M16's ten new
# tables. GAP-0060's mitigation: a `@rodata` table has no length word, so every
# call site repeats the length, and a table whose doc comment and whose length
# literal disagree is a `uartWrite` that runs off the end of it.
python3 - "$CORE_DIR/kernel" "$CORE_DIR/build/kmain.o" <<'PY' || fail "a @rodata table does not match the string its doc comment records, or a call site passes the wrong length"
import glob, os, re, subprocess, sys
kdir, obj = sys.argv[1], sys.argv[2]
sizes = {}
for line in subprocess.check_output(
        ["x86_64-elf-readelf", "-sW", obj]).decode().splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == "OBJECT":
        sizes[f[7]] = int(f[2])
bad = []
n = 0
for path in sorted(glob.glob(os.path.join(kdir, "*.dart"))):
    src = open(path).read()
    base = os.path.basename(path)
    for m in re.finditer(
            r"/// `'((?:[^'\\]|\\.)*)'` -- (\d+) bytes\.\n@rodata\nfinal List<u8> (\w+) = const \[\n(.*?)\n\];",
            src, re.S):
        text, want, name, body = m.group(1), int(m.group(2)), m.group(3), m.group(4)
        n += 1
        # Two spellings of a newline appear in this kernel's doc comments --
        # `\n` and `\\n` -- and both mean one byte. The double one is undone
        # FIRST, or the single-backslash pass leaves a stray backslash behind
        # and every table in user.dart and vm.dart reads one byte long.
        literal = text.replace("\\\\n", "\n").replace("\\n", "\n")
        literal = literal.replace("\\'", "'")
        if len(literal.encode()) != want:
            bad.append("%s: %s's doc comment says %d bytes and the string is %d"
                       % (base, name, want, len(literal.encode())))
            continue
        got = bytes(int(x, 16) for x in re.findall(r"u8\((0x[0-9A-Fa-f]{2})\)", body))
        if got != literal.encode():
            bad.append("%s: %s's bytes are not its doc comment's string" % (base, name))
        if name in sizes and sizes[name] != want:
            bad.append("%s: %s is %d bytes in kmain.o and %d in its doc comment"
                       % (base, name, sizes[name], want))
        for call in re.finditer(
                r"Rodata\.addressOf\(%s\), u64\((\d+)\)" % re.escape(name), src):
            if int(call.group(1)) != want:
                bad.append("%s: a call site passes %s with length %s, not %d"
                           % (base, name, call.group(1), want))
if n < 70:
    bad.append("only %d @rodata tables were checked; fat.dart alone has more than that" % n)
for b in bad:
    print("    - " + b, file=sys.stderr)
print("    (%d @rodata tables checked against their doc comments and call sites)" % n)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  every @rodata table in core/kernel/ equals the string its doc comment records, has that size in kmain.o, and is passed that length at every call site"

# 2h. THE FREESTANDING RULE.
FS_OUT="$(cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o 2>&1)"
FS_STATUS=$?
echo "$FS_OUT"
[[ $FS_STATUS -eq 0 ]] || fail "verify-freestanding.sh rejected build/kmain.o"
EXTERN_COUNT=$(sed -E 's/.*\(([0-9]+) declared extern.*/\1/' <<<"$FS_OUT")
# M17 (ADR-0021) deleted all SIXTEEN `_addr()` accessor externs: every block of
# assembly-donated `.bss` they addressed is now a DCDart `@bss` mutable static in
# the subsystem that owns it. The kernel declares 44 externs, not 60, and each of
# the sixteen is asserted ABSENT as well — a count alone can be restored by an
# unrelated extern.
for gone in \
            vga_cursor_addr m2_phase_addr shell_line_addr \
            shell_len_addr shell_state_addr shell_mbinfo_addr \
            kbd_prefix_addr fault_count_addr fb_state_addr \
            pmm_store_addr vm_store_addr user_store_addr \
            elf_store_addr proc_store_addr fat_store_addr \
            file_store_addr; do
  grep -q "\\b$gone\\b" <<<"$FS_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
[[ "$EXTERN_COUNT" -eq 44 ]] \
  || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — M16 was supposed to add NONE (the write path reuses port_outw, which core/boot/portio.S has carried since M5), and ADR-0021 took 60 to 44 by deleting sixteen accessors"
for o in kdata.o portio.o; do
  (cd "$CORE_DIR" && bash scripts/verify-freestanding.sh "build/$o" >/dev/null 2>&1) \
    || fail "verify-freestanding.sh rejected build/$o"
done
echo "STRUCTURAL: pass  verify-freestanding is clean, $EXTERN_COUNT declared externs — M16 added none"

# ---------------------------------------------------------------------------
# Step 3 — build the three programs and the volume.
# ---------------------------------------------------------------------------
PROGDIR="$WORKDIR/progs"
PROG_OUT="$(bash "$SCRIPT_DIR/build-progs.sh" "$PROGDIR" 2>&1)"
PROG_STATUS=$?
echo "$PROG_OUT"
[[ $PROG_STATUS -eq 0 ]] || fail "build-progs.sh exited $PROG_STATUS"

BASE_IMG="$WORKDIR/m16.img"
LAYOUT="$WORKDIR/layout.json"
python3 "$SCRIPT_DIR/make-image.py" "$BASE_IMG" "$PROGDIR/prog.elf" \
  "$PROGDIR/progn.elf" "$PROGDIR/verify.elf" \
  || fail "make-image.py could not write the volume"
python3 "$SCRIPT_DIR/make-image.py" "$BASE_IMG" "$PROGDIR/prog.elf" \
  "$PROGDIR/progn.elf" "$PROGDIR/verify.elf" --json > "$LAYOUT" \
  || fail "make-image.py could not describe the volume"
FULL_IMG="$WORKDIR/m16-full.img"
FULL_LAYOUT="$WORKDIR/layout-full.json"
python3 "$SCRIPT_DIR/make-image.py" "$FULL_IMG" "$PROGDIR/prog.elf" \
  "$PROGDIR/progn.elf" "$PROGDIR/verify.elf" --variant=full >/dev/null \
  || fail "make-image.py could not write the `full` variant"
python3 "$SCRIPT_DIR/make-image.py" "$FULL_IMG" "$PROGDIR/prog.elf" \
  "$PROGDIR/progn.elf" "$PROGDIR/verify.elf" --variant=full --json > "$FULL_LAYOUT" \
  || fail "make-image.py could not describe the `full` variant"
IMG_BYTES=$(wc -c <"$BASE_IMG" | tr -d ' ')

# ---------------------------------------------------------------------------
# Step 4 — THE HOST TOOLS, BEFORE. The volume this repo wrote has to be a FAT16
# volume by somebody else's standards before the guest is allowed near it,
# because otherwise "fsck accepts it afterwards" would be a claim about
# fsck rather than about the kernel.
# ---------------------------------------------------------------------------
command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found; this harness will not certify a FAT volume no independent tool has read"
command -v hdiutil >/dev/null 2>&1 \
  || setup_error "hdiutil not found; this harness will not certify a written volume that macOS's own msdos driver has not mounted"

fsck_clean() {
  local img="$1" label="$2"
  local out status
  out="$("$FSCK" -n "$img" 2>&1)"
  status=$?
  [[ $status -eq 0 ]] || { echo "$out" >&2; fail "fsck_msdos rejected the $label image (exit $status)"; }
  grep -q "Phase 3" <<<"$out" || { echo "$out" >&2; fail "fsck_msdos did not reach phase 3 on the $label image"; }
  # The phase headings themselves say "Orphan Clusters", so they are dropped
  # before the complaint words are looked for.
  grep -v "^\*\* Phase" <<<"$out" \
    | grep -qiE "difference|differ|orphan|truncat|bad sector|invalid|marked|FATs" \
    && { echo "$out" >&2; fail "fsck_msdos reported a problem on the $label image"; }
  FSCK_SUMMARY="$(grep -E '^Warning|files,' <<<"$out" | tail -1)"
}

fsck_clean "$BASE_IMG" "as-built"
echo "IMAGE: pass  fsck_msdos accepts the volume BEFORE the guest touches it: $FSCK_SUMMARY"

# Mount it and take the two files the guest must not damage.
mkdir -p "$MOUNTPOINT"
ATTACH_OUT="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nobrowse \
                -mountpoint "$MOUNTPOINT" "$BASE_IMG" 2>&1)"
ATTACHED="$(awk '/^\/dev\// {print $1; exit}' <<<"$ATTACH_OUT")"
[[ -n "$ATTACHED" ]] || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount the as-built image"; }
KEEP_LONG="keep-this-file-exactly-as-it-is.bin"
[[ -f "$MOUNTPOINT/$KEEP_LONG" ]] || { hdiutil detach "$ATTACHED" >/dev/null 2>&1; ATTACHED=""; fail "the mounted volume has no $KEEP_LONG"; }
cp "$MOUNTPOINT/$KEEP_LONG" "$WORKDIR/keep-before.bin"
cp "$MOUNTPOINT/SEED.TXT" "$WORKDIR/seed-before.bin"
[[ -f "$MOUNTPOINT/NEW.BIN" ]] && { hdiutil detach "$ATTACHED" >/dev/null 2>&1; ATTACHED=""; fail "NEW.BIN is ALREADY on the as-built volume — the guest creating it would prove nothing"; }
hdiutil detach "$ATTACHED" >/dev/null 2>&1
ATTACHED=""
cmp -s "$WORKDIR/keep-before.bin" "$BASE_IMG.keep" \
  || fail "KEEP.BIN read through macOS's msdos driver is not the file make-image.py wrote"
cmp -s "$WORKDIR/seed-before.bin" "$BASE_IMG.seed" \
  || fail "SEED.TXT read through macOS's msdos driver is not the file make-image.py wrote"
echo "IMAGE: pass  macOS's own msdos driver mounts the as-built volume; KEEP.BIN ($(wc -c <"$WORKDIR/keep-before.bin" | tr -d ' ') bytes) and SEED.TXT ($(wc -c <"$WORKDIR/seed-before.bin" | tr -d ' ')) read back byte-for-byte, and there is no NEW.BIN on it"

# ---------------------------------------------------------------------------
# Step 5 — derive every expectation, INCLUDING WHICH CLUSTERS THE KERNEL WILL
# ALLOCATE, from the volume and the ELFs.
# ---------------------------------------------------------------------------
DERIVED="$WORKDIR/derived.txt"
python3 "$SCRIPT_DIR/derive.py" "$LAYOUT" "$FULL_LAYOUT" "$PROGDIR/prog.elf" \
  "$PROGDIR/progn.elf" "$PROGDIR/verify.elf" "$CORE_DIR/kernel" > "$DERIVED" \
  || fail "derive.py could not derive the expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
[[ -n "$(d new_fnv_hex)" ]] || fail "derive.py produced no new_fnv"
echo "DERIVED: NEW.BIN will be $(d new_bytes) bytes written in $(d chunk)-byte pieces onto clusters $(d new_chain)"
echo "DERIVED: that chain goes BACKWARDS $(d new_backward_links) time(s); the file must hash to $(d new_fnv_hex), SEED.TXT to $(d seed_fnv_hex), EMPTY.TXT to $(d zero_fnv_hex) and SCRATCH.BIN to $(d scratch_fnv_hex)"
echo "DERIVED: the kernel must write $(d disk_writes) sectors in total — $(d data_sectors) of data, $(d fat_entry_writes) FAT entries times $( python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['num_fats'])" "$LAYOUT") copies, and $(d dir_writes) directory sectors"

# ---------------------------------------------------------------------------
# Step 6 — the boots. SIX of them, and every one gets its OWN COPY of an image,
# because five of them change what they are given.
# ---------------------------------------------------------------------------
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5" img="$6"
  shift 6
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port=$(( 47500 + ($$ % 8000) + portoff ))
  timeout 600 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$img,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  python3 "$DRIVER" \
    --port "$port" \
    --serial "$ser" \
    --wait-for 'M1 END\n' \
    --png "$png" \
    --screen-text "$outdir/screen.txt" \
    --keys "$keys" \
    "$@"
  local drive_status=$?
  wait "$qemu_pid" 2>/dev/null
  local qemu_status=$?
  if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot (log above)"
  fi
}

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

# `frames` brackets the session: the frame allocator's free count must be
# identical before and after, which is the leak check for everything the loader
# and the file syscalls touched.
#
# `ls` AFTER the program is not decoration. It is the KERNEL's own read path
# looking at a directory the KERNEL's write path has just changed, from ring 0,
# through the code M14 shipped and M16 did not touch — and the entry it prints
# for NEW.BIN carries the first cluster and the size that derive.py predicted.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run prog.elf"),ret,wait:120000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "ls"),ret,wait:2500"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:1500"

MAIN_IMG="$WORKDIR/main.img"
cp "$BASE_IMG" "$MAIN_IMG"
SHOT_PNG="$CORE_DIR/build/screenshot-filewrite.png"
drive_session "$WORKDIR/main" "$SESSION_KEYS" "$SHOT_PNG" "main" 0 "$MAIN_IMG"
SERIAL="$WORKDIR/main/serial.txt"
SCREEN="$WORKDIR/main/screen.txt"
[[ -s "$SERIAL" ]] || fail "the main boot captured no serial output at all"

have() { grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { grep -qF -- "$1" "$SERIAL" && fail "the transcript contains what it must not: $1"; }

# ---------------------------------------------------------------------------
# Step 7 — the derived checks on the main boot.
# ---------------------------------------------------------------------------

# 7a. A FILE THAT WAS ALREADY THERE WAS REPLACED.
have "USER WRITE SEED WROTE $(d seed_new) REF 0 CLOSE 0"
have "USER WRITE SEED BACK $(d seed_new) H $(d seed_fnv_hex)"
echo "CHECK 7a: pass  SEED.TXT arrived with $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['seed_bytes'])" "$LAYOUT") bytes on $(d seed_freed) scattered clusters and left with $(d seed_new) on $(d seed_chain); the program read back exactly what it wrote"

# 7b. A FILE THAT WAS NOT THERE IS THERE, AND ITS BYTES ARE THE PROGRAM'S.
have "USER WRITE NEW WROTE $(d new_bytes) REF 0 CLOSE 0"
have "USER WRITE NEW BACK $(d new_bytes) H $(d new_fnv_hex)"
echo "CHECK 7b: pass  the program created NEW.BIN, wrote all $(d new_bytes) bytes of it in $(d chunk)-byte pieces, closed it, reopened it and read back the same $(d new_fnv_hex) the host computes"

# 7c. A FILE OF NO BYTES AT ALL, BOTH WAYS ROUND.
have "USER WRITE EMPTY CLOSE 0 OPEN $(d eempty)"
have "USER WRITE ZERO WROTE $(d zero_new) BACK $(d zero_new) H $(d zero_fnv_hex)"
echo "CHECK 7c: pass  EMPTY2.TX was created and closed without a byte and opening it for READING is $(d eempty); EMPTY.TXT was a zero-length file already on the volume and now has $(d zero_new) bytes hashing to $(d zero_fnv_hex)"

# 7d. EVERY REFUSAL, OBSERVED FROM RING 3 AS A RETURN VALUE.
have "USER WRITE R MODEW $(d ebadmode) MODER $(d ebadmode) MODES $(d ebadmode) MODEO $(d ebadmode)"
have "USER WRITE R PTR $(d ebadptr) LEN0 $(d ebadlen) LENB $(d ebadlen) FD $(d ebadfd) CLOSED $(d ebadfd)"
have "USER WRITE R HOLE $(d ebadptr) STRADDLE $(d ebadptr)"
have "USER WRITE R ISDIR $(d eisdir) BADNAME $(d ebadname) RODATA $(d ro_bytes) CLOSE 0"
echo "CHECK 7d: pass  thirteen refusals came back to ring 3 as return values: a source page INSIDE the program's window that is not mapped, a range whose FIRST page is mapped and whose second is not, fdwrite to a READ descriptor, read and seek on a WRITE descriptor, an open mode that is neither, a pointer outside the program, a zero length, a length above $(d write_max), a descriptor number nobody has, a descriptor that was just closed, create(\"SUB\") on a subdirectory and create() of a name FAT forbids"

# 7e. THE ONE THAT MUST SUCCEED, AND THE PROPERTY IT ESTABLISHES.
#
# `__ro_start` is present, user-accessible and NOT writable. `read` into it is
# refused (that is M15's check); `fdwrite` OUT of it must go through, because a
# source needs the USER bit and does not need the WRITABLE one. If the write-side
# validator had been reused here, this would be $(d ebadptr) and SCRATCH.BIN
# would be empty.
have "USER WRITE SCRATCH BACK $(d ro_bytes) H $(d scratch_fnv_hex)"
havent "USER WRITE R ISDIR $(d eisdir) BADNAME $(d ebadname) RODATA $(( 16#$(d ebadptr) ))"
echo "CHECK 7e: pass  fdwrite() out of the program's own read-only segment SUCCEEDED with $(d ro_bytes) bytes, and SCRATCH.BIN hashes to $(d scratch_fnv_hex) — which is what the host computes over the first $(d ro_bytes) bytes of prog.elf's R+X segment"

# 7f. THE PROGRAM'S OWN IMAGE IS UNCHANGED.
SELF_LINE="USER WRITE SELF $(d self_fnv_hex) $(d self_bytes)"
[[ $(grep -cF -- "$SELF_LINE" "$SERIAL") -eq 2 ]] \
  || fail "the program's R+X segment does not hash to $(d self_fnv_hex) both before and after the session"
echo "CHECK 7f: pass  the program's own R+X segment hashes to $(d self_fnv_hex) both before and after $(d write_calls) writes, one of which read out of it"

# 7g. THE KERNEL'S OWN ACCOUNT OF THE SESSION, EVERY FIELD DERIVED.
FILEW_LINE=$(printf "FILEW WRITES %08X BYTES %08X SECTORS %08X CREATED %08X TRUNC %08X FLUSH %08X DISKW %08X ALLOC %08X FREED %08X" \
  "$(d write_calls)" "$(d write_bytes)" "$(d data_sectors)" "$(d creates)" \
  "$(d truncs)" "$(d flushes)" "$(d disk_writes)" "$(d allocs)" "$(d frees)")
have "$FILEW_LINE"
FILE_LINE=$(printf "FILE OPENS %08X READS %08X" 10 "$(d read_calls)")
have "$FILE_LINE"
echo "CHECK 7g: pass  the kernel's own line reports $(d write_calls) writes of $(d write_bytes) bytes over $(d data_sectors) data sectors, $(d creates) files created, $(d truncs) truncated, $(d flushes) directory entries flushed, $(d disk_writes) sectors written to the drive in total, $(d allocs) clusters allocated and $(d frees) freed — every one derived from prog.c's call sequence and the volume's free set, and the DISKW figure is what it is only because BOTH copies of the FAT are written"

# 7h. THE KERNEL'S READ PATH SEES WHAT THE KERNEL'S WRITE PATH MADE.
#
# `ls`, typed at the shell after the program has exited, is M14's directory
# walker looking at a directory M16 changed. The entry it prints carries the
# first cluster and the size derive.py predicted BEFORE the boot.
NEW_FIRST=$(cut -d, -f1 <<<"$(d new_chain)")
LS_LINE=$(printf "FS ENT %02X NAME NEW     .BIN ATTR 20 CLUS %04X SIZE %08X" \
  "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['ghost_entry'])" "$LAYOUT")" \
  "$NEW_FIRST" "$(d new_bytes)")
have "$LS_LINE"
echo "CHECK 7h: pass  \`ls\` shows NEW.BIN in the root directory at entry $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['ghost_entry'])" "$LAYOUT") — THE SLOT A DELETED ENTRY OCCUPIED — with first cluster $NEW_FIRST and size $(d new_bytes), all three of them predicted before the boot"

# 7i. NO FRAME LEAKED.
FREE_BEFORE=$(grep -m1 "^PMM MANAGED" "$SERIAL" | sed -E 's/.*FREE ([0-9A-F]+).*/\1/')
FREE_AFTER=$(grep "^PMM MANAGED" "$SERIAL" | tail -1 | sed -E 's/.*FREE ([0-9A-F]+).*/\1/')
[[ -n "$FREE_BEFORE" && "$FREE_BEFORE" == "$FREE_AFTER" ]] \
  || fail "the frame allocator had $FREE_BEFORE free frames before the session and $FREE_AFTER after"
echo "CHECK 7i: pass  the frame allocator's free count is identical before and after — $((16#$FREE_BEFORE)) frames"

# 7j. M1's GOLDEN IS STILL A PREFIX, BYTE FOR BYTE.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL" | cmp -s - "$M1_EXPECTED" \
  || fail "the first $M1_BYTES bytes of this boot are not m1-interrupts' golden. M16 grew a donated block that is initialised before the first byte of output; if it printed anything, it printed it there."
echo "CHECK 7j: pass  the first $M1_BYTES bytes are m1-interrupts' golden, byte for byte"

# 7k. THE EXIT STATUS IS A FUNCTION OF THE BYTES THAT REACHED THE DISK.
have "$(printf "ELF DONE EXIT %016X" "$(d status)")"
echo "CHECK 7k: pass  the program exited $(d status_hex), which the host computes from the bytes it required NEW.BIN to contain"

# ---------------------------------------------------------------------------
# Step 8 — THE HOST TOOLS, AFTER. THIS IS THE MILESTONE.
#
# Everything above was this kernel's account of what it did. A filesystem driver
# that is wrong in a self-consistent way passes all of it. What follows is two
# programs nobody here wrote reading the volume the guest left behind.
# ---------------------------------------------------------------------------
fsck_clean "$MAIN_IMG" "written"
echo "CHECK 8a: pass  fsck_msdos accepts the volume AFTER the guest wrote to it, with no lost chain, no FAT difference and no bad directory: $FSCK_SUMMARY"

# 8b. BOTH COPIES OF THE FAT ARE IDENTICAL, and NEW.BIN's chain is the one
#     derive.py predicted before the boot.
python3 - "$MAIN_IMG" "$LAYOUT" "$(d new_chain)" "$(d seed_chain)" "$(d zero_chain)" "$(d scratch_chain)" <<'PY' || fail "the volume the guest wrote does not have the structure derive.py predicted"
import json, struct, sys
img = open(sys.argv[1], "rb").read()
lay = json.load(open(sys.argv[2]))
want = {"NEW.BIN": sys.argv[3], "SEED.TXT": sys.argv[4],
        "EMPTY.TXT": sys.argv[5], "SCRATCH.BIN": sys.argv[6]}
S = lay["bytes_per_sector"]
fs, fsz, nf = lay["fat_start"], lay["fat_sectors"], lay["num_fats"]
fat = img[fs * S:(fs + fsz) * S]
bad = []
for n in range(1, nf):
    other = img[(fs + n * fsz) * S:(fs + (n + 1) * fsz) * S]
    if other != fat:
        first = next(i for i in range(len(fat)) if fat[i] != other[i])
        bad.append("FAT copy %d differs from copy 0, first at byte %d — a volume "
                   "`fsck_msdos` calls 'FATs differ' and a host driver may read "
                   "from either" % (n, first))
root = img[lay["root_start"] * S:(lay["root_start"] + lay["root_sectors"]) * S]
seen = {}
for i in range(lay["root_entries"]):
    e = root[i * 32:(i + 1) * 32]
    if e[0] == 0:
        break
    if e[0] == 0xE5 or e[11] == 0x0F:
        continue
    raw = e[:11].decode("latin1")
    name = raw[:8].rstrip() + ("." + raw[8:].rstrip() if raw[8:].strip() else "")
    first = struct.unpack_from("<H", e, 26)[0]
    size = struct.unpack_from("<I", e, 28)[0]
    hi = struct.unpack_from("<H", e, 20)[0]
    if hi:
        bad.append("%s's DIR_FstClusHI is %d and must be 0 on FAT16" % (name, hi))
    chain, c = [], first
    while 2 <= c < 0xFFF8 and len(chain) < 5000:
        chain.append(c)
        c = struct.unpack_from("<H", fat, c * 2)[0]
    seen[name] = (chain, size, e[11])
for name, spec in want.items():
    if name not in seen:
        bad.append("%s is not in the root directory the guest left behind" % name)
        continue
    got, size, attr = seen[name]
    exp = [int(x) for x in spec.split(",")] if spec else []
    if got != exp:
        bad.append("%s's chain is %s and derive.py predicted %s" % (name, got, exp))
    if attr != 0x20:
        bad.append("%s's attribute byte is %#x, expected 0x20 (ARCHIVE)" % (name, attr))
if "EMPTY2.TX" not in seen:
    bad.append("EMPTY2.TX is not in the root directory")
elif seen["EMPTY2.TX"][0] or seen["EMPTY2.TX"][1]:
    bad.append("EMPTY2.TX has clusters or a size; a file created and never "
               "written must be first cluster 0 and size 0")
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "CHECK 8b: pass  both copies of the FAT are byte-for-byte identical; NEW.BIN's chain is $(d new_chain) — every cluster of it the one derive.py predicted, including the one that goes BACKWARDS; SEED.TXT is on $(d seed_chain), EMPTY.TXT on $(d zero_chain), SCRATCH.BIN on $(d scratch_chain); EMPTY2.TX has first cluster 0 and size 0; and no entry has a non-zero FAT32 high cluster word"

# 8c. macOS's OWN msdos DRIVER READS EVERY FILE THE GUEST WROTE.
mkdir -p "$MOUNTPOINT"
ATTACH_OUT="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nobrowse \
                -mountpoint "$MOUNTPOINT" "$MAIN_IMG" 2>&1)"
ATTACHED="$(awk '/^\/dev\// {print $1; exit}' <<<"$ATTACH_OUT")"
[[ -n "$ATTACHED" ]] || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount the image the guest wrote — macOS's own msdos driver does not think this is a FAT volume any more"; }
for f in NEW.BIN SEED.TXT EMPTY.TXT SCRATCH.BIN EMPTY2.TX; do
  cp "$MOUNTPOINT/$f" "$WORKDIR/host-$f" 2>/dev/null \
    || { hdiutil detach "$ATTACHED" >/dev/null 2>&1; ATTACHED=""; fail "the mounted volume has no $f"; }
done
cp "$MOUNTPOINT/$KEEP_LONG" "$WORKDIR/keep-after.bin" \
  || { hdiutil detach "$ATTACHED" >/dev/null 2>&1; ATTACHED=""; fail "the mounted volume has lost $KEEP_LONG"; }
HOST_LS="$(ls "$MOUNTPOINT")"
hdiutil detach "$ATTACHED" >/dev/null 2>&1
ATTACHED=""

python3 - "$WORKDIR" "$SCRIPT_DIR/prog.c" "$PROGDIR/prog.elf" "$(d ro_bytes)" <<'PY' || fail "a file the guest wrote does not read back byte-for-byte through macOS's own msdos driver"
import re, struct, sys
work, progc, elf, ro_bytes = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
src = open(progc).read()


def c(name):
    return int(re.search(r"^#define %s (\d+)" % name, src, re.M).group(1))


def new_byte(i):
    return ((i * 181) ^ (i >> 3) ^ ((i * i) >> 5) ^ 0x7E) & 0xFF


def seed_byte(i):
    return ((i * 211) + (i >> 1) + 0x2D) & 0xFF


def zero_byte(i):
    return (0x61 + (i % 26)) & 0xFF


def ro_range(path):
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
    raise SystemExit("no executable PT_LOAD in %s" % path)


want = {
    "NEW.BIN": bytes(new_byte(i) for i in range(c("NEW_BYTES"))),
    "SEED.TXT": bytes(seed_byte(i) for i in range(c("SEED_NEW"))),
    "EMPTY.TXT": bytes(zero_byte(i) for i in range(c("ZERO_NEW"))),
    "SCRATCH.BIN": ro_range(elf)[:ro_bytes],
    "EMPTY2.TX": b"",
}
bad = []
for name, expect in want.items():
    got = open("%s/host-%s" % (work, name), "rb").read()
    if got == expect:
        continue
    if len(got) != len(expect):
        bad.append("%s is %d bytes through the host driver and the program wrote %d"
                   % (name, len(got), len(expect)))
        continue
    first = next(i for i in range(len(got)) if got[i] != expect[i])
    bad.append("%s differs from what the program wrote at byte %d (%#04x vs %#04x)"
               % (name, first, got[first], expect[first]))

# THE ONE THAT SAYS THE SLACK IS DEFINED. Every free cluster on the as-built
# volume held make-image.py's background pattern, whose every sector begins
# "OSCORTEX SECTOR". If any of it survived into a file the guest wrote, the
# kernel failed to define the bytes past the end of a partial sector.
for name in ("NEW.BIN", "SEED.TXT", "EMPTY.TXT", "SCRATCH.BIN"):
    if b"OSCORTEX SECTOR" in open("%s/host-%s" % (work, name), "rb").read():
        bad.append("%s contains the volume's background pattern — the kernel left "
                   "part of a sector it wrote undefined" % name)

# THE OLD SEED.TXT IS GONE. Not one byte of the file that used to be there may
# be readable through the name.
old = open("%s/seed-before.bin" % work, "rb").read()
now = open("%s/host-SEED.TXT" % work, "rb").read()
if old[:8] in now or (len(now) >= 32 and now[:32] in old):
    bad.append("SEED.TXT still contains bytes of the file it replaced")

for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
cmp -s "$WORKDIR/keep-before.bin" "$WORKDIR/keep-after.bin" \
  || fail "KEEP.BIN CHANGED. It occupies every even cluster of the band the guest allocated into, so this is what a contiguous writer, or a data-region offset wrong by one cluster, destroys. $(cmp "$WORKDIR/keep-before.bin" "$WORKDIR/keep-after.bin" 2>&1 | head -1)"
echo "CHECK 8c: pass  macOS's own msdos driver mounts the written volume and reads NEW.BIN ($(d new_bytes) bytes), SEED.TXT ($(d seed_new)), EMPTY.TXT ($(d zero_new)), SCRATCH.BIN ($(d ro_bytes)) and a zero-length EMPTY2.TX back BYTE-FOR-BYTE against payloads this harness generated independently; none of them carries a byte of the volume's background pattern; not one byte of the old SEED.TXT survives; and KEEP.BIN's 307200 bytes — on the clusters INTERLEAVED with NEW.BIN's — are unchanged"
echo "         the volume the host sees is: $(tr '\n' ' ' <<<"$HOST_LS")"

# ---------------------------------------------------------------------------
# Step 9 — THE SECOND BOOT. The machine is switched off and on, and a program
# with no `fdwrite` and no `create` in it (build-progs.sh checked) reads what
# the first boot wrote.
#
# THIS IS THE PROPERTY THAT MATTERS. Everything above could in principle be
# satisfied by a kernel that kept the file in memory and handed it back. The
# image is copied first, so the check afterwards can also require that a
# READ-ONLY boot changed nothing at all.
# ---------------------------------------------------------------------------
PERSIST_IMG="$WORKDIR/persist.img"
cp "$MAIN_IMG" "$PERSIST_IMG"
BEFORE_SUM=$(shasum -a 256 "$PERSIST_IMG" | cut -d' ' -f1)
VERIFY_KEYS="$(typekeys "run verify.elf"),ret,wait:25000"
drive_session "$WORKDIR/persist" "$VERIFY_KEYS" "$WORKDIR/persist.png" "persistence" 11 "$PERSIST_IMG"
PSER="$WORKDIR/persist/serial.txt"
phave() { grep -qF -- "$1" "$PSER" || { sed -n '/M1 END/,$p' "$PSER" >&2; fail "the second boot's transcript does not contain: $1"; }; }
phave "USER WRITE V NEW $(d new_bytes) H $(d new_fnv_hex)"
phave "USER WRITE V SEED $(d seed_new) H $(d seed_fnv_hex)"
phave "USER WRITE V ZERO $(d zero_new) H $(d zero_fnv_hex)"
phave "USER WRITE V SCRATCH $(d ro_bytes) H $(d scratch_fnv_hex)"
phave "USER WRITE V EMPTY $(d eempty)"
phave "$(printf "ELF DONE EXIT %016X" "$(d status)")"
grep -qF -- "FILEW WRITES" "$PSER" \
  && fail "the read-only boot printed a FILEW line — VERIFY.ELF wrote something"
AFTER_SUM=$(shasum -a 256 "$PERSIST_IMG" | cut -d' ' -f1)
[[ "$BEFORE_SUM" == "$AFTER_SUM" ]] \
  || fail "the read-only boot CHANGED the image (sha256 $BEFORE_SUM -> $AFTER_SUM)"
echo "CHECK 9: pass  a SECOND BOOT of the machine, against the image the first one wrote, read NEW.BIN back as $(d new_fnv_hex), SEED.TXT as $(d seed_fnv_hex), EMPTY.TXT as $(d zero_fnv_hex) and SCRATCH.BIN as $(d scratch_fnv_hex), found EMPTY2.TX still a zero-length file, exited with the same derived status — and left the image byte-for-byte identical, sha256 $BEFORE_SUM"

# ---------------------------------------------------------------------------
# Step 10 — RUNNING OUT OF DISK. The `full` volume has five free clusters, ten
# once SEED.TXT is truncated and eight left after its rewrite; the program wants
# twenty-two for NEW.BIN alone.
# ---------------------------------------------------------------------------
FULL_RUN="$WORKDIR/full-run.img"
cp "$FULL_IMG" "$FULL_RUN"
FULL_KEYS="$(typekeys "run prog.elf"),ret,wait:60000"
drive_session "$WORKDIR/full" "$FULL_KEYS" "$WORKDIR/full.png" "full-volume" 22 "$FULL_RUN"
FSER="$WORKDIR/full/serial.txt"
fhave() { grep -qF -- "$1" "$FSER" || { sed -n '/M1 END/,$p' "$FSER" >&2; fail "the full-volume boot's transcript does not contain: $1"; }; }
fhave "USER WRITE NEW WROTE $(d full_new_bytes) REF $(d enospace) CLOSE 0"
grep -qF -- "USER WRITE NEW WROTE $(d new_bytes)" "$FSER" \
  && fail "the full-volume boot claims it wrote the whole file"
fhave "USER WRITE NEW BACK $(d full_new_bytes) H $(d full_new_fnv_hex)"
fhave "$(printf "ELF DONE EXIT %016X" "$(d full_status)")"
fsck_clean "$FULL_RUN" "full-volume"
echo "CHECK 10: pass  on a volume with room for $(( $(d full_new_bytes) / 1024 )) more clusters the write went SHORT at exactly $(d full_new_bytes) bytes and the next call was refused with $(d enospace); the truncated file reads back as $(d full_new_fnv_hex), the program exited $(d full_status_hex), and fsck_msdos still calls the volume clean: $FSCK_SUMMARY"

# ---------------------------------------------------------------------------
# Step 11 — THE NEGATIVE CONTROL, on the volume where its one difference
# matters. Same source, same kernel, same disk. It adds what it ASKED for
# instead of what fdwrite RETURNED.
# ---------------------------------------------------------------------------
NEG_RUN="$WORKDIR/neg-run.img"
cp "$FULL_IMG" "$NEG_RUN"
NEG_KEYS="$(typekeys "run progn.elf"),ret,wait:60000"
drive_session "$WORKDIR/neg" "$NEG_KEYS" "$WORKDIR/neg.png" "negative-control" 33 "$NEG_RUN"
NSER="$WORKDIR/neg/serial.txt"
grep -qF -- "USER WRITE NEW WROTE $(d full_neg_bytes) REF $(d enospace) CLOSE 0" "$NSER" \
  || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "the control boot did not report the WRONG byte count $(d full_neg_bytes)"; }
grep -qF -- "USER WRITE NEW WROTE $(d full_new_bytes) REF" "$NSER" \
  && fail "the control boot reported the RIGHT byte count — its one difference did nothing"
# ... and the KERNEL was right, which is what the disk says.
grep -qF -- "USER WRITE NEW BACK $(d full_new_bytes) H $(d full_new_fnv_hex)" "$NSER" \
  || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "the control boot's read-back does not agree with the real program's"; }
fsck_clean "$NEG_RUN" "negative-control"
python3 - "$NEG_RUN" "$FULL_RUN" <<'PY' || fail "the control boot left a different volume from the real program's, so the difference between them is not confined to userland"
import sys
a = open(sys.argv[1], "rb").read()
b = open(sys.argv[2], "rb").read()
if len(a) != len(b):
    raise SystemExit(1)
# The two images differ only where the two PROGRAM BINARIES sit; every byte of
# every file the guest WROTE must be identical.
diff = [i for i in range(len(a)) if a[i] != b[i]]
print("    (%d bytes differ between the two volumes)" % len(diff))
sys.exit(1 if diff else 0)
PY
echo "CHECK 11: pass  the control build — one \`#if\` different, counting what it ASKED for instead of what fdwrite RETURNED — reported $(d full_neg_bytes) bytes where the real program reported $(d full_new_bytes), and the DISK agrees with the kernel: the two boots left byte-for-byte identical volumes and the file reads back as $(d full_new_fnv_hex) on both. The count fdwrite returns is load-bearing."

# ---------------------------------------------------------------------------
# Step 12 — TWO VOLUMES ON WHICH THE WRITE MUST NOT HAPPEN.
#
# A full root directory, and a SEED.TXT whose chain is a cycle. The second is
# the important one: it is refused BEFORE anything is freed, so the volume comes
# back byte-for-byte identical. A truncate that started walking before it had
# validated the chain would have freed part of one it did not understand — and
# that is a corruption a read test cannot see.
# ---------------------------------------------------------------------------
VAR_KEYS="$(typekeys "run prog.elf"),ret,wait:40000"

DIRFULL_IMG="$WORKDIR/m16-dirfull.img"
python3 "$SCRIPT_DIR/make-image.py" "$DIRFULL_IMG" "$PROGDIR/prog.elf" \
  "$PROGDIR/progn.elf" "$PROGDIR/verify.elf" --variant=dirfull >/dev/null \
  || fail "make-image.py could not write the dirfull variant"
fsck_clean "$DIRFULL_IMG" "dirfull as-built"
DIRFULL_RUN="$WORKDIR/dirfull-run.img"
cp "$DIRFULL_IMG" "$DIRFULL_RUN"
drive_session "$WORKDIR/dirfull" "$VAR_KEYS" "$WORKDIR/dirfull.png" "dirfull" 44 "$DIRFULL_RUN"
DSER="$WORKDIR/dirfull/serial.txt"
grep -qF -- "USER WRITE NEW CREATE $(d enospace)" "$DSER" \
  || { sed -n '/M1 END/,$p' "$DSER" >&2; fail "the dirfull boot did not refuse create(\"NEW.BIN\") with $(d enospace)"; }
grep -qF -- "USER WRITE NEW WROTE" "$DSER" \
  && fail "the dirfull boot wrote to a file it could not create"
grep -qF -- "$(printf "ELF DONE EXIT %016X" 18)" "$DSER" \
  || fail "the dirfull boot's program did not exit with its own 0x12 create-failure code"
fsck_clean "$DIRFULL_RUN" "dirfull after"
echo "CHECK 12a: pass  on a volume whose 512 root-directory entries are all in use, create(\"NEW.BIN\") was refused with $(d enospace), nothing was written to it, the program exited 0x12, and fsck_msdos still calls the volume clean"

SEEDCYCLE_IMG="$WORKDIR/m16-seedcycle.img"
python3 "$SCRIPT_DIR/make-image.py" "$SEEDCYCLE_IMG" "$PROGDIR/prog.elf" \
  "$PROGDIR/progn.elf" "$PROGDIR/verify.elf" --variant=seedcycle >/dev/null \
  || fail "make-image.py could not write the seedcycle variant"
SEEDCYCLE_RUN="$WORKDIR/seedcycle-run.img"
cp "$SEEDCYCLE_IMG" "$SEEDCYCLE_RUN"
CYCLE_BEFORE=$(shasum -a 256 "$SEEDCYCLE_RUN" | cut -d' ' -f1)
drive_session "$WORKDIR/seedcycle" "$VAR_KEYS" "$WORKDIR/seedcycle.png" "seedcycle" 55 "$SEEDCYCLE_RUN"
CSER="$WORKDIR/seedcycle/serial.txt"
grep -qF -- "USER WRITE SEED CREATE $(d eio)" "$CSER" \
  || { sed -n '/M1 END/,$p' "$CSER" >&2; fail "the seedcycle boot did not refuse create(\"SEED.TXT\") with $(d eio)"; }
grep -qF -- "$(printf "ELF DONE EXIT %016X" 17)" "$CSER" \
  || fail "the seedcycle boot's program did not exit with its own 0x11 create-failure code"
grep -qF -- "FILEW WRITES" "$CSER" \
  && fail "the seedcycle boot printed a FILEW line — something reached the drive on a volume whose chain the kernel had refused to understand"
CYCLE_AFTER=$(shasum -a 256 "$SEEDCYCLE_RUN" | cut -d' ' -f1)
[[ "$CYCLE_BEFORE" == "$CYCLE_AFTER" ]] \
  || fail "the seedcycle boot CHANGED the image (sha256 $CYCLE_BEFORE -> $CYCLE_AFTER). Opening a file whose chain is a cycle for WRITING must refuse before it frees anything."
echo "CHECK 12b: pass  on a volume where SEED.TXT's chain loops back on itself, opening it for WRITING was refused with $(d eio) BEFORE anything was freed: the program exited 0x11, no FILEW line was printed at all, and the image is byte-for-byte identical, sha256 $CYCLE_BEFORE"

# 12c. A DIRECTORY WITH SOMETHING PAST ITS END MARKER.
#
# THIS BOOT EXISTS BECAUSE A MUTATION SURVIVED WITHOUT IT (GAP-0129). A FAT
# directory ends at its first 0x00 slot and nothing may look past it; when
# `fatDirCreate` CONSUMES that slot, the slot after it becomes the new marker,
# and `fatDirTerminate` is what makes sure it reads as one. Removing that call
# changed nothing observable on a freshly formatted volume, because the slot
# after the marker was already zero.
#
# This volume puts a live-looking `JUNK.BIN` one slot past the marker.
# `fsck_msdos` REFUSES it as built — "entries after end of directory" — and the
# guest, by doing the right thing, REPAIRS it: after the boot the volume is
# clean and JUNK.BIN is gone. A kernel that skipped the terminator leaves both
# the complaint and the entry.
DIRJUNK_IMG="$WORKDIR/m16-dirjunk.img"
python3 "$SCRIPT_DIR/make-image.py" "$DIRJUNK_IMG" "$PROGDIR/prog.elf" \
  "$PROGDIR/progn.elf" "$PROGDIR/verify.elf" --variant=dirjunk >/dev/null \
  || fail "make-image.py could not write the dirjunk variant"
DJ_OUT="$("$FSCK" -n "$DIRJUNK_IMG" 2>&1)"
grep -q "entries after end of directory" <<<"$DJ_OUT" \
  || { echo "$DJ_OUT" >&2; fail "fsck_msdos does NOT complain about the dirjunk volume as built, so this variant controls for nothing"; }
DIRJUNK_RUN="$WORKDIR/dirjunk-run.img"
cp "$DIRJUNK_IMG" "$DIRJUNK_RUN"
DJ_KEYS="$(typekeys "run prog.elf"),ret,wait:120000"
DJ_KEYS="$DJ_KEYS,$(typekeys "ls"),ret,wait:2500"
drive_session "$WORKDIR/dirjunk" "$DJ_KEYS" "$WORKDIR/dirjunk.png" "dirjunk" 66 "$DIRJUNK_RUN"
JSER="$WORKDIR/dirjunk/serial.txt"
grep -qF -- "USER WRITE NEW BACK $(d new_bytes) H $(d new_fnv_hex)" "$JSER" \
  || { sed -n '/M1 END/,$p' "$JSER" >&2; fail "the dirjunk boot did not write NEW.BIN correctly"; }
grep -qF -- "JUNK    .BIN" "$JSER" \
  && { sed -n '/M1 END/,$p' "$JSER" >&2; fail "\`ls\` printed JUNK.BIN — the entry past the directory's end marker survived, so fatDirTerminate did not run"; }
fsck_clean "$DIRJUNK_RUN" "dirjunk after"
echo "CHECK 12c: pass  on a volume with a live-looking entry ONE SLOT PAST the directory's end marker — which fsck_msdos refuses as built — the guest consumed the marker slot, re-established the marker, and left a volume fsck_msdos calls CLEAN with no JUNK.BIN in \`ls\`: $FSCK_SUMMARY"

# ---------------------------------------------------------------------------
# Step 13 — the byte-exact goldens.
# ---------------------------------------------------------------------------
if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL" "$EXPECTED_SERIAL"
  cp "$SCREEN" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $EXPECTED_SERIAL ($(wc -c <"$EXPECTED_SERIAL" | tr -d ' ') bytes) and $EXPECTED_SCREEN"
fi
[[ -f "$EXPECTED_SERIAL" ]] || fail "no golden at $EXPECTED_SERIAL (run once with --regen)"
[[ -f "$EXPECTED_SCREEN" ]] || fail "no golden at $EXPECTED_SCREEN (run once with --regen)"
SERIAL_BYTES=$(wc -c <"$EXPECTED_SERIAL" | tr -d ' ')
if ! cmp -s "$SERIAL" "$EXPECTED_SERIAL"; then
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL") | head -40 >&2
  fail "the serial capture does not match $EXPECTED_SERIAL byte for byte"
fi
echo "ASSERT: pass  the ${SERIAL_BYTES}-byte serial capture matches expected.txt exactly"
if ! cmp -s "$SCREEN" "$EXPECTED_SCREEN"; then
  diff "$EXPECTED_SCREEN" "$SCREEN" | head -20 >&2
  fail "the 80x25 VGA text buffer does not match expected-screen.txt"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"
[[ -s "$SHOT_PNG" ]] || fail "no screenshot at $SHOT_PNG"
head -c 8 "$SHOT_PNG" | cmp -s - <(printf '\x89PNG\r\n\x1a\n') || fail "$SHOT_PNG is not a PNG"
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

echo "M16-filewrite: PASS — dcc build -> assemble -> link -> clang builds core/user/libc's five objects AND ONE PROGRAM SOURCE THREE TIMES (the real one, a negative control that counts what it ASKED for instead of what fdwrite RETURNED, and a read-only VERIFY build with no fdwrite and no create in it) -> make-image.py writes a ${IMG_BYTES}-byte FAT16 volume whose FREE SPACE IS FRAGMENTED BY CONSTRUCTION, KEEP.BIN holding every even cluster of a 600-cluster band so that a contiguous writer destroys it -> fsck_msdos and macOS's own msdos driver both accept it BEFORE the guest runs -> 8 structural checks (donated .bss 12768 -> 14048 with file_store one 2560-byte symbol whose FOUR regions tile exactly and fat_store unmoved at 1824, the storage seam exactly 4 call sites in one file, fileOwnsWrite and fileOwnsRead both bounding their pointer before touching it and differing in exactly the WRITABLE bit, ataWriteFrom defined once and called from exactly one place and ending in FLUSH CACHE with the only port_outw aimed at 0x1F0 inside it, fatSetEntry writing every copy of the FAT, all 25 of oslibc.h's file numbers read back out of file.dart with THIRTEEN distinct reachable refusals above one floor, shellStrHelp UNCHANGED at 2147 so no golden moves, and every @rodata table against its own doc comment and call site) -> verify-freestanding pass ($EXTERN_COUNT declared externs, none of them new) -> SEVEN real QEMU boots. A ${SERIAL_BYTES}-byte serial match with M1's ${M1_BYTES}-byte golden intact as a prefix; A C PROGRAM CREATING A FILE THAT WAS NOT ON THE VOLUME AND WRITING $(d new_bytes) BYTES TO IT in $(d chunk)-byte pieces -- a size that divides neither a sector nor a cluster nor the file -- onto the chain $(d new_chain), every cluster of which derive.py predicted from fat.dart's allocation policy before the boot and one link of which goes BACKWARDS by 2923 clusters; the same program replacing a 5000-byte SEED.TXT that was already there and freeing its five scattered clusters; a file created and closed without a byte, and a zero-length file that was already there given contents; thirteen refusals observed from ring 3 as return values, two of them pointer ranges no bounds check alone would catch; a write OUT OF the program's own read-only segment succeeding, which the write-side validator would have refused; fsck_msdos pronouncing the written volume CLEAN and macOS's own msdos driver mounting it and reading every file back BYTE-FOR-BYTE against payloads this harness generated independently, with KEEP.BIN's 307200 interleaved bytes unchanged and both copies of the FAT identical; A SECOND BOOT OF THE MACHINE finding all of it still there and changing nothing; a volume down to its last free clusters producing a SHORT write of exactly $(d full_new_bytes) bytes and then $(d enospace), still clean; the control build reporting $(d full_neg_bytes) where the kernel reported $(d full_new_bytes) and the DISK siding with the kernel; a full root directory refusing create() with nothing written; a cyclic chain refusing an open-for-write BEFORE freeing anything, leaving the image byte-for-byte identical; and a directory with a live-looking entry PAST its end marker, which fsck_msdos refuses as built and calls clean after the guest has re-established the marker. Screenshot at $SHOT_PNG"
exit 0
