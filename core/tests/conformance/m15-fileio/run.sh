#!/usr/bin/env bash
# core/tests/conformance/m15-fileio/run.sh
#
# Mechanical check of ROADMAP.md's M15 exit criterion: A C PROGRAM RUNNING IN
# RING 3 ON THIS OPERATING SYSTEM OPENS A FILE BY NAME, READS IT IN 116 PIECES
# AT OFFSETS IT CHOOSES, AND EXITS WITH A STATUS DERIVED FROM ITS CONTENTS.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# M14 gave the KERNEL a filesystem and M13 gave userland a C library, and the
# two did not touch: `run <name>` was the shell loading a program, and no
# program on this machine could read one byte of one file (GAP-0113). M15 adds
# four syscalls -- `open`, `read`, `close`, `seek` -- a per-program descriptor
# table, and a buffered reader in the library.
#
#   * THE PROGRAM COMPUTES SOMETHING THE HOST COMPUTED INDEPENDENTLY. prog.c
#     runs FNV-1a over the 20000 bytes of DATA.BIN as it reads them; derive.py
#     runs the same hash over the same file on the host. FNV-1a rather than a
#     sum BECAUSE A SUM IS INVARIANT UNDER A PERMUTATION OF CLUSTERS, which is
#     exactly the corruption a chain-ignoring reader produces.
#
#   * THE FILE'S CHAIN GOES BACKWARDS. M14's fragmentation was interleaved but
#     INCREASING, so a driver that sorted a chain would have passed it. DATA.BIN
#     runs 1500 -> 2997 -> 2494 -> 1991 -> 3488 ... and make-image.py refuses to
#     write an image with fewer than eight backward links.
#
#   * THE CHUNK SIZE DIVIDES NOTHING. 173 bytes divides neither a sector (512)
#     nor a cluster (1024) nor the file (20000), so reads start mid-sector, end
#     mid-sector, cross sector boundaries and cross CLUSTER boundaries -- and
#     the last one is short.
#
#   * TWO FILES ARE OPEN AT ONCE AND READ ALTERNATELY. `fat.dart` holds ONE
#     cluster chain (GAP-0116 item 5). M15 did not make it bigger; it made it a
#     CACHE OF ONE that any descriptor can re-select. The alternating phase
#     forces a rebuild on every single read, and the kernel's own exit line
#     reports the count, which derive.py computes as exactly 2 * ALTN.
#
#   * THE SAME FILE IS OPEN TWICE WITH INDEPENDENT OFFSETS, and the two 16-byte
#     reads at two different offsets hash to two different derived values.
#
#   * A `read` INTO THE PROGRAM'S OWN R+X SEGMENT IS REFUSED. This is the check
#     M15 exists to get right: `read` is the first syscall in this kernel that
#     WRITES through a ring-3 pointer, and the read-side validator M9 built
#     would have accepted that pointer. The program hashes its own R+X segment
#     BEFORE and AFTER and both hashes must be the derived one.
#
#   * ELEVEN REFUSALS, EVERY ONE OBSERVED FROM RING 3 AS A RETURN VALUE, and
#     every one of the eleven values read back out of core/kernel/file.dart.
#
#   * A NEGATIVE CONTROL THAT IS A SECOND BUILD OF THE SAME SOURCE. PROGN.ELF
#     ignores the byte count `read` returns and hashes the whole 173-byte chunk.
#     It is wrong only on the LAST read of the file. derive.py computes what it
#     produces; this harness requires the control to print THAT and not the true
#     hash, and to exit with a different status.
#
#   * TWO MORE NEGATIVE CONTROLS THAT ARE BROKEN VOLUMES. `nodata` renames
#     DATA.BIN's directory entry and `datacycle` makes its chain a cycle; in
#     both the program's open() is refused, it says which refusal it got, and it
#     exits with its own error code instead of a hash.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * THERE ARE NO WRITES, ANYWHERE, AT ANY LAYER. GAP-0116 item 1 is unchanged
#     and this harness re-greps for it.
#   * NO DIRECTORIES, NO `stat`, NO `dup`, NO `stdin`, NO VFS. GAP-0122.
#   * NOTHING HERE IS CONCURRENT. One program, one address space at a time.
#
# Usage:
#   core/tests/conformance/m15-fileio/run.sh
#   ... --regen    rewrite the goldens from this boot (every derived check below
#                  still has to pass, so a wrong kernel cannot enshrine itself)
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "M15-fileio: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M15-fileio: FAIL — $1" >&2; exit 2; }

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths. Resolved to a real path
# here for the same reason m14-fat does it.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m15.XXXXXX")" || setup_error "mktemp failed"
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
  x86_64-elf-readelf -sW "$1" | awk -v s="$2" '$8==s {print $3; exit}'
}

# ---------------------------------------------------------------------------
# Step 2 — structural checks. Everything that can be established without
# booting is established without booting.
# ---------------------------------------------------------------------------

