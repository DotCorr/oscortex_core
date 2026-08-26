#!/usr/bin/env bash
# core/tests/conformance/m20-ipc/run.sh
#
# Mechanical check of M20's exit criterion: TWO RING-3 PROCESSES, IN TWO
# DIFFERENT ADDRESS SPACES, EXCHANGE MESSAGES THROUGH THE KERNEL, AND EACH ONE
# EXITS WITH A 64-BIT HASH OF THE BYTES IT ACTUALLY RECEIVED -- a number this
# harness computed on the host before the machine was booted.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Before M20 the two processes m11 and m18 run share nothing but a CPU. They
# cannot address one byte of each other's memory -- m11's `proc cross` proves it
# with a #PF -- and they have no way to say anything to each other at all.
# M20 adds `core/kernel/chan.dart` and three syscalls, and:
#
#   * ONE BINARY TAKES BOTH ROLES. `make-image.py` writes the SAME BYTES to two
#     disk slots and refuses to build an image where they differ. Which process
#     becomes the requester and which the responder is decided ENTIRELY by which
#     one `chanopen` answers first. So "the two processes behaved differently"
#     is a claim about the kernel, not about two programs.
#
#   * THE RECEIVED CONTENTS ARE ASSERTED, NOT THE RETURN CODE. Each side exits
#     with an FNV-1a hash of every payload byte the kernel handed it, and
#     `derive.py` computes both hashes independently from the protocol's
#     formulas. A kernel that returned the right lengths over a zero-filled
#     buffer, or delivered a stale ring slot, produces a different 64-bit number.
#     The two hashes are also required to DIFFER from each other, so one exit
#     status cannot satisfy both checks.
#
#   * EIGHT MESSAGES ARE DELIVERED BY A PROCESS THAT HAS ALREADY EXITED. The
#     requester fills the ring and exits without its peer having read a byte.
#     The responder then drains all eight, checks every one against the host's
#     model, and only THEN gets CHAN_PEERGONE. That is the ownership/lifetime
#     claim of ADR-0027 section 5, executed.
#
#   * NINETEEN REFUSAL OUTCOMES ARE OBSERVED FROM RING 3 AS RETURN VALUES,
#     covering TWELVE of chan.dart's FOURTEEN refusal-and-status codes. The two
#     that are NOT exercised are named rather than left to be counted:
#     `chanRetBusy` needs a THIRD process to try an already-open port and `proc
#     coop` starts exactly two (GAP-0167), and `chanRetCorrupt` is a state
#     nothing in this kernel can produce (GAP-0166).
#     Including the two that matter most: a `chanrecv` whose destination is the program's own
#     READ-ONLY page (refused, because the kernel must not write through a
#     mapping ring 3 cannot write, ADR-0027 section 4), and a `chansend` whose
#     pointer is 0xFFFFFFFFFFFFFFFF (refused BEFORE the kernel adds the length
#     to it, because DCDart traps on overflow and a #UD inside the syscall
#     handler would be ring 3 choosing the kernel's next instruction).
#
#   * THE SAME PORT NUMBER IS REUSED BY A SECOND SESSION IN THE SAME BOOT, with
#     a different generation and two new process ids, and produces byte-for-byte
#     the same two hashes -- which is what proves the port was actually wiped
#     and returned to FREE rather than merely appearing to.
#
#   * A NEGATIVE CONTROL THAT IS NOT A PROCESS. The SAME BINARY started with
#     `run <lba>` is an M10-style program with no process slot, and all three
#     syscalls refuse it with CHAN_NOPROC. GAP-0164.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * NOTHING HERE IS CONCURRENT. One CPU, and `proc coop` does not preempt, so
#     the interleaving is exactly the two programs' yields. ADR-0027 section 6
#     says what that leaves unproven and GAP-0165 records it.
#   * NO BLOCKING. The responder POLLS. There is no wait queue and no wakeup;
#     GAP-0160.
#   * NO SHARED MEMORY AND NO FRAME EVER MOVES. A message is 64 bytes, checked
#     in the kernel. ADR-0027 section 2 is why.
#   * THE CHANNEL IS NOT REACHABLE FROM AN M9 PAYLOAD. Only the `run <lba>` half
#     of that is exercised here; the M9 `user` path is not.
#
# Usage:
#   core/tests/conformance/m20-ipc/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "M20-ipc: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M20-ipc: FAIL — $1" >&2; exit 2; }

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m20.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
[[ -f "$M1_EXPECTED" ]] || setup_error "m1-interrupts/expected.txt not found"

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

symsize() {
  x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$1" '$8==s {print $3; exit}'
}

# ---------------------------------------------------------------------------
# Step 2 — structural checks. Everything establishable without booting is.
# ---------------------------------------------------------------------------

# 2a. THE .bss ACCOUNTING, AND WHY M20's BLOCK IS THE LAST ONE.
#
# `chanStore` is 2624 bytes of DCDart `@bss` declared in `chan.dart`, which
# kmain.dart lists LAST. That is not a filing preference: every harness from M2
# onward measures "the donated bytes from MY block to the end of .bss", and a new
# block anywhere other than the end would change every one of those numbers at
# once. At the end, each older harness subtracts this one first -- exactly what
# M14, M15, M16 and M19 each got in turn, and what the twelve harnesses this
# milestone edited now do for this block.
bssfield() {   # bssfield <readelf column> <symbol> -- kmain.o first, then kdata.o
  local f="$1" n="$2" o v
  for o in kmain.o kdata.o; do
    v=$(x86_64-elf-readelf -sW "$CORE_DIR/build/$o" \
          | awk -v s="$n" -v f="$f" '$4=="OBJECT" && $8==s {print $f; exit}')
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  done
  return 1
}
bsssize() { bssfield 3 "$1"; }
bssoff()  { bssfield 2 "$1"; }

DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section"
ASM_BSS=$((16#$ASM_BSS_HEX))
[[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o donates $ASM_BSS bytes of .bss, expected exactly 96"
KDATA_BSS=$(( DART_BSS + ASM_BSS ))
[[ "$KDATA_BSS" -eq 16992 ]] || fail "the kernel's mutable static storage is $KDATA_BSS bytes, expected 16992 — 14368 through M19 plus chanStore's 2624. If that changed, it changed deliberately and this number, GAP-0053's running total, and every harness that subtracts a later block move with it."

CHAN_STORE_SIZE=$(bsssize chanStore)
[[ "$CHAN_STORE_SIZE" == "2624" ]] || fail "chanStore is ${CHAN_STORE_SIZE:-missing} bytes, expected 2624"
CHAN_OFF=$(bssoff chanStore)
[[ -n "$CHAN_OFF" ]] || fail "chanStore has no .bss offset in kmain.o"
[[ $(( 16#$CHAN_OFF + CHAN_STORE_SIZE )) -eq "$DART_BSS" ]] \
  || fail "chanStore ends at $(( 16#$CHAN_OFF + CHAN_STORE_SIZE )) and kmain.o's .bss is $DART_BSS — M20's block is NOT the last one, so every earlier harness's 'bytes from my block to the end' number has silently moved"
[[ $(( KDATA_BSS - CHAN_STORE_SIZE )) -eq 14368 ]] \
  || fail "the .bss outside chanStore is $(( KDATA_BSS - CHAN_STORE_SIZE )), not M19's 14368 — M20 moved storage it does not own"

# THE REGIONS TILE EXACTLY. A region that ran past the end of a port record
# would corrupt the NEXT port's header -- silently, because `.bss` is not zeroed
# and nothing guards it. Multiplied out here rather than trusted.
C_MSG=$(dartconst chanMsgBytes chan.dart)
C_DEPTH=$(dartconst chanRingDepth chan.dart)
C_MASK=$(dartconst chanRingMask chan.dart)
C_PORTS=$(dartconst chanPorts chan.dart)
C_SIDES=$(dartconst chanSides chan.dart)
C_EPS=$(dartconst chanEndpoints chan.dart)
C_HDRW=$(dartconst chanHdrWords chan.dart)
C_HDRB=$(dartconst chanHdrBytes chan.dart)
C_LENOFF=$(dartconst chanLenOffset chan.dart)
C_LENB=$(dartconst chanLenBytes chan.dart)
C_DATAOFF=$(dartconst chanDataOffset chan.dart)
C_DATAB=$(dartconst chanDataBytes chan.dart)
C_PORTB=$(dartconst chanPortBytes chan.dart)
C_METAW=$(dartconst chanMetaWords chan.dart)
C_METAB=$(dartconst chanMetaBytes chan.dart)
C_PORTOFF=$(dartconst chanPortOffset chan.dart)
C_STORE=$(dartconst chanStoreBytes chan.dart)

[[ "$C_STORE" -eq "$CHAN_STORE_SIZE" ]] || fail "chan.dart says chanStoreBytes=$C_STORE and the image has $CHAN_STORE_SIZE"
[[ $(( C_METAW * 8 )) -eq "$C_METAB" ]] || fail "chanMetaWords*8 != chanMetaBytes"
[[ "$C_METAB" -eq "$C_PORTOFF" ]] || fail "the global counters do not end where the port records begin"
[[ $(( C_PORTOFF + C_PORTS * C_PORTB )) -eq "$C_STORE" ]] || fail "the $C_PORTS port records at $C_PORTOFF do not end at the block's end ($C_STORE)"
[[ $(( C_HDRW * 8 )) -eq "$C_HDRB" ]] || fail "chanHdrWords*8 != chanHdrBytes"
[[ "$C_HDRB" -eq "$C_LENOFF" ]] || fail "the port header does not end where the length array begins"
[[ $(( C_SIDES * C_DEPTH * 8 )) -eq "$C_LENB" ]] || fail "chanLenBytes is $C_LENB, expected $(( C_SIDES * C_DEPTH * 8 ))"
[[ $(( C_LENOFF + C_LENB )) -eq "$C_DATAOFF" ]] || fail "the length array does not end where the message data begins"
[[ $(( C_SIDES * C_DEPTH * C_MSG )) -eq "$C_DATAB" ]] || fail "chanDataBytes is $C_DATAB, expected $(( C_SIDES * C_DEPTH * C_MSG ))"
[[ $(( C_DATAOFF + C_DATAB )) -eq "$C_PORTB" ]] || fail "the message data does not end at the port record's end"
[[ $(( C_PORTS * C_SIDES )) -eq "$C_EPS" ]] || fail "chanEndpoints is $C_EPS, expected chanPorts*chanSides = $(( C_PORTS * C_SIDES ))"
# The ring depth must be a power of two, because the slot index is a MASK.
[[ $(( C_DEPTH & C_MASK )) -eq 0 && $(( C_DEPTH - 1 )) -eq "$C_MASK" ]] \
  || fail "chanRingDepth $C_DEPTH and chanRingMask $C_MASK are not a power of two and its mask — `counter & mask` would not be a slot index"
echo "STRUCTURAL: pass  chanStore is $C_STORE bytes and the LAST block in .bss: $C_METAW global words at 0, then $C_PORTS port records of $C_PORTB (a ${C_HDRB}-byte header, $C_LENB bytes of per-slot lengths, $C_DATAB bytes of ring), tiling exactly; $C_DEPTH slots per direction is a power of two and $C_MASK is its mask"

# 2b. THE 64-BYTE CAP IS THE DESIGN, AND IT IS CHECKED IN THE KERNEL.
#
# This is ADR-0027 section 2 as a mechanical check. If `chanMsgBytes` ever grows
# to something that could hold a frame, this milestone's central argument -- that
# bulk data must travel by reference and the primitive must make that
# unavoidable -- has been abandoned, and it should be abandoned deliberately.
[[ "$C_MSG" -eq 64 ]] || fail "chanMsgBytes is $C_MSG, expected 64. ADR-0027 §2: this is a HARD cap, not a default, and it is what forces frames onto a shared-region path instead of through the kernel."
# ...and BOTH validators bound the length before touching the pointer.
python3 - "$CORE_DIR/kernel/chan.dart" <<'PY' || fail "chan.dart's pointer validators do not bound the length before using the pointer"
import re, sys
src = open(sys.argv[1]).read()
fails = []
for name, needs_w in (("chanOwnsRead", False), ("chanOwnsWrite", True)):
    m = re.search(r"u64 %s\(u64 ptr, u64 len\) \{(.*?)\n\}" % name, src, re.S)
    if not m:
        fails.append("%s is missing" % name); continue
    body = m.group(1)
    # The order that matters: every bound on `len` must appear BEFORE the one
    # place `ptr + len` is computed. DCDart traps on overflow, so an addition
    # that ran first would be a #UD inside the syscall handler.
    add = body.find("(ptr + len) >")
    cap = body.find("len > u64(chanMsgBytes)")
    zero = body.find("len < u64(1)")
    if add < 0:
        fails.append("%s never bounds ptr + len against the window's end" % name)
    if cap < 0 or cap > add:
        fails.append("%s does not bound len by chanMsgBytes BEFORE computing ptr + len" % name)
    if zero < 0 or zero > add:
        fails.append("%s does not refuse a zero length before computing ptr + len" % name)
    if "vmEffective(a) & u64(2)" not in body and "e & u64(2)" not in body:
        fails.append("%s does not require the USER bit on every page" % name)
    has_w = "u64(4)" in body
    if needs_w and not has_w:
        fails.append("%s does not require the WRITABLE bit -- IPC would be a way to "
                     "write through a read-only user mapping from ring 0" % name)
    if (not needs_w) and has_w:
        fails.append("chanOwnsRead requires the WRITABLE bit; sending out of a "
                     "read-only page is legitimate and must work")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "STRUCTURAL: pass  chanMsgBytes is 64 and BOTH validators bound the length before computing ptr+len; chanOwnsWrite requires the W bit and chanOwnsRead deliberately does not"

# 2c. THE SINGLE-PRODUCER DISCIPLINE IS IN THE SOURCE.
#
# ADR-0027 section 6's whole claim is that no word in a ring has two writers, so
# that the SMP fix is two fences rather than a redesign. That is a property of
# where `chanSetPort` is called with a head or a tail word, and this is the only
# place it can be checked -- one CPU cannot demonstrate its absence.
python3 - "$CORE_DIR/kernel/chan.dart" <<'PY' || fail "the ring's single-producer/single-consumer discipline is not what ADR-0027 §6 claims"
import re, sys
src = open(sys.argv[1]).read()
fails = []
def body(name):
    m = re.search(r"void %s\(u64 frame\) \{(.*?)\n\}" % name, src, re.S)
    return m.group(1) if m else None
send, recv = body("chanSysSend"), body("chanSysRecv")
if not send or not recv:
    fails.append("chanSysSend or chanSysRecv is missing")
else:
    # The producer advances ONLY the head; the consumer ONLY the tail.
    if "chanSetPort(port, chanHeadWord(d)" not in send:
        fails.append("chanSysSend never advances the head")
    if "chanSetPort(port, chanTailWord(d)" in send:
        fails.append("chanSysSend writes a TAIL -- the consumer's word. The ring is "
                     "no longer single-consumer and ADR-0027 §6's SMP argument is void.")
    if "chanSetPort(port, chanTailWord(d)" not in recv:
        fails.append("chanSysRecv never advances the tail")
    if "chanSetPort(port, chanHeadWord(d)" in recv:
        fails.append("chanSysRecv writes a HEAD -- the producer's word.")
    # PUBLICATION ORDER: the payload is stored before the head is advanced.
    ci = send.find("chanCopyIn(")
    li = send.find("chanLenAddr(port, d, slot)")
    hi = send.find("chanSetPort(port, chanHeadWord(d)")
    if not (0 <= ci < hi and 0 <= li < hi):
        fails.append("chanSysSend advances the head before the slot and its length "
                     "are written -- the consumer could read an unpublished message")
    co = recv.find("chanCopyOut(")
    ti = recv.find("chanSetPort(port, chanTailWord(d)")
    if not (0 <= co < ti):
        fails.append("chanSysRecv advances the tail before copying the slot out -- "
                     "the producer could overwrite a message being read")
    # THE UNDERFLOW GUARD. `head - tail` on a corrupted pair would be a `ud2`.
    for n, b in (("chanSysSend", send), ("chanSysRecv", recv)):
        if "head < tail" not in b:
            fails.append("%s subtracts tail from head without guarding head < tail; "
                         "DCDart traps on underflow, so that is a #UD in a syscall "
                         "handler rather than a refusal" % n)
    # THE OWNER IS NEVER AN ARGUMENT.
    for n, b in (("chanSysSend", send), ("chanSysRecv", recv)):
        if "chanCallerId()" not in b:
            fails.append("%s does not derive the caller from procCurrent()" % n)
        if "chanOwnerWord(side)) != id" not in b:
            fails.append("%s does not compare the endpoint's owner against the caller" % n)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "STRUCTURAL: pass  each ring has ONE writer per index word, the payload is published before the head moves and consumed before the tail does, head<tail is a refusal rather than a DCDart underflow trap, and neither syscall takes the caller's identity as an argument"

# 2d. THE STORAGE SEAM: THREE ACCESSORS, ONE FILE.
SEAM=$(grep -cE "^  return Bss[.]addressOf[(]chanStore[)]" "$CORE_DIR/kernel/chan.dart")
[[ "$SEAM" -eq 3 ]] || fail "chan.dart has $SEAM \`return Bss.addressOf(chanStore)\` call sites, expected exactly 3 (ADR-0011 §0's seam discipline)"
OUTSIDE=$(grep -rlw "chanStore" "$CORE_DIR/kernel/" | grep -v "/chan.dart$" | wc -l | tr -d ' ')
[[ "$OUTSIDE" -eq 0 ]] || fail "$OUTSIDE file(s) outside chan.dart name chanStore"
# AND THE RELEASE HAS EXACTLY ONE CALLER, WHICH IS procCleanup.
REL=$(grep -c "chanReleaseOwner(" "$CORE_DIR/kernel/proc.dart")
[[ "$REL" -eq 1 ]] || fail "proc.dart calls chanReleaseOwner $REL time(s), expected exactly 1"
grep -q "chanReleaseOwner(procGet(s, u64(procSlotId)));" "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart does not release endpoints by PROCESS ID"
python3 - "$CORE_DIR/kernel/proc.dart" <<'PY' || fail "chanReleaseOwner is not called from procCleanup"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void procCleanup\(u64 s\) \{(.*?)\n\}", src, re.S)
if not m or "chanReleaseOwner(" not in m.group(1):
    print("    - procCleanup does not call chanReleaseOwner. That is the ONE function "
          "both the exit path and the fault/kill path go through; anywhere else and a "
          "KILLED process keeps its endpoint forever.", file=sys.stderr)
    sys.exit(1)
PY
OTHER=$(grep -rl "chanReleaseOwner" "$CORE_DIR/kernel/" | grep -v "/chan.dart$" | grep -v "/proc.dart$" | wc -l | tr -d ' ')
[[ "$OTHER" -eq 0 ]] || fail "$OTHER file(s) other than chan.dart and proc.dart call chanReleaseOwner"
echo "STRUCTURAL: pass  chanStore is reached through exactly 3 accessors in one file, named nowhere else in core/kernel/, and released from exactly one place — procCleanup, by process id"

# 2e. THE REFUSAL CODES ARE DISTINCT AND EVERY ONE IS ABOVE THE FLOOR.
python3 - "$CORE_DIR/kernel/chan.dart" <<'PY' || fail "chan.dart's refusal codes are not distinct, or one is below the floor"
import re, sys
src = open(sys.argv[1]).read()
vals = {n: int(v, 16) for n, v in
        re.findall(r"^const int (chanRet\w+) = (0x[0-9A-Fa-f]+);", src, re.M)}
floor = vals.pop("chanRetFloor", None)
if floor is None:
    print("    - no chanRetFloor", file=sys.stderr); sys.exit(1)
if len(vals) < 12:
    print("    - only %d refusal codes, expected at least 12" % len(vals), file=sys.stderr)
    sys.exit(1)
if len(set(vals.values())) != len(vals):
    print("    - duplicate refusal values: %r" % vals, file=sys.stderr); sys.exit(1)
for n, v in vals.items():
    if v < floor:
        print("    - %s (0x%X) is below chanRetFloor (0x%X); a caller's one-comparison "
              "test would read it as a length" % (n, v, floor), file=sys.stderr)
        sys.exit(1)
# The three syscall numbers must not collide with any existing one.
print("    (%d distinct refusal codes, all >= 0x%X)" % (len(vals), floor))
PY
python3 - "$CORE_DIR/kernel" <<'PY' || fail "two syscalls share a number"
import os, re, sys
root = sys.argv[1]
seen = {}
fails = []
for fn in sorted(os.listdir(root)):
    if not fn.endswith(".dart"):
        continue
    src = open(os.path.join(root, fn)).read()
    for m in re.finditer(r"^const int (\w*Sys\w*No) = (\d+);", src, re.M):
        name, val = m.group(1), int(m.group(2))
        if val in seen and seen[val][0] != name:
            fails.append("syscall %d is both %s (%s) and %s (%s)"
                         % (val, seen[val][0], seen[val][1], name, fn))
        seen.setdefault(val, (name, fn))
for need in (11, 12, 13):
    if need not in seen:
        fails.append("syscall %d is not declared anywhere" % need)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d distinct syscall numbers: %s)"
      % (len(seen), ", ".join("%d=%s" % (v, seen[v][0]) for v in sorted(seen))))
PY
CODE_COUNT=$(grep -c "^const int chanRet" "$CORE_DIR/kernel/chan.dart")
CODE_COUNT=$(( CODE_COUNT - 1 ))   # chanRetFloor is the floor, not a code
echo "STRUCTURAL: pass  every chanRet* value is distinct and above the floor, and M20's three syscall numbers collide with nothing"

# 2f. EVERY @rodata TABLE IS THE SIZE ITS CALL SITE PASSES (GAP-0060).
check_table() {
  local sym="$1" want="$2" got
  got=$(symsize "$sym")
  [[ -n "$got" ]] || fail "$sym not found in kmain.o"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
  grep -q "uartWrite(Rodata.addressOf($sym), u64($want));" "$CORE_DIR/kernel/chan.dart" \
    || fail "no call site in chan.dart passes u64($want) for $sym"
}
check_table chanStrOpen 12
check_table chanStrS 3
check_table chanStrEp 4
check_table chanStrId 4
check_table chanStrG 3
check_table chanStrSend 13
check_table chanStrLen 5
check_table chanStrSeq 5
check_table chanStrRecv 13
check_table chanStrRefuse 14
check_table chanStrR 3
check_table chanStrRel 11
check_table chanStrSt 4
check_table chanStrTotal 13
check_table chanStrB 3
check_table chanStrE 3
check_table chanStrX 3
echo "STRUCTURAL: pass  all 17 of M20's @rodata tables are exactly the sizes their call sites pass"

# 2g. shellStrHelp IS UNCHANGED, SO NOT ONE EARLIER GOLDEN MOVES.
#
# GAP-0105: `shellStrHelp` is inside the byte-exact goldens of m3, m4, m5, m6 and
# m14. M20 adds three SYSCALLS and NO shell command -- IPC is something programs
# do, not something a prompt does -- so this number must not move.
HELP_SIZE=$(symsize shellStrHelp)
[[ "$HELP_SIZE" -eq 2224 ]] || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2224 — UNCHANGED from M14. M20 adds three syscalls and no help line; if that changed, five byte-exact goldens move with it."
echo "STRUCTURAL: pass  shellStrHelp is unchanged at 2224 bytes — M20 adds no shell command, so no help-text golden moves"

# 2h. THE EXIT REPORT AND THE INIT ARE SILENT ON A BOOT THAT OPENS NO CHANNEL.
#
# This is what keeps every byte-exact golden from M1 through M19 exactly where
# it was, and it is a property of one `if` in each of two functions.
grep -q "if (chanMeta(u64(chanMetaOpens)) < u64(1)) {" "$CORE_DIR/kernel/chan.dart" \
  || fail "chanExitReport does not return early when no channel was ever opened — every golden from M1 to M19 moves"
python3 - "$CORE_DIR/kernel/chan.dart" <<'PY' || fail "chanInit is not silent"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void chanInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("    - chanInit is missing", file=sys.stderr); sys.exit(1)
if "uart" in m.group(1).lower():
    print("    - chanInit prints. m1-interrupts asserts the ENTIRE 544-byte capture.",
          file=sys.stderr)
    sys.exit(1)
PY
grep -q "chanInit();" "$CORE_DIR/kernel/kmain.dart" || fail "kmain does not call chanInit"
grep -q "chanExitReport();" "$CORE_DIR/kernel/user.dart" || fail "userSysExit does not call chanExitReport"
echo "STRUCTURAL: pass  chanInit prints nothing and chanExitReport prints nothing unless a channel was opened — no golden from M1 to M19 moves"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding (CLAUDE.md rule 1).
# ---------------------------------------------------------------------------
FS_OUT="$(OSCORTEX_ALLOWLIST="${OSCORTEX_ALLOWLIST:-$CORE_DIR/tools/bare-symbol-allowlist.txt}" \
          bash "$CORE_DIR/scripts/verify-freestanding.sh" "$CORE_DIR/build/kmain.o" 2>&1)"
FS_STATUS=$?
echo "$FS_OUT"
[[ $FS_STATUS -eq 0 ]] || fail "verify-freestanding.sh exited $FS_STATUS"
EXTERN_COUNT=$(sed -n 's/.*(\([0-9]*\) declared extern.*/\1/p' <<<"$FS_OUT")
[[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — UNCHANGED, because M20 added no assembly at all"

# ---------------------------------------------------------------------------
# Step 4 — build the program, and check what was built.
# ---------------------------------------------------------------------------
PROGDIR="$WORKDIR/progs"
bash "$SCRIPT_DIR/build-progs.sh" "$PROGDIR" "$CORE_DIR/kernel" || fail "build-progs.sh failed"

# ---------------------------------------------------------------------------
# Step 5 — the disk: ONE program, TWO byte-identical slots.
# ---------------------------------------------------------------------------
DISK_IMG="$WORKDIR/disk.img"
LAYOUT="$WORKDIR/layout.json"
python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/ipc.elf" --json > "$LAYOUT" \
  || fail "make-image.py could not write the volume"
[[ -s "$DISK_IMG" ]] || fail "make-image.py produced no image"
lba_of() { python3 -c "
import json,sys
print('%X' % json.load(open(sys.argv[1]))['slots'][sys.argv[2]]['header_lba'])
" "$LAYOUT" "$1"; }
LBA_A=$(lba_of A)
LBA_B=$(lba_of B)
IMG_BYTES=$(wc -c <"$DISK_IMG" | tr -d ' ')
echo "IMAGE: pass  $IMG_BYTES bytes = $(( IMG_BYTES / 512 )) sectors, TWO BYTE-IDENTICAL program slots (A at 0x$LBA_A, B at 0x$LBA_B)"

# ---------------------------------------------------------------------------
# Step 6 — derive every expectation, on the host, before booting.
# ---------------------------------------------------------------------------
DERIVED="$WORKDIR/derived.txt"
python3 "$SCRIPT_DIR/derive.py" "$CORE_DIR/kernel" "$SCRIPT_DIR/prog.c" > "$DERIVED" \
  || fail "derive.py could not derive the expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
[[ -n "$(d a_hash)" ]] || fail "derive.py produced no hashes"
[[ "$(d a_hash)" != "$(d b_hash)" ]] || fail "the two sides' derived hashes are equal"
echo "DERIVED: side 0 must exit $(d a_hash) — FNV-1a over the four replies ($(d rep_lens) bytes)"
echo "DERIVED: side 1 must exit $(d b_hash) — FNV-1a over the four requests ($(d req_lens) bytes) then $(d burst) x $(d msg_bytes)"
echo "DERIVED: the kernel must report $(d sends) sends, $(d recvs) recvs and $(d total_bytes) bytes per session"

# ---------------------------------------------------------------------------
# Step 7 — the boots.
# ---------------------------------------------------------------------------
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4"
  shift 4
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
      --png "$png" \
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
    echo "--- serial captured so far ---" >&2
    sed -n '/M1 END/,$p' "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot (log above)"
  fi
}

# ---- BOOT 1: TWO SESSIONS ON THE SAME PORT NUMBER, IN ONE BOOT -------------
#
# `frames` brackets the whole thing: the allocator's free count must be identical
# before and after two sessions of two processes each.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "proc coop $LBA_A $LBA_B"),ret,wait:20000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "proc coop $LBA_A $LBA_B"),ret,wait:20000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:1500"

SHOT_PNG="$CORE_DIR/build/screenshot-ipc.png"
drive_session "$WORKDIR/main" "$SESSION_KEYS" "$SHOT_PNG" "two sessions"
SERIAL="$WORKDIR/main/serial.txt"
[[ -s "$SERIAL" ]] || fail "the main boot captured no serial output at all"

have() { grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { grep -qF -- "$1" "$SERIAL" && { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript contains what it must not: $1"; }; }
countof() { grep -cF -- "$1" "$SERIAL" | tr -d ' '; }

# 7a. THE KERNEL HANDED OUT TWO SIDES OF ONE PORT TO TWO DIFFERENT PROCESS IDS.
have "CHAN OPEN P 00 S 0 EP 00 ID 00000001 G 00000001"
have "CHAN OPEN P 00 S 1 EP 01 ID 00000002 G 00000001"
# ...and the SECOND session got a NEW generation and NEW ids on the SAME port.
have "CHAN OPEN P 00 S 0 EP 00 ID 00000003 G 00000002"
have "CHAN OPEN P 00 S 1 EP 01 ID 00000004 G 00000002"
echo "CHECK 1: pass  the kernel assigned side 0 to the first opener and side 1 to the second, by PROCESS ID, twice on the same port number with two different generations"

# 7b. THE PROGRAMS AGREE ABOUT WHICH END THEY ARE. One binary, two roles.
have "IPC OPEN R 0000000000000000"
have "IPC OPEN R 0000000000000001"
[[ "$(countof 'IPC OPEN R 0000000000000000')" -eq 2 ]] || fail "the requester role was taken $(countof 'IPC OPEN R 0000000000000000') times, expected 2 (once per session)"
[[ "$(countof 'IPC OPEN R 0000000000000001')" -eq 2 ]] || fail "the responder role was taken $(countof 'IPC OPEN R 0000000000000001') times, expected 2"
echo "CHECK 2: pass  the SAME BINARY took the requester role twice and the responder role twice, deciding each time from nothing but chanopen's return value"

# 7c. THE MESSAGES CROSSED, WITH THE RIGHT LENGTHS, IN BOTH DIRECTIONS.
#
# Four requests of four different lengths and four replies of four more, read out
# of the KERNEL's own send/recv lines rather than out of what a program said.
for k in 0 1 2 3; do
  RL=$(d "req${k}_len"); PL=$(d "rep${k}_len")
  have "$(printf 'CHAN SEND EP 00 LEN %02X' "$RL")"
  have "$(printf 'CHAN RECV EP 01 LEN %02X' "$RL")"
  have "$(printf 'CHAN SEND EP 01 LEN %02X' "$PL")"
  have "$(printf 'CHAN RECV EP 00 LEN %02X' "$PL")"
done
echo "CHECK 3: pass  all four request lengths ($(d req_lens)) crossed EP 00 -> EP 01 and all four reply lengths ($(d rep_lens)) crossed EP 01 -> EP 00, every one of them named by the kernel"

# 7d. THE CONTENTS. THE EXIT STATUS IS A HASH OF WHAT WAS RECEIVED.
#
# This is the assertion the milestone exists for. Both numbers were computed on
# the host by derive.py before the machine booted, and both are 64 bits wide.
have "PROC EXIT SLOT 00 ID 00000001 CODE $(d a_hash)"
have "PROC EXIT SLOT 01 ID 00000002 CODE $(d b_hash)"
have "PROC EXIT SLOT 00 ID 00000003 CODE $(d a_hash)"
have "PROC EXIT SLOT 01 ID 00000004 CODE $(d b_hash)"
have "IPC A HASH $(d a_hash)"
have "IPC B HASH $(d b_hash)"
# AND NEITHER SIDE REPORTED A SINGLE MISMATCH.
[[ "$(countof 'BAD 0000')" -eq 4 ]] || fail "expected four ' BAD 0000' reports (two programs x two sessions); got $(countof 'BAD 0000'). A non-zero BAD means a program found a byte it did not expect."
havent "CODE DEAD"
echo "CHECK 4: pass  BOTH PROCESSES EXITED WITH A 64-BIT FNV-1a HASH OF THE BYTES THEY RECEIVED — $(d a_hash) for the requester and $(d b_hash) for the responder, each computed on the host from the protocol's formulas before the boot, each reproduced exactly twice, and neither program found a single wrong byte"

# 7e. THE PER-ROUND RUNNING HASHES, so a failure names its round.
for k in 0 1 2 3; do
  have "IPC A ROUND $k TX $(printf '%02X' "$(d "req${k}_len")") RX $(printf '%02X' "$(d "rep${k}_len")") H $(d "a_h$k")"
  have "IPC B ROUND $k RX $(printf '%02X' "$(d "req${k}_len")") H $(d "b_h$k")"
done
echo "CHECK 5: pass  the running hash after every one of the four rounds matches the host's, on both sides — so a wrong byte would name the round it was in"

# 7f. THE RING FILLED, AND THE NINTH SEND WAS REFUSED.
#
# BOTH SIDES OF THE BOUND. Exactly chanRingDepth messages are ACCEPTED and one
# more is REFUSED, so "the ring is bounded" is not satisfied by a kernel that
# refuses the second.
have "IPC CHK SENDFULL GOT FFFFFFFFFFFFFFF6 WANT FFFFFFFFFFFFFFF6"
have "CHAN REFUSE C 0C EP 0000000000000000 R FFFFFFFFFFFFFFF6"
SEQ_LAST=$(printf '%08X' $(( $(d rounds) + $(d burst) - 1 )))
have "CHAN SEND EP 00 LEN 40 SEQ $SEQ_LAST"
havent "CHAN SEND EP 00 LEN 40 SEQ $(printf '%08X' $(( $(d rounds) + $(d burst) )))"
echo "CHECK 6: pass  exactly $(d burst) 64-byte messages were ACCEPTED (the last at SEQ $SEQ_LAST, which is chanRingDepth deep) and the next one was REFUSED with CHAN_FULL — the bound is exercised from both sides"

# 7g. EIGHT MESSAGES DELIVERED BY A PROCESS THAT HAD ALREADY EXITED.
#
# THE ORDERING IS THE CLAIM. In the transcript, `PROC EXIT SLOT 00` and the
# `CHAN REL` that follows it must come BEFORE the eight `CHAN RECV EP 01 LEN 40`
# lines. A kernel that dropped a dead sender's queued messages could not produce
# this order, and neither could one that delivered them early.
python3 - "$SERIAL" "$(d burst)" <<'PY' || fail "the queued messages of a DEAD peer were not delivered after its death"
import re, sys
lines = [l.rstrip("\r\n") for l in open(sys.argv[1], encoding="latin-1")]
burst = int(sys.argv[2])
fails = []
# Each session: find the requester's exit, its release, then the burst receives.
exits = [i for i, l in enumerate(lines) if l.startswith("PROC EXIT SLOT 00 ID ")]
if len(exits) != 2:
    fails.append("expected two `PROC EXIT SLOT 00` lines (one per session), got %d" % len(exits))
for n, e in enumerate(exits):
    rel = [i for i, l in enumerate(lines) if i > e and l.startswith("CHAN REL P 00 S 0 ID ")]
    if not rel:
        fails.append("session %d: the requester exited and never released its endpoint" % n)
        continue
    rel = rel[0]
    # The release must leave the port HALF-CLOSED (state 3), not free: the peer
    # is still holding the other end and is owed eight messages.
    if not lines[rel].endswith(" ST 3"):
        fails.append("session %d: %r — the port went to a state other than 3 "
                     "(halfClosed) while its peer was still alive" % (n, lines[rel]))
    after = [i for i, l in enumerate(lines)
             if i > rel and l.startswith("CHAN RECV EP 01 LEN 40 ")]
    before = [i for i, l in enumerate(lines)
              if e < i < rel and l.startswith("CHAN RECV EP 01 LEN 40 ")]
    if before:
        fails.append("session %d: a 64-byte message was delivered between the exit and "
                     "the release" % n)
    nxt = exits[n + 1] if n + 1 < len(exits) else len(lines)
    got = [i for i in after if i < nxt]
    if len(got) != burst:
        fails.append("session %d: %d of the %d burst messages were delivered AFTER the "
                     "sender's endpoint was released, expected all %d"
                     % (n, len(got), burst, burst))
    # ...and only THEN is the peer reported gone, on both directions.
    gone_r = [i for i in range(nxt if nxt <= len(lines) else len(lines))
              if i > (got[-1] if got else rel)
              and lines[i] == "CHAN REFUSE C 0D EP 0000000000000001 R FFFFFFFFFFFFFFF3"]
    gone_s = [i for i in range(nxt if nxt <= len(lines) else len(lines))
              if i > (got[-1] if got else rel)
              and lines[i] == "CHAN REFUSE C 0C EP 0000000000000001 R FFFFFFFFFFFFFFF3"]
    if not gone_r:
        fails.append("session %d: the survivor never got CHAN_PEERGONE from a receive "
                     "after draining" % n)
    if not gone_s:
        fails.append("session %d: the survivor never got CHAN_PEERGONE from a send" % n)
    # AND CHAN_PEERGONE WAS NEVER RETURNED WHILE MESSAGES WERE STILL QUEUED.
    early = [i for i in range(rel, got[0] if got else rel)
             if "R FFFFFFFFFFFFFFF3" in lines[i]]
    if early:
        fails.append("session %d: CHAN_PEERGONE was returned at line %d, BEFORE the "
                     "dead peer's queued messages had been drained" % (n, early[0]))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (in both sessions: exit -> release to state 3 -> all %d queued messages "
      "delivered -> CHAN_PEERGONE on both a receive and a send)" % burst)
PY
for j in 0 1 2 3 4 5 6 7; do
  have "IPC B BURST $j RX 40 H $(d "b_burst_h$j")"
done
echo "CHECK 7: pass  EIGHT MESSAGES SENT BY A PROCESS THAT THEN EXITED WERE DELIVERED IN FULL to a survivor whose peer no longer existed — after the release, before any CHAN_PEERGONE, every byte matching the host's model, and only then was the peer reported gone on BOTH directions"

# 7h. THE REFUSALS, OBSERVED FROM RING 3 AS RETURN VALUES.
chkline() {
  have "IPC CHK $1 GOT $2 WANT $2"
}
chkline OPENBADPORT FFFFFFFFFFFFFFFE
chkline OPENTWICE   FFFFFFFFFFFFFFFB
chkline SENDBADEP   FFFFFFFFFFFFFFFA
chkline SENDNOTOWNER FFFFFFFFFFFFFFF9
chkline SENDLEN0    FFFFFFFFFFFFFFF7
chkline SENDLEN65   FFFFFFFFFFFFFFF7
chkline SENDKERNPTR FFFFFFFFFFFFFFF8
chkline SENDOVERFLOW FFFFFFFFFFFFFFF8
chkline SENDSTRADDLE FFFFFFFFFFFFFFF8
chkline RECVROPTR   FFFFFFFFFFFFFFF8
chkline RECVLEN0    FFFFFFFFFFFFFFF7
chkline RECVLEN65   FFFFFFFFFFFFFFF7
chkline RECVBADEP   FFFFFFFFFFFFFFFA
chkline RECVNOTOWNER FFFFFFFFFFFFFFF9
chkline RECVEMPTY   FFFFFFFFFFFFFFF5
chkline RECVTOOBIG  FFFFFFFFFFFFFFF2
chkline RECVGONE    FFFFFFFFFFFFFFF3
chkline SENDGONE    FFFFFFFFFFFFFFF3
chkline SENDFULL    FFFFFFFFFFFFFFF6
# THE KERNEL SAID SO TOO, on its own side of the boundary, for the two that
# matter most: the read-only destination and the overflowing pointer.
have "CHAN REFUSE C 0D EP 0000000000000000 R FFFFFFFFFFFFFFF8"
have "CHAN REFUSE C 0C EP 0000000000000000 R FFFFFFFFFFFFFFF8"
# AND THE CHANNEL SURVIVED ALL OF THEM: the conversation continued afterwards,
# which is what the eight burst sends that follow the battery demonstrate.
echo "CHECK 8: pass  NINETEEN refusal outcomes observed FROM RING 3 as return values — including a receive into the program's own READ-ONLY page (W^X held: the kernel refused rather than writing through a mapping ring 3 cannot write) and a send with ptr = 0xFFFFFFFFFFFFFFFF (bounded before the addition, so DCDart's overflow trap never fired inside the syscall handler) — and the channel kept working afterwards"

# 7i. THE KERNEL'S OWN TOTALS, PER SESSION.
EXPECT_TOTAL="CHAN TOTAL O 00000002 S $(printf '%08X' "$(d sends)") R $(printf '%08X' "$(d recvs)") B $(printf '%08X' "$(d total_bytes)")"
grep -qF -- "$EXPECT_TOTAL" "$SERIAL" \
  || { grep -F "CHAN TOTAL" "$SERIAL" >&2; fail "no CHAN TOTAL line matching \"$EXPECT_TOTAL\" — the kernel's own count of opens/sends/recvs/bytes is not the host's model"; }
echo "CHECK 9: pass  the kernel's own accounting for a session is 2 opens, $(d sends) sends, $(d recvs) receives and $(d total_bytes) bytes — every number equal to the host's model, computed from the protocol rather than read off the boot"

# 7j. THE PORT WENT BACK TO FREE, AND NOTHING LEAKED.
#
# `ST 0` is the LAST release of each session: the survivor leaving a half-closed
# port. Two sessions, so two of them -- and the second session could not have
# opened at all if the first had not returned the port to FREE.
[[ "$(countof 'CHAN REL P 00 S 1 ID ')" -eq 2 ]] || fail "expected two side-1 releases, got $(countof 'CHAN REL P 00 S 1 ID ')"
[[ "$(grep -c 'CHAN REL P 00 S 1 .* ST 0$' "$SERIAL" | tr -d ' ')" -eq 2 ]] \
  || fail "the survivor's release did not return the port to state 0 (free) in both sessions"
FREE_BEFORE=$(grep -m1 "PMM MANAGED" "$SERIAL" | sed -n 's/.*FREE \([0-9A-F]*\).*/\1/p')
FREE_AFTER=$(grep "PMM MANAGED" "$SERIAL" | tail -1 | sed -n 's/.*FREE \([0-9A-F]*\).*/\1/p')
[[ -n "$FREE_BEFORE" && -n "$FREE_AFTER" ]] || fail "the transcript has fewer than two \`PMM MANAGED\` lines"
[[ "$FREE_BEFORE" == "$FREE_AFTER" ]] \
  || fail "the frame allocator's free count went $FREE_BEFORE -> $FREE_AFTER across two IPC sessions; M20 leaks"
BASELINE=$(grep -m1 "PMM MANAGED" "$SERIAL" | sed -n 's/.*BASELINE \([0-9A-F]*\).*/\1/p')
[[ "$FREE_AFTER" == "$BASELINE" ]] \
  || fail "the free count after the sessions is $FREE_AFTER and the allocator's own baseline is $BASELINE"
echo "CHECK 10: pass  both sessions ended with the port back in state 0 (free) and the frame allocator's free count identical, to the frame, before and after — $FREE_AFTER, equal to its own baseline. IPC costs the allocator nothing: a channel is @bss."

# 7k. THE SECOND SESSION IS THE PROOF THE PORT WAS ACTUALLY WIPED.
#
# Two different pairs of process ids, a different generation, and byte-for-byte
# the same two hashes. A port that had kept a single stale head or tail index
# would produce a different one.
[[ "$(countof "PROC EXIT SLOT 00 ID 00000003 CODE $(d a_hash)")" -eq 1 ]] \
  || fail "the second session's requester did not exit with the same hash as the first's"
[[ "$(countof "PROC EXIT SLOT 01 ID 00000004 CODE $(d b_hash)")" -eq 1 ]] \
  || fail "the second session's responder did not exit with the same hash as the first's"
echo "CHECK 11: pass  a SECOND session on the SAME port number, generation 2, with process ids 3 and 4, produced byte-for-byte the same two hashes — so the port was genuinely wiped and reset rather than merely looking free"

# 7l. M1's GOLDEN IS INTACT AS A PREFIX.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL" | cmp -s - "$M1_EXPECTED" \
  || fail "the first $M1_BYTES bytes of this boot are not m1-interrupts' golden — M20 moved a byte it does not own"
echo "CHECK 12: pass  the first $M1_BYTES bytes are m1-interrupts' golden, byte for byte"

# ---- BOOT 2: THE NEGATIVE CONTROL — THE SAME BINARY, NOT A PROCESS ---------
#
# `run <lba>` loads the SAME BYTES as an M10-style program: ring 3, its own
# address space, a heap, file descriptors -- and no process slot. An endpoint is
# owned by a PROCESS ID, so all three syscalls must refuse it BY NAME.
NP_KEYS="$(typekeys "run $LBA_A"),ret,wait:8000"
drive_session "$WORKDIR/noproc" "$NP_KEYS" "$WORKDIR/noproc/shot.png" "no-process control"
NP_SERIAL="$WORKDIR/noproc/serial.txt"
nphave() { grep -qF -- "$1" "$NP_SERIAL" || { sed -n '/M1 END/,$p' "$NP_SERIAL" >&2; fail "the control transcript does not contain: $1"; }; }
nphavent() { grep -qF -- "$1" "$NP_SERIAL" && { sed -n '/M1 END/,$p' "$NP_SERIAL" >&2; fail "the control transcript contains what it must not: $1"; }; }

nphave "IPC OPEN R FFFFFFFFFFFFFFFD"
nphave "CHAN REFUSE C 0B EP 0000000000000000 R FFFFFFFFFFFFFFFD"
nphave "CHAN REFUSE C 0C EP 0000000000000000 R FFFFFFFFFFFFFFFD"
nphave "CHAN REFUSE C 0D EP 0000000000000000 R FFFFFFFFFFFFFFFD"
nphave "IPC CHK NPSEND GOT FFFFFFFFFFFFFFFD WANT FFFFFFFFFFFFFFFD"
nphave "IPC CHK NPRECV GOT FFFFFFFFFFFFFFFD WANT FFFFFFFFFFFFFFFD"
nphave "IPC NOPROC BAD 0000"
nphave "USER EXIT CODE 00004E4F50524F43"
# NOTHING WAS OPENED, so the exit report says nothing at all.
nphavent "CHAN TOTAL"
nphavent "CHAN OPEN P"
nphavent "CHAN REL P"
echo "CHECK 13: pass  NEGATIVE CONTROL — the SAME BINARY started with \`run 0x$LBA_A\` is in ring 3 with no process slot, and all three syscalls refuse it with CHAN_NOPROC; no channel was opened, so chanExitReport printed NOTHING (which is what keeps every golden from M1 to M19 where it is)"

# ---- The exit criterion, stated once more against what actually happened. --
SERIAL_BYTES=$(wc -c <"$SERIAL" | tr -d ' ')
echo
echo "M20-ipc: PASS — dcc build -> assemble -> link -> clang + x86_64-elf-ld build ONE freestanding static ELF64 program which make-image.py writes to TWO BYTE-IDENTICAL disk slots (it refuses to build an image where they differ) -> 8 structural checks (chanStore 2624 bytes and the LAST block in .bss with its regions tiling exactly and the ring depth a power of two, chanMsgBytes HARD-CAPPED at 64 in the kernel with both validators bounding the length before touching the pointer and only the WRITE one requiring the W bit, the single-producer discipline and the publication order read out of chanSysSend/chanSysRecv, a 3-call-site storage seam named nowhere else with exactly one release site which is procCleanup, $CODE_COUNT distinct refusal-and-status codes all above one floor (12 of them provoked from ring 3 in this run) and three syscall numbers colliding with nothing, 17 @rodata tables against their call sites, shellStrHelp UNCHANGED at 2224, and chanInit/chanExitReport both silent on a boot that opens no channel) -> verify-freestanding pass ($EXTERN_COUNT declared externs, UNCHANGED — M20 added no assembly) -> TWO real QEMU boots, M1's ${M1_BYTES}-byte golden a byte-exact prefix of both. ${SERIAL_BYTES} bytes of transcript in which TWO RING-3 PROCESSES IN TWO DIFFERENT ADDRESS SPACES EXCHANGED SIXTEEN MESSAGES: the SAME BINARY took the requester role and the responder role because \`chanopen\` told it which it was, four requests of four different lengths ($(d req_lens)) crossed one way and four replies of four more ($(d rep_lens)) came back DERIVED FROM THE BYTES THAT ARRIVED, and each process EXITED WITH A 64-BIT FNV-1a HASH OF EVERY PAYLOAD BYTE IT RECEIVED — $(d a_hash) and $(d b_hash), both computed on the host from the protocol's formulas BEFORE the machine booted, both reproduced exactly by a SECOND session on the same port number with a new generation and two new process ids; the ring filled to exactly $(d burst) messages and refused the ninth; EIGHT MESSAGES SENT BY A PROCESS THAT THEN EXITED WERE DELIVERED IN FULL to a survivor whose peer no longer existed, in that order, with CHAN_PEERGONE arriving only once the last of them was drained; nineteen refusal outcomes observed from ring 3 as return values, among them a receive into the program's own read-only page and a send with a pointer of 0xFFFFFFFFFFFFFFFF; the frame allocator's free count identical to the frame across both sessions because a channel is @bss and costs it nothing; and the SAME BINARY run as an M10-style program with no process slot refused by all three syscalls with CHAN_NOPROC. Screenshot at $SHOT_PNG"
exit 0
