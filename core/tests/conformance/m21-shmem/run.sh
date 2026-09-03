#!/usr/bin/env bash
# core/tests/conformance/m21-shmem/run.sh
#
# Mechanical check of M21's exit criterion: TWO RING-3 PROCESSES, IN TWO
# DIFFERENT ADDRESS SPACES, SHARE ONE SET OF PHYSICAL FRAMES, AND THE READER
# EXITS WITH A 64-BIT HASH OF THE BYTES IT ACTUALLY READ THROUGH THE SHARED
# MAPPING -- a number this harness computed on the host before the machine
# booted.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
#   * ONE BINARY TAKES BOTH ROLES. `make-image.py` writes the SAME BYTES to two
#     disk slots and refuses to build an image where they differ. Which process
#     creates the region and which receives it is decided ENTIRELY by which one
#     `chanopen` answers first -- M20's discipline, and M19's before it. So "one
#     process wrote a page and the other read it" is a claim about the KERNEL.
#
#   * THE CONTENTS ARE ASSERTED, NOT THE RETURN CODE. The consumer exits with
#     an FNV-1a hash of all 16384 bytes it read through the shared mapping, and
#     `derive.py` computes the same number independently from the protocol's own
#     formula. The two sides' hashes are also required to DIFFER, so one exit
#     status cannot satisfy both checks.
#
#   * THE SAME PHYSICAL FRAME IN TWO ADDRESS SPACES, READ OUT OF THE LIVE PAGE
#     TABLES. The kernel prints a `SHM PAGE <va> P U W X PA <pa>` line per page
#     per mapping, walked from CR3 through `vmEffective`, and this harness
#     requires the producer's and the consumer's PA columns to be EQUAL. That is
#     the exact inverse of `m11-proc`'s isolation check -- which requires every
#     commonly-mapped address to be a DIFFERENT frame -- and it is a fact no
#     single-process bug can fabricate.
#
#   * W^X, AGAINST THE TABLES RATHER THAN THE SOURCE. Every one of those lines
#     must read `X 0`, in BOTH address spaces. The producer's must read `W 1`
#     and the consumer's `W 0`, so "read-write to the creator, read-only to the
#     grantee" is checked rather than described.
#
#   * A REGION OUTLIVES ITS CREATOR. The producer exits while the consumer still
#     holds a capability; the consumer then observes CHAN_PEERGONE and RE-READS
#     ALL 16384 BYTES, requiring the same hash. `procSpaceFree` walked the dead
#     process's page table and handed every present leaf to `freeFrame`, and the
#     frames are still here because `freeFrame` consulted the shared bit-plane
#     and declined. ADR-0027 §5's "a dead sender's messages are still delivered",
#     one rung up.
#
#   * TWENTY REFUSALS OBSERVED FROM RING 3 AS RETURN VALUES, including the three
#     the brief names: an EXECUTABLE mapping refused, a FORGED handle refused,
#     and an OUT-OF-RANGE length refused. A guard that has only ever been seen
#     passing is indistinguishable from one that cannot fail.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * NOTHING HERE IS CONCURRENT. One CPU, `proc coop` does not preempt, and the
#     region has exactly ONE WRITER by construction. ADR-0041 §6 says what that
#     leaves unproven and GAP-0236 records it.
#   * NO INVOLUNTARY REVOCATION IS TESTED BECAUSE THERE IS NONE. GAP-0233.
#   (A write through the read-only mapping IS attempted -- see BOOT 2. It was
#    deferred at first and is no longer: GAP-0238 is closed.)
#
# Usage:
#   core/tests/conformance/m21-shmem/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "M21-shmem: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M21-shmem: FAIL — $1" >&2; exit 2; }

# GAP-0168 / ADR-0032: shared harness machinery -- the `ck` assertion counter,
# the `require_assertions` floor checked immediately before the PASS line, and
# the capture()/capture_sh() replacements for capture-then-`$?`.
# Sourced AFTER fail(), which every helper in it reports through.
source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=94

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m21.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    mkdir -p "$CORE_DIR/build"
    [[ -f "$WORKDIR/share/serial.txt" ]] &&
      cp "$WORKDIR/share/serial.txt" "$CORE_DIR/build/m21-last-serial.txt" || true
    [[ -f "$WORKDIR/share/qemu.log" ]] &&
      cp "$WORKDIR/share/qemu.log" "$CORE_DIR/build/m21-last-qemu.log" || true
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"

# ---------------------------------------------------------------------------
# Step 1 — build the kernel.
# ---------------------------------------------------------------------------
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
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

MODEL="$WORKDIR/model.json"
capture_sh MODEL_OUT MODEL_STATUS -- "python3 '$SCRIPT_DIR/derive.py' > '$MODEL'"
ck; [[ $MODEL_STATUS -eq 0 ]] || { echo "$MODEL_OUT" >&2; fail "derive.py could not build the host model"; }

jget() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$MODEL" "$1"; }

WANT_PROD_HASH=$(jget producer_hash)
WANT_CONS_HASH=$(jget consumer_hash)
WANT_REGION_VA=$(printf '%016X' "$(jget region_va)")
WANT_PAGES=$(jget pages)
WANT_FRAMES=$(jget frames_per_region)
ck; [[ "$WANT_PROD_HASH" != "$WANT_CONS_HASH" ]] \
  || fail "the host model's two hashes are equal — one exit status could satisfy both checks"

# ---------------------------------------------------------------------------
# Step 2 — structural checks.
# ---------------------------------------------------------------------------
echo
echo "=== STRUCTURAL ==="

# 2a. THE WINDOW MULTIPLIES OUT, and it does not overlap the load region.
VM_SHM_BASE=$(dartconst vmShmBase vm.dart)
VM_SHM_END=$(dartconst vmShmEnd vm.dart)
VM_SHM_BYTES=$(dartconst vmShmBytes vm.dart)
VM_SHM_PAGES=$(dartconst vmShmPages vm.dart)
VM_SHM_PD=$(dartconst vmShmPdIndex vm.dart)
VM_USER_END=$(dartconst vmUserEnd vm.dart)
VM_PROG_BASE=$(dartconst vmProgBase vm.dart)
VM_PROG_END=$(dartconst vmProgEnd vm.dart)
VM_BIG_BYTES=$(dartconst vmBigBytes vm.dart)
PAGE_BYTES=$(dartconst vmPageBytes vm.dart)

ck; [[ "$VM_SHM_BASE" -eq "$VM_PROG_END" ]] \
  || fail "vmShmBase ($VM_SHM_BASE) is not vmProgEnd ($VM_PROG_END) — the shared window must begin exactly where the load region ends, or there is address space neither owns"
ck; [[ $(( VM_SHM_END - VM_SHM_BASE )) -eq "$VM_SHM_BYTES" ]] \
  || fail "vmShmBytes does not span vmShmBase..vmShmEnd"
ck; [[ $(( VM_SHM_PAGES * PAGE_BYTES )) -eq "$VM_SHM_BYTES" ]] \
  || fail "vmShmPages * vmPageBytes != vmShmBytes"
ck; [[ $(( VM_SHM_BASE / VM_BIG_BYTES )) -eq "$VM_SHM_PD" ]] \
  || fail "vmShmPdIndex is $VM_SHM_PD but vmShmBase/vmBigBytes is $(( VM_SHM_BASE / VM_BIG_BYTES ))"
ck; [[ "$VM_SHM_PD" -eq $(( $(dartconst vmProgPdIndex vm.dart) + 1 )) ]] \
  || fail "the shared window's page-directory entry is not the one immediately after the load region's"
VM_PLAT_BASE=$(dartconst vmPlatBase vm.dart)
VM_PLAT_END=$(dartconst vmPlatEnd vm.dart)
ck; [[ "$VM_PLAT_BASE" -eq "$VM_SHM_END" ]] \
  || fail "vmPlatBase ($VM_PLAT_BASE) is not vmShmEnd ($VM_SHM_END) — the platform window must begin exactly where SHM ends"
ck; [[ "$VM_USER_END" -eq "$VM_PLAT_END" ]] \
  || fail "vmUserEnd ($VM_USER_END) is not vmPlatEnd ($VM_PLAT_END) — the bound the pointer validators test must be one past the last address ring 3 can reach (ADR-0124)"
ck; [[ "$VM_SHM_BASE" -eq $(jget shm_base) ]] || fail "derive.py's SHM_BASE disagrees with vm.dart"
ck; [[ "$VM_SHM_PD" -eq $(jget shm_pd_index) ]] || fail "derive.py's SHM_PD_INDEX disagrees with vm.dart"

