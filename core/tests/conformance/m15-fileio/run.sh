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

# GAP-0168 / ADR-0032: shared harness machinery -- the `ck` assertion counter,
# the `require_assertions` floor checked immediately before the PASS line, and
# the capture()/run_status()/await() replacements for capture-then-`$?`.
# Sourced AFTER fail(), which every helper in it reports through.
source "$SCRIPT_DIR/../_lib/harness.sh"

# How many checks this harness must have executed before it is allowed to
# print PASS. Derived from a run, not counted by hand: run the harness and
# read the "ASSERTIONS: pass  <n> checks executed" line it prints just above
# its PASS line. It moves when the harness legitimately gains or loses checks,
# exactly like the pinned .bss sizes elsewhere in this file -- and a DROP
# below it is the failure this exists to catch.
ASSERTIONS_REQUIRED=210


for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths. Resolved to a real path
# here for the same reason m14-fat does it.
ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m15.XXXXXX")" || setup_error "mktemp failed"
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
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
ck; [[ -f "$M1_EXPECTED" ]] || setup_error "m1-interrupts/expected.txt not found"
ck; [[ -d "$LIBC_DIR" ]] || setup_error "no C library at $LIBC_DIR"

# ---------------------------------------------------------------------------
# Step 1 — build the kernel.
# ---------------------------------------------------------------------------
capture BUILD_OUT BUILD_STATUS -- bash "$CORE_DIR/scripts/build-kernel.sh"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

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
# 11488 -> 14048, and the 2560 is `file_store` (M16 grew it from 1280: sixteen
# more metadata words, four more per descriptor, and a second sector buffer for
# the read-modify-write a partial write needs). The region offsets in
# file.dart are multiplied out against the block's own size here, because a
# region that ran past the end would corrupt whatever `.bss` follows and would
# do it silently -- `.bss` is not zeroed and nothing in this kernel guards it.
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
ck; [[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
ck; [[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section — the five assembly-written words are gone"
ASM_BSS=$((16#$ASM_BSS_HEX))
ck; [[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o still donates $ASM_BSS bytes of .bss, expected exactly 96 — cpu_info (64) plus the four resume words. Anything else in there is storage that ADR-0021 says should be a @bss mutable static in the subsystem that owns it."
KDATA_BSS=$DART_BSS
# S0 (ADR-0033) added a block AFTER M19's, and it is now the LAST one in .bss:
# `ioctlStore`, 512 bytes -- 32 metadata words and the 256-byte `ioctl` bounce
# buffer, which is the only memory a DRM payload is ever copied through.
# Subtracted FIRST, before M19's, exactly as M14, M15, M16 and M19 each were in
# turn, so that every earlier milestone's number continues to mean what it meant
# when it was written.
#
# **ADR-0031 §4.3 rule 5 SAID PUTTING THE BLOCK LAST WOULD LEAVE "every existing
# harness's 'bytes from my block to the end' arithmetic unchanged". THAT IS NOT
# QUITE TRUE, AND THIS BLOCK IS THE PROOF.** Last is necessary but not
# sufficient: the previously-last block's own to-the-end measurement is exactly
# the one a new block after it changes. M19's number went 256 -> 768 and twelve
# harnesses said so. ADR-0033 §6.4.
# M21 (ADR-0041) added a block AFTER S0's, and it was the LAST one in .bss until
# D4 (ADR-0050) put `wmStore` behind it:
# `shmStore`, 8576 bytes -- 16 global counter words, four 64-byte shared-region
# records, and an 8192-byte BIT-PLANE with one bit per frame in the machine that
# says whether a live region owns that frame. The plane is what makes the guard
# at the top of `freeFrame` O(1) instead of a linear scan on all 65536 calls of
# `frames refill` (`docs/design/memory.md` §2.4).
#
# Subtracted FIRST, before S0's, exactly as M14, M15, M16, M19 and S0 each were
# in turn -- so that every earlier milestone's number continues to mean what it
# meant when it was written. This is the THIRD application of ADR-0033 §6.4's
# correction to ADR-0031 §4.3 rule 5: last is necessary but not sufficient, and
# the previously-last block's own to-the-end measurement is exactly the one a
# new block after it changes. S0's number goes 512 -> 8960 nowhere, because it
# is measured to shmStore's start rather than to the end of .bss -- which is the
# line below, and which is why it still reads 512.
# D4 (ADR-0050) added a block AFTER M21's, and it is now the LAST one in .bss:
# `wmStore`, 320 bytes -- nineteen compositor state words (counters, the drag
# and its grab offset, the painted pointer position, and the re-entrancy guard)
# in a 24-word block, then two 64-byte window records, one per shared region,
# because a window's pixels live in a region and `shmMax` is 2.
#
# Subtracted FIRST, before M21's, exactly as M14, M15, M16, M19, S0 and M21 each
# were in turn -- so that every earlier milestone's number continues to mean what
# it meant when it was written. This is the FOURTH application of ADR-0033 s6.4's
# correction to ADR-0031 s4.3 rule 5: last is necessary but not sufficient, and
# the previously-last block's own to-the-end measurement is exactly the one a new
# block after it changes. M21's number below still reads 8576 for that reason --
# it is now measured to wmStore's START rather than to the end of .bss.
# D2 (ADR-0054) added a block AFTER D4's, and it is now the LAST one in .bss:
# `kbdqStore`, 288 bytes -- four header words (head, tail, dropped, count)
# and 32 event slots. Subtracted FIRST, before D4's, so D4's number still
# reads 320 -- it is now measured to kbdqStore's START rather than to the
# end of .bss.
# D7 (ADR-0055) added a block AFTER D2's, and it is now the LAST one in .bss:
# `wmeventStore`, 192 bytes -- two per-window rings (four header words and
# 8 event slots each). Subtracted FIRST, before D2's, so D2's number still
# reads 288 -- it is now measured to wmeventStore's START rather than to
# the end of .bss.
D7_OFF_HEX=$(bssoff wmeventStore)
ck; [[ -n "$D7_OFF_HEX" ]] || fail "wmeventStore has no .bss offset in kmain.o -- D7's click-event block (ADR-0055) is missing"
D7_BSS=$(( KDATA_BSS - 16#$D7_OFF_HEX ))
ck; [[ "$D7_BSS" -eq 1920 ]] || fail "the bytes from D7's wmeventStore to the end of .bss are $D7_BSS, expected 1920. If that block changed size, change it in ADR-0109, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D7_BSS ))
D2_OFF_HEX=$(bssoff kbdqStore)
ck; [[ -n "$D2_OFF_HEX" ]] || fail "kbdqStore has no .bss offset in kmain.o -- D2's input-queue block (ADR-0054) is missing"
D2_BSS=$(( KDATA_BSS - 16#$D2_OFF_HEX ))
ck; [[ "$D2_BSS" -eq 288 ]] || fail "the bytes from D2's kbdqStore to D7's wmeventStore are $D2_BSS, expected 288. If that block changed size, change it in ADR-0054, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D2_BSS ))
D4_OFF_HEX=$(bssoff wmStore)
ck; [[ -n "$D4_OFF_HEX" ]] || fail "wmStore has no .bss offset in kmain.o -- D4's compositor block (ADR-0050) is missing"
D4_BSS=$(( KDATA_BSS - 16#$D4_OFF_HEX ))
ck; [[ "$D4_BSS" -eq 1472 ]] || fail "the bytes from D4's wmStore to D2's kbdqStore are $D4_BSS, expected 1472. If that block changed size, change it in ADR-0109, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D4_BSS ))
M21_OFF_HEX=$(bssoff shmStore)
ck; [[ -n "$M21_OFF_HEX" ]] || fail "shmStore has no .bss offset in kmain.o -- M21's shared-memory block (ADR-0041) is missing"
M21_BSS=$(( KDATA_BSS - 16#$M21_OFF_HEX ))
ck; [[ "$M21_BSS" -eq 9600 ]] || fail "the bytes from M21's shmStore to D4's wmStore are $M21_BSS, expected 8832 — ADR-0109 made it 4480, and ADR-0155 doubled `pmmMaxFrames` to 65536, which the bit-plane must track (`shmPlaneFrames == pmmMaxFrames`, asserted in m21-shmem), so the plane went 4096 -> 8192. If that block changed size, change it in ADR-0109/ADR-0155, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M21_BSS ))
S0_OFF_HEX=$(bssoff ioctlStore)
ck; [[ -n "$S0_OFF_HEX" ]] || fail "ioctlStore has no .bss offset in kmain.o -- S0's ioctl block (ADR-0033) is missing"
S0_BSS=$(( KDATA_BSS - 16#$S0_OFF_HEX ))
ck; [[ "$S0_BSS" -eq 512 ]] || fail "the bytes from S0's ioctlStore to M21's shmStore are $S0_BSS, expected 512. If that block changed size, change it in ADR-0033, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - S0_BSS ))
# D1 (ADR-0042) added a block BEFORE S0's, because ADR-0031 s4.3 rule 5 requires
# the ioctl bounce buffer to stay LAST: `mouseStore`, 160 bytes -- twenty words
# of PS/2 mouse driver state, of which the first five are the packet being
# assembled and the rest are the accumulated pointer, five counters, the DETECTED
# packet size and device id, and the init-progress bitmap. Subtracted SECOND,
# after S0's block and before M20's, exactly as M14, M15, M16, M19, M20 and S0
# each were in turn, so that every earlier milestone's number continues to mean
# what it meant when it was written.
D1_OFF_HEX=$(bssoff mouseStore)
ck; [[ -n "$D1_OFF_HEX" ]] || fail "mouseStore has no .bss offset in kmain.o -- D1's PS/2 mouse block (ADR-0042) is missing"
D1_BSS=$(( KDATA_BSS - 16#$D1_OFF_HEX ))
ck; [[ "$D1_BSS" -eq 160 ]] || fail "the bytes from D1's mouseStore to S0's ioctlStore are $D1_BSS, expected 160. If that block changed size, change it in ADR-0042, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - D1_BSS ))
# M19 (ADR-0023) added a block AFTER M16's, and it is the LAST one in .bss:
# `argsStore`, 256 bytes -- eight metadata words, eight per-argument offsets and
# 128 bytes of argument text, which is where a command line is staged before it
# is copied onto the program's own stack page. Subtracted FIRST, before every
# earlier milestone's, so that this harness's own number continues to mean what
# it meant when it was written. Exactly the accounting M14, M15 and M16 each got
# in turn.
# M20 (ADR-0027) added a block AFTER M19's, and S0's `ioctlStore` later landed
# behind it, so it is the SECOND-TO-LAST block in .bss and is subtracted second:
# `chanStore`, 2624 bytes -- eight global counter words and two 1280-byte channel
# port records, each of which is a 128-byte header, 128 bytes of per-slot lengths
# and 1024 bytes of message ring. Subtracted after S0's block and before every
# earlier milestone's, so that this harness's own number continues to mean what it meant
# when it was written. Exactly the accounting M14, M15, M16 and M19 each got in
# turn.
M20_OFF_HEX=$(bssoff chanStore)
ck; [[ -n "$M20_OFF_HEX" ]] || fail "chanStore has no .bss offset in kmain.o -- M20's IPC channel block (ADR-0027) is missing"
M20_BSS=$(( KDATA_BSS - 16#$M20_OFF_HEX ))
ck; [[ "$M20_BSS" -eq 2624 ]] || fail "the bytes from M20's chanStore to D1's mouseStore are $M20_BSS, expected 2624. If that block changed size, change it in ADR-0027, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M20_BSS ))
M19_OFF_HEX=$(bssoff argsStore)
ck; [[ -n "$M19_OFF_HEX" ]] || fail "argsStore has no .bss offset in kmain.o -- M19's argument block (ADR-0023) is missing"
M19_BSS=$(( KDATA_BSS - 16#$M19_OFF_HEX ))
ck; [[ "$M19_BSS" -eq 256 ]] || fail "the bytes from M19's argsStore to M20's chanStore are $M19_BSS, expected 256. If that block changed size, change it in ADR-0023, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M19_BSS ))
KDATA_BSS=$(( KDATA_BSS + ASM_BSS ))   # M17 (ADR-0021): the DCDart half plus the 96 assembly-owned bytes
ck; [[ "$KDATA_BSS" -eq 33824 ]] || fail "the kernel's mutable static storage is $KDATA_BSS bytes, expected 23456 — 11552 through M14 (11488, plus M18's 64-byte scheduler header, ADR-0022) plus file_store's 3584. If that changed, it changed deliberately and this number and docs/known-gaps.md GAP-0053's running total both move with it. This number carries the 4224 bytes the blocks BELOW it gained and no milestone here declared: ADR-0155 doubled pmmMaxFrames to 65536 so pmmStore went 4672 -> 8768, ADR-0189's larger fine map took vmStore 128 -> 240, and ADR-0064's scanout fallback chain put two geometry words in fbStateBlock, 32 -> 48."
FILE_STORE_SIZE=$(bsssize fileStore)
ck; [[ "$FILE_STORE_SIZE" == "6016" ]] || fail "kdata.o's file_store is ${FILE_STORE_SIZE:-missing} bytes, expected 2560"
ck; [[ $(( KDATA_BSS - FILE_STORE_SIZE )) -eq 28064 ]] || fail "the .bss outside file_store is $(( KDATA_BSS - FILE_STORE_SIZE )), not M14's 11488 plus M18's 64 plus 4224 — M15 moved storage it does not own. Since these numbers were pinned the blocks BELOW this milestone grew by 4224 bytes in total, every one of them authorised: pmmStore +4096 (ADR-0155 doubled pmmMaxFrames to 65536), vmStore +112 (ADR-0189 took vmFineBytes to 32MiB, vmMapBytes to 256MiB and vmFrameCount to 20) and fbStateBlock +16 (ADR-0064's scanout geometry words) — see GAP-0053's ledger."

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
ck; [[ "$STORE_BYTES" -eq "$FILE_STORE_SIZE" ]] || fail "file.dart says fileStoreBytes=$STORE_BYTES and kdata.S donates $FILE_STORE_SIZE"
ck; [[ "$META_OFF" -eq 0 ]] || fail "fileMetaOffset is $META_OFF, expected 0"
ck; [[ $(( META_OFF + META_WORDS * 8 )) -eq "$TABLE_OFF" ]] \
  || fail "the metadata region ($META_WORDS words at $META_OFF) does not end where the table begins ($TABLE_OFF)"
ck; [[ $(( ROW_WORDS )) -eq $(( MAX_FDS * FD_WORDS )) ]] \
  || fail "fileRowWords ($ROW_WORDS) is not fileMaxFds * fileFdWords ($MAX_FDS * $FD_WORDS)"
ck; [[ $(( TABLE_OFF + ROWS * ROW_WORDS * 8 )) -eq "$BUF_OFF" ]] \
  || fail "the descriptor table ($ROWS rows of $ROW_WORDS words at $TABLE_OFF) does not end where the bounce buffer begins ($BUF_OFF)"
SEC_OFF=$(dartconst fileSecOffset file.dart)
ck; [[ $(( BUF_OFF + 512 )) -eq "$SEC_OFF" ]] \
  || fail "the bounce buffer (512 bytes at $BUF_OFF) does not end where M16's read-modify-write sector begins ($SEC_OFF)"
ck; [[ $(( SEC_OFF + 512 )) -eq "$STORE_BYTES" ]] \
  || fail "the read-modify-write sector (512 bytes at $SEC_OFF) does not end at the block's end ($STORE_BYTES)"
ck; [[ "$RUN_ROW" -eq "$PROC_MAX" ]] \
  || fail "fileRunRow is $RUN_ROW and proc.dart's procMax is $PROC_MAX — rows 0..procMax-1 must be the process slots and the row above them the \`run <name>\` program, or two programs would share descriptors"
ck; [[ "$ROWS" -eq $(( PROC_MAX + 1 )) ]] || fail "fileRows is $ROWS, expected procMax + 1 = $(( PROC_MAX + 1 ))"
echo "STRUCTURAL: pass  kdata.o donates 14112 bytes of .bss, 3584 of them file_store: $META_WORDS metadata words at $META_OFF, $ROWS x $MAX_FDS x $FD_WORDS descriptor words at $TABLE_OFF, a 512-byte bounce buffer at $BUF_OFF, and M16's read-modify-write sector after it, ending exactly at $STORE_BYTES"

# 2b. THE STORAGE SEAM: ONE ACCESSOR, FOUR CALL SITES, ONE FILE (ADR-0011 §0).
#
# THREE at M15 and FOUR since M16, which added `fileSecBase`. The number moved
# by substitution and the property did not: one symbol, one file, a countable
# set of places that know where the memory came from.
CODE=$(grep -v '^[[:space:]]*//' "$CORE_DIR/kernel/file.dart")
SEAM=$(printf '%s\n' "$CODE" | grep -c "return Bss[.]addressOf(fileStore)")
MENTIONS=$(printf '%s\n' "$CODE" | grep -cw "fileStore")
ck; [[ "$SEAM" -eq 4 ]] || fail "core/kernel/file.dart has $SEAM call sites of Bss.addressOf(fileStore), expected exactly 4 (fileMetaBase, fileTableBase, fileBufBase, fileSecBase). A fifth turns the migration to DCDart mutable statics into an audit — ADR-0011 §0."
ck; [[ "$MENTIONS" -eq 5 ]] || fail "file.dart names fileStore $MENTIONS times, expected 5: one @extern declaration and the four seam functions (three at M15, four since M16 added fileSecBase)"
OUTSIDE=$(grep -rlw "fileStore" "$CORE_DIR/kernel/" | grep -v "/file.dart$" | wc -l | tr -d ' ')
ck; [[ "$OUTSIDE" -eq 0 ]] || fail "fileStore is named outside core/kernel/file.dart"
for f in fileMetaBase fileTableBase fileBufBase; do
  ck; grep -q "u64 $f() {" "$CORE_DIR/kernel/file.dart" || fail "core/kernel/file.dart has no $f()"
done
echo "STRUCTURAL: pass  the storage seam is exactly 3 \`return Bss.addressOf(fileStore)\` in file.dart and 0 anywhere else in core/kernel/"

# 2c. THE WRITE-SIDE POINTER CHECK IS A DIFFERENT FUNCTION FROM THE READ-SIDE
#     ONE, AND IT LOOKS AT A SECOND BIT.
#
# This is M15's security property and it is the one thing here that a boot alone
# would not pin down: the boot proves that ONE read into ONE read-only page was
# refused, and this proves the refusal comes from a general rule.
ck; grep -q "u64 fileOwnsWrite(u64 ptr, u64 len) {" "$CORE_DIR/kernel/file.dart" \
  || fail "core/kernel/file.dart has no fileOwnsWrite"
ck; python3 - "$CORE_DIR/kernel/file.dart" <<'PY' || fail "fileOwnsWrite does not check BOTH the user bit and the writable bit out of vmEffective, or it does arithmetic on ptr before bounding it"
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
# M21 (ADR-0041) split the LOAD bound from the REACHABILITY bound: `vmProgEnd`
# is still where the loadable region ends, but what a user-pointer validator
# must test is `vmUserEnd`, which is one past the last address ring 3 can reach
# and now includes the shared-region window. Pinned by NAME rather than
# loosened to "some bound", because reverting this to `vmProgEnd` would be a
# real defect in the other direction -- it would refuse every legitimate
# pointer into a shared region -- and reverting it to nothing would be the
# overflow hole this check exists for.
first_bound = body.find("ptr >= u64(vmUserEnd)")
if first_bound < 0:
    bad.append("fileOwnsWrite does not bound ptr against vmUserEnd (ADR-0041); "
               "if it still says vmProgEnd it is refusing every pointer into a "
               "shared region, and if it says neither it is the overflow hole")
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
# ...and there is exactly ONE function that stores through a caller-supplied
# address, `fileCopyOut`, called only from `fileSysRead`, AFTER the validator
# has run. ADR-0100 added a second call site in the same function for `:ROOT`
# records; both sit behind `fileOwnsWrite`. A third site, or one outside
# `fileSysRead`, is the hole this check exists for.
#
# COUNTED BY FUNCTION AND NOT BY TEXT, since M16. Until M16 this counted the
# literal `Pointer<u8>.fromAddress(dst` and required exactly one, which worked
# because `dst` was a user pointer in the only place that spelling appeared.
# M16 added `fileCopyIn` and `fileSplice`, both of which store through a local
# `dst` that is a KERNEL buffer, so the text count is 3 and means nothing. What
# it was protecting -- that the one store to a user address is behind the one
# validator, in that order -- is checked directly here instead.
ck; python3 - "$CORE_DIR/kernel/file.dart" <<'PY2' || fail "the one store to a caller-supplied address is not behind fileOwnsWrite"
import re, sys
src = open(sys.argv[1]).read()
bad = []
if len(re.findall(r"^void fileCopyOut\(", src, re.M)) != 1:
    bad.append("fileCopyOut is not defined exactly once")
calls = [m for m in re.finditer(r"fileCopyOut\(", src)
         if not src[:m.start()].rstrip().endswith("void")]
if len(calls) != 2:
    bad.append("fileCopyOut has %d call sites, expected 2 (file read + :ROOT)" % len(calls))
m = re.search(r"^void fileSysRead\(u64 frame\) \{\n(.*?)^\}", src, re.M | re.S)
if not m:
    bad.append("file.dart has no `void fileSysRead(u64 frame)`")
else:
    b = m.group(1)
    if b.count("fileCopyOut(") != 2:
        bad.append("fileSysRead contains %d fileCopyOut calls, expected 2" % b.count("fileCopyOut("))
    if b.count("fileOwnsWrite(dst, len)") < 2:
        bad.append("fileSysRead does not validate dst with fileOwnsWrite on both arms")
    elif b.find("fileOwnsWrite(dst, len)") > b.find("fileCopyOut("):
        bad.append("fileSysRead copies BEFORE it validates")
    # Each copy must have an owns-write before it in source order.
    pos = 0
    while True:
        c = b.find("fileCopyOut(", pos)
        if c < 0:
            break
        o = b.rfind("fileOwnsWrite(dst, len)", 0, c)
        if o < 0:
            bad.append("a fileCopyOut in fileSysRead has no fileOwnsWrite before it")
        pos = c + 1
for x in bad:
    print("    - " + x, file=sys.stderr)
sys.exit(1 if bad else 0)
PY2
echo "STRUCTURAL: pass  fileOwnsWrite bounds ptr before touching it, requires the USER bit AND the WRITABLE bit page by page, and is the gate on the one store to a caller-supplied address in the file -- fileCopyOut, defined once, called twice from fileSysRead (file + :ROOT), after the validator"

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
  ck; [[ -n "$k" && -n "$c" ]] || fail "could not compare $1 against $2 in core/kernel/$3"
  ck; [[ "$k" -eq "$c" ]] || fail "oslibc.h has $1 = $c and core/kernel/$3 says $2 = $k. A library that disagrees with the kernel about what a refusal LOOKS LIKE will treat one as a byte count."
done
# Every refusal must be above the floor, and every RESULT must be below it.
FLOOR=$(dartconst fileRetFloor file.dart)
for name in fileRetBadFd fileRetBadPtr fileRetBadLen fileRetNoSlot fileRetBadName \
            fileRetNotFound fileRetIsDir fileRetEmpty fileRetIo fileRetBadSeek \
            fileRetNoOwner fileRetBadMode fileRetNoSpace fileRetReadOnly; do
  v=$(dartconst "$name" file.dart)
  ck; [[ "$v" -ge "$FLOOR" ]] 2>/dev/null || python3 -c "import sys; sys.exit(0 if $v >= $FLOOR else 1)" \
    || fail "$name is below fileRetFloor, so a caller's one comparison would take it for a result"
done
ck; python3 - <<PY || fail "the fourteen refusal values are not distinct"
vals = [$(for n in fileRetBadFd fileRetBadPtr fileRetBadLen fileRetNoSlot fileRetBadName \
              fileRetNotFound fileRetIsDir fileRetEmpty fileRetIo fileRetBadSeek fileRetNoOwner \
              fileRetBadMode fileRetNoSpace fileRetReadOnly; do
            printf '%s,' "$(dartconst "$n" file.dart)"; done)]
import sys
sys.exit(0 if len(set(vals)) == 14 else 1)
PY
READ_MAX_K=$(dartconst fileReadMax file.dart)
ck; [[ "$READ_MAX_K" -eq $(cdefine RFILE_BUFSZ) ]] \
  || fail "RFILE_BUFSZ ($(cdefine RFILE_BUFSZ)) is not the kernel's fileReadMax ($READ_MAX_K) — the buffered layer would either waste a syscall or be refused"
echo "STRUCTURAL: pass  M15's nineteen file numbers still read back out of core/kernel/file.dart, and the refusal set M16 grew to thirteen and GAP-0152 grew to fourteen is still fourteen DISTINCT values all above one floor"

# 2e. THE HELP TEXT AND THE EXTERN COUNT: M15 ADDS NO SHELL COMMAND AND ONE
#     EXTERN.
#
# GAP-0105: `shellStrHelp` is asserted by m3, m4, m5, m6 and m14, and a
# milestone that moved it would move five goldens. M15's whole surface is
# syscalls, so it moves nothing.
HELP_SIZE=$(symsize "$CORE_DIR/build/kmain.o" shellStrHelp)
ck; [[ "$HELP_SIZE" -eq 2511 ]] || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511. M15 adds SYSCALLS, not commands; the number moved in the shakedown commit, which added five help lines and regenerated every golden that carries them."
echo "STRUCTURAL: pass  shellStrHelp is $HELP_SIZE bytes — M15 added four syscalls and no shell command"

# 2f. M15's SESSION STILL WRITES NOTHING — AND THAT IS NOW CHECKED BY RUNNING.
#
# THIS ASSERTION WAS REPLACED AT M16, DELIBERATELY AND IN THE OPEN. Until M16
# these lines grepped for an ATA write opcode, for a write function by name, and
# for an open mode in oslibc.h, and required all three to be absent. That was
# the strongest available statement while nothing in this kernel could write.
# M16 (docs/decisions/0020-writing-to-a-disk.md) makes all three FALSE: `0x30`
# is `ataCmdWriteSectors`, `fatWrite*` is a whole layer, and `O_WRITE` is a mode
# `open` takes.
#
# What replaces them is stronger, not weaker. THE CLAIM M15 ACTUALLY NEEDS is
# that M15's OWN BOOTS change nothing on the disk they are given — which is a
# statement about what ran rather than about what is spellable, and which a
# kernel that could write but did not still has to satisfy. It is made in two
# places: `m15_readonly_before` records the image's SHA-256 here, and the check
# at the end of this file requires it to be identical after all four boots.
#
# The one grep that survives is the one whose meaning did not change: `open`
# with no mode is still a READ-ONLY open. m15's program never passes a mode, and
# a kernel that made the mode-less form writable would be caught by the checksum
# rather than by a grep.
ck; [[ $(dartconst fileOpenRead file.dart) -eq 0 ]] \
  || fail "core/kernel/file.dart's fileOpenRead is not 0 — a two-argument open(), which is what every M15 program performs, would no longer be a read-only one"
ck; grep -q "sys_call(SYS_OPEN, (unsigned long)name, strlen(name))" "$LIBC_DIR/syscall.c" \
  || grep -q "open(const char \*name) { return openmode(name, O_READ); }" "$LIBC_DIR/syscall.c" \
  || fail "core/user/libc's open() no longer asks for a read-only descriptor"
echo "STRUCTURAL: pass  open() with no mode is still O_READ (0) — the M16 mode argument did not silently make M15's opens writable. That M15's boots write nothing at all is asserted at the end of this file, by comparing the image's SHA-256 before and after, which is a stronger claim than the three greps this check replaced."

# 2g. EVERY @rodata TABLE IN file.dart IS THE SIZE ITS CALL SITE PASSES.
ck; python3 - "$CORE_DIR/kernel/file.dart" "$CORE_DIR/build/kmain.o" <<'PY' || fail "a @rodata table in file.dart does not match the string its doc comment records, or the length its call site passes"
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
ck; grep -q "fileReleaseOwner(u64(fileRunRow))" "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart's elfTeardown does not release the \`run <name>\` program's descriptors"
ck; grep -q "fileReleaseOwner(s)" "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart's procCleanup does not release the slot's descriptors"
ck; grep -q "fileExitReport();" "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart's exit path does not call fileExitReport"
echo "STRUCTURAL: pass  descriptors are released by elfTeardown and procCleanup, both of which run on the fault path as well as the exit path"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding.sh (CLAUDE.md rule 1). 44 externs since ADR-0021
# deleted all sixteen `_addr()` accessors. It was 60: M14's 59 plus
# fileStore, and nothing else.
# ---------------------------------------------------------------------------
capture_sh VF_OUT VF_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VF_OUT"
ck; [[ $VF_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed on kmain.o"
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VF_OUT" | head -1 | grep -oE '[0-9]+')
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
  ck; grep -q "\\b$gone\\b" <<<"$VF_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
# D3 added resume_user and proc_idle_gate. Subtract so this milestone's extern pin still describes THIS change.
if [[ -f "$CORE_DIR/build/kmain.o.externs" ]]; then
  D3_EXTERNS=$(grep -cE '^(resume_user|proc_idle_gate|kbd_drain_gate)$' "$CORE_DIR/build/kmain.o.externs" || true)
  EXTERN_COUNT=$(( EXTERN_COUNT - D3_EXTERNS ))
fi
# ADR-0104 (the OS calls osgfx), ADR-0113/ADR-0133 (osxui paints through
# osgfx), ADR-0136 (panel hex is an osgfx glyph), ADR-0172 (Venus encodes
# retained SPIR-V) and ADR-0181 (the generative desk) gave the OS platform C
# modules to call. Their entry points are `external` too, so the RAW count
# moves every time the OS calls one more of its own modules -- which is not
# what any milestone's extern pin below is about.
#
# Subtracted BY PATTERN rather than by a typed list, because a typed list is a
# second place to forget: `osgfx_*` and `osxui_*` are, by ADR-0104, C module
# entry points. Read out of dcc's own manifest, which is the authority on what
# kmain.o declares, the same file the D3 block above reads. The pin they are
# subtracted from still says exactly what it always said -- THIS milestone
# added no new assembly primitive -- and each module entry point is asserted
# NOT to be defined in assembly, which is the property the pin exists to
# protect and which a bumped total would not state.
EXTERN_MANIFEST="$CORE_DIR/build/kmain.o.externs"
ck; [[ -f "$EXTERN_MANIFEST" ]] || fail "dcc wrote no $EXTERN_MANIFEST — the extern census below has nothing authoritative to read"
PLAT_EXTERNS=$(grep -E '^(osgfx|osxui)_[A-Za-z0-9_]+$' "$EXTERN_MANIFEST" | sort -u)
PLAT_PRESENT=$(wc -w <<<"$PLAT_EXTERNS" | tr -d ' ')
ck; [[ "$PLAT_PRESENT" -ge 7 ]] \
  || fail "kmain.o declares only $PLAT_PRESENT osgfx_/osxui_ entry points, expected at least the seven of ADR-0104/0113/0136/0172/0181 — the OS stopped calling its own C modules"
for sym in $PLAT_EXTERNS; do
  ck; ! grep -qE "^[.]glob(a)?l[[:space:]]+$sym\b" "$CORE_DIR/boot/isr.S" "$CORE_DIR/boot/boot.S" "$CORE_DIR/boot/portio.S" \
    || fail "$sym is defined in assembly — it is a platform C module entry point (ADR-0104), and an assembly definition of it would mean the module seam had been replaced by a stub"
done
EXTERN_COUNT=$(( EXTERN_COUNT - PLAT_PRESENT ))
# ADR-0148's TLS door is the one genuinely NEW assembly primitive since these
# numbers were pinned: `setfs` has to land in the FS_BASE MSR, and wrmsr has no
# DCDart spelling. Subtracted by name, and asserted to BE assembly.
ck; grep -qE "^[.]glob(a)?l[[:space:]]+msr_write\b" "$CORE_DIR/boot/isr.S" \
  || fail "msr_write is not defined in isr.S — ADR-0148's FS_BASE door was supposed to be one wrmsr stub in assembly"
MSR_PRESENT=$(grep -cE '^msr_write$' "$EXTERN_MANIFEST" || true)
EXTERN_COUNT=$(( EXTERN_COUNT - MSR_PRESENT ))
ck; [[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — M14's 59 less the fifteen accessors ADR-0021 deleted at or before M14; M15's only extern was file_store_addr, so M15 now adds NONE"
for obj in kdata.o portio.o; do
  ck; (cd "$CORE_DIR" && bash scripts/verify-freestanding.sh "build/$obj" >/dev/null 2>&1) \
    || fail "verify-freestanding.sh failed on $obj"
done
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o, M14's 59 less the fifteen accessors ADR-0021 deleted; M15's own file_store_addr is gone too, so M15 adds NONE; kdata.o and portio.o clean standalone"

# ---------------------------------------------------------------------------
# Step 4 — build the two programs and the volume, and have two independent
# tools agree it is a FAT16 volume before the kernel is allowed near it.
# ---------------------------------------------------------------------------
PROGDIR="$WORKDIR/progs"
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$PROGDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/m15.img"
LAYOUT="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/prog.elf" "$PROGDIR/progn.elf" \
  || fail "make-image.py could not write the volume"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/prog.elf" "$PROGDIR/progn.elf" --json \
  > "$LAYOUT" || fail "make-image.py --json failed"

# M16 replaced this harness's three "there is no write path" greps with a
# measurement (see 2f). This is the first half of it: the SHA-256 of the volume
# before any boot has seen it. The second half is at the end of this file.
M15_SHA_BEFORE=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found; this harness will not certify a FAT volume no independent tool has read"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image (exit $FSCK_STATUS)"; }
ck; grep -q "Phase 3" <<<"$FSCK_OUT" || { echo "$FSCK_OUT" >&2; fail "fsck_msdos did not get as far as phase 3"; }
echo "IMAGE: pass  fsck_msdos accepts the volume: $(grep -E '^Warning|files,' <<<"$FSCK_OUT" | tail -1)"

MOUNT_VERIFIED="not attempted (no hdiutil)"
if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
  ck; if [[ $ATTACH_STATUS -ne 0 ]]; then
    echo "$ATTACH_OUT" >&2
    fail "hdiutil could not mount the image — macOS's own msdos driver does not think this is a FAT volume"
  fi
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  for want in DATA.BIN SMALL.TXT PROG.ELF PROGN.ELF; do
    ck; [[ -f "$MOUNTPOINT/$want" ]] || fail "the mounted volume has no $want"
  done
  ck; cmp -s "$MOUNTPOINT/DATA.BIN" "$DISK_IMG.data" \
    || fail "macOS's msdos driver reads DATA.BIN back DIFFERENTLY from what was written — the scattered chain is wrong, and this kernel agreeing with the generator would prove nothing"
  # OTHER.BIN is behind three REAL long-filename entries, so the host driver
  # shows the long name and this kernel deliberately does not (GAP-0116 item 3).
  # Both facts are asserted here: the long name resolves for macOS, and the
  # PROGRAM reaches the same bytes by the 8.3 alias.
  LONGNAME=$(ls "$MOUNTPOINT" | grep -c 'other-data-with-a-long-name.bin')
  ck; [[ "$LONGNAME" -eq 1 ]] \
    || fail "macOS does not see OTHER.BIN's long filename — the LFN entries on this volume are not the real thing"
  ck; cmp -s "$MOUNTPOINT/other-data-with-a-long-name.bin" "$DISK_IMG.other" || fail "macOS reads OTHER.BIN back differently"
  ck; cmp -s "$MOUNTPOINT/SMALL.TXT" "$DISK_IMG.small" || fail "macOS reads SMALL.TXT back differently"
  ck; cmp -s "$MOUNTPOINT/PROG.ELF" "$PROGDIR/prog.elf" || fail "macOS reads PROG.ELF back differently"
  ck; [[ -d "$MOUNTPOINT/SUB" ]] || fail "the mounted volume's SUB is not a directory"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  MOUNT_VERIFIED="mounted by macOS's own msdos driver; DATA.BIN, OTHER.BIN, SMALL.TXT and PROG.ELF all read back byte-for-byte along their scattered chains, and SUB is a directory, with OTHER.BIN reachable to the host only by its long name"
fi
echo "IMAGE: pass  $MOUNT_VERIFIED"

# ---------------------------------------------------------------------------
# Step 5 — derive every expectation from the volume that was just built.
# ---------------------------------------------------------------------------
DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG" "$PROGDIR/prog.elf" "$PROGDIR/progn.elf" \
  "$CORE_DIR/kernel" > "$DERIVED" \
  || fail "derive.py could not derive the expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
ck; [[ -n "$(d data_fnv_hex)" ]] || fail "derive.py produced no data_fnv"
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
  # GAP-0150: a port that is FREE RIGHT NOW, from the host kernel, rather
  # than a hash of this shell's PID -- which collides with a concurrent
  # harness, with a re-run onto a recycled PID, and with this harness's own
  # previous boot still in TIME_WAIT. All three used to surface as QEMU
  # dying with "Address already in use".
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
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
  local drive_status
  run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$ser" --wait-for 'M1 END\n' --png "$png" --screen-text "$outdir/screen.txt" --keys "$keys" "$@"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
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
ck; [[ -s "$SERIAL" ]] || fail "the main boot captured no serial output at all"

have() { ck; grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { ck; grep -qF -- "$1" "$SERIAL" && fail "the transcript contains what it must not: $1"; }

# ---------------------------------------------------------------------------
# Step 7 — the derived checks. Every number below came out of derive.py, which
# read it off the volume; not one of them is typed here.
# ---------------------------------------------------------------------------

# 7a. THE PROGRAM READ THE WHOLE FILE, IN PIECES, AND GOT THE RIGHT ANSWER.
have "M15 PROG NEG 0 SELF BYTES $(d self_bytes_hex) FNV $(d self_fnv_hex)"
have "M15 DATA BYTES $(d data_bytes_hex) READS $(d data_reads_hex) FNV $(d data_fnv_hex)"
ck; [[ "$(d data_reads)" -gt 1 ]] || fail "derive.py says the file is read in $(d data_reads) pieces; M15's criterion needs more than one"
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

# 7f-ter. AND THE KERNEL SAID SO ITSELF, WHICH IT DID NOT USED TO.
#
# THE DEFECT THIS CLOSES (ADR-0038). `fileRefuse` is the single funnel through
# which all fourteen `fileRet*` refusals pass, and until this commit its whole
# body was a counter bump and a write to the caller's RAX. It printed NOTHING.
# 43 call sites, none of them audible.
#
# CHECK 7f above passes without it, and that is the point: it asserts on the
# RING-3 PROGRAM's output. prog.c prints the codes itself, so this harness has
# always tested the ABI and never the transcript -- and the transcript is where
# an operator without a purpose-built program has to look. All such an operator
# got was the aggregate ` REFUSED 0000000E` on the exit line, plus an `FSERR`
# field carrying the FAT-level code and not this one.
#
# So: every code the PROGRAM reports must also appear on a line the KERNEL
# printed, and the two accounts must agree on the COUNT as well as the values.
# The count is the half a per-value grep would miss -- a funnel that narrated
# some refusals and not others would satisfy the greps and fail this.
ck; python3 - "$SERIAL" <<'PY' || fail "the kernel's own transcript does not name the file refusals its own aggregate counts -- docs/decisions/0038-a-refusal-that-does-not-name-itself.md"
import re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []

lines = re.findall(r"^FILE REFUSED ([0-9A-F]{16})$", cap, re.M)
if not lines:
    fails.append("not one `FILE REFUSED <code>` line in the whole capture. "
                 "fileRefuse is silent again (ADR-0038).")

# The aggregate the kernel prints at exit, and the number of lines it printed.
m = re.search(r"^FILE OPENS [0-9A-F]+ READS [0-9A-F]+ CLOSES [0-9A-F]+ "
              r"SEEKS [0-9A-F]+ REFUSED ([0-9A-F]+) ", cap, re.M)
if not m:
    fails.append("no `FILE OPENS ... REFUSED <n>` exit line to compare against")
else:
    agg = int(m.group(1), 16)
    if agg != len(lines):
        fails.append("the kernel's exit line counts %d refusals and it printed "
                     "%d `FILE REFUSED` lines. One of the 43 call sites is "
                     "reaching the counter without reaching the narration."
                     % (agg, len(lines)))

# Every value ring 3 reported must be one the kernel named. prog.c prints them
# in lower case and 8 digits; the kernel prints 16 upper-case.
seen = set(lines)
prog = set()
for m in re.finditer(r"^USER WRITE M15 REFUSE \w+ ((?:[0-9a-f]{8} ?)+)$", cap, re.M):
    for tok in m.group(1).split():
        prog.add(("FFFFFFFF" + tok.upper()))
missing = sorted(v for v in prog if v not in seen)
if missing:
    fails.append("ring 3 was given %s and the kernel never named %s"
                 % (", ".join(sorted(prog)), ", ".join(missing)))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d `FILE REFUSED` lines, equal to the kernel's own aggregate, and "
      "every one of the %d distinct values ring 3 was given is named on one of "
      "them)" % (len(lines), len(prog)))
PY
echo "CHECK 7f-ter: pass  the KERNEL's own transcript names every file refusal it made, one FILE-REFUSED line each, and the number of those lines equals the aggregate its own exit line reports — the half CHECK 7f could not test, because CHECK 7f reads the program's output and not the kernel's (ADR-0038)"

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
ck; [[ "$SECTORS" -ge "$(d k_sectors_lo)" && "$SECTORS" -le "$(d k_sectors_hi)" ]] \
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
ck; [[ "$(d k_chains)" -eq $(( 2 * $(python3 -c "
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
ck; python3 - "$SERIAL" "$DISK_IMG.small" <<'PY' || fail "the bytes \`cat\` printed are not SMALL.TXT's bytes — fatParseName/fatParseAt disagree, or the shell path broke"
import sys
cap = open(sys.argv[1], "rb").read()
want = open(sys.argv[2], "rb").read()
sys.exit(0 if want in cap else 1)
PY
echo "CHECK 7l: pass  \`cat small.txt\` typed at the shell printed the file byte-for-byte — the ONE 8.3 parser serves both the typed line and open()"

# 7m. NO FRAME LEAKED.
FREE_BEFORE=$(grep -m1 "^PMM MANAGED" "$SERIAL" | sed -E 's/.*FREE ([0-9A-F]+).*/\1/')
FREE_AFTER=$(grep "^PMM MANAGED" "$SERIAL" | tail -1 | sed -E 's/.*FREE ([0-9A-F]+).*/\1/')
ck; [[ -n "$FREE_BEFORE" && "$FREE_BEFORE" == "$FREE_AFTER" ]] \
  || fail "the frame allocator had $FREE_BEFORE free frames before the session and $FREE_AFTER after"
echo "CHECK 7m: pass  the frame allocator's free count is identical before and after — $((16#$FREE_BEFORE)) frames — so the loader and $(d k_opens) opens leaked nothing"

# 7n. M1's 544-BYTE GOLDEN IS STILL A PREFIX, BYTE FOR BYTE.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
ck; head -c "$M1_BYTES" "$SERIAL" | cmp -s - "$M1_EXPECTED" \
  || fail "the first $M1_BYTES bytes of this boot are not m1-interrupts' golden. M15 added a subsystem that initialises before the first byte of output; if it printed anything, it printed it there."
echo "CHECK 7n: pass  the first $M1_BYTES bytes are m1-interrupts' golden, byte for byte"

# ---------------------------------------------------------------------------
# Step 8 — THE NEGATIVE-CONTROL BUILD. Same source, same volume, same kernel.
# The only difference is that it throws away the byte count `read` returns.
# ---------------------------------------------------------------------------
NEG_KEYS="$(typekeys "run progn.elf"),ret,wait:20000"
drive_session "$WORKDIR/neg" "$NEG_KEYS" "$WORKDIR/neg.png" "negative-control" 11 "$DISK_IMG"
NSER="$WORKDIR/neg/serial.txt"
nhave() { ck; grep -qF -- "$1" "$NSER" || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "the control boot's transcript does not contain: $1"; }; }
nhavent() { ck; grep -qF -- "$1" "$NSER" && fail "the control boot's transcript contains what it must not: $1"; }
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
  ck; python3 "$SCRIPT_DIR/make-image.py" "$VIMG" "$PROGDIR/prog.elf" "$PROGDIR/progn.elf" \
    "--variant=$v" >/dev/null || fail "make-image.py could not write the $v variant"
  vsha_before=$(shasum -a 256 "$VIMG" | cut -d' ' -f1)
  drive_session "$WORKDIR/$v" "$VARIANT_KEYS" "$WORKDIR/$v.png" "$v" $(( 21 + vi )) "$VIMG"
  VSER="$WORKDIR/$v/serial.txt"
  want="M15 OPEN DATA REFUSED ${VWANT[$vi]}"
  ck; grep -qF -- "$want" "$VSER" \
    || { sed -n '/M1 END/,$p' "$VSER" >&2; fail "the $v boot's transcript does not contain: $want"; }
  ck; grep -qF -- "M15 DATA BYTES" "$VSER" \
    && fail "the $v boot printed a DATA line — the program read a file it should not have been able to open"
  ck; grep -qF -- "$(printf "ELF DONE EXIT %016X" 225)" "$VSER" \
    || fail "the $v boot's program did not exit with its own 0xE1 open-failure code"
  ck; grep -qF -- "$(d data_fnv_hex)" "$VSER" \
    && fail "the $v boot produced the correct hash off a volume on which the file is unreachable"
  vsha_after=$(shasum -a 256 "$VIMG" | cut -d' ' -f1)
  ck; [[ "$vsha_before" == "$vsha_after" ]] \
    || fail "the $v boot CHANGED its image (sha256 $vsha_before -> $vsha_after); M15 writes nothing"
  echo "CHECK 9.$vi: pass  the $v volume made open(\"DATA.BIN\") refuse with ${VWANT[$vi]}; the program said so and exited 0xE1 without printing a hash, and left the image byte-for-byte identical"
  vi=$(( vi + 1 ))
done

# ---------------------------------------------------------------------------
# Step 9b — M15'S BOOTS WROTE NOTHING, MEASURED RATHER THAN GREPPED FOR.
#
# The other half of check 2f. This image was carried through the main boot and
# the negative-control boot, both of which loaded a program off it, read tens of
# thousands of bytes out of it and exercised every file syscall M15 has. Since
# M16 the kernel underneath is one that CAN write a sector; this says it did
# not write one here.
#
# The two broken-volume boots in step 9 each got their own image and are checked
# the same way, in the loop above.
# ---------------------------------------------------------------------------
M15_SHA_AFTER=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)
ck; [[ "$M15_SHA_BEFORE" == "$M15_SHA_AFTER" ]] \
  || fail "M15's boots CHANGED the volume (sha256 $M15_SHA_BEFORE -> $M15_SHA_AFTER). This kernel can write to a disk since M16; nothing M15 does is supposed to."
echo "CHECK 9b: pass  the volume is byte-for-byte identical after both boots — sha256 $M15_SHA_AFTER — so M15's read path still writes nothing, checked by RUNNING rather than by grepping for an opcode that now exists"

# ---------------------------------------------------------------------------
# Step 10 — the byte-exact goldens.
# ---------------------------------------------------------------------------
if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL" "$EXPECTED_SERIAL"
  cp "$SCREEN" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $EXPECTED_SERIAL ($(wc -c <"$EXPECTED_SERIAL" | tr -d ' ') bytes) and $EXPECTED_SCREEN"
fi
ck; [[ -f "$EXPECTED_SERIAL" ]] || fail "no golden at $EXPECTED_SERIAL (run once with --regen)"
ck; [[ -f "$EXPECTED_SCREEN" ]] || fail "no golden at $EXPECTED_SCREEN (run once with --regen)"
SERIAL_BYTES=$(wc -c <"$EXPECTED_SERIAL" | tr -d ' ')
ck; if ! cmp -s "$SERIAL" "$EXPECTED_SERIAL"; then
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL") | head -40 >&2
  fail "the serial capture does not match $EXPECTED_SERIAL byte for byte"
fi
echo "ASSERT: pass  the ${SERIAL_BYTES}-byte serial capture matches expected.txt exactly"
ck; if ! cmp -s "$SCREEN" "$EXPECTED_SCREEN"; then
  diff "$EXPECTED_SCREEN" "$SCREEN" | head -20 >&2
  fail "the 80x25 VGA text buffer does not match expected-screen.txt"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"
ck; [[ -s "$SHOT_PNG" ]] || fail "no screenshot at $SHOT_PNG"
ck; head -c 8 "$SHOT_PNG" | cmp -s - <(printf '\x89PNG\r\n\x1a\n') || fail "$SHOT_PNG is not a PNG"
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# GAP-0168: the PASS line below describes work; this refuses to print it
# unless that many checks actually executed. An abort, a loop that iterated
# zero times, a branch not taken or a deleted guard all land here.
require_assertions "$ASSERTIONS_REQUIRED"
echo "M15-fileio: PASS — dcc build -> assemble -> link -> clang builds core/user/libc's FIVE OBJECTS (syscall, string, malloc, printf and M15's buffered rfile) AND ONE PROGRAM SOURCE TWICE, the second ignoring the byte count read() returns as a negative control -> make-image.py writes a FAT16 volume whose 20000-byte DATA.BIN lives on 20 scattered clusters with $BACKLINKS BACKWARD links, accepted by fsck_msdos and read back byte-for-byte by macOS's own msdos driver -> 8 structural checks (donated .bss 11488 -> 14048 with file_store one 2560-byte symbol whose four regions multiply out exactly, the storage seam exactly 4 call sites in one file, fileOwnsWrite bounding its pointer before touching it and requiring the USER and WRITABLE bits page by page as the gate on the ONE store to a caller-supplied address, M15's nineteen oslibc.h numbers read back out of file.dart with FOURTEEN distinct refusal VALUES above one floor (GAP-0152 added the fourteenth), shellStrHelp UNCHANGED at 2147 so no golden moves, a mode-less open() still meaning O_READ, every @rodata table against its own doc comment and call site, and descriptors released by elfTeardown and procCleanup rather than by exit) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 59 + 1, kdata.o and portio.o clean standalone) -> FOUR real QEMU boots. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; a C PROGRAM opening a file by name and reading all $(d data_bytes) bytes of it in $(d data_reads) reads of $(d chunk) -- a size that divides neither a sector nor a cluster nor the file -- and hashing them to $(d data_fnv_hex), which the host computes over the same file and which a contiguous reader could not produce; seek() to both ends of the file finding both markers, to the end returning the size, and one past it refused; TWO FILES open at once and read alternately, each hashing to its own derived value, with the kernel rebuilding a cluster chain exactly $(d k_chains) times and saying so; the SAME file open twice with two independent offsets; four descriptors and a fifth refused; fourteen refusals observed from ring 3 as return values, including a read aimed into the program's own R+X segment which left it hashing to the same $(d self_fnv_hex) as before; a buffered rfread() over a 512-byte window agreeing to the byte with the 173-byte raw loop, rfgets() finding $(d rf_lines) lines, and the first of them coming back through the kernel's own pointer validator; \`cat small.txt\` typed at the shell proving the one 8.3 parser still serves both callers; an exit status derived from the file's contents; the negative-control build printing the WRONG derived hash and the WRONG derived status; two broken volumes on which open() is refused and the program says which refusal it got; the frame allocator's free count identical, to the frame, before and after; and EVERY IMAGE BYTE-FOR-BYTE IDENTICAL AFTER EVERY BOOT, which is what M16 replaced this harness's three read-only greps with. Screenshot at $SHOT_PNG"
exit 0