# 2a. THE DONATED BLOCK, AND THE THREE REGIONS INSIDE IT.
#
# 11488 -> 12768, and the 1280 is `file_store`. The three region offsets in
# file.dart are multiplied out against the block's own size here, because a
# region that ran past the end would corrupt whatever `.bss` follows and would
# do it silently -- `.bss` is not zeroed and nothing in this kernel guards it.
KDATA_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$KDATA_BSS_HEX" ]] || fail "kdata.o has no .bss section"
KDATA_BSS=$((16#$KDATA_BSS_HEX))
[[ "$KDATA_BSS" -eq 12768 ]] || fail "kdata.o .bss is $KDATA_BSS bytes, expected 12768 — 11488 through M14 plus file_store's 1280. If that changed, it changed deliberately and this number and docs/known-gaps.md GAP-0053's running total both move with it."
FILE_STORE_SIZE=$(symsize "$CORE_DIR/build/kdata.o" file_store)
[[ "$FILE_STORE_SIZE" == "1280" ]] || fail "kdata.o's file_store is ${FILE_STORE_SIZE:-missing} bytes, expected 1280"
[[ $(( KDATA_BSS - FILE_STORE_SIZE )) -eq 11488 ]] || fail "the .bss outside file_store is $(( KDATA_BSS - FILE_STORE_SIZE )), not M14's 11488 — M15 moved storage it does not own"

META_OFF=$(dartconst fileMetaOffset file.dart)
TABLE_OFF=$(dartconst fileTableOffset file.dart)
BUF_OFF=$(dartconst fileBufOffset file.dart)
STORE_BYTES=$(dartconst fileStoreBytes file.dart)
META_WORDS=$(dartconst fileMetaWords file.dart)
FD_WORDS=$(dartconst fileFdWords file.dart)
ROW_WORDS=$(dartconst fileRowWords file.dart)
MAX_FDS=$(dartconst fileMaxFds file.dart)
ROWS=$(dartconst fileRows file.dart)
RUN_ROW=$(dartconst fileRunRow file.dart)
PROC_MAX=$(dartconst procMax proc.dart)
[[ "$STORE_BYTES" -eq "$FILE_STORE_SIZE" ]] || fail "file.dart says fileStoreBytes=$STORE_BYTES and kdata.S donates $FILE_STORE_SIZE"
[[ "$META_OFF" -eq 0 ]] || fail "fileMetaOffset is $META_OFF, expected 0"
[[ $(( META_OFF + META_WORDS * 8 )) -eq "$TABLE_OFF" ]] \
  || fail "the metadata region ($META_WORDS words at $META_OFF) does not end where the table begins ($TABLE_OFF)"
[[ $(( ROW_WORDS )) -eq $(( MAX_FDS * FD_WORDS )) ]] \
  || fail "fileRowWords ($ROW_WORDS) is not fileMaxFds * fileFdWords ($MAX_FDS * $FD_WORDS)"
[[ $(( TABLE_OFF + ROWS * ROW_WORDS * 8 )) -eq "$BUF_OFF" ]] \
  || fail "the descriptor table ($ROWS rows of $ROW_WORDS words at $TABLE_OFF) does not end where the bounce buffer begins ($BUF_OFF)"
[[ $(( BUF_OFF + 512 )) -eq "$STORE_BYTES" ]] \
  || fail "the bounce buffer (512 bytes at $BUF_OFF) does not end at the block's end ($STORE_BYTES)"
[[ "$RUN_ROW" -eq "$PROC_MAX" ]] \
  || fail "fileRunRow is $RUN_ROW and proc.dart's procMax is $PROC_MAX — rows 0..procMax-1 must be the process slots and the row above them the \`run <name>\` program, or two programs would share descriptors"
[[ "$ROWS" -eq $(( PROC_MAX + 1 )) ]] || fail "fileRows is $ROWS, expected procMax + 1 = $(( PROC_MAX + 1 ))"
echo "STRUCTURAL: pass  kdata.o donates 12768 bytes of .bss, 1280 of them file_store: $META_WORDS metadata words at $META_OFF, $ROWS x $MAX_FDS x $FD_WORDS descriptor words at $TABLE_OFF, a 512-byte bounce buffer at $BUF_OFF, ending exactly at $STORE_BYTES"

# 2b. THE STORAGE SEAM: ONE ACCESSOR, THREE CALL SITES, ONE FILE (ADR-0011 §0).
CODE=$(grep -v '^[[:space:]]*//' "$CORE_DIR/kernel/file.dart")
SEAM=$(printf '%s\n' "$CODE" | grep -c "return file_store_addr()")
MENTIONS=$(printf '%s\n' "$CODE" | grep -c "file_store_addr")
[[ "$SEAM" -eq 3 ]] || fail "core/kernel/file.dart has $SEAM call sites of file_store_addr(), expected exactly 3 (fileMetaBase, fileTableBase, fileBufBase). A fourth turns the migration to DCDart mutable statics into an audit — ADR-0011 §0."
[[ "$MENTIONS" -eq 4 ]] || fail "file.dart names file_store_addr $MENTIONS times, expected 4: one @extern declaration and the three seam functions"
OUTSIDE=$(grep -rl "file_store_addr" "$CORE_DIR/kernel/" | grep -v "/file.dart$" | wc -l | tr -d ' ')
[[ "$OUTSIDE" -eq 0 ]] || fail "file_store_addr is named outside core/kernel/file.dart"
for f in fileMetaBase fileTableBase fileBufBase; do
  grep -q "u64 $f() {" "$CORE_DIR/kernel/file.dart" || fail "core/kernel/file.dart has no $f()"
done
echo "STRUCTURAL: pass  the storage seam is exactly 3 \`return file_store_addr()\` in file.dart and 0 anywhere else in core/kernel/"

# 2c. THE WRITE-SIDE POINTER CHECK IS A DIFFERENT FUNCTION FROM THE READ-SIDE
#     ONE, AND IT LOOKS AT A SECOND BIT.
#
# This is M15's security property and it is the one thing here that a boot alone
# would not pin down: the boot proves that ONE read into ONE read-only page was
# refused, and this proves the refusal comes from a general rule.
grep -q "u64 fileOwnsWrite(u64 ptr, u64 len) {" "$CORE_DIR/kernel/file.dart" \
  || fail "core/kernel/file.dart has no fileOwnsWrite"
python3 - "$CORE_DIR/kernel/file.dart" <<'PY' || fail "fileOwnsWrite does not check BOTH the user bit and the writable bit out of vmEffective, or it does arithmetic on ptr before bounding it"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"u64 fileOwnsWrite\(u64 ptr, u64 len\) \{(.*?)\n\}", src, re.S)
body = m.group(1)
bad = []
if "vmEffective(a)" not in body:
    bad.append("fileOwnsWrite does not consult vmEffective at all")
if "u64(2)" not in body:
    bad.append("fileOwnsWrite does not test bit 1 of vmEffective (the USER bit)")
if "u64(4)" not in body:
    bad.append("fileOwnsWrite does not test bit 2 of vmEffective (the WRITABLE bit) -- "
               "which is the whole of what makes it different from elfOwns")
# The bound on ptr must come before any arithmetic on it (ADR-0013 section 5):
# DCDart traps on overflow with a real ud2, so `ptr + len` on an unbounded ptr
# is a ring-3 program choosing which instruction the kernel executes next.
first_arith = body.find("ptr +")
first_bound = body.find("ptr >= u64(vmProgEnd)")
if first_bound < 0 or (first_arith >= 0 and first_arith < first_bound):
    bad.append("fileOwnsWrite does arithmetic on ptr before bounding it")
# And the loop must walk EVERY page, not just the first.
if "a = a + u64(vmPageBytes)" not in body:
    bad.append("fileOwnsWrite does not advance page by page, so a range spanning a "
               "read-only page after a writable one would be accepted")
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
# ...and there is exactly ONE store through a caller-supplied address in the
# whole file, in fileCopyOut, whose only caller validates first.
STORES=$(printf '%s\n' "$CODE" | grep -c "Pointer<u8>.fromAddress(dst")
[[ "$STORES" -eq 1 ]] || fail "core/kernel/file.dart writes through a \`dst\` pointer at $STORES places, expected exactly 1 (fileCopyOut). Every one of them is a place a user pointer could be written without validation."
grep -q "if (fileOwnsWrite(dst, len) < u64(1)) {" "$CORE_DIR/kernel/file.dart" \
  || fail "fileSysRead does not validate dst with fileOwnsWrite before copying"
echo "STRUCTURAL: pass  fileOwnsWrite bounds ptr before touching it, requires the USER bit AND the WRITABLE bit page by page, and is the gate on the one store to a caller-supplied address in the file"

# 2d. EVERY NUMBER oslibc.h KNOWS ABOUT FILE I/O IS THE KERNEL'S OWN.
for pair in "SYS_OPEN fileSysOpenNo file.dart" "SYS_READ fileSysReadNo file.dart" \
            "SYS_CLOSE fileSysCloseNo file.dart" "SYS_SEEK fileSysSeekNo file.dart" \
            "READ_MAX fileReadMax file.dart" "FILE_MAX_FDS fileMaxFds file.dart" \
            "FILE_NAME_MAX fileNameMax file.dart" \
            "FILE_ERR_FLOOR fileRetFloor file.dart" \
            "FILE_EBADFD fileRetBadFd file.dart" "FILE_EBADPTR fileRetBadPtr file.dart" \
            "FILE_EBADLEN fileRetBadLen file.dart" "FILE_ENOSLOT fileRetNoSlot file.dart" \
            "FILE_EBADNAME fileRetBadName file.dart" \
            "FILE_ENOTFOUND fileRetNotFound file.dart" \
            "FILE_EISDIR fileRetIsDir file.dart" "FILE_EEMPTY fileRetEmpty file.dart" \
            "FILE_EIO fileRetIo file.dart" "FILE_EBADSEEK fileRetBadSeek file.dart" \
            "FILE_ENOOWNER fileRetNoOwner file.dart"; do
  set -- $pair
  k=$(dartconst "$2" "$3")
  c=$(cdefine "$1")
  [[ -n "$k" && -n "$c" ]] || fail "could not compare $1 against $2 in core/kernel/$3"
  [[ "$k" -eq "$c" ]] || fail "oslibc.h has $1 = $c and core/kernel/$3 says $2 = $k. A library that disagrees with the kernel about what a refusal LOOKS LIKE will treat one as a byte count."
done
# Every refusal must be above the floor, and every RESULT must be below it.
FLOOR=$(dartconst fileRetFloor file.dart)
for name in fileRetBadFd fileRetBadPtr fileRetBadLen fileRetNoSlot fileRetBadName \
            fileRetNotFound fileRetIsDir fileRetEmpty fileRetIo fileRetBadSeek \
            fileRetNoOwner; do
  v=$(dartconst "$name" file.dart)
  [[ "$v" -ge "$FLOOR" ]] 2>/dev/null || python3 -c "import sys; sys.exit(0 if $v >= $FLOOR else 1)" \
    || fail "$name is below fileRetFloor, so a caller's one comparison would take it for a result"
done
python3 - <<PY || fail "the eleven refusal values are not distinct"
vals = [$(for n in fileRetBadFd fileRetBadPtr fileRetBadLen fileRetNoSlot fileRetBadName \
              fileRetNotFound fileRetIsDir fileRetEmpty fileRetIo fileRetBadSeek fileRetNoOwner; do
            printf '%s,' "$(dartconst "$n" file.dart)"; done)]
import sys
sys.exit(0 if len(set(vals)) == 11 else 1)
PY
READ_MAX_K=$(dartconst fileReadMax file.dart)
[[ "$READ_MAX_K" -eq $(cdefine RFILE_BUFSZ) ]] \
  || fail "RFILE_BUFSZ ($(cdefine RFILE_BUFSZ)) is not the kernel's fileReadMax ($READ_MAX_K) — the buffered layer would either waste a syscall or be refused"
echo "STRUCTURAL: pass  all nineteen of oslibc.h's file numbers -- four syscall numbers, three bounds, the floor and eleven distinct refusals all above it -- read back out of core/kernel/file.dart"

# 2e. THE HELP TEXT AND THE EXTERN COUNT: M15 ADDS NO SHELL COMMAND AND ONE
#     EXTERN.
#
# GAP-0105: `shellStrHelp` is asserted by m3, m4, m5, m6 and m14, and a
# milestone that moved it would move five goldens. M15's whole surface is
# syscalls, so it moves nothing.
HELP_SIZE=$(symsize "$CORE_DIR/build/kmain.o" shellStrHelp)
[[ "$HELP_SIZE" -eq 2147 ]] || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2147 — UNCHANGED from M14. M15 adds SYSCALLS, not commands; if it needed a command that is a different change and five goldens move with it."
echo "STRUCTURAL: pass  shellStrHelp is 2147 bytes, unchanged from M14 — M15 added four syscalls and no shell command"

# 2f. THE FILESYSTEM IS STILL READ-ONLY. GAP-0116 item 1, re-checked here
#     because M15 is the milestone at which somebody would be tempted.
grep -qE "ataWriteInto|ataWriteSector|fatWrite|fatSetDir|fatAlloc|fileWrite|fileSysWrite" \
  "$CORE_DIR/kernel/"*.dart \
  && fail "a write function appeared in core/kernel/ — M15 adds a READ path and GAP-0116 item 1 says there are no writes at any layer"
grep -qE "0x30|0x34" <(grep -E "ataCmd\w+ = " "$CORE_DIR/kernel/ata.dart") \
  && fail "ata.dart declares an ATA WRITE SECTORS opcode"
grep -qE "^#define O_(WRONLY|RDWR|CREAT|APPEND|TRUNC)" "$LIBC_DIR/oslibc.h" \
  && fail "oslibc.h defines an open mode — there is no write path to have one for"
echo "STRUCTURAL: pass  no write opcode, no write function and no open mode anywhere: the filesystem M15 reads from is still read-only end to end"

# 2g. EVERY @rodata TABLE IN file.dart IS THE SIZE ITS CALL SITE PASSES.
python3 - "$CORE_DIR/kernel/file.dart" "$CORE_DIR/build/kmain.o" <<'PY' || fail "a @rodata table in file.dart does not match the string its doc comment records, or the length its call site passes"
import re, subprocess, sys
src = open(sys.argv[1]).read()
obj = sys.argv[2]
sizes = {}
for line in subprocess.run(["x86_64-elf-readelf", "-sW", obj],
                           capture_output=True, text=True).stdout.splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == "OBJECT":
        sizes[f[7]] = int(f[2])
bad = []
# Each table's doc comment states the string and its byte count.
for m in re.finditer(r"/// `'((?:[^']|'')*)'` -- (\d+) bytes\.\n@rodata\n"
                     r"final List<u8> (\w+) = const \[(.*?)\];", src, re.S):
    text, want, name, body = m.group(1), int(m.group(2)), m.group(3), m.group(4)
    got = [int(x, 16) for x in re.findall(r"u8\((0x[0-9A-Fa-f]{2})\)", body)]
    if len(got) != want:
        bad.append("%s: the doc comment says %d bytes and the table has %d" % (name, want, len(got)))
    if bytes(got).decode("latin-1") != text:
        bad.append("%s: the table is %r and the doc comment says %r"
                   % (name, bytes(got).decode("latin-1"), text))
    if name in sizes and sizes[name] != want:
        bad.append("%s: kmain.o says %d bytes, the doc comment says %d" % (name, sizes[name], want))
    for cs in re.finditer(r"Rodata\.addressOf\(%s\), u64\((\d+)\)" % name, src):
        if int(cs.group(1)) != want:
            bad.append("%s: a call site passes %s and the table is %d bytes (GAP-0060)"
                       % (name, cs.group(1), want))
if not bad and len(re.findall(r"@rodata", src)) < 5:
    bad.append("file.dart has fewer than five @rodata tables; this check found nothing to check")
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  every @rodata table in file.dart matches its doc comment, kmain.o's symbol size and the length its call site passes"

# 2h. THE DESCRIPTORS ARE RELEASED ON THE TEARDOWN PATH, NOT ON THE EXIT PATH.
#
# Two of the callers of each of these are FAULTS. A descriptor table cleaned up
# only when the program was polite would let a faulting program hand its open
# files to whatever ran next.
grep -q "fileReleaseOwner(u64(fileRunRow))" "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart's elfTeardown does not release the \`run <name>\` program's descriptors"
grep -q "fileReleaseOwner(s)" "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart's procCleanup does not release the slot's descriptors"
grep -q "fileExitReport();" "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart's exit path does not call fileExitReport"
echo "STRUCTURAL: pass  descriptors are released by elfTeardown and procCleanup, both of which run on the fault path as well as the exit path"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1). 60 externs: M14's 59 plus
# file_store_addr, and nothing else.
# ---------------------------------------------------------------------------
VF_OUT="$(cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o 2>&1)"
VF_STATUS=$?
echo "$VF_OUT"
[[ $VF_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed on kmain.o"
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VF_OUT" | head -1 | grep -oE '[0-9]+')
[[ "$EXTERN_COUNT" -eq 60 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 60 — M14's 59 plus file_store_addr, and nothing else"
grep -qx "file_store_addr" "$CORE_DIR/build/kmain.o.externs" \
  || fail "file_store_addr is not among kmain.o's declared externs"
for obj in kdata.o portio.o; do
  (cd "$CORE_DIR" && bash scripts/verify-freestanding.sh "build/$obj" >/dev/null 2>&1) \
    || fail "verify-freestanding.sh failed on $obj"
done
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o, M14's 59 plus file_store_addr and nothing else; kdata.o and portio.o clean standalone"

# ---------------------------------------------------------------------------
# Step 4 — build the two programs and the volume, and have two independent
# tools agree it is a FAT16 volume before the kernel is allowed near it.
# ---------------------------------------------------------------------------
PROGDIR="$WORKDIR/progs"
BUILD_PROGS_OUT="$(bash "$SCRIPT_DIR/build-progs.sh" "$PROGDIR" 2>&1)"
BP_STATUS=$?
echo "$BUILD_PROGS_OUT"
[[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/m15.img"
LAYOUT="$WORKDIR/layout.json"
python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/prog.elf" "$PROGDIR/progn.elf" \
  || fail "make-image.py could not write the volume"
python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/prog.elf" "$PROGDIR/progn.elf" --json \
  > "$LAYOUT" || fail "make-image.py --json failed"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
[[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found; this harness will not certify a FAT volume no independent tool has read"
FSCK_OUT="$("$FSCK" -n "$DISK_IMG" 2>&1)"
FSCK_STATUS=$?
[[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image (exit $FSCK_STATUS)"; }
grep -q "Phase 3" <<<"$FSCK_OUT" || { echo "$FSCK_OUT" >&2; fail "fsck_msdos did not get as far as phase 3"; }
echo "IMAGE: pass  fsck_msdos accepts the volume: $(grep -E '^Warning|files,' <<<"$FSCK_OUT" | tail -1)"

MOUNT_VERIFIED="not attempted (no hdiutil)"
if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  ATTACH_OUT="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nobrowse \
                  -mountpoint "$MOUNTPOINT" "$DISK_IMG" 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo "$ATTACH_OUT" >&2
    fail "hdiutil could not mount the image — macOS's own msdos driver does not think this is a FAT volume"
  fi
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  for want in DATA.BIN SMALL.TXT PROG.ELF PROGN.ELF; do
    [[ -f "$MOUNTPOINT/$want" ]] || fail "the mounted volume has no $want"
  done
  cmp -s "$MOUNTPOINT/DATA.BIN" "$DISK_IMG.data" \
    || fail "macOS's msdos driver reads DATA.BIN back DIFFERENTLY from what was written — the scattered chain is wrong, and this kernel agreeing with the generator would prove nothing"
  # OTHER.BIN is behind three REAL long-filename entries, so the host driver
  # shows the long name and this kernel deliberately does not (GAP-0116 item 3).
  # Both facts are asserted here: the long name resolves for macOS, and the
  # PROGRAM reaches the same bytes by the 8.3 alias.
  LONGNAME=$(ls "$MOUNTPOINT" | grep -c 'other-data-with-a-long-name.bin')
  [[ "$LONGNAME" -eq 1 ]] \
    || fail "macOS does not see OTHER.BIN's long filename — the LFN entries on this volume are not the real thing"
  cmp -s "$MOUNTPOINT/other-data-with-a-long-name.bin" "$DISK_IMG.other" || fail "macOS reads OTHER.BIN back differently"
  cmp -s "$MOUNTPOINT/SMALL.TXT" "$DISK_IMG.small" || fail "macOS reads SMALL.TXT back differently"
  cmp -s "$MOUNTPOINT/PROG.ELF" "$PROGDIR/prog.elf" || fail "macOS reads PROG.ELF back differently"
  [[ -d "$MOUNTPOINT/SUB" ]] || fail "the mounted volume's SUB is not a directory"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  MOUNT_VERIFIED="mounted by macOS's own msdos driver; DATA.BIN, OTHER.BIN, SMALL.TXT and PROG.ELF all read back byte-for-byte along their scattered chains, and SUB is a directory, with OTHER.BIN reachable to the host only by its long name"
fi
echo "IMAGE: pass  $MOUNT_VERIFIED"

# ---------------------------------------------------------------------------
# Step 5 — derive every expectation from the volume that was just built.
# ---------------------------------------------------------------------------
DERIVED="$WORKDIR/derived.txt"
python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG" "$PROGDIR/prog.elf" "$PROGDIR/progn.elf" \
  "$CORE_DIR/kernel" > "$DERIVED" \
  || fail "derive.py could not derive the expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
[[ -n "$(d data_fnv_hex)" ]] || fail "derive.py produced no data_fnv"
BACKLINKS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['backward_links'])" "$LAYOUT")
CHAIN=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['files']['DATA.BIN']['chain'])" "$LAYOUT")
echo "DERIVED: DATA.BIN is $(d data_bytes) bytes on $CHAIN — $BACKLINKS of those links go BACKWARDS"
echo "DERIVED: the program must hash it to $(d data_fnv_hex) in $(d data_reads) reads of $(d chunk) bytes; a contiguous reader would get $(d contig_fnv_hex) and that must never appear; the control build must get $(d neg_fnv_hex)"

# ---------------------------------------------------------------------------
# Step 6 — the boots. FOUR: the real program, the negative-control build, and
# two deliberately broken volumes.
# ---------------------------------------------------------------------------
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5" img="$6"
  shift 6
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port=$(( 47000 + ($$ % 8000) + portoff ))
  timeout 420 qemu-system-x86_64 \
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
# `cat small.txt` before the program is not decoration. M15 refactored
# `fatParseName` into `fatParseAt` so that the shell and `open` share ONE 8.3
# parser; the typed form has to keep working, and this is where that is a boot
# rather than a hope.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "ls"),ret,wait:1400"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "cat small.txt"),ret,wait:2000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run prog.elf"),ret,wait:20000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:1200"

SHOT_PNG="$CORE_DIR/build/screenshot-fileio.png"
drive_session "$WORKDIR/main" "$SESSION_KEYS" "$SHOT_PNG" "main" 0 "$DISK_IMG"
SERIAL="$WORKDIR/main/serial.txt"
SCREEN="$WORKDIR/main/screen.txt"
[[ -s "$SERIAL" ]] || fail "the main boot captured no serial output at all"

have() { grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { grep -qF -- "$1" "$SERIAL" && fail "the transcript contains what it must not: $1"; }

# ---------------------------------------------------------------------------
# Step 7 — the derived checks. Every number below came out of derive.py, which
# read it off the volume; not one of them is typed here.
# ---------------------------------------------------------------------------

# 7a. THE PROGRAM READ THE WHOLE FILE, IN PIECES, AND GOT THE RIGHT ANSWER.
have "M15 PROG NEG 0 SELF BYTES $(d self_bytes_hex) FNV $(d self_fnv_hex)"
have "M15 DATA BYTES $(d data_bytes_hex) READS $(d data_reads_hex) FNV $(d data_fnv_hex)"
[[ "$(d data_reads)" -gt 1 ]] || fail "derive.py says the file is read in $(d data_reads) pieces; M15's criterion needs more than one"
# A contiguous reader's answer, and the control build's answer, must NOT be
# what the real program printed.
havent "M15 DATA BYTES $(d data_bytes_hex) READS $(d data_reads_hex) FNV $(d contig_fnv_hex)"
havent "M15 DATA BYTES $(d data_bytes_hex) READS $(d data_reads_hex) FNV $(d neg_fnv_hex)"
havent "$(d contig_fnv_hex)"
echo "CHECK 7a: pass  the program read all $(d data_bytes) bytes of DATA.BIN in $(d data_reads) reads of $(d chunk) and hashed them to $(d data_fnv_hex), which is what the host computes over the same file; the $(d contig_fnv_hex) a contiguous reader would have produced appears nowhere in the capture"

# 7b. SEEK: the markers at both ends, the end itself, and one past it.
have "M15 SEEK HEAD 1 TAIL 1 END $(d data_bytes_hex) EOFREAD 0 PAST $(d ret_badseek)"
echo "CHECK 7b: pass  seek(0) found the head marker and seek(size-8) the tail marker; seek(size) returned the size, the read there returned 0, and seek(size+1) was refused with $(d ret_badseek)"

# 7c. TWO FILES OPEN AT ONCE, READ ALTERNATELY.
have "M15 ALT $(d alt_bytes_hex) FNVA $(d alt_fnva_hex) FNVB $(d alt_fnvb_hex)"
echo "CHECK 7c: pass  $(d alt_bytes) bytes read alternately out of two open files hash to the two values the host computes over DATA.BIN's and OTHER.BIN's first $(d alt_bytes) bytes"

# 7d. THE SAME FILE OPEN TWICE, WITH INDEPENDENT OFFSETS.
have "M15 TWOFD AT5000 $(d peek_at5000_hex) ATALT $(d peek_atalt_hex)"
echo "CHECK 7d: pass  two descriptors on the SAME file read from two different offsets, hashing to two different derived values — the offset lives in the descriptor and not in the file"

# 7e. THE FOUR DESCRIPTORS, AND THE FIFTH.
have "M15 FDS 0 1 2 3 FIFTH $(d ret_noslot)"
echo "CHECK 7e: pass  four descriptors numbered 0..3 and a fifth open refused with $(d ret_noslot)"

# 7f. EVERY REFUSAL, OBSERVED FROM RING 3 AS A RETURN VALUE.
have "M15 REFUSE OPEN $(d ret_notfound) $(d ret_isdir) $(d ret_badname) $(d ret_badlen)"
have "M15 REFUSE OPEN2 $(d ret_badptr) $(d ret_empty)"
have "M15 REFUSE READ $(d ret_badptr) $(d ret_badptr) $(d ret_badlen) $(d ret_badfd) CLOSE $(d ret_badfd)"
# 7f-bis. THE RANGE THAT STRADDLES THE END OF THE MAPPED IMAGE.
#
# The first page of it is user and writable; the second is not mapped at all.
# This is the ONLY check that distinguishes "the validator looked at the first
# page" from "the validator walked every page", and without it a validator that
# checked only the first page passes everything else in this harness -- which is
# not a hypothesis: it was a surviving mutant until this line existed.
have "M15 REFUSE STRADDLE $(d ret_badptr)"
echo "CHECK 7f: pass  fourteen refusals came back to ring 3 as return values: a fifth open, a seek past the end, a missing name, a subdirectory, a malformed 8.3 name, an over-long name, a NAME POINTER into kernel memory, a real zero-length file, a read into read-only memory, a read into KERNEL memory, an over-long read, a read on a descriptor nothing opened, and a close of the same, and a range STRADDLING the last mapped page of the image and the unmapped one after it"

# 7g. THE W^X PROPERTY SURVIVED THE READ THAT WAS AIMED AT IT.
have "M15 SELF AGAIN $(d self_fnv_hex) SAME 1"
echo "CHECK 7g: pass  the program's own R+X segment hashes to $(d self_fnv_hex) both before and after a read() was aimed into it — the refusal refused, rather than partially writing"

# 7h. THE BUFFERED LAYER AGREES WITH THE RAW LOOP.
have "M15 RFILE BYTES $(d rf_bytes_hex) FNV $(d rf_fnv_hex) EOF 1"
have "M15 RFGETS LINES $(d rf_lines_hex) CHARS $(d rf_chars_hex)"
have "USER WRITE $(d first_line)"
echo "CHECK 7h: pass  rfread() over a 512-byte buffer produced the SAME hash as the 173-byte raw loop; rfgets() found $(d rf_lines) lines totalling $(d rf_chars) characters; and the first line of the file came back through the kernel's own ring-3 pointer validator"

# 7i. THE KERNEL'S OWN ACCOUNT OF THE SESSION, EVERY FIELD DERIVED.
FILE_LINE=$(printf "FILE OPENS %08X READS %08X CLOSES %08X SEEKS %08X REFUSED %08X BYTES %08X" \
  "$(d k_opens)" "$(d k_reads)" "$(d k_closes)" "$(d k_seeks)" "$(d k_refused)" "$(d k_bytes)")
have "$FILE_LINE"
CHAIN_FIELD=$(printf "CHAINS %08X PEAK %02X" "$(d k_chains)" "$(d k_peak)")
have "$CHAIN_FIELD"
# Sectors: bounded, because the exact count is a simulation of the program
# rather than a property of the volume. Read back out of the line.
SECTORS=$(grep -m1 "^FILE OPENS " "$SERIAL" | sed -E 's/.*SECTORS ([0-9A-F]+).*/\1/')
SECTORS=$((16#$SECTORS))
[[ "$SECTORS" -ge "$(d k_sectors_lo)" && "$SECTORS" -le "$(d k_sectors_hi)" ]] \
  || fail "the kernel read $SECTORS data sectors for ring 3; the derived bounds are $(d k_sectors_lo)..$(d k_sectors_hi)"
# The program deliberately leaves ONE descriptor open, so the kernel's teardown
# has something to close and says so. A teardown that did nothing would print no
# line at all -- which was a surviving mutant until the program stopped tidying
# up after itself.
have "$(printf "FILE ORPHANS %02X" "$(d k_orphans)")"
echo "CHECK 7i: pass  the kernel's own exit line reports $(d k_opens) opens, $(d k_reads) reads, $(d k_closes) closes, $(d k_seeks) seeks, $(d k_refused) refusals, $(d k_bytes) bytes, $(d k_chains) chain rebuilds and a peak of $(d k_peak) descriptors open at once — every one of them derived from prog.c's call sequence and the sizes of the files on the volume — and the ONE descriptor the program deliberately left open was closed by the teardown, which said so"

# 7j. THE CHAIN WAS REBUILT EXACTLY WHEN THE PROGRAM SWITCHED FILES.
#
# This is the number that says the one-chain-at-a-time filesystem underneath was
# actually re-selected per descriptor rather than the two files quietly sharing
# a chain. 2 * ALTN and not one more.
[[ "$(d k_chains)" -eq $(( 2 * $(python3 -c "
import re,sys
src = open(sys.argv[1]).read()
print(re.search(r'#define ALTN (\d+)', src).group(1))" "$SCRIPT_DIR/prog.c") )) ]] \
  || fail "derive.py's chain-rebuild count is not 2 * ALTN"
echo "CHECK 7j: pass  the cluster chain was rebuilt exactly $(d k_chains) times — once per read in the alternating phase and never anywhere else"

# 7k. THE EXIT STATUS IS A FUNCTION OF THE FILE'S CONTENTS.
EXIT_LINE=$(printf "ELF DONE EXIT %016X" "$(d exit)")
have "$EXIT_LINE"
echo "CHECK 7k: pass  the program exited $EXIT_LINE, which the host computes from DATA.BIN's and OTHER.BIN's bytes"

# 7l. `cat small.txt` STILL WORKS, so M15's refactor of the 8.3 parser did not
#     break the typed form of a name.
python3 - "$SERIAL" "$DISK_IMG.small" <<'PY' || fail "the bytes \`cat\` printed are not SMALL.TXT's bytes — fatParseName/fatParseAt disagree, or the shell path broke"
import sys
cap = open(sys.argv[1], "rb").read()
want = open(sys.argv[2], "rb").read()
sys.exit(0 if want in cap else 1)
PY
echo "CHECK 7l: pass  \`cat small.txt\` typed at the shell printed the file byte-for-byte — the ONE 8.3 parser serves both the typed line and open()"

# 7m. NO FRAME LEAKED.
FREE_BEFORE=$(grep -m1 "^PMM MANAGED" "$SERIAL" | sed -E 's/.*FREE ([0-9A-F]+).*/\1/')
FREE_AFTER=$(grep "^PMM MANAGED" "$SERIAL" | tail -1 | sed -E 's/.*FREE ([0-9A-F]+).*/\1/')
[[ -n "$FREE_BEFORE" && "$FREE_BEFORE" == "$FREE_AFTER" ]] \
  || fail "the frame allocator had $FREE_BEFORE free frames before the session and $FREE_AFTER after"
echo "CHECK 7m: pass  the frame allocator's free count is identical before and after — $((16#$FREE_BEFORE)) frames — so the loader and $(d k_opens) opens leaked nothing"

# 7n. M1's 544-BYTE GOLDEN IS STILL A PREFIX, BYTE FOR BYTE.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL" | cmp -s - "$M1_EXPECTED" \
  || fail "the first $M1_BYTES bytes of this boot are not m1-interrupts' golden. M15 added a subsystem that initialises before the first byte of output; if it printed anything, it printed it there."
echo "CHECK 7n: pass  the first $M1_BYTES bytes are m1-interrupts' golden, byte for byte"

# ---------------------------------------------------------------------------
# Step 8 — THE NEGATIVE-CONTROL BUILD. Same source, same volume, same kernel.
# The only difference is that it throws away the byte count `read` returns.
# ---------------------------------------------------------------------------
NEG_KEYS="$(typekeys "run progn.elf"),ret,wait:20000"
drive_session "$WORKDIR/neg" "$NEG_KEYS" "$WORKDIR/neg.png" "negative-control" 11 "$DISK_IMG"
NSER="$WORKDIR/neg/serial.txt"
nhave() { grep -qF -- "$1" "$NSER" || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "the control boot's transcript does not contain: $1"; }; }
nhavent() { grep -qF -- "$1" "$NSER" && fail "the control boot's transcript contains what it must not: $1"; }
nhave "M15 PROG NEG 1 SELF BYTES $(d neg_self_bytes_hex) FNV $(d neg_self_fnv_hex)"
nhave "M15 DATA BYTES $(d data_bytes_hex) READS $(d data_reads_hex) FNV $(d neg_fnv_hex)"
nhavent "M15 DATA BYTES $(d data_bytes_hex) READS $(d data_reads_hex) FNV $(d data_fnv_hex)"
nhave "$(printf "ELF DONE EXIT %016X" "$(d neg_exit)")"
nhavent "$(printf "ELF DONE EXIT %016X" "$(d exit)")"
# It read the same bytes and it still gets the RIGHT answer through the buffered
# layer, because rfread() reports its own count and this build believes that
# one. The difference is confined to the raw loop, which is the point.
nhave "M15 RFILE BYTES $(d rf_bytes_hex) FNV $(d rf_fnv_hex) EOF 1"
echo "CHECK 8: pass  the control build -- one \`#if\` different, hashing the whole $(d chunk)-byte chunk instead of the count \`read\` returned -- printed $(d neg_fnv_hex) and NOT $(d data_fnv_hex), and exited $(printf %02X "$(d neg_exit)") and not $(printf %02X "$(d exit)"). The byte count \`read\` returns is load-bearing."

# ---------------------------------------------------------------------------
# Step 9 — TWO DELIBERATELY BROKEN VOLUMES. The program is unchanged; the disk
# under it is not.
# ---------------------------------------------------------------------------
VARIANT_KEYS="$(typekeys "run prog.elf"),ret,wait:8000"
declare -a VNAMES=(nodata datacycle)
declare -a VWANT=("$(d ret_notfound)" "$(d ret_io)")
vi=0
for v in "${VNAMES[@]}"; do
  VIMG="$WORKDIR/m15-$v.img"
  python3 "$SCRIPT_DIR/make-image.py" "$VIMG" "$PROGDIR/prog.elf" "$PROGDIR/progn.elf" \
    "--variant=$v" >/dev/null || fail "make-image.py could not write the $v variant"
  drive_session "$WORKDIR/$v" "$VARIANT_KEYS" "$WORKDIR/$v.png" "$v" $(( 21 + vi )) "$VIMG"
  VSER="$WORKDIR/$v/serial.txt"
  want="M15 OPEN DATA REFUSED ${VWANT[$vi]}"
  grep -qF -- "$want" "$VSER" \
    || { sed -n '/M1 END/,$p' "$VSER" >&2; fail "the $v boot's transcript does not contain: $want"; }
  grep -qF -- "M15 DATA BYTES" "$VSER" \
    && fail "the $v boot printed a DATA line — the program read a file it should not have been able to open"
  grep -qF -- "$(printf "ELF DONE EXIT %016X" 225)" "$VSER" \
    || fail "the $v boot's program did not exit with its own 0xE1 open-failure code"
  grep -qF -- "$(d data_fnv_hex)" "$VSER" \
    && fail "the $v boot produced the correct hash off a volume on which the file is unreachable"
  echo "CHECK 9.$vi: pass  the $v volume made open(\"DATA.BIN\") refuse with ${VWANT[$vi]}; the program said so and exited 0xE1 without printing a hash"
  vi=$(( vi + 1 ))
done

# ---------------------------------------------------------------------------
# Step 10 — the byte-exact goldens.
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

echo "M15-fileio: PASS — dcc build -> assemble -> link -> clang builds core/user/libc's FIVE OBJECTS (syscall, string, malloc, printf and M15's buffered rfile) AND ONE PROGRAM SOURCE TWICE, the second ignoring the byte count read() returns as a negative control -> make-image.py writes a FAT16 volume whose 20000-byte DATA.BIN lives on 20 scattered clusters with $BACKLINKS BACKWARD links, accepted by fsck_msdos and read back byte-for-byte by macOS's own msdos driver -> 8 structural checks (donated .bss 11488 -> 12768 with file_store one 1280-byte symbol whose three regions multiply out exactly, the storage seam exactly 3 call sites in one file, fileOwnsWrite bounding its pointer before touching it and requiring the USER and WRITABLE bits page by page as the gate on the ONE store to a caller-supplied address, all nineteen of oslibc.h's file numbers read back out of file.dart with eleven distinct refusal VALUES above one floor, shellStrHelp UNCHANGED at 2147 so no golden moves, still no write opcode or write function or open mode anywhere, every @rodata table against its own doc comment and call site, and descriptors released by elfTeardown and procCleanup rather than by exit) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 59 + 1, kdata.o and portio.o clean standalone) -> FOUR real QEMU boots. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; a C PROGRAM opening a file by name and reading all $(d data_bytes) bytes of it in $(d data_reads) reads of $(d chunk) -- a size that divides neither a sector nor a cluster nor the file -- and hashing them to $(d data_fnv_hex), which the host computes over the same file and which a contiguous reader could not produce; seek() to both ends of the file finding both markers, to the end returning the size, and one past it refused; TWO FILES open at once and read alternately, each hashing to its own derived value, with the kernel rebuilding a cluster chain exactly $(d k_chains) times and saying so; the SAME file open twice with two independent offsets; four descriptors and a fifth refused; fourteen refusals observed from ring 3 as return values, including a read aimed into the program's own R+X segment which left it hashing to the same $(d self_fnv_hex) as before; a buffered rfread() over a 512-byte window agreeing to the byte with the 173-byte raw loop, rfgets() finding $(d rf_lines) lines, and the first of them coming back through the kernel's own pointer validator; \`cat small.txt\` typed at the shell proving the one 8.3 parser still serves both callers; an exit status derived from the file's contents; the negative-control build printing the WRONG derived hash and the WRONG derived status; two broken volumes on which open() is refused and the program says which refusal it got; and the frame allocator's free count identical, to the frame, before and after. Screenshot at $SHOT_PNG"
exit 0