# 2b. THE LOAD REGION DID NOT MOVE. This is the whole argument for a second
# window rather than a bigger one (`docs/design/memory.md` §1.3): if any of
# these moved, nine harnesses' goldens and m12-heap's entire structural block
# moved with them.
ck; [[ "$VM_PROG_BASE" -eq 268435456 ]] || fail "vmProgBase moved to $VM_PROG_BASE; M21 must not move the load region"
ck; [[ "$VM_PROG_END" -eq 270532608 ]] || fail "vmProgEnd moved to $VM_PROG_END; M21 must not move the load region"
ck; [[ "$(dartconst heapTop heap.dart)" -eq 270524416 ]] || fail "heapTop moved; M21 must not move the heap's ceiling"
ck; [[ "$(dartconst vmProgStackPage vm.dart)" -eq 270528512 ]] || fail "vmProgStackPage moved; M21 must not move the stack"
ck; [[ "$(dartconst vmProgPages vm.dart)" -eq 512 ]] || fail "vmProgPages moved; ELF WINDOW PAGES would change in five goldens"

# 2c. shmStore TILES EXACTLY. A region record that ran past the end of its slot
# would corrupt the next one -- silently, because `.bss` is not zeroed.
S_METAW=$(dartconst shmMetaWords shm.dart)
S_METAB=$(dartconst shmMetaBytes shm.dart)
S_REGOFF=$(dartconst shmRegOffset shm.dart)
S_REGW=$(dartconst shmRegWords shm.dart)
S_REGB=$(dartconst shmRegBytes shm.dart)
S_MAX=$(dartconst shmMax shm.dart)
S_PLANEOFF=$(dartconst shmPlaneOffset shm.dart)
S_PLANEB=$(dartconst shmPlaneBytes shm.dart)
S_PLANEF=$(dartconst shmPlaneFrames shm.dart)
S_STORE=$(dartconst shmStoreBytes shm.dart)
S_SLOTPAGES=$(dartconst shmSlotPages shm.dart)
S_MAXPAGES=$(dartconst shmMaxPages shm.dart)
S_CAPS=$(dartconst shmCapsPerProc shm.dart)

PROG_MAXPAGES=$(sed -n 's/^#define SHM_MAX_PAGES \([0-9][0-9]*\)UL$/\1/p' "$SCRIPT_DIR/prog.c")
ck; [[ -n "$PROG_MAXPAGES" && "$PROG_MAXPAGES" -eq "$S_MAXPAGES" ]] \
  || fail "prog.c's SHM_MAX_PAGES ($PROG_MAXPAGES) disagrees with shm.dart ($S_MAXPAGES) — LENBIG would cease to be an out-of-range control"
ck; [[ $(( S_METAW * 8 )) -eq "$S_METAB" ]] || fail "shmMetaWords*8 != shmMetaBytes"
ck; [[ "$S_METAB" -eq "$S_REGOFF" ]] || fail "the counter words do not end where the region records begin"
ck; [[ $(( S_REGW * 8 )) -eq "$S_REGB" ]] || fail "shmRegWords*8 != shmRegBytes"
ck; [[ $(( S_REGOFF + S_MAX * S_REGB )) -eq "$S_PLANEOFF" ]] \
  || fail "the $S_MAX region records at $S_REGOFF do not end where the bit-plane begins ($S_PLANEOFF)"
ck; [[ $(( S_PLANEOFF + S_PLANEB )) -eq "$S_STORE" ]] || fail "the bit-plane does not end at the block's end"
ck; [[ $(( S_PLANEB * 8 )) -eq "$S_PLANEF" ]] || fail "shmPlaneBytes*8 != shmPlaneFrames"
# THE PLANE MUST DESCRIBE EVERY FRAME THE ALLOCATOR MANAGES. A plane shorter
# than the bitmap would silently stop protecting the top of memory, and
# `shmFrameShared` returns 0 -- "not shared" -- for a frame past its end.
ck; [[ "$S_PLANEF" -eq "$(dartconst pmmMaxFrames pmm.dart)" ]] \
  || fail "the shared bit-plane describes $S_PLANEF frames and the allocator manages $(dartconst pmmMaxFrames pmm.dart) — every frame the allocator can hand out must be describable, or a shared frame above the plane's end would be silently freed"
# THE REGION SLOTS MUST TILE THE WINDOW, and a region must not be able to run
# out of its slot into the next one's address space.
ck; [[ $(( S_MAX * S_SLOTPAGES )) -eq "$VM_SHM_PAGES" ]] \
  || fail "$S_MAX slots of $S_SLOTPAGES pages do not tile the window's $VM_SHM_PAGES pages"
ck; [[ "$S_MAXPAGES" -le "$VM_SHM_PAGES" ]] \
  || fail "shmMaxPages ($S_MAXPAGES) exceeds the shared window ($VM_SHM_PAGES)"
ck; [[ "$S_MAX" -le "$S_CAPS" ]] \
  || fail "a process has $S_CAPS capability slots and there are $S_MAX regions; it could not hold one for each"

# 2d. THE @bss BLOCK IS THE SIZE IT SAYS AND IT IS LAST.
bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$3" -v f="$1" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield 3 x "$1"; }
bssoff()  { bssfield 2 x "$1"; }
SHM_SIZE=$(bsssize shmStore)
ck; [[ "$SHM_SIZE" -eq "$S_STORE" ]] \
  || fail "shm.dart says shmStoreBytes=$S_STORE and the image has $SHM_SIZE"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
SHM_OFF=$(bssoff shmStore)
# D4 (ADR-0050) added `wmStore` AFTER this block, so M21's is no longer the last
# one -- this is ADR-0033 §6.4's correction to ADR-0031 §4.3 rule 5 applied for
# the fourth time, and the check moves from "shmStore is last" to "shmStore is
# immediately before the block that now is", which is the same property stated
# against a moving end. d1-mouse's mouseStore/ioctlStore pair is checked exactly
# this way and for exactly this reason.
WM_OFF=$(bssoff wmStore)
ck; [[ -n "$WM_OFF" ]] || fail "wmStore has no .bss offset in kmain.o — D4's compositor block (ADR-0050) is missing, and this harness can no longer say where .bss ends"
ck; [[ $(( 16#$SHM_OFF + SHM_SIZE )) -eq $(( 16#$WM_OFF )) ]] \
  || fail "shmStore ends at $(( 16#$SHM_OFF + SHM_SIZE )) and wmStore begins at $(( 16#$WM_OFF )) — M21's block is not immediately before D4's, so every earlier harness's 'bytes from my block to the end' arithmetic has silently moved"
WM_SIZE=$(bsssize wmStore)
KBDQ_OFF=$(bssoff kbdqStore)
KBDQ_SIZE=$(bsssize kbdqStore)
EV_OFF=$(bssoff wmeventStore)
EV_SIZE=$(bsssize wmeventStore)
ck; [[ -n "$KBDQ_OFF" ]] || fail "kbdqStore has no .bss offset in kmain.o — D2's input-queue block (ADR-0054) is missing"
ck; [[ -n "$EV_OFF" ]] || fail "wmeventStore has no .bss offset in kmain.o — D7's click-event block (ADR-0055) is missing"
ck; [[ $(( 16#$WM_OFF + WM_SIZE )) -eq $(( 16#$KBDQ_OFF )) ]] \
  || fail "wmStore ends at $(( 16#$WM_OFF + WM_SIZE )) and kbdqStore begins at $(( 16#$KBDQ_OFF )) — D4's block is not immediately before D2's"
ck; [[ $(( 16#$KBDQ_OFF + KBDQ_SIZE )) -eq $(( 16#$EV_OFF )) ]] \
  || fail "kbdqStore ends at $(( 16#$KBDQ_OFF + KBDQ_SIZE )) and wmeventStore begins at $(( 16#$EV_OFF )) — D2's block is not immediately before D7's"
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore ends at $(( 16#$EV_OFF + EV_SIZE )) and kmain.o's .bss is $DART_BSS — D7's block is not last"
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
ck; [[ $(( DART_BSS + 16#$ASM_BSS_HEX )) -eq 31584 ]] \
  || fail "the kernel's mutable static storage is $(( DART_BSS + 16#$ASM_BSS_HEX )) bytes, expected 31584 — ADR-0109's 23264, plus ADR-0155's doubling of `pmmMaxFrames` to 65536 (`pmmStore` 4672 -> 8768 and `shmStore` 4480 -> 8576, because `shmPlaneFrames` must equal `pmmMaxFrames`), plus ADR-0189's larger fine map (`vmStore` 128 -> 240), plus the two geometry words ADR-0064's fallback chain needs (`fbStateBlock` 32 -> 48). If that changed, it changed deliberately and GAP-0053's running total and every harness that subtracts a later block move with it."

# 2e. THE STORAGE SEAM. ADR-0011 §0: the symbol is named in its accessors and
# nowhere else in the kernel.
SEAM=$(grep -cE "^  return Bss[.]addressOf[(]shmStore[)]" "$CORE_DIR/kernel/shm.dart")
ck; [[ "$SEAM" -eq 4 ]] \
  || fail "Bss.addressOf(shmStore) is returned from $SEAM functions in shm.dart, expected exactly 4 (the meta, region, plane and whole-block accessors)"
# COMMENTS STRIPPED. The seam is about CODE reaching the symbol, and a check
# that could not tell prose from code makes it illegal to WRITE ABOUT the
# block -- which is what `wm.dart` does when it explains (ADR-0050 §3) that
# `shmStore` was the last `.bss` block until D4's went behind it. That
# explanation is the kind of thing this repo's documentation rules ask for, and
# the first version of this check failed on it.
capture_sh SEAM_OUT SEAM_STATUS -- "python3 - '$CORE_DIR/kernel' <<'PY'
import os, re, sys
d = sys.argv[1]
bad = []
for f in sorted(os.listdir(d)):
    if not f.endswith('.dart') or f == 'shm.dart':
        continue
    src = open(os.path.join(d, f)).read()
    src = re.sub(r'///[^\n]*', ' ', src)
    src = re.sub(r'//[^\n]*', ' ', src)
    if 'shmStore' in src:
        bad.append(f)
if bad:
    raise SystemExit('shmStore is referenced in CODE outside shm.dart: %s' % bad)
print('    shmStore is reached only through shm.dart accessors')
PY"
ck; [[ $SEAM_STATUS -eq 0 ]] || { echo "$SEAM_OUT" >&2; fail "the shmStore storage seam is broken"; }
echo "$SEAM_OUT"

# 2f. W^X, STRUCTURALLY -- the state must not be EXPRESSIBLE, not merely
# refused. `vmShmMap` must take no `exec` parameter and must set NX
# unconditionally. This is checked by reading the function body, because a
# conditional NX would still pass every runtime test that never asks for X.
capture_sh WX_OUT WX_STATUS -- "python3 - '$CORE_DIR/kernel/vm.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^u64 vmShmMap\((.*?)\) \{(.*?)^\}', src, re.M | re.S)
if not m:
    raise SystemExit('vmShmMap is gone or its signature changed')
params, body = m.group(1), m.group(2)
if 'exec' in params:
    raise SystemExit('vmShmMap has an exec parameter: %s -- a shared executable '
                     'page must not be expressible, not merely refused' % params)
if 'vmNxBit()' not in body:
    raise SystemExit('vmShmMap no longer sets NX at all')
# The NX bit must be OR-ed in unconditionally, i.e. on the same statement that
# builds the base bits, not inside an if.
if not re.search(r'u64 bits = u64\(vmPresent\) \| u64\(vmUser\) \| vmNxBit\(\);', body):
    raise SystemExit('vmShmMap does not set NX unconditionally in its base bits; '
                     'a conditional NX passes every test that never asks for X')
for frag in re.findall(r'if \([^)]*\) \{[^}]*vmNxBit\(\)', body):
    raise SystemExit('vmShmMap sets NX inside a conditional: %r' % frag)
print('    (vmShmMap takes no exec parameter and ORs vmNxBit() into its base bits unconditionally)')
PY"
ck; [[ $WX_STATUS -eq 0 ]] || { echo "$WX_OUT" >&2; fail "vmShmMap can express a writable+executable shared page"; }
echo "STRUCTURAL: pass  a shared page cannot be mapped executable — vmShmMap has no exec parameter and NX is unconditional"
echo "$WX_OUT"

# 2g. EVERY USER-POINTER VALIDATOR STILL WALKS EVERY PAGE.
#
# M21 widened the bound those validators test from `vmProgEnd` to `vmUserEnd`,
# and the ONLY reason that is safe is the per-page `vmEffective` walk: between
# the load region and the shared window there are 512 pages that are mapped only
# where a region has been mapped in, and a validator that tested lo/hi would now
# accept every address in that span. GAP-0124 is the evidence that the walk is
# what kills that mutation. If any of these six stops walking, this check fails.
capture_sh VAL_OUT VAL_STATUS -- "python3 - '$CORE_DIR/kernel' <<'PY'
import os, re, sys
root = sys.argv[1]
want = {
    'elfOwns': 'elf.dart', 'fileOwnsWrite': 'file.dart', 'fileOwnsRead': 'file.dart',
    'chanOwnsRead': 'chan.dart', 'chanOwnsWrite': 'chan.dart',
}
bad = []
for fn, fname in want.items():
    src = open(os.path.join(root, fname)).read()
    m = re.search(r'^u64 %s\(u64 ptr, u64 len\) \{(.*?)^\}' % fn, src, re.M | re.S)
    if not m:
        bad.append('%s is gone or changed signature' % fn); continue
    body = m.group(1)
    if 'vmUserEnd' not in body:
        bad.append('%s does not bound against vmUserEnd' % fn)
    if 'while (a <= last)' not in body:
        bad.append('%s no longer walks page by page -- it is a range test now, and '
                   'the unmapped span between the load region and the shared window '
                   'is a hole (GAP-0124)' % fn)
    if 'vmEffective(a)' not in body:
        bad.append('%s no longer consults vmEffective per page' % fn)
    # The length bound must precede any arithmetic on ptr (ADR-0013 §5).
    li = body.find('len > u64(')
    pi = body.find('(ptr + len)')
    if li < 0 or pi < 0 or li > pi:
        bad.append('%s does not bound len BEFORE computing ptr+len; DCDart traps on '
                   'overflow with a real ud2 and ring 3 chooses ptr' % fn)
if bad:
    raise SystemExit('\n'.join(bad))
print('    (elfOwns, fileOwnsRead, fileOwnsWrite, chanOwnsRead, chanOwnsWrite: all five bound against vmUserEnd, all five still walk every page through vmEffective, all five bound len before touching ptr)')
PY"
ck; [[ $VAL_STATUS -eq 0 ]] || { echo "$VAL_OUT" >&2; fail "a user-pointer validator stopped walking every page, and the widened bound is now a hole"; }
echo "STRUCTURAL: pass  every user-pointer validator still walks every page — which is what makes vmUserEnd safe"
echo "$VAL_OUT"

# 2h. RELEASE-ON-EXIT HAS EXACTLY ONE CALL SITE, AND IT IS procCleanup.
REL=$(grep -c "shmReleaseOwner(" "$CORE_DIR"/kernel/*.dart | awk -F: '{s+=$2} END{print s}')
ck; [[ "$REL" -eq 2 ]] \
  || fail "shmReleaseOwner appears $REL times across the kernel, expected 2 (its definition in shm.dart and its ONE call site) — a resource released from more than one place is one that some path does not release"
ck; grep -q "shmReleaseOwner(s);" "$CORE_DIR/kernel/proc.dart" \
  || fail "procCleanup does not call shmReleaseOwner — a process that FAULTS with a capability would pin a region's frames for the rest of the boot"
capture_sh CLEAN_OUT CLEAN_STATUS -- "python3 - '$CORE_DIR/kernel/proc.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^void procCleanup\(u64 s\) \{(.*?)^\}', src, re.M | re.S)
if not m:
    raise SystemExit('procCleanup is gone')
body = m.group(1)
for need in ('fileReleaseOwner', 'chanReleaseOwner', 'shmReleaseOwner'):
    if need not in body:
        raise SystemExit('procCleanup does not call %s' % need)
# The space must be freed BEFORE the capabilities are dropped: shmReleaseOwner
# does not unmap, it decrements what the mappings stood for.
if body.index('procSpaceFree') > body.index('shmReleaseOwner'):
    raise SystemExit('shmReleaseOwner runs before procSpaceFree; it assumes the '
                     'page tables are already gone')
print('    (procCleanup releases descriptors, endpoints and capabilities, in that order, after procSpaceFree)')
PY"
ck; [[ $CLEAN_STATUS -eq 0 ]] || { echo "$CLEAN_OUT" >&2; fail "procCleanup's release order is wrong"; }
echo "STRUCTURAL: pass  capabilities are released from exactly one place — procCleanup, which the exit path AND the fault/kill path both go through"
echo "$CLEAN_OUT"

# 2i. A NEW ADDRESS SPACE DOES NOT INHERIT A SHARED-REGION MAPPING.
# `procSpaceBuild` copies all 512 page-directory entries by value and must clear
# BOTH windows' entries afterwards. Missing the second one would give every
# process created after a region existed a silent path to another's memory.
ck; grep -q "vmShmPdCount" "$CORE_DIR/kernel/proc.dart" \
  || fail "procSpaceBuild does not walk vmShmPdCount; a new address space would INHERIT a shared-region page table from a second SHM PDE"
ck; grep -q "vmSetEntry(pd, u64(vmShmPdIndex) + shmPdI, u64(0));" "$CORE_DIR/kernel/proc.dart" \
  || fail "procSpaceBuild does not clear PD[vmShmPdIndex + i]; a new address space would INHERIT whatever shared-region page table the kernel's page directory happened to carry"
ck; grep -q "vmSetEntry(pd, u64(vmProgPdIndex), u64(0));" "$CORE_DIR/kernel/proc.dart" \
  || fail "procSpaceBuild no longer clears PD[vmProgPdIndex]"

# 2j. THE ONE BRANCH IN freeFrame, in the right place.
capture_sh FF_OUT FF_STATUS -- "python3 - '$CORE_DIR/kernel/pmm.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^u64 freeFrame\(u64 addr\) \{(.*?)^\}', src, re.M | re.S)
if not m:
    raise SystemExit('freeFrame is gone')
body = m.group(1)
if 'shmFrameShared(addr)' not in body:
    raise SystemExit('freeFrame does not consult shmFrameShared -- a shared frame '
                     'would be released by whichever process exits first')
i_align = body.index('pmmFrameMask')
i_guard = body.index('shmFrameShared')
i_range = body.index('pmmFreeRange')
if not (i_align < i_guard < i_range):
    raise SystemExit('the shared-frame guard is not between the alignment check and '
                     'the range check; an unaligned address must never compute a '
                     'frame number (docs/design/memory.md 2.2)')
# The guard must hand back pmmFreeOk. A distinct code would be more expressive
# and would silently start adding a non-zero number to procHeadErrors at four
# call sites, because every caller ADDS this status to a running error counter
# and only pmmFreeOk is zero (memory.md 2.3).
guard = body[i_guard:body.index('final u64 f =')]
if 'return u64(pmmFreeOk);' not in guard:
    raise SystemExit('the shared-frame guard does not return pmmFreeOk: %r' % guard)
if re.search(r'^const int pmmFreeShared', src, re.M):
    raise SystemExit('a pmmFreeShared status code was declared; see memory.md 2.3')
print('    (the guard sits after ready and alignment, before range, and returns pmmFreeOk)')
PY"
ck; [[ $FF_STATUS -eq 0 ]] || { echo "$FF_OUT" >&2; fail "freeFrame's shared-frame guard is missing or misplaced"; }
echo "STRUCTURAL: pass  freeFrame's shared-frame guard is one branch, in the one place five teardown paths funnel through"
echo "$FF_OUT"

# 2k. THE REFUSAL CODES ARE DISTINCT, ALL ABOVE ONE FLOOR, AND prog.c's PRIVATE
# COPY AGREES WITH THE KERNEL'S.
#
# The program is freestanding and shares no header with the kernel, so it
# carries its own copy of every return value. THIS is the check that makes a
# private copy safe rather than a second source of truth -- and the reverse
# direction matters just as much: a fifteenth refusal added to shm.dart without
# teaching the program about it fails here rather than going untested.
capture_sh RET_OUT RET_STATUS -- "python3 - '$CORE_DIR/kernel/shm.dart' '$SCRIPT_DIR/prog.c' <<'PY'
import re, sys
kern = open(sys.argv[1]).read()
prog = open(sys.argv[2]).read()
kv = {m.group(1): int(m.group(2), 16)
      for m in re.finditer(r'^const int (shmRet\w+) = (0x[0-9A-Fa-f]+);', kern, re.M)}
pv = {m.group(1): int(m.group(2), 16)
      for m in re.finditer(r'^#define (SHM_[A-Z0-9_]+) (0x[0-9A-Fa-f]+)UL', prog, re.M)}
floor = kv.get('shmRetFloor')
if floor is None:
    raise SystemExit('shm.dart has no shmRetFloor')
codes = {k: v for k, v in kv.items() if k != 'shmRetFloor'}
if len(set(codes.values())) != len(codes):
    raise SystemExit('two shmRet* constants share a value: %r' % sorted(codes.items()))
for k, v in codes.items():
    if v <= floor:
        raise SystemExit('%s (0x%X) is not above shmRetFloor (0x%X)' % (k, v, floor))
# DERIVED, not listed. This used to be a hand-kept table, and a hand-kept
# table is a second place to forget: ADR-0163 added shmRetBadFixed to shm.dart
# and the table did not know the name, so the census went red with 'a refusal
# was added without a test' -- correctly, but only because someone had to come
# and edit two files. The mapping is mechanical (shmRetBadLen -> SHM_BADLEN),
# so derive it, and keep ONE explicit irregular spelling with its reason.
IRREGULAR = {'shmRetNoPeer': 'SHM_NOPEER2'}   # SHM_NOPEER is already taken in prog.c
pairs = {}
for kk in kv:
    pk = IRREGULAR.get(kk) or ('SHM_' + kk[len('shmRet'):].upper())
    pairs[pk] = kk
for pk, kk in pairs.items():
    if pk not in pv:
        raise SystemExit('prog.c does not define %s' % pk)
    if kk not in kv:
        raise SystemExit('shm.dart does not declare %s' % kk)
    if pv[pk] != kv[kk]:
        raise SystemExit('prog.c %s = 0x%X but shm.dart %s = 0x%X' % (pk, pv[pk], kk, kv[kk]))
unknown = set(kv) - set(pairs.values())
if unknown:
    raise SystemExit('shm.dart declares %s, which prog.c has not been taught to '
                     'recognise -- a refusal was added without a test' % sorted(unknown))
# The permission words too.
for name, want in (('SHM_R', 'shmPermRead'), ('SHM_W', 'shmPermWrite'), ('SHM_X', 'shmPermExec'),
                   ('SHM_RO', 'shmPermRo'), ('SHM_RW', 'shmPermRw')):
    km = re.search(r'^const int %s = (\d+);' % want, kern, re.M)
    pm = re.search(r'^#define %s (\d+)UL' % name, prog, re.M)
    if not km or not pm or int(km.group(1)) != int(pm.group(1)):
        raise SystemExit('%s / %s disagree' % (name, want))
print('    (%d refusal codes, all distinct, all above one floor, and prog.c agrees with shm.dart on every one — and on the five permission words)' % len(codes))
PY"
ck; [[ $RET_STATUS -eq 0 ]] || { echo "$RET_OUT" >&2; fail "shm.dart's refusal codes and prog.c's private copy do not agree"; }
echo "STRUCTURAL: pass  every refusal code is distinct, above one floor, and known to the program"
echo "$RET_OUT"

# 2l. THE SYSCALL REGISTRY IS THE ALLOCATOR (GAP-0213). Two branches that cannot
# see each other have claimed the same number twice in this project's history;
# the registry verifier reads BOTH the table and the kernel and is what caught
# it the second time.
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh' 2>&1"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh rejected M21's syscall numbers"; }
echo "$REG_OUT"
for n in 16 17 18 19; do
  ck; grep -qE "^\| $n \| \`shm" "$CORE_DIR/docs/syscall-registry.md" \
    || fail "syscall $n has no shm* row in the registry"
done

# 2m. A GRANT IS READ-ONLY, AND THAT IS NOT A PARAMETER.
capture_sh GR_OUT GR_STATUS -- "python3 - '$CORE_DIR/kernel/shm.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^void shmSysGrant\(u64 frame\) \{(.*?)^\}', src, re.M | re.S)
if not m:
    raise SystemExit('shmSysGrant is gone')
body = m.group(1)
if 'shmCapPack(r, u64(shmPermRo)' not in body:
    raise SystemExit('shmSysGrant does not install a READ-ONLY capability; a grant '
                     'that could convey write access makes the number of writers a '
                     'property of the caller argument rather than of the design')
if re.search(r'userFrame\(frame, u64\(userFrameRdx\)\)', body):
    raise SystemExit('shmSysGrant reads a third argument -- permissions must not be '
                     'one')
print('    (shmSysGrant installs shmPermRo unconditionally and reads no permission argument)')
PY"
ck; [[ $GR_STATUS -eq 0 ]] || { echo "$GR_OUT" >&2; fail "a grant is no longer unconditionally read-only"; }
echo "STRUCTURAL: pass  a grant conveys READ-ONLY and cannot convey anything else — so a region has exactly one writer, by construction"
echo "$GR_OUT"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding (CLAUDE.md rule 1).
# ---------------------------------------------------------------------------
echo
echo "=== FREESTANDING ==="
for obj in kmain.o kdata.o portio.o kernel.elf; do
  capture_sh VF_OUT VF_STATUS -- "cd '$CORE_DIR' && bash scripts/verify-freestanding.sh build/$obj 2>&1"
  ck; [[ $VF_STATUS -eq 0 ]] || { echo "$VF_OUT" >&2; fail "verify-freestanding.sh rejected $obj"; }
  echo "$VF_OUT" | tail -1
done

# ---------------------------------------------------------------------------
# Step 4 — build the program and the disk image.
# ---------------------------------------------------------------------------
echo
echo "=== PROGRAM ==="
capture_sh BP_OUT BP_STATUS -- "bash '$SCRIPT_DIR/build-progs.sh' '$WORKDIR' '$CORE_DIR/kernel' 2>&1"
ck; [[ $BP_STATUS -eq 0 ]] || { echo "$BP_OUT" >&2; fail "build-progs.sh could not build the program"; }
echo "$BP_OUT"

DISK_IMG="$WORKDIR/disk.img"
capture_sh MI_OUT MI_STATUS -- "python3 '$SCRIPT_DIR/make-image.py' '$DISK_IMG' '$WORKDIR/shm.elf' 2>&1"
ck; [[ $MI_STATUS -eq 0 ]] || { echo "$MI_OUT" >&2; fail "make-image.py could not build the disk image"; }
echo "$MI_OUT"
# The shell parses `proc coop` / `run` arguments as HEX, so the LBAs are passed
# without their 0x and lower-cased. Field 5 is `0x20,` in `slot A: header LBA
# 0x20, image LBA 0x21, ...`.
# The second image carries the -DM21_ROFAULT binary in both slots, so that boot
# is also "one binary, two roles" and the role split is still the kernel's.
RO_IMG="$WORKDIR/disk-rofault.img"
capture_sh RI_OUT RI_STATUS -- "python3 '$SCRIPT_DIR/make-image.py' '$RO_IMG' '$WORKDIR/shm-rofault.elf' 2>&1"
ck; [[ $RI_STATUS -eq 0 ]] || { echo "$RI_OUT" >&2; fail "make-image.py could not build the read-only-store image"; }

LBA_A=$(echo "$MI_OUT" | awk '/^slot A:/{gsub("0x","",$5); gsub(",","",$5); print tolower($5)}')
LBA_B=$(echo "$MI_OUT" | awk '/^slot B:/{gsub("0x","",$5); gsub(",","",$5); print tolower($5)}')
ck; [[ -n "$LBA_A" && -n "$LBA_B" ]] || fail "could not read the two slot LBAs out of make-image.py's report"

# ---------------------------------------------------------------------------
# Step 5 — boot.
# ---------------------------------------------------------------------------
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" label="$3"
  shift 3
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  # GAP-0150: the port is BOUND-THEN-RELEASED by pick-port.py rather than
  # derived from $$, and the launch is RETRIED if QEMU still loses the race.
  local attempt=0 port drive_status qemu_status qemu_pid
  while :; do
    attempt=$(( attempt + 1 ))
    port=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
    : >"$ser"
    timeout 300 qemu-system-x86_64 \
      -kernel "$KERNEL_ELF" \
      -m 128M \
      -cpu qemu64 \
      -vga std \
      -serial "file:$ser" \
      -display none \
      -no-reboot \
      -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
      -qmp "tcp:127.0.0.1:$port,server,nowait" \
      >"$outdir/qemu.log" 2>&1 &
    qemu_pid=$!
    python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --png "$outdir/shot.png" \
      --screen-text "$outdir/screen.txt" \
      --keys "$keys" \
      "$@"
    drive_status=$?
    wait "$qemu_pid" 2>/dev/null
    qemu_status=$?
    if [[ $drive_status -ne 0 ]] && grep -q "Address already in use" "$outdir/qemu.log" \
       && [[ $attempt -lt 5 ]]; then
      echo "    (port $port was taken between the probe and the launch; retrying — attempt $attempt)"
      continue
    fi
    break
  done
  if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot"
  fi
}

echo
echo "=== BOOT 1: two processes share a page ==="
# `frames` BRACKETS THE WHOLE SESSION. The allocator's free count must be
# IDENTICAL before and after -- which for M21 is a stronger claim than it was
# for M20, because it also proves the region's frames came BACK. They are
# retained across the producer's exit and released only when the LAST capability
# goes, so a bracket taken across each exit separately would not balance and a
# bracket taken across the session must (docs/design/memory.md §2.3).
SESSION_KEYS="f,r,a,m,e,s,ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "proc coop $LBA_A $LBA_B"),ret,wait:20000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:900"
drive_session "$WORKDIR/share" "$SESSION_KEYS" "share"
SER="$WORKDIR/share/serial.txt"

# EVERY ASSERTION BELOW READS A PRINTABLE-ONLY VIEW OF THE CAPTURE.
#
# The program writes raw bytes on purpose -- `progTouch` exists so the RW
# PT_LOAD has a non-zero `p_filesz` and is not optimised away -- so the serial
# capture is not a text file. BSD `grep` detects that and goes QUIET, printing
# "Binary file matches" instead of the match, which makes every `grep -q` here
# succeed and every `grep -c` return nothing. That is a harness that passes
# without checking anything, so the bytes are removed rather than worked around:
# this keeps printable ASCII, tab and newline, and drops everything else.
sread() { python3 -c "
import sys
raw = open(sys.argv[1], 'rb').read()
keep = bytes(b for b in raw if b == 9 or b == 10 or 32 <= b < 127)
sys.stdout.write(keep.decode('ascii'))" "$1"; }
sread "$SER" > "$WORKDIR/share/serial.text"
SERT="$WORKDIR/share/serial.text"

echo
echo "=== ASSERT ==="

# 5a. THE TWO PROCESSES EXISTED AND WERE DIFFERENT PROCESSES.
ck; grep -q "PROC NEW SLOT 00 ID 00000001" "$SERT" || fail "process 1 was never created"
ck; grep -q "PROC NEW SLOT 01 ID 00000002" "$SERT" || fail "process 2 was never created"
PML4_A=$(grep -oE "PROC NEW SLOT 00 ID [0-9A-F]+ PML4 ([0-9A-F]+)" "$SERT" | awk '{print $NF}' | head -1)
PML4_B=$(grep -oE "PROC NEW SLOT 01 ID [0-9A-F]+ PML4 ([0-9A-F]+)" "$SERT" | awk '{print $NF}' | head -1)
ck; [[ -n "$PML4_A" && "$PML4_A" != "$PML4_B" ]] \
  || fail "the two processes report the same PML4 ($PML4_A) — they are not two address spaces, and nothing below means anything"

# 5b. THE REGION WAS CREATED, GRANTED AND MAPPED -- ONCE EACH.
ck; [[ "$(grep -c 'SHM CREATE' "$SERT")" -eq 1 ]] || fail "expected exactly one SHM CREATE"
ck; grep -q "SHM CREATE R 0 GEN 00000001 PAGES 000$WANT_PAGES VA $WANT_REGION_VA" "$SERT" \
  || fail "the region was not created at the address, generation and size the model says: expected 'SHM CREATE R 0 GEN 00000001 PAGES 000$WANT_PAGES VA $WANT_REGION_VA'"
ck; [[ "$(grep -c 'SHM GRANT' "$SERT")" -eq 1 ]] || fail "expected exactly one SHM GRANT"
ck; grep -q "SHM GRANT R 0 TO 00000002 REFS 0002" "$SERT" \
  || fail "the grant did not go to process 2, or did not take the region's reference count to 2"
ck; [[ "$(grep -c 'SHM MAP' "$SERT")" -eq 1 ]] || fail "expected exactly one SHM MAP"
ck; grep -q "SHM MAP R 0 PERM 1 VA $WANT_REGION_VA MAPS 0002" "$SERT" \
  || fail "the consumer did not map the region read-only at $WANT_REGION_VA with two address spaces mapping it"

# 5c. THE SAME PHYSICAL FRAMES IN BOTH ADDRESS SPACES, W^X IN BOTH.
#
# THIS IS THE ASSERTION THE MILESTONE EXISTS FOR, and it is read out of the LIVE
# PAGE TABLES: `shmPageReport` walks from CR3 through `vmEffective` on each
# mapping, so these lines are the permissions the CPU will enforce rather than
# the arguments the mapping was requested with.
capture_sh PG_OUT PG_STATUS -- "python3 - '$SERT' '$MODEL' <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
model = json.load(open(sys.argv[2]))
rx = re.compile(r'^SHM PAGE ([0-9A-F]{16}) P (\d) U (\d) W (\d) X (\d) PA ([0-9A-F]{16})\$', re.M)
rows = rx.findall(text)
n = model['pages']
if len(rows) != 2 * n:
    raise SystemExit('expected %d SHM PAGE lines (%d pages, two mappings), got %d'
                     % (2 * n, n, len(rows)))
prod, cons = rows[:n], rows[n:]
fails = []
for label, got, want in (('producer', prod, model['producer_pages']),
                         ('consumer', cons, model['consumer_pages'])):
    for i, (va, p, u, w, x, pa) in enumerate(got):
        wva, ww, wx = want[i]
        if va != wva:
            fails.append('%s page %d is at %s, expected %s' % (label, i, va, wva))
        if p != '1' or u != '1':
            fails.append('%s page %d is P %s U %s -- a shared page must be present and '
                         'user-accessible' % (label, i, p, u))
        if int(w) != ww:
            fails.append('%s page %d is W %s, expected W %d' % (label, i, w, ww))
        if int(x) != wx:
            fails.append('%s page %d is X %s, expected X %d -- A SHARED PAGE MUST NEVER '
                         'BE EXECUTABLE' % (label, i, x, wx))
        if int(w) == 1 and int(x) == 1:
            fails.append('%s page %d is WRITABLE AND EXECUTABLE. W^X is undone.' % (label, i))
# THE SHARING ITSELF.
for i in range(n):
    if prod[i][5] != cons[i][5]:
        fails.append('page %d is frame %s in the producer and %s in the consumer -- the '
                     'two processes are NOT sharing memory, they have two private copies'
                     % (i, prod[i][5], cons[i][5]))
frames = [r[5] for r in prod]
if len(set(frames)) != n:
    fails.append('the region\\'s %d pages are not %d distinct frames: %r -- one frame '
                 'mapped repeatedly would hash identically to a correct region only by '
                 'accident' % (n, n, frames))
if fails:
    raise SystemExit('\n'.join(fails))
print('    (%d pages; producer W 1 X 0, consumer W 0 X 0, and every page is the SAME '
      'physical frame in both address spaces: %s)' % (n, ' '.join(f[-6:] for f in frames)))
PY"
ck; [[ $PG_STATUS -eq 0 ]] || { echo "$PG_OUT" >&2; fail "the live page tables do not show one set of frames shared read-write/read-only with NX in two address spaces"; }
echo "ASSERT: pass  the SAME physical frames are mapped in BOTH address spaces — writable to the creator, read-only to the grantee, and NOT EXECUTABLE in either"
echo "$PG_OUT"

# 5d. THE CONTENTS. The consumer exits with an FNV-1a of all 16384 bytes it read
# through the shared mapping, and derive.py computed that number on the host
# before the machine booted.
ck; grep -q "M21 C EXIT H $WANT_CONS_HASH" "$SERT" \
  || fail "the consumer did not exit with the hash the host model computed ($WANT_CONS_HASH). Got: $(grep -oE 'M21 C EXIT H [0-9A-F]+' "$SERT" | head -1)"
ck; grep -q "M21 P EXIT H $WANT_PROD_HASH" "$SERT" \
  || fail "the producer did not exit with the hash the host model computed ($WANT_PROD_HASH). Got: $(grep -oE 'M21 P EXIT H [0-9A-F]+' "$SERT" | head -1)"
ck; grep -q "USER EXIT CODE $WANT_CONS_HASH" "$SERT" \
  || fail "the KERNEL did not report the consumer's exit code as $WANT_CONS_HASH — the program printed it but did not exit with it"
ck; grep -q "USER EXIT CODE $WANT_PROD_HASH" "$SERT" \
  || fail "the KERNEL did not report the producer's exit code as $WANT_PROD_HASH"

# 5e. THE REGION OUTLIVED ITS CREATOR.
#
# The producer exits first, holding a read-write mapping of four frames. Its
# address space is torn down -- `procSpaceFree` walks its page table and hands
# every present leaf to `freeFrame`. The consumer then re-reads ALL 16384 BYTES
# and requires the same hash it got before. If the frames had been released and
# reused, this differs.
ck; grep -q "PROC EXIT SLOT 00 ID 00000001 CODE $WANT_PROD_HASH LEFT 00000001" "$SERT" \
  || fail "the producer did not exit first with one process still live — the peer-death case did not happen"
ck; grep -q "M21 C PEERGONE 1" "$SERT" \
  || fail "the consumer never observed CHAN_PEERGONE, so it did not re-read the region AFTER its creator died"
ck; grep -q "M21 C SURVIVED H $WANT_CONS_HASH" "$SERT" \
  || fail "the region's contents after the creator's death are not what they were before it"
# The order matters and is checked: the producer's exit must PRECEDE the
# consumer's second read.
capture_sh ORD_OUT ORD_STATUS -- "python3 - '$SERT' <<'PY'
import sys
t = open(sys.argv[1]).read()
i_exit = t.index('PROC EXIT SLOT 00')
i_kill = t.index('PROC KILL SLOT 00')
i_gone = t.index('M21 C PEERGONE 1')
i_surv = t.index('M21 C SURVIVED')
if not (i_exit < i_kill < i_gone < i_surv):
    raise SystemExit('the ordering is wrong: exit=%d kill=%d peergone=%d survived=%d -- '
                     'the second read must happen AFTER the producer is gone and its '
                     'address space reclaimed, or it proves nothing'
                     % (i_exit, i_kill, i_gone, i_surv))
print('    (producer exit -> address space reclaimed -> peer-gone observed -> 16384 bytes re-read, in that order)')
PY"
ck; [[ $ORD_STATUS -eq 0 ]] || { echo "$ORD_OUT" >&2; fail "the peer-death sequence did not happen in the order that makes it meaningful"; }
echo "ASSERT: pass  the region outlived its creator — 16384 bytes re-read, byte-for-byte, after the producer exited and its address space was reclaimed"
echo "$ORD_OUT"

# 5f. THE FRAME ACCOUNTING.
#
# The producer's teardown must NOT have counted the shared frames, and the
# region's destruction must return exactly the pages plus its frame-vector page.
ck; grep -q "SHM DROP R 0 REFS 0001 MAPS 0001" "$SERT" \
  || fail "the producer's exit did not take the region to one reference and one mapping"
ck; grep -q "SHM DROP R 0 REFS 0000 MAPS 0000" "$SERT" \
  || fail "the consumer's shmdrop did not take the region to zero references"
ck; grep -q "SHM DEAD R 0 GEN 00000001 FREED 0000000$WANT_FRAMES" "$SERT" \
  || fail "the region did not return $WANT_FRAMES frames when it died ($WANT_PAGES pages plus its frame-vector page). Got: $(grep -oE 'SHM DEAD.*' "$SERT" | head -1)"
capture_sh KILL_OUT KILL_STATUS -- "python3 - '$SERT' '$MODEL' <<'PY'
import json, re, sys
t = open(sys.argv[1]).read()
model = json.load(open(sys.argv[2]))
kills = re.findall(r'^PROC KILL SLOT (\d\d) FREED ([0-9A-F]{8})\$', t, re.M)
if len(kills) != 2:
    raise SystemExit('expected two PROC KILL lines, got %d' % len(kills))
counts = {s: int(v, 16) for s, v in kills}
# Six program pages + PML4 + PDPT + PD + program PT + shared-window PT = 11.
# The region's frames are NOT in this number, and that is the assertion: they
# were handed to freeFrame and the guard declined, so they were not counted.
for slot, n in counts.items():
    if n != 11:
        raise SystemExit('slot %s freed %d frames, expected 11 (6 program pages, 4 table '
                         'frames, 1 shared-window page table). If it is %d, the region\\'s '
                         '%d frames were counted as freed by a process that did not own '
                         'them.' % (slot, n, 11 + model['frames_per_region'], model['frames_per_region']))
print('    (both processes freed exactly 11 frames each — their own pages and tables, and NOT one frame of the region they shared)')
PY"
ck; [[ $KILL_STATUS -eq 0 ]] || { echo "$KILL_OUT" >&2; fail "a process teardown counted frames it did not own"; }
echo "ASSERT: pass  neither process's teardown released or counted a frame belonging to the shared region"
echo "$KILL_OUT"

# 5g. THE ALLOCATOR BALANCES ACROSS THE WHOLE SESSION.
capture_sh FRM_OUT FRM_STATUS -- "python3 - '$SERT' <<'PY'
import re, sys
t = open(sys.argv[1]).read()
free = re.findall(r'^PMM MANAGED [0-9A-F]{8} FREE ([0-9A-F]{8}) USED', t, re.M)
if len(free) < 2:
    raise SystemExit('expected two frames reports bracketing the session, got %d' % len(free))
if free[0] != free[-1]:
    raise SystemExit('the allocator had 0x%s frames free before the session and 0x%s after '
                     '-- a shared region leaked frames, or freed some twice'
                     % (free[0], free[-1]))
print('    (0x%s frames free before the session and 0x%s after — to the frame)' % (free[0], free[-1]))
PY"
ck; [[ $FRM_STATUS -eq 0 ]] || { echo "$FRM_OUT" >&2; fail "the frame allocator does not balance across a session that created and destroyed a shared region"; }
echo "ASSERT: pass  the frame allocator's free count is identical before and after — the region's frames came back"
echo "$FRM_OUT"
ck; ! grep -qE "PMM .* ERRORS 0000000[1-9]" "$SERT" \
  || fail "the frame allocator recorded an error during the session — a double free, or a free of a frame the guard should have retained"

# 5h. THE NEGATIVE CONTROLS, SHOWN FAILING.
#
# Twenty refusals, each observed from ring 3 AS A RETURN VALUE and each compared
# by the program against the specific code it expected -- not against "some
# refusal". A control that silently stopped being refused fails here.
capture_sh CTL_OUT CTL_STATUS -- "python3 - '$SERT' <<'PY'
import re, sys
t = open(sys.argv[1]).read()
rows = re.findall(r'M21 CTL (\w+) R ([0-9A-F]{16}) (OK|BAD WANT [0-9A-F]{16})', t)
bad = [(n, r, v) for n, r, v in rows if v != 'OK']
if bad:
    raise SystemExit('these controls did not get the refusal they expected: %r' % bad)
names = [n for n, _, _ in rows]
# The three the brief names by hand, plus the escalation one.
need = {
    'EXEC': 'an executable shared mapping',
    'EXEC_RW': 'a writable+executable shared mapping',
    'ESCALATE': 'a read-only capability asking to be mapped writable',
    'FORGE_MAP': 'a forged handle',
    'FORGE_IDX': 'a handle with an out-of-range index',
    'FORGE_IDX1': 'an index the kernel never filled',
    'FORGE_GRANT': 'a forged handle offered to shmgrant',
    'FORGE_DROP': 'a forged handle offered to shmdrop',
    'LEN0': 'a zero-page region',
    'LENBIG': 'a region one page over the maximum',
    'LENHUGE': 'a region of 0xFFFFFFFFFFFFFFFF pages',
    'STALEGEN': 'a stale generation',
    'BADEP': 'an endpoint the caller does not own',
    'TWICE': 'the same region granted to the same peer twice',
    'REMAP': 'a capability mapped twice',
    'PERM0': 'a permission word of zero',
    'PERM_W': 'a write-only permission word',
    'AFTERDROP': 'a handle used after it was dropped',
    'DROPTWICE': 'a handle dropped twice',
}
missing = [k for k in need if k not in names]
if missing:
    raise SystemExit('these controls never ran: %r' % sorted(missing))
if len(rows) != 20:
    raise SystemExit('expected 20 control observations, got %d: %r' % (len(rows), names))
print('    (%d refusals observed from ring 3 as return values, every one compared against '
      'the SPECIFIC code expected: %s)' % (len(rows), ', '.join(names)))
PY"
ck; [[ $CTL_STATUS -eq 0 ]] || { echo "$CTL_OUT" >&2; fail "a negative control did not fail the way it must"; }
echo "ASSERT: pass  twenty negative controls, each shown being refused with the exact code it expected"
echo "$CTL_OUT"
ck; grep -q "M21 P ACK R 0000000000000003 CTLS 0008" "$SERT" \
  || fail "the producer did not observe its eight controls and the consumer's three-byte ack"
ck; grep -q "M21 C EXIT H $WANT_CONS_HASH CTLS 000C" "$SERT" \
  || fail "the consumer did not observe all twelve of its controls"

# 5i. THE MECHANISMS COMPOSED AND NEITHER CHANGED.
#
# The capability's NAME travelled in a 64-byte message on M20's channel, which
# is `chanMsgBytes` exactly. ADR-0027 §2.3 said a frame descriptor would fit and
# that `chan.dart` would not have to change to carry one; this is that claim,
# executed.
ck; [[ "$(dartconst chanMsgBytes chan.dart)" -eq 64 ]] \
  || fail "chanMsgBytes is no longer 64 — M21's frame descriptor is sized to it"
ck; grep -q "CHAN SEND EP 00 LEN 40 SEQ 00000000" "$SERT" \
  || fail "the frame descriptor was not sent as a single 0x40-byte message on the channel"
ck; grep -q "CHAN RECV EP 01 LEN 40 SEQ 00000000" "$SERT" \
  || fail "the consumer did not receive the 0x40-byte descriptor"
# And the AUTHORITY did not travel in it.
capture_sh CMP_OUT CMP_STATUS -- "python3 - '$CORE_DIR/kernel/chan.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^u64 chanPeerId\(u64 ep, u64 id\) \{(.*?)^\}', src, re.M | re.S)
if not m:
    raise SystemExit('chanPeerId is gone')
body = m.group(1)
for forbidden in ('chanCopyIn', 'chanCopyOut', 'chanHeadWord', 'chanTailWord'):
    if forbidden in body:
        raise SystemExit('chanPeerId touches the message rings (%s) -- it must only NAME '
                         'the peer, never carry anything' % forbidden)
if 'chanOwnerWord(side)' not in body or 'chanPortOpen' not in body:
    raise SystemExit('chanPeerId no longer checks that the caller owns the endpoint and '
                     'that the port is open')
print('    (chanPeerId reads no ring; it checks ownership against the scheduler and returns an id)')
PY"
ck; [[ $CMP_STATUS -eq 0 ]] || { echo "$CMP_OUT" >&2; fail "M21's contact with chan.dart is not confined to naming the peer"; }
echo "ASSERT: pass  the 64-byte channel message carried the region's NAME; the authority was installed by the kernel in the peer's own table"
echo "$CMP_OUT"

# ---------------------------------------------------------------------------
# THE NO-PROCESS GUARD: STRUCTURAL, AND THAT IS A WEAKER CLAIM STATED AS ONE.
#
# `shmSysCreate`, `shmSysGrant`, `shmSysMap` and `shmSysDrop` each begin by
# asking `shmCallerId()`, which returns 0 when `procLive() < 1`, and each refuses
# such a caller with `shmRetNoProc`. THIS HARNESS CANNOT REACH THAT PATH, and the
# reason is not that the guard is dead:
#
# ADR-0034 unified the launch path so that `run <lba>` goes through
# `procCreate`. Every ring-3 program the shell can start therefore HAS a process
# slot, and nothing reachable from a prompt produces `procLive() < 1` while
# ring-3 code runs. M20 hit this first and GAP-0214 records it in full: its
# CHECK 13 had been a real boot in which the same binary started with `run`
# was refused by all three channel syscalls, and ADR-0034 abolished the premise
# rather than the guard.
#
# M21 INHERITS EXACTLY THAT SITUATION and it is filed as GAP-0239, in GAP-0214's
# category and explicitly NOT in GAP-0206's: the path still exists and is still
# reachable -- an M9-style `user` payload runs with no process slot and would hit
# these four lines today -- what is missing is a payload that issues `shmcreate`.
# A live defence with nothing proving it works is worse than a dead-and-known
# one, so it is recorded rather than quietly counted as covered.
#
# What is asserted here is therefore only that the guard has not been DELETED.
capture_sh NP_OUT NP_STATUS -- "python3 - '$CORE_DIR/kernel/shm.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
missing = []
for fn in ('shmSysCreate', 'shmSysGrant', 'shmSysMap', 'shmSysDrop'):
    m = re.search(r'^void %s\(u64 frame\) \{(.*?)^\}' % fn, src, re.M | re.S)
    if not m:
        missing.append('%s is gone' % fn); continue
    body = m.group(1)
    if 'shmCallerId()' not in body:
        missing.append('%s does not ask shmCallerId()' % fn)
    if 'shmRetNoProc' not in body:
        missing.append('%s does not refuse with shmRetNoProc' % fn)
    # And the guard must be FIRST: a capability table is slot storage, so
    # nothing may touch procCurrent() before the caller is known to be a process.
    i_id = body.index('shmCallerId()') if 'shmCallerId()' in body else 1 << 30
    i_cur = body.index('procCurrent()') if 'procCurrent()' in body else 1 << 30
    if i_cur < i_id:
        missing.append('%s reaches procCurrent() before it has established that the '
                       'caller is a process' % fn)
m = re.search(r'^u64 shmCallerId\(\) \{(.*?)^\}', src, re.M | re.S)
if not m or 'procLive() < u64(1)' not in m.group(1):
    missing.append('shmCallerId no longer returns 0 when procLive() is 0')
if missing:
    raise SystemExit('\n'.join(missing))
print('    (all four syscalls ask shmCallerId() before touching procCurrent(), all four '
      'refuse with shmRetNoProc, and shmCallerId still returns 0 when procLive() is 0)')
PY"
ck; [[ $NP_STATUS -eq 0 ]] || { echo "$NP_OUT" >&2; fail "the no-process guard has been weakened or removed"; }
echo "STRUCTURAL: pass  the no-process guard is present in all four syscalls and runs before anything reads the process slot — asserted by READING, not by running (GAP-0239)"
echo "$NP_OUT"

# ---------------------------------------------------------------------------
# BOOT 2 — A STORE THROUGH THE GRANTEE'S READ-ONLY MAPPING MUST FAULT.
#
# The page tables say `W 0` (asserted above, out of the live tables). This boot
# asserts the CPU AGREES, because those are the same claim only if CR0.WP and
# the ring-3 boundary behave as M8 and M9 established — and M21 is the milestone
# that introduces a page ring 3 can REACH and must not WRITE.
#
# TWO-SIDED. If the mapping is read-only the store raises #PF with error 0x7 —
# present, write, user — and `ROSTORE SURVIVED` never appears. If a grantee were
# ever mapped writable the store SUCCEEDS and that line DOES appear, and this
# harness fails on its presence. Neither outcome can pass by accident.
#
# The hash is read out of the TRANSCRIPT here, not out of an exit code: the
# faulting process is killed and never reaches `exit`, which is exactly why
# prog.c prints it before storing.
# ---------------------------------------------------------------------------
echo
echo "=== BOOT 2: a store through the read-only mapping ==="
DISK_IMG="$RO_IMG"
RO_KEYS="$(typekeys "proc coop $LBA_A $LBA_B"),ret,wait:20000"
drive_session "$WORKDIR/rofault" "$RO_KEYS" "read-only-store"
sread "$WORKDIR/rofault/serial.txt" > "$WORKDIR/rofault/serial.text"
ROT="$WORKDIR/rofault/serial.text"

ck; grep -q "M21 C SURVIVED H $WANT_CONS_HASH" "$ROT" \
  || fail "the read-only-store boot did not get as far as reading the region correctly, so its fault would prove nothing"
ck; grep -q "M21 C ROSTORE VA $WANT_REGION_VA" "$ROT" \
  || fail "the program never announced the store it was about to make"
# THE CONTROL THAT MUST NOT APPEAR.
ck; ! grep -q "ROSTORE SURVIVED" "$ROT" \
  || fail "A STORE THROUGH THE GRANTEE'S MAPPING SUCCEEDED. The shared region is writable to a process that holds a READ-ONLY capability; ADR-0041 §6.2's one-writer property is false and every claim resting on it is void."
# AND THE FAULT THAT MUST.
ck; grep -q "PF CR2 $WANT_REGION_VA ERR 00000007 PRESENT WRITE USER DATA" "$ROT" \
  || fail "no page fault at $WANT_REGION_VA with error 0x7 (present, write, user, data). Got: $(grep -oE 'PF CR2 [0-9A-F]+ ERR [0-9A-F]+ .*' "$ROT" | head -1)"
ck; grep -qE "USER FAULT VEC 0E ERR 0000000000000007 RIP [0-9A-F]+ CPL 3" "$ROT" \
  || fail "the fault was not reported as a ring-3 (CPL 3) #PF"
# AND THE PROCESS DIED FOR IT.
capture_sh ROK_OUT ROK_STATUS -- "python3 - '$ROT' <<'PY'
import re, sys
t = open(sys.argv[1]).read()
i_hash = t.find('M21 C SURVIVED')
i_ann  = t.find('M21 C ROSTORE VA')
i_pf   = t.find('PF CR2')
if not (i_hash >= 0 and i_ann > i_hash and i_pf > i_ann):
    raise SystemExit('the ordering is wrong: the region must be read correctly, THEN the '
                     'store announced, THEN the fault (hash=%d announce=%d pf=%d)'
                     % (i_hash, i_ann, i_pf))
kills = re.findall(r'^PROC KILL SLOT (\d\d) FREED ([0-9A-F]{8})\$', t, re.M)
if not kills:
    raise SystemExit('nothing was killed; a faulting ring-3 process must be torn down')
print('    (region read correctly -> store announced -> #PF at the region base -> process killed, in that order)')
PY"
ck; [[ $ROK_STATUS -eq 0 ]] || { echo "$ROK_OUT" >&2; fail "the read-only-store sequence did not happen in the order that makes it meaningful"; }
echo "ASSERT: pass  a store through the grantee's mapping FAULTS — #PF error 0x7 at the region base, from CPL 3, and the process is killed. GAP-0238 closed."
echo "$ROK_OUT"

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------
echo
require_assertions "$ASSERTIONS_REQUIRED"
echo "M21-shmem: PASS — dcc build -> link -> clang builds ONE freestanding ELF64 -> make-image.py writes it to two byte-identical disk slots -> structural checks (the shared window multiplies out against the load region it must not move; shmStore tiles exactly at 8576 and is immediately before D4's wmStore, which is now last, with the total at 22336; the storage seam is 4 call sites in one file; vmShmMap CANNOT EXPRESS a writable+executable page; all five user-pointer validators still walk every page, which is what makes the widened vmUserEnd safe; freeFrame's shared-frame guard is one branch in the one place five teardown paths funnel through; procCleanup releases capabilities on the fault path as well as the exit path; procSpaceBuild clears BOTH windows; a grant is unconditionally read-only; 16 refusal codes distinct, above one floor, and agreeing with prog.c's private copy; the syscall registry accepts 16..19) -> verify-freestanding pass on kmain.o, kdata.o, portio.o and kernel.elf -> TWO REAL QEMU BOOTS. Two processes in two different address spaces (two different PML4s) share ${WANT_PAGES} frames: the SAME physical frames appear in BOTH page tables, walked out of the live tables through vmEffective, WRITABLE to the creator, READ-ONLY to the grantee, and NOT EXECUTABLE in either. The consumer exits with $WANT_CONS_HASH, an FNV-1a of all 16384 bytes it read through the shared mapping, computed on the host before the machine booted and different from the producer's $WANT_PROD_HASH. The producer then EXITS while the consumer still holds a capability, its address space is reclaimed, and the consumer re-reads all 16384 bytes and gets the same hash — with neither teardown releasing or counting one frame of the region. The region dies with its last capability, returns exactly $WANT_FRAMES frames, and the allocator's free count is identical before and after. Twenty negative controls observed from ring 3 as return values, including an executable mapping refused, a read-only capability refused permission to widen, four forged handles refused and three out-of-range lengths refused. A SECOND BOOT stores through the grantee's read-only mapping and requires the #PF: ERR 0x7 (present, write, user, data) at the region base, from CPL 3, with the process killed -- and requires the ABSENCE of the line the program prints if that store succeeds, so the control is two-sided. The no-process guard is asserted STRUCTURALLY and not behaviourally, because ADR-0034 left nothing the shell can start without a process slot — GAP-0239, in GAP-0214's category."
