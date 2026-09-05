#!/usr/bin/env bash
# core/tests/conformance/d1-mouse/run.sh
#
# Mechanical check of D1's exit criterion: THIS KERNEL HAS A POINTING DEVICE.
# A PS/2 mouse on the 8042's auxiliary port, IRQ12 on the slave 8259, the
# three-byte packet protocol with its four-byte IntelliMouse extension DETECTED
# rather than assumed, a resynchronisation rule with something real to
# resynchronise, an arrow drawn on the 800x600 framebuffer, and the decoded
# position readable from ring 3.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
#   * EXACT DELTAS, NOT "SOMETHING HAPPENED". Twelve pointer events are injected
#     through QMP `input-send-event`, and `derive.py` computes -- on the host,
#     before the machine boots, from the protocol -- the twelve lines the kernel
#     must print, BYTE FOR BYTE, including the raw nine-bit deltas, the
#     accumulated position after each one, and the button bitmap. A driver that
#     moved the pointer by the right amount in the wrong direction, or by the
#     wrong amount in the right direction, produces different text.
#
#   * A PRESS AND A RELEASE ARE TWO SEPARATE CLAIMS. Four button edges on two
#     different buttons, each its own QMP call and therefore its own packet,
#     because a press and a release in one call would be one sync and one packet
#     in which the button was never seen down.
#
#   * THE SIGN EXTENSION IS ASSERTED WITH THE INPUT THAT DISTINGUISHES IT. The
#     nine-bit delta's ninth bit is in BYTE 0; the obvious wrong answer is to
#     sign-extend from byte 1's own high bit. Those two agree on every value
#     QEMU's +/-127 clamp allows a real motion to carry, so the decoder boot
#     feeds `08 C8 C8 00` -- a POSITIVE 200 whose byte 1 is 0xC8 -- straight
#     into the packet state machine, and the harness requires the correct
#     position to be present AND the naive one to be absent.
#
#   * THE RESYNCHRONISATION IS OF THE REAL DEVICE'S REAL BYTES. One byte is fed
#     to leave the decoder mid-packet, and then a genuine QMP motion arrives
#     into that offset. The harness asserts the whole sequence: ONE wrong packet
#     (the protocol's own limit -- there is no more information on the wire),
#     then the discard, then a correct packet.
#
#   * THE PIXELS ARE READ BACK OUT OF GUEST MEMORY, AT AN ADDRESS THE KERNEL
#     REPORTED. m5-pci's rule, with one more variable: where the cursor is is
#     the thing under test, so the kernel prints the address of row 8 of the
#     arrow it drew and the monitor dumps twelve pixels there. Edge, seven fill,
#     edge, three background -- and if the driver had decoded a different
#     position, that address is different and those pixels are background.
#
#   * THE KEYBOARD STILL WORKS. Every command in every boot is typed, after the
#     mouse has been initialised on the SAME CONTROLLER, and the last one is
#     typed after twelve IRQ12s have been serviced. A mouse that kills typing is
#     worse than no mouse, and this harness cannot reach its own PASS line
#     without the keyboard having answered.
#
#   * IRQ12 SURVIVES A `ticks` COMMAND. Until D1 every PIC mask write in this
#     kernel was a WHOLE BYTE, so every one of them re-masked every line it did
#     not name (docs/design/display-protocol.md s4.4). `ticks` runs BEFORE the
#     pointer events here, so all twelve packets are after it -- and QEMU's own
#     `info pic` is read at the end, so the mask state is asserted from the
#     emulator's device model and not only from the fact that packets arrived.
#
#   * RING 3 CAN READ IT. A program loaded off a raw disk with `run <lba>` --
#     the weakest caller in the system, with no channel and no file descriptor --
#     calls syscall $MOUSE_SYSNO and reports the packed value both by writing it and by
#     exiting with it. Both numbers were computed on the host before the boot.
#
#   * SIX CONTROLS THAT MUST FAIL, AND THEY ARE RUN. A driver test that passes
#     when the device is absent is the classic case, so a third boot injects NO
#     pointer events at all and must contain no packet line -- paired with the
#     same grep against the main boot, so the absence is not vacuous, and with
#     an assertion that the device was initialised anyway, so it is not passing
#     because the driver is dead.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * THE CURSOR DOES NOT TRACK. It is drawn by the `mouse` command, not by the
#     interrupt handler, because restoring what was under it needs a save buffer
#     and there is no allocation in an interrupt handler. GAP-0251.
#   * NOTHING HERE IS A COMPOSITOR. There is no focus, no event queue and no
#     enter/leave. GAP-0253, and docs/design/display-protocol.md D2 is the
#     milestone that adds a queue.
#   * THE WHEEL IS ASSERTED ONLY BECAUSE THE DEVICE ANSWERED 0x03. The harness
#     asserts `SIZE 4 ID 003` from the transcript; on a device that answered
#     anything else the packets would be three bytes and this script's derived
#     lines would not match, which is the correct failure rather than a silent
#     one.
#   * NO REAL HARDWARE. QEMU's 8042 and QEMU's IMPS/2 mouse. GAP-0055 already
#     records that this kernel assumes an 8042 exists at all.
#
# Usage:
#   core/tests/conformance/d1-mouse/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "D1-mouse: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D1-mouse: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Derived from a run, not counted by hand: run the harness, read the number
# `require_assertions` prints, and pin it here.
ASSERTIONS_REQUIRED=97

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
[[ -x /bin/bash ]] || setup_error "/bin/bash not found — ADR-0028's controls need the system bash"

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d1.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
ck; [[ -f "$M1_EXPECTED" ]] || setup_error "m1-interrupts/expected.txt not found"

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
symsize() {
  x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$1" '$8==s {print $3; exit}'
}
bssfield() {
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

# ===========================================================================
# Step 2 — STRUCTURAL. Everything establishable without booting is.
# ===========================================================================

# --- 2a. THE STATE BLOCK, AND WHERE IT SITS IN .bss -----------------------
#
# D1's block goes SECOND-TO-LAST, immediately before S0's `ioctlStore`, because
# ADR-0031 §4.3 rule 5 requires the ioctl bounce buffer to stay last. Twelve
# harnesses subtract it; this is where its size and its position are pinned.
MOUSE_BYTES=$(dartconst mouseStoreBytes mouse.dart)
MOUSE_WORDS=$(dartconst mouseStoreWords mouse.dart)
ck; [[ "$MOUSE_BYTES" == "160" ]] || fail "mouseStoreBytes is ${MOUSE_BYTES:-missing}, expected 160 — twenty u64 words"
ck; [[ "$MOUSE_WORDS" == "20" && $(( MOUSE_WORDS * 8 )) -eq "$MOUSE_BYTES" ]] \
  || fail "mouseStoreWords is ${MOUSE_WORDS:-missing} and mouseStoreBytes is $MOUSE_BYTES — they must multiply out, because mouseInit loops over the WORDS and every harness measures the BYTES"
# ...and the zeroing loop's bound is that constant, not a literal. A block that
# grew by a word without the loop growing with it would leave the new word as
# `.bss` litter -- read by an interrupt handler, on the first packet of the boot.
ck; grep -q 'while (i < u64(mouseStoreWords))' "$CORE_DIR/kernel/mouse.dart" \
  || fail "mouseInit's zeroing loop does not bound itself with mouseStoreWords" 
MOUSE_SIZE=$(bsssize mouseStore)
ck; [[ "$MOUSE_SIZE" == "$MOUSE_BYTES" ]] || fail "mouseStore is ${MOUSE_SIZE:-missing} bytes in kmain.o but mouseStoreBytes says $MOUSE_BYTES"
IOCTL_OFF=$(bssoff ioctlStore)
MOUSE_OFF=$(bssoff mouseStore)
ck; [[ -n "$IOCTL_OFF" && -n "$MOUSE_OFF" ]] || fail "mouseStore or ioctlStore has no .bss offset in kmain.o"
ck; [[ $(( 16#$MOUSE_OFF + MOUSE_SIZE )) -eq $(( 16#$IOCTL_OFF )) ]] \
  || fail "mouseStore ends at $(( 16#$MOUSE_OFF + MOUSE_SIZE )) and ioctlStore begins at $(( 16#$IOCTL_OFF )) — D1's block is not immediately before S0's, so ADR-0031 §4.3 rule 5 is broken and twelve harnesses' block arithmetic has silently moved"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
ck; [[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section"
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
ck; [[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section"
TOTAL_BSS=$(( 16#$DART_BSS_HEX + 16#$ASM_BSS_HEX ))
ck; [[ "$TOTAL_BSS" -eq 51936 ]] || fail "the kernel's mutable static storage is $TOTAL_BSS bytes, expected 51936 — ADR-0109's 23264, plus ADR-0155's doubling of `pmmMaxFrames` to 65536 (`pmmStore` 4672 -> 8768 and `shmStore` 4480 -> 8576, because `shmPlaneFrames` must equal `pmmMaxFrames`), plus ADR-0189's larger fine map (`vmStore` 128 -> 240), plus the two geometry words ADR-0064's fallback chain needs (`fbStateBlock` 32 -> 48). If that changed, it changed deliberately and GAP-0053's running total and every harness that subtracts a later block move with it."
echo "STRUCTURAL: pass  mouseStore is $MOUSE_SIZE bytes at .bss+0x$MOUSE_OFF, immediately before ioctlStore at 0x$IOCTL_OFF; total .bss $TOTAL_BSS"

# --- 2b. NO GOLDEN MOVES --------------------------------------------------
#
# D1 adds a shell command and a syscall and MUST NOT add a help line: five
# byte-exact serial goldens and m3-shell's screen golden contain `shellStrHelp`
# verbatim (GAP-0105, GAP-0115), and M18 and M20 each declined to move them for
# the same reason. GAP-0254 records what that costs.
HELP_SIZE=$(symsize shellStrHelp)
ck; [[ "$HELP_SIZE" -eq 2511 ]] || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511. D1 itself adds a command and a syscall and NO help line — the half of this assertion that does not move is the check below, that no help-shaped mouse line exists. The number moved from 2224 to 2511 on the merge, exactly as the note here predicted it would: B1 paid GAP-0142 and listed M18's three commands. Every other harness in this suite already pins 2511; this was the last one holding the pre-merge value."
# THE HALF THAT SURVIVES A MERGE. A byte count is a pin and pins get re-pinned;
# what D1 is actually claiming is that IT added no line, and that stays true
# whatever else the help text grows to.
ck; ! grep -qF "  mouse " <(x86_64-elf-objdump -s -j .rodata "$CORE_DIR/build/kmain.o" | cut -c53-) \
  || fail "the kernel's .rodata contains a help-shaped \"  mouse \" line — D1 added a help entry after all, and six goldens moved with it"
echo "STRUCTURAL: pass  shellStrHelp is $HELP_SIZE bytes and the kernel's .rodata carries no help-shaped mouse line — no help-text golden moves"

# --- 2c. THE BOOT PATH IS SILENT ------------------------------------------
#
# `mouseInit` runs in kmain and `mouseEnable` runs in m2Enter, and
# m1-interrupts asserts the ENTIRE 544-byte serial capture. One line from either
# — INCLUDING ON A FAILURE PATH, which is the half that is easy to forget —
# breaks a green milestone.
python3 - "$CORE_DIR/kernel/mouse.dart" <<'PY' || fail "mouseInit or mouseEnable prints"
import re, sys
src = open(sys.argv[1]).read()
bad = []
for fn in ("void mouseInit()", "void mouseEnable()"):
    m = re.search(re.escape(fn) + r" \{(.*?)\n\}", src, re.S)
    if not m:
        bad.append("%s is missing" % fn); continue
    body = m.group(1)
    for token in ("uart", "vga", "conPutc"):
        if token in body:
            bad.append("%s mentions %r; m1-interrupts asserts the ENTIRE 544-byte capture"
                       % (fn, token))
if bad:
    for b in bad: print("    - " + b, file=sys.stderr)
    sys.exit(1)
PY
ck; grep -q "mouseInit();" "$CORE_DIR/kernel/kmain.dart" || fail "kmain does not call mouseInit"
ck; grep -q "mouseEnable();" "$CORE_DIR/kernel/vga.dart" || fail "m2Enter does not call mouseEnable"
echo "STRUCTURAL: pass  mouseInit and mouseEnable print nothing on any path — no golden from M0 to S0 moves"

# --- 2d. THE WHEEL IS DETECTED, NOT ASSUMED -------------------------------
#
# The claim this milestone must not fudge. Two halves, both structural:
# the packet size defaults to THREE, and the only assignment of FOUR is guarded
# by a comparison against the identity byte 0xF2 answered.
SZ_PLAIN=$(dartconst mousePacketPlain mouse.dart)
SZ_WHEEL=$(dartconst mousePacketWheel mouse.dart)
ID_WHEEL=$(dartconst mouseIdWheel mouse.dart)
ck; [[ "$SZ_PLAIN" == "3" && "$SZ_WHEEL" == "4" && "$ID_WHEEL" == "3" ]] \
  || fail "mousePacketPlain/mousePacketWheel/mouseIdWheel are $SZ_PLAIN/$SZ_WHEEL/$ID_WHEEL, expected 3/4/3"
python3 - "$CORE_DIR/kernel/mouse.dart" <<'PY' || fail "the four-byte packet size is not gated on the device's own answer"
import re, sys
src = open(sys.argv[1]).read()
bad = []
if "mouseSetState(u64(mouseWordSize), u64(mousePacketPlain));" not in src:
    bad.append("mouseInit does not default the packet size to mousePacketPlain")
sets4 = re.findall(r"mouseSetState\(u64\(mouseWordSize\), u64\(mousePacketWheel\)\)", src)
if len(sets4) != 1:
    bad.append("the four-byte packet size is written at %d sites, expected exactly 1 "
               "— every extra one is a place it could be set without asking the device"
               % len(sets4))
# ...and that one site is inside the `id == mouseIdWheel` arm.
m = re.search(r"if \(id == u64\(mouseIdWheel\)\) \{(.*?)\n    \}", src, re.S)
if not m or "mousePacketWheel" not in m.group(1):
    bad.append("the four-byte packet size is not inside the `id == mouseIdWheel` arm")
# ...and the identity is read with 0xF2 AFTER the knock, not before it.
if "u64 mouseKnockForWheel()" not in src:
    bad.append("mouseKnockForWheel is missing")
if not re.search(r"mouseAuxWrite\(u8\(mouseDevGetId\)\)", src):
    bad.append("nothing sends 0xF2 — the device is never asked what it is")
if bad:
    for b in bad: print("    - " + b, file=sys.stderr)
    sys.exit(1)
PY
echo "STRUCTURAL: pass  the packet size defaults to 3, is set to 4 at exactly one site, and that site is inside the arm that compares the device's own 0xF2 answer against 0x03"

# --- 2e. THE PIC MASK IS READ-MODIFY-WRITE --------------------------------
#
# display-protocol.md §4.4's cross-cutting blocker, closed. A whole-byte mask
# write is legitimate in exactly two places -- `picRemap`, which has just
# re-initialised both chips and is stating a whole mask, and `picMaskAll`, whose
# entire meaning is "everything". Anywhere else it silently re-masks lines it
# does not name.
python3 - "$CORE_DIR/kernel" <<'PY' || fail "a whole-byte PIC mask write survives outside picRemap and picMaskAll"
import os, re, sys
bad = []
sites = []
for f in sorted(os.listdir(sys.argv[1])):
    if not f.endswith(".dart"):
        continue
    src = open(os.path.join(sys.argv[1], f)).read()
    for m in re.finditer(r"Port\.outb\(u16\(pic(?:Master|Slave)Data\), u8\(0x[0-9A-F]{2}\)\)", src):
        # Which function is it in?
        head = src.rfind("\nvoid ", 0, m.start())
        name = re.match(r"\nvoid (\w+)", src[head:]).group(1) if head >= 0 else "?"
        sites.append((f, name))
allowed = {"picRemap", "picMaskAll"}
for f, name in sites:
    if name not in allowed:
        bad.append("%s: a literal whole-byte mask write inside %s() — it re-masks "
                   "every line it does not name, which is what killed IRQ12 at the "
                   "next `ticks` command before D1" % (f, name))
# ...and the two bit-wise helpers exist and READ before they WRITE.
mouse = open(os.path.join(sys.argv[1], "mouse.dart")).read()
for fn in ("picUnmaskLine", "picMaskLine"):
    m = re.search(r"void %s\(u64 irq\) \{(.*?)\n\}" % fn, mouse, re.S)
    if not m:
        bad.append("%s is missing" % fn); continue
    body = m.group(1)
    if body.count("Port.inb") != 2 or body.count("Port.outb") != 2:
        bad.append("%s does %d in and %d out, expected 2 and 2 — one read and one "
                   "write per chip, which is what makes it read-modify-write"
                   % (fn, body.count("Port.inb"), body.count("Port.outb")))
for fn in ("picUnmaskKeyboardOnly", "picUnmaskTimerAndKeyboard"):
    src = open(os.path.join(sys.argv[1], "keyboard.dart")).read()
    m = re.search(r"void %s\(\) \{(.*?)\n\}" % fn, src, re.S)
    if not m:
        bad.append("%s is missing" % fn); continue
    if "Port.outb" in m.group(1):
        bad.append("%s still writes a port directly instead of going through "
                   "picMaskLine/picUnmaskLine" % fn)
if bad:
    for b in bad: print("    - " + b, file=sys.stderr)
    sys.exit(1)
print("    (%d whole-byte mask writes, all of them inside picRemap or picMaskAll)" % len(sites))
PY
echo "STRUCTURAL: pass  every PIC mask change outside picRemap/picMaskAll is a read-modify-write of one bit — so an unmasked IRQ12 survives every other line's mask change"

# --- 2f. THE IRQ12 ARM, AND THE EOI TO BOTH CHIPS -------------------------
VEC_MOUSE=$(dartconst vectorMouse interrupts.dart)
[[ -n "$VEC_MOUSE" ]] || VEC_MOUSE=$(dartconst vectorMouse mouse.dart)
ck; [[ "$VEC_MOUSE" == "44" ]] || fail "vectorMouse is ${VEC_MOUSE:-missing}, expected 44 (0x2C = the slave's base 0x28 plus IRQ12's line 4)"
python3 - "$CORE_DIR/kernel" <<'PY' || fail "the IRQ12 arm or its double EOI is wrong"
import os, re, sys
bad = []
ints = open(os.path.join(sys.argv[1], "interrupts.dart")).read()
m = re.search(r"if \(vector == u64\(vectorMouse\)\) \{(.*?)\n  \}", ints, re.S)
if not m:
    bad.append("isrDispatch has no `vector == vectorMouse` arm")
else:
    arm = m.group(1)
    if "mouseHandle();" not in arm:
        bad.append("the IRQ12 arm does not call mouseHandle")
    if "picEoiSlave();" not in arm:
        bad.append("the IRQ12 arm does not call picEoiSlave — an EOI to the master "
                   "alone leaves the slave's in-service bit set and IRQ12 fires "
                   "exactly once per boot")
    if "picEoiMaster();" in arm:
        bad.append("the IRQ12 arm calls picEoiMaster directly; picEoiSlave already "
                   "acknowledges both, in slave-then-master order")
mouse = open(os.path.join(sys.argv[1], "mouse.dart")).read()
m = re.search(r"void picEoiSlave\(\) \{(.*?)\n\}", mouse, re.S)
if not m:
    bad.append("picEoiSlave is missing")
else:
    body = m.group(1)
    if "picSlaveCmd" not in body or "picMasterCmd" not in body:
        bad.append("picEoiSlave does not write BOTH command ports")
    elif body.index("picSlaveCmd") > body.index("picMasterCmd"):
        bad.append("picEoiSlave acknowledges the master before the slave")
# ...and the handler reads the STATUS before the DATA, because bit 5 describes
# the byte that is waiting and reading the data port consumes it.
m = re.search(r"void mouseHandle\(\) \{(.*?)\n\}", mouse, re.S)
if not m:
    bad.append("mouseHandle is missing")
else:
    body = m.group(1)
    if "kbdStatus" not in body or "kbdData" not in body:
        bad.append("mouseHandle does not read both the status and the data port")
    elif body.index("kbdStatus") > body.index("kbdData"):
        bad.append("mouseHandle reads the DATA port before the STATUS port — the "
                   "auxiliary bit describes a byte that is then already gone")
    if "mouseStatusAux" not in body:
        bad.append("mouseHandle never checks the auxiliary bit, so a keyboard byte "
                   "delivered on IRQ12 would be decoded as pointer motion")
if bad:
    for b in bad: print("    - " + b, file=sys.stderr)
    sys.exit(1)
PY
echo "STRUCTURAL: pass  vector 0x2C dispatches to mouseHandle and acknowledges the slave THEN the master; the handler reads the status before the data and checks the auxiliary bit"

# --- 2g. THE @rodata TABLES AGAINST THEIR CALL SITES ----------------------
#
# GAP-0060: a @rodata table has no length word, so every `uartWrite` carries a
# hand-maintained byte count. m5-pci invented this check and every milestone
# since has run it: the count in the source must be the size in the symbol
# table.
python3 - "$CORE_DIR/build/kmain.o" "$CORE_DIR/kernel/mouse.dart" "$CORE_DIR/kernel/shell.dart" <<'PY' \
  || fail "a mouse.dart @rodata length literal disagrees with the symbol table"
import re, subprocess, sys
obj = sys.argv[1]
# Both files, because the two COMMAND-NAME tables are matched by `shellExecute`
# in shell.dart rather than written by mouse.dart -- and a length literal is
# just as wrong in a matcher as in a writer. `shellIsCmd(..., u64(5))` with a
# six-byte table matches a prefix of every longer command.
src_paths = sys.argv[2:]
syms = subprocess.run(["x86_64-elf-readelf", "-sW", obj],
                      capture_output=True, text=True).stdout
size = {}
for line in syms.splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == "OBJECT" and f[7].startswith("mouseStr"):
        size[f[7]] = int(f[2])
src = "".join(open(p).read() for p in src_paths)
bad = []
seen = set()
for m in re.finditer(r"Rodata\.addressOf\((mouseStr\w+)\), u64\((\d+)\)", src):
    name, n = m.group(1), int(m.group(2))
    seen.add(name)
    if name not in size:
        bad.append("%s is written but is not an OBJECT in the symbol table" % name)
    elif size[name] != n:
        bad.append("%s is %d bytes and its call site says %d" % (name, size[name], n))
# Two tables are matched by shellExecute rather than written, so they have no
# uartWrite site; they are checked against their match lengths instead.
for name, n in (("mouseStrCmd", 5), ("mouseStrCmdFeed", 11)):
    seen.add(name)
    if size.get(name) != n:
        bad.append("%s is %s bytes, expected %d" % (name, size.get(name), n))
    if ("Rodata.addressOf(%s), u64(%d)" % (name, n)) not in src:
        bad.append("%s is not matched with a length of %d" % (name, n))
missing = set(size) - seen
if missing:
    bad.append("declared but never used at any call site: %s" % ", ".join(sorted(missing)))
if len(seen) < 25:
    bad.append("only %d mouseStr* tables were checked; mouse.dart declares 29" % len(seen))
if bad:
    for b in bad: print("    - " + b, file=sys.stderr)
    sys.exit(1)
print("    (%d mouseStr* tables, every length literal equal to its symbol size)" % len(seen))
PY
echo "STRUCTURAL: pass  every mouse.dart @rodata length literal is the size in the symbol table (GAP-0060)"

# --- 2h. THE SYSCALL NUMBER REGISTRY --------------------------------------
capture REG_OUT REG_STATUS -- bash "$CORE_DIR/scripts/verify-syscall-registry.sh"
echo "$REG_OUT"
ck; [[ $REG_STATUS -eq 0 ]] || fail "verify-syscall-registry.sh exited $REG_STATUS — D1 took a number without a row, or took one that was already taken"
MOUSE_SYSNO=$(dartconst mouseSysNo mouse.dart)
ck; [[ "$MOUSE_SYSNO" == "20" ]] || fail "mouseSysNo is ${MOUSE_SYSNO:-missing}, expected 20"
ck; grep -q '^| 20 | `mouse` | `mouseSysNo` |' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "docs/syscall-registry.md has no row allocating 20 to mouseSysNo"
echo "STRUCTURAL: pass  syscall $MOUSE_SYSNO is allocated to \`mouse\` by a row in the registry, and the registry, the kernel and oslibc.h agree"

# ===========================================================================
# Step 3 — verify-freestanding (CLAUDE.md rule 1), under /bin/bash.
#
# EXPLICITLY /bin/bash 3.2.57 and not `env bash`, which finds brew's bash 5 and
# proves nothing — ADR-0028 is the entry that exists because this check was
# silently broken under the system bash for a whole milestone.
# ===========================================================================
BASH_VER="$(/bin/bash -c 'echo $BASH_VERSION')"
ck; [[ "$BASH_VER" == 3.2.* ]] || echo "    (note: /bin/bash reports $BASH_VER, not a 3.2.x — ADR-0028's portability claim is being checked against a different shell than it was written for)"
capture FS_OUT FS_STATUS -- env OSCORTEX_ALLOWLIST="${OSCORTEX_ALLOWLIST:-$CORE_DIR/tools/bare-symbol-allowlist.txt}" \
  /bin/bash "$CORE_DIR/scripts/verify-freestanding.sh" \
  "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" \
  "$CORE_DIR/build/portio.o" "$CORE_DIR/build/kernel.elf"
echo "$FS_OUT"
ck; [[ $FS_STATUS -eq 0 ]] || fail "verify-freestanding.sh exited $FS_STATUS under /bin/bash $BASH_VER"
ck; [[ "$(grep -c '^FREESTANDING: pass' <<<"$FS_OUT")" -eq 4 ]] \
  || fail "verify-freestanding reported $(grep -c '^FREESTANDING: pass' <<<"$FS_OUT") passes, expected 4 — one each for kmain.o, kdata.o, portio.o and kernel.elf"
EXTERN_COUNT=$(sed -n 's/.*(\([0-9]*\) declared extern.*/\1/p' <<<"$FS_OUT")
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
# Subtract plat names verify actually honors, not unused leftovers still
# sitting in the manifest. Two unused osgfx @externs were dropped; the
# assembly remainder is 44 (60 honored - D3 3 - plat 12 - msr 1).
HONORED_PLAT=$(echo "$FS_OUT" | python3 -c "
import re, sys
text = sys.stdin.read()
m = re.search(r'declared extern\(s\): (.+)', text)
names = m.group(1).split() if m else []
print(sum(1 for n in names if n.startswith('osgfx_') or n.startswith('osxui_')))
")
EXTERN_COUNT=$(( EXTERN_COUNT - HONORED_PLAT ))
# ADR-0148's TLS door is the one genuinely NEW assembly primitive since these
# numbers were pinned: `setfs` has to land in the FS_BASE MSR, and wrmsr has no
# DCDart spelling. Subtracted by name, and asserted to BE assembly.
ck; grep -qE "^[.]glob(a)?l[[:space:]]+msr_write\b" "$CORE_DIR/boot/isr.S" \
  || fail "msr_write is not defined in isr.S — ADR-0148's FS_BASE door was supposed to be one wrmsr stub in assembly"
MSR_PRESENT=$(grep -cE '^msr_write$' "$EXTERN_MANIFEST" || true)
EXTERN_COUNT=$(( EXTERN_COUNT - MSR_PRESENT ))
ck; [[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — honored plat $HONORED_PLAT/$PLAT_PRESENT and msr_write are subtracted by name; D1 added no assembly."
echo "FREESTANDING: pass  four objects, $EXTERN_COUNT declared externs, UNCHANGED — and NO dc_alloc anywhere, which is what \"no allocation in an interrupt handler\" is mechanically"

# ===========================================================================
# Step 4 — the ring-3 witness, and the disk it lives on.
# ===========================================================================
PROGDIR="$WORKDIR/progs"
capture PROG_OUT PROG_STATUS -- bash "$SCRIPT_DIR/build-prog.sh" "$PROGDIR" "$CORE_DIR/kernel"
echo "$PROG_OUT"
ck; [[ $PROG_STATUS -eq 0 ]] || fail "build-prog.sh exited $PROG_STATUS"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT="$WORKDIR/layout.json"
capture_sh MKIMG_OUT MKIMG_STATUS -- "python3 '$SCRIPT_DIR/make-image.py' '$DISK_IMG' '$PROGDIR/ptr.elf' --json > '$LAYOUT'"
ck; [[ $MKIMG_STATUS -eq 0 ]] || fail "make-image.py could not write the volume: $MKIMG_OUT"
ck; [[ -s "$DISK_IMG" ]] || fail "make-image.py produced no image"
LBA=$(python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['header_lba'])" "$LAYOUT")
echo "IMAGE: pass  $(wc -c <"$DISK_IMG" | tr -d ' ') bytes, one program slot at LBA 0x$LBA"

# ===========================================================================
# Step 5 — derive every expectation, on the host, before booting.
# ===========================================================================
DERIVED_MAIN="$WORKDIR/derived-main.txt"
DERIVED_DEC="$WORKDIR/derived-decode.txt"
capture_sh DM_OUT DM_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$SCRIPT_DIR/events-main.txt' > '$DERIVED_MAIN'"
ck; [[ $DM_STATUS -eq 0 ]] || fail "derive.py could not derive the main script: $DM_OUT"
capture_sh DD_OUT DD_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$SCRIPT_DIR/events-decode.txt' > '$DERIVED_DEC'"
ck; [[ $DD_STATUS -eq 0 ]] || fail "derive.py could not derive the decoder script: $DD_OUT"
dm() { grep -m1 "^$1=" "$DERIVED_MAIN" | cut -d= -f2-; }
dd_() { grep -m1 "^$1=" "$DERIVED_DEC" | cut -d= -f2-; }
ck; [[ "$(dm lines)" -eq 12 ]] || fail "the main script derives $(dm lines) lines, expected 12"
ck; [[ "$(dd_ lines)" -eq 12 ]] || fail "the decoder script derives $(dd_ lines) lines, expected 12"
ck; [[ "$(dd_ naive_x)" != "$(dd_ final_x)" ]] \
  || fail "the decoder script's naive sign-extension X equals its correct X — the sign-extension control cannot tell the two decoders apart and is testing nothing"
echo "DERIVED: the main boot must print $(dm lines) lines and end at X $(dm final_x) Y $(dm final_y), WU $(dm wu) WD $(dm wd)"
echo "DERIVED: ring 3 must read $(dm packed) and exit $(dm exit_code)"
echo "DERIVED: the decoder boot must print $(dd_ lines) lines — $(dd_ syncs) discards, $(dd_ overflows) overflow drops — and end at X $(dd_ final_x); a byte-1 sign extension would end at X $(dd_ naive_x)"

# ===========================================================================
# Step 6 — the boots.
# ===========================================================================
# The `ret` IS PART OF THIS HELPER, not of its call sites. The first run of this
# harness left it out, every command was typed into one line that was never
# submitted -- the transcript read `fbticks` and `run 20cpufbmouse` -- and the
# boot STILL produced twelve perfectly correct packet lines, because the pointer
# path does not go through the shell at all. A helper that types a command
# without submitting it is a helper that silently tests nothing.
typekeys() { python3 -c "
import sys
print(','.join([{' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
                for c in sys.argv[1]] + ['ret']))
" "$1"; }

QEMU_PIDS=""
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" disk="$5"
  shift 5
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  # GAP-0150: the port is BOUND-THEN-RELEASED by pick-port.py rather than
  # derived from $$, and the launch is RETRIED if QEMU still loses the race.
  local attempt=0 port drive_status qemu_status qemu_pid
  local drive_args=()
  [[ -n "$disk" ]] && drive_args=(-drive "file=$disk,format=raw,if=ide,index=0,media=disk")
  while :; do
    attempt=$(( attempt + 1 ))
    port=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
    : >"$ser"
    timeout 400 qemu-system-x86_64 \
      -kernel "$KERNEL_ELF" \
      -m 128M \
      -cpu qemu64 \
      -vga std \
      -serial "file:$ser" \
      -display none \
      -no-reboot \
      ${drive_args[@]+"${drive_args[@]}"} \
      -qmp "tcp:127.0.0.1:$port,server,nowait" \
      >"$outdir/qemu.log" 2>&1 &
    qemu_pid=$!
    QEMU_PIDS="$QEMU_PIDS $qemu_pid"
    run_status drive_status -- python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --png "$png" \
      --screen-text "$outdir/screen.txt" \
      --keys "$keys" \
      "$@"
    await qemu_status "$qemu_pid"
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

# ---- BOOT 1: the real device -------------------------------------------
#
# `fb` first, so there is a framebuffer to draw into. `ticks` SECOND and before
# any pointer event, so every packet in this boot arrives after a command that
# used to re-mask the whole slave PIC. Then the twelve events, then the ring-3
# witness, then `cpu` (typed AFTER twelve IRQ12s), then `fb` again to repaint --
# because the console has scrolled text over the whole screen by now and the
# cursor must be drawn onto a clean frame for the read-back to mean anything --
# and finally `mouse`, which reports and draws.
MAIN_KEYS="$(typekeys 'fb'),wait:900"
MAIN_KEYS="$MAIN_KEYS,$(typekeys 'ticks'),wait:4000"
MAIN_KEYS="$MAIN_KEYS,$(python3 "$SCRIPT_DIR/script-to-keys.py" "$SCRIPT_DIR/events-main.txt")"
MAIN_KEYS="$MAIN_KEYS,$(typekeys "run $LBA"),wait:4000"
MAIN_KEYS="$MAIN_KEYS,$(typekeys 'cpu'),wait:900"
MAIN_KEYS="$MAIN_KEYS,$(typekeys 'fb'),wait:900"
MAIN_KEYS="$MAIN_KEYS,$(typekeys 'mouse'),wait:1200"

SHOT_PNG="$CORE_DIR/build/screenshot-mouse.png"
drive_session "$WORKDIR/main" "$MAIN_KEYS" "$SHOT_PNG" "real device" "$DISK_IMG" \
  --monitor-command 'xp/12wx {addr}' \
  --monitor-command 'info pic' \
  --monitor-capture "$WORKDIR/main/monitor.txt" \
  --addr-from-serial 'MOUSE DRAW X [0-9A-F]{4} Y [0-9A-F]{4} BASE [0-9A-F]{8} PITCH [0-9A-F]{8} ROW8 ([0-9A-F]{16})'
SERIAL="$WORKDIR/main/serial.txt"
ck; [[ -s "$SERIAL" ]] || fail "the main boot captured no serial output at all"

have() { grep -qF -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the $3 transcript does not contain: $1"; }; }
havere() { grep -qE -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the $3 transcript matches nothing against: $1"; }; }
havent() { grep -qF -- "$1" "$2" && { sed -n '/M1 END/,$p' "$2" >&2; fail "the $3 transcript contains what it must not: $1"; }; return 0; }
# `M1 FAULT 06 ...` is in EVERY boot -- it is M1's own deliberate #UD and it is
# inside the 544-byte golden. So "no fault" has to be asked about the
# RECOVERABLE fault report (core/kernel/interrupts.dart's faultReport), which
# begins a line or follows a prompt, and not about the substring.
haventre() { grep -qE -- "$1" "$2" && { sed -n '/M1 END/,$p' "$2" >&2; fail "the $3 transcript contains what it must not: $1"; }; return 0; }
countof() { grep -cF -- "$1" "$2" | tr -d ' '; }

# --- CHECK 1: M1's golden is a byte-exact prefix --------------------------
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
# `head -c N | cmp -s -` and NOT `cmp -n N`, which is what this was written as
# first and what the second run of this harness caught. macOS's cmp takes
# neither `-n` nor `--bytes` the way GNU's does: it IGNORES the limit, compares
# the whole of both files, and reports "EOF on <golden>" for every transcript
# longer than the golden -- so the check failed on a boot whose first 544 bytes
# were byte-for-byte correct. It would have failed the same way for a boot whose
# prefix was WRONG, which is why this was caught rather than merely noticed; a
# limit flag that is silently ignored in the other direction is exactly the
# vacuous-check family ADR-0028 exists for. m20-ipc already used this idiom.
ck; head -c "$M1_BYTES" "$SERIAL" | cmp -s - "$M1_EXPECTED" \
  || fail "the first $M1_BYTES bytes of this boot are not m1-interrupts' golden — D1 printed something during boot, and mouseInit/mouseEnable are supposed to be silent"
echo "CHECK 1: pass  M1's $M1_BYTES-byte golden is a byte-exact prefix of this boot — nothing D1 added prints before the console exists"

# --- CHECK 2: TWELVE PACKETS, BYTE FOR BYTE, IN ORDER ---------------------
#
# The milestone's headline. Every line was computed on the host from the
# protocol before this machine booted, and every field in it is a separate
# claim: the raw bytes are what the device sent, DX/DY are the nine-bit deltas
# read out of them, X/Y are the accumulated position, B is the button bitmap.
python3 - "$SERIAL" "$DERIVED_MAIN" <<'PY' || fail "the twelve derived packet lines are not the twelve the kernel printed, in order"
import re, sys
serial = [l.rstrip("\r\n") for l in open(sys.argv[1], encoding="latin-1")]
# `startswith("line")` also matches the `lines=<n>` total, which is how the
# third run of this harness failed with twelve correct packets and a
# thirteenth expectation of "12".
want = [v for k, v in (l.rstrip("\n").split("=", 1) for l in open(sys.argv[2]))
        if re.match(r"line\d+$", k)]
# The kernel prints packet lines interleaved with the shell's prompt, so a
# transcript line may have `oscortex> ` in front of it. Compare on the tail.
got = []
for l in serial:
    i = l.find("MOUSE ")
    if i >= 0 and not l[i:].startswith("MOUSE STATE") and not l[i:].startswith("MOUSE DRAW") \
       and not l[i:].startswith("MOUSE FEED"):
        got.append(l[i:])
if got != want:
    print("    the kernel's packet lines and the derived ones differ:", file=sys.stderr)
    for i in range(max(len(got), len(want))):
        g = got[i] if i < len(got) else "<missing>"
        w = want[i] if i < len(want) else "<unexpected>"
        print(("    %2d %s\n       got  %s\n       want %s" % (i, "OK" if g == w else "**", g, w))
              if g != w else "    %2d OK %s" % (i, g), file=sys.stderr)
    sys.exit(1)
print("    (%d packet lines, byte for byte, in order)" % len(got))
PY
echo "CHECK 2: pass  ALL $(dm lines) PACKETS DECODED EXACTLY — every raw byte, every nine-bit delta, every accumulated coordinate and every button bitmap is the one derived on the host from the protocol before the boot"

# --- CHECK 3: PRESS AND RELEASE ARE SEPARATE CLAIMS -----------------------
ck; have "$(dm line2)" "$SERIAL" "main"   # left DOWN   -> B 1
ck; have "$(dm line3)" "$SERIAL" "main"   # left UP     -> B 0
ck; have "$(dm line4)" "$SERIAL" "main"   # right DOWN  -> B 2
ck; have "$(dm line5)" "$SERIAL" "main"   # right UP    -> B 0
ck; [[ "$(countof ' B 1' "$SERIAL")" -eq 1 ]] || fail "the left button was reported down in $(countof ' B 1' "$SERIAL") packets, expected exactly 1"
ck; [[ "$(countof ' B 2' "$SERIAL")" -eq 1 ]] || fail "the right button was reported down in $(countof ' B 2' "$SERIAL") packets, expected exactly 1"
echo "CHECK 3: pass  left down, left up, right down and right up are four separate packets with four different button bitmaps — and each button is down in exactly one of them"

# --- CHECK 4: THE WHEEL, DETECTED ----------------------------------------
ck; havere "MOUSE STATE .* SIZE 4 ID 003 " "$SERIAL" "main" 
ck; have "$(dm line6)" "$SERIAL" "main"   # wheel-up down -> Z FF
ck; have "$(dm line8)" "$SERIAL" "main"   # wheel-down down -> Z 01
ck; havere "MOUSE STATE .* WU $(dm wu) WD $(dm wd) " "$SERIAL" "main"
echo "CHECK 4: pass  the device ANSWERED 0x03 to 0xF2, so the driver took four-byte packets — and the two wheel clicks arrived as Z FF and Z 01 and were counted in opposite directions. SCROLL-WHEEL MODE WAS DETECTED, NOT ASSUMED"

# --- CHECK 5: THE FINAL STATE, AND NO SILENT LOSS -------------------------
ck; havere "$(dm state_final 2>/dev/null || true)$(python3 -c "
import re,sys
print('MOUSE STATE X %s Y %s B %s PKT %08X SYNC 00000000 OVF 00000000 IRQ [0-9A-F]{8} STRAY 00000000 SIZE 4 ID [0-9A-F]{3} WU %s WD %s INIT [0-9A-F]{4}' % (
  '$(dm final_x)', '$(dm final_y)', '$(dm final_b)', $(dm packets), '$(dm wu)', '$(dm wd)'))
")" "$SERIAL" "main"
echo "CHECK 5: pass  the accumulated state is exactly the derived one, with ZERO resynchronisations, ZERO overflow drops and ZERO stray bytes across twelve real packets"

# --- CHECK 6: IRQ12 SURVIVED `ticks`, ASSERTED FROM QEMU'S OWN DEVICE MODEL
#
# The mask consolidation's whole point, and it is asserted twice over. The
# behavioural half is that all twelve packets above arrived AFTER a `ticks`
# command, which before D1 would have written 0xFF to the slave. The structural
# half is QEMU's `info pic` -- a SECOND, INDEPENDENT description of the same
# machine, the way m5-pci compares the kernel's PCI walk against QEMU's.
MON="$WORKDIR/main/monitor.txt"
ck; [[ -s "$MON" ]] || fail "no monitor capture from the main boot"
ck; grep -q '^M1 TICKS' "$SERIAL" || fail "the \`ticks\` command never ran, so nothing in this boot re-masked anything and CHECK 6 would pass on a kernel that had never fixed the whole-byte mask write"
python3 - "$MON" <<'PY' || fail "after a \`ticks\` command the PIC masks are not what an unmasked mouse needs"
import re, sys
blob = open(sys.argv[1]).read()
# PARSED BY LABEL, NOT BY ORDER. QEMU 11 prints `pic1:` BEFORE `pic0:` -- the
# slave first -- so taking the first `imr=` as the master reads the slave's mask
# and reports IRQ12 masked when it is not (and, worse, would report it unmasked
# when it was). The order is the emulator's business and this check is not
# entitled to an opinion about it.
imrs = dict((int(n), int(v, 16))
            for n, v in re.findall(r"pic([01]):.*?imr=([0-9a-fA-F]+)", blob))
if 0 not in imrs or 1 not in imrs:
    print("    - `info pic` did not report both pic0 and pic1:\n%s" % blob,
          file=sys.stderr)
    sys.exit(1)
master, slave = imrs[0], imrs[1]
bad = []
if master & 0x02:
    bad.append("master IMR 0x%02X has bit 1 SET — the KEYBOARD is masked" % master)
if master & 0x04:
    bad.append("master IMR 0x%02X has bit 2 SET — the cascade is masked, so nothing "
               "the slave raises can reach the CPU at all" % master)
if slave & 0x10:
    bad.append("slave IMR 0x%02X has bit 4 SET — IRQ12 is masked" % slave)
if bad:
    for b in bad: print("    - " + b, file=sys.stderr)
    print("    This is display-protocol.md §4.4's cross-cutting blocker: a whole-byte\n"
          "    mask write somewhere re-masked a line it did not name.", file=sys.stderr)
    sys.exit(1)
print("    (QEMU's own device model: master IMR 0x%02X, slave IMR 0x%02X — IRQ1, IRQ2 "
      "and IRQ12 all unmasked)" % (master, slave))
PY
echo "CHECK 6: pass  IRQ2 and IRQ12 are STILL unmasked after a \`ticks\` command, according to QEMU's own 8259 model — and all $(dm lines) packets arrived after it"

# --- CHECK 7: THE CURSOR IS ON THE FRAMEBUFFER, AT THE DECODED POSITION ---
#
# Read back out of GUEST PHYSICAL MEMORY, at an address the KERNEL reported,
# and cross-checked against an address this harness derived independently from
# the framebuffer base the kernel ALSO reported. Both halves matter: the second
# is what makes the first evidence rather than a tautology.
FB_BASE=$(sed -n 's/^FB BAR \([0-9A-F]*\) .*/\1/p' "$SERIAL" | head -1)
ck; [[ -n "$FB_BASE" ]] || fail "the kernel never reported a framebuffer BAR"
KERNEL_ROW8=$(sed -n 's/.*ROW8 \([0-9A-F]\{16\}\).*/\1/p' "$SERIAL" | head -1)
ck; [[ -n "$KERNEL_ROW8" ]] || fail "the kernel never reported a ROW8 address"
WANT_ROW8=$(printf '%016X' $(( 16#$FB_BASE + 16#$(dm row8_offset) )))
ck; [[ "$KERNEL_ROW8" == "$WANT_ROW8" ]] \
  || fail "the kernel drew the cursor's row 8 at $KERNEL_ROW8 and the derived position puts it at $WANT_ROW8 — the address the pixels were read from is not the address the decoded position implies"
python3 - "$MON" <<'PY' || fail "the twelve pixels at the cursor's row 8 are not the arrow"
import re, sys
# The capture is `=== <command> ===` headers with each command's output under
# it, so the section is delimited by the NEXT header line and not by the string
# "===" -- which also ends the header itself, and which is how the fifth run of
# this harness parsed zero pixels out of a dump that was right there.
blob = open(sys.argv[1]).read()
body_lines = []
inside = False
for line in blob.splitlines():
    if line.startswith("==="):
        inside = line.startswith("=== xp/")
        continue
    if inside:
        body_lines.append(line)
body = "\n".join(body_lines)
words = []
for line in body.splitlines():
    if ":" not in line:
        continue
    for tok in line.split(":", 1)[1].split():
        if tok.startswith("0x"):
            words.append(int(tok, 16))
# Row 8 of the arrow is `edge, seven fill, edge` and then three pixels the
# cursor does not touch. Three DIFFERENT colours in one twelve-pixel read: the
# outline, the interior, and the console background.
want = [0x000000] + [0xFFFFFF] * 7 + [0x000000] + [0x101018] * 3
if len(words) != 12:
    print("    - parsed %d pixels from the dump, expected 12:\n%s" % (len(words), body),
          file=sys.stderr)
    sys.exit(1)
if words != want:
    print("    - the pixels at the cursor's row 8 are not the arrow:", file=sys.stderr)
    print("      got  " + " ".join("%06X" % w for w in words), file=sys.stderr)
    print("      want " + " ".join("%06X" % w for w in want), file=sys.stderr)
    sys.exit(1)
print("    (12 pixels: 1 outline, 7 interior, 1 outline, 3 background — three "
      "distinct colours, at the address the kernel named)")
PY
echo "CHECK 7: pass  the arrow is IN THE FRAMEBUFFER at the position the driver decoded — twelve pixels read out of guest physical memory at $KERNEL_ROW8, which is the base the kernel reported plus the offset this harness derived from the deltas it injected"

# --- CHECK 8: RING 3 CAN READ THE POINTER --------------------------------
ck; have "USER WRITE PTR RAW $(dm packed)" "$SERIAL" "main"
ck; have "USER WRITE PTR X $(dm final_x) Y $(dm final_y) B $(dm final_b) N $(dm count_field)" "$SERIAL" "main"
ck; have "USER EXIT CODE $(dm exit_code)" "$SERIAL" "main"
ck; have "CODE $(dm exit_code)" "$SERIAL" "main"
ck; [[ "$(countof "REFUSALS 00000000" "$SERIAL")" -ge 1 ]] || fail "the ring-3 witness had a syscall refused"
echo "CHECK 8: pass  A PROGRAM AT CPL 3 READ THE POINTER — syscall $MOUSE_SYSNO returned $(dm packed), the program took it apart on its own side of the boundary into X $(dm final_x) Y $(dm final_y) B $(dm final_b) N $(dm count_field), and exited with $(dm exit_code), a number computed on the host before the boot"

# --- CHECK 9: THE KEYBOARD STILL WORKS -----------------------------------
#
# Seventeen commands were typed on this boot, on the SAME 8042 whose
# configuration byte the mouse driver modified, and the last of them was typed
# after twelve IRQ12s had been serviced. A mouse that kills typing is worse than
# no mouse.
ck; have "CPU VENDOR" "$SERIAL" "main"
ck; have "MOUSE STATE" "$SERIAL" "main"
ck; haventre "^FAULT |> FAULT " "$SERIAL" "main"
TYPED_PROMPTS=$(countof "oscortex>" "$SERIAL")
ck; [[ "$TYPED_PROMPTS" -ge 6 ]] || fail "only $TYPED_PROMPTS prompts in the transcript — six commands were typed and the shell stopped answering part-way through (the first prompt is screen-only, so one per answered command reaches COM1)"
echo "CHECK 9: pass  THE KEYBOARD STILL WORKS AFTER MOUSE INIT — $TYPED_PROMPTS prompts, every command answered, including three typed after twelve IRQ12s, and not one recoverable fault"

ck; [[ -s "$SHOT_PNG" ]] || fail "no screenshot at $SHOT_PNG"
ck; [[ "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" == "89504e470d0a1a0a" ]] \
  || fail "$SHOT_PNG is not a PNG"
echo "SCREENSHOT: pass  $SHOT_PNG"

# ---- BOOT 2: the decoder ------------------------------------------------
DEC_KEYS="$(python3 "$SCRIPT_DIR/script-to-keys.py" "$SCRIPT_DIR/events-decode.txt")"
DEC_KEYS="$DEC_KEYS,$(typekeys 'cpu'),wait:900"
drive_session "$WORKDIR/decode" "$DEC_KEYS" "$WORKDIR/decode/shot.png" "decoder" ""
DSERIAL="$WORKDIR/decode/serial.txt"
ck; [[ -s "$DSERIAL" ]] || fail "the decoder boot captured no serial output at all"

# --- CHECK 10: THE FRAMING RULE, AND THE RESYNCHRONISATION ---------------
python3 - "$DSERIAL" "$DERIVED_DEC" <<'PY' || fail "the decoder boot's lines are not the derived ones, in order"
import re, sys
serial = [l.rstrip("\r\n") for l in open(sys.argv[1], encoding="latin-1")]
# `startswith("line")` also matches the `lines=<n>` total, which is how the
# third run of this harness failed with twelve correct packets and a
# thirteenth expectation of "12".
want = [v for k, v in (l.rstrip("\n").split("=", 1) for l in open(sys.argv[2]))
        if re.match(r"line\d+$", k)]
got = []
for l in serial:
    i = l.find("MOUSE ")
    if i >= 0 and not l[i:].startswith(("MOUSE STATE", "MOUSE DRAW", "MOUSE FEED",
                                        "MOUSE NOFB")):
        got.append(l[i:])
if got != want:
    print("    the decoder's lines and the derived ones differ:", file=sys.stderr)
    for i in range(max(len(got), len(want))):
        g = got[i] if i < len(got) else "<missing>"
        w = want[i] if i < len(want) else "<unexpected>"
        print("    %2d %s\n       got  %s\n       want %s"
              % (i, "OK" if g == w else "**", g, w), file=sys.stderr)
    sys.exit(1)
print("    (%d lines: %d discards, %d overflow drops, %d packets, in order)"
      % (len(got), sum(1 for l in got if "SYNC" in l),
         sum(1 for l in got if "OVF" in l), sum(1 for l in got if "PKT" in l)))
PY
ck; have "$(dd_ line0)" "$DSERIAL" "decoder"
ck; have "$(dd_ line10)" "$DSERIAL" "decoder"
ck; havere "$(dd_ state_e)" "$DSERIAL" "decoder"
ck; havere "$(dd_ state_f)" "$DSERIAL" "decoder"
echo "CHECK 10: pass  A MISALIGNED STREAM RESYNCHRONISES — three bytes that cannot be first bytes are discarded one at a time with the stream staying where it is, and then a REAL device packet arriving into a one-byte offset produces exactly ONE wrong report (the protocol's own limit) before the next byte is discarded and the stream is aligned again"

# --- CHECK 11: THE SIGN EXTENSION ----------------------------------------
#
# The paired control. `08 C8 C8 00` is a POSITIVE 200 whose byte 1 has its own
# high bit set; `18 C8 C8 00` is the same byte 1 with byte 0's ninth bit set and
# is therefore -56. A driver that sign-extended from byte 1 would read both as
# -56 and end this boot at a different X, so the harness requires the correct
# final position to be PRESENT and the naive one to be ABSENT.
ck; have "$(dd_ line4)" "$DSERIAL" "decoder"
ck; have "$(dd_ line5)" "$DSERIAL" "decoder"
ck; havere "MOUSE STATE X $(dd_ final_x) " "$DSERIAL" "decoder"
ck; havent "MOUSE STATE X $(dd_ naive_x) " "$DSERIAL" "decoder"
echo "CHECK 11: pass  the nine-bit delta is sign-extended from BYTE 0 — the same byte 1 (0xC8) decodes as +200 with byte 0's sign bit clear and as -56 with it set, and the boot ends at X $(dd_ final_x) rather than at the X $(dd_ naive_x) a byte-1 sign extension would give"

# --- CHECK 12: OVERFLOW IS DISCARDED, NOT APPLIED ------------------------
ck; have "$(dd_ line7)" "$DSERIAL" "decoder"
ck; have "$(dd_ line8)" "$DSERIAL" "decoder"
ck; havere "$(dd_ state_b)" "$DSERIAL" "decoder"
ck; havere "$(dd_ state_c)" "$DSERIAL" "decoder"
echo "CHECK 12: pass  both overflow flags discard the whole packet and the position is IDENTICAL before and after two of them — a driver that applied an overflowed byte would have moved the pointer by a number the hardware never reported"

# --- CHECK 13: THE CLAMP -------------------------------------------------
#
# `38 40 40 00` is -192 on both axes from X 160, so X must clamp at 0. This is
# not cosmetic: every value in this kernel's language is unsigned and traps on
# underflow, so an unclamped subtraction here is a #UD INSIDE AN INTERRUPT
# HANDLER, which is a triple fault rather than a misplaced pointer.
ck; have "$(dd_ line6)" "$DSERIAL" "decoder"
ck; haventre "^FAULT |> FAULT " "$DSERIAL" "decoder"
echo "CHECK 13: pass  a delta that takes the pointer past the left edge clamps at 0 instead of underflowing — and the boot took no fault at all"

# --- CHECK 14: ONE BYTE IS NOT A PACKET ----------------------------------
ck; havere "$(dd_ state_d)" "$DSERIAL" "decoder"
ck; [[ "$(dd_ state_c)" == "$(dd_ state_d)" ]] \
  || fail "the derived states either side of the single fed byte differ — this control cannot show that one byte produced nothing"
echo "CHECK 14: pass  a single fed byte produced no packet line and left every counter identical — the decoder is not simply printing on every byte"

ck; have "CPU VENDOR" "$DSERIAL" "decoder"
echo "CHECK 15: pass  the keyboard answered on the decoder boot too, after four resynchronisations and two overflow drops"

# ---- BOOT 3: THE NEGATIVE CONTROL BOOT ----------------------------------
#
# NO POINTER EVENTS AT ALL. A driver test that passes when the device never
# moves is the classic vacuous test, and this is the boot that would catch it.
NONE_KEYS="$(typekeys 'mouse'),wait:1200,$(typekeys 'cpu'),wait:900"
drive_session "$WORKDIR/none" "$NONE_KEYS" "$WORKDIR/none/shot.png" "no pointer events" ""
NSERIAL="$WORKDIR/none/serial.txt"
ck; [[ -s "$NSERIAL" ]] || fail "the no-pointer boot captured no serial output at all"
ck; [[ "$(countof 'MOUSE PKT' "$NSERIAL")" -eq 0 ]] \
  || fail "a boot with no pointer events printed $(countof 'MOUSE PKT' "$NSERIAL") packet lines — the driver is reporting movement nothing produced"
ck; [[ "$(countof 'MOUSE SYNC' "$NSERIAL")" -eq 0 ]] || fail "a boot with no pointer events resynchronised"
ck; havere "MOUSE STATE X 0000 Y 0000 B 0 PKT 00000000 SYNC 00000000 OVF 00000000 " "$NSERIAL" "no-pointer"
# ...AND THE DEVICE WAS INITIALISED ANYWAY, so the silence above is the absence
# of MOTION and not the absence of a DRIVER. Without this line the check above
# would pass just as well on a kernel whose mouse never came up at all.
ck; havere "MOUSE STATE .* SIZE 4 ID 003 WU 0000 WD 0000 INIT 07FF" "$NSERIAL" "no-pointer"
ck; have "MOUSE NOFB" "$NSERIAL" "no-pointer"
ck; have "CPU VENDOR" "$NSERIAL" "no-pointer"
echo "CHECK 16: pass  A BOOT WITH NO POINTER EVENTS PRINTS NO PACKET LINE — and reports SIZE 4 ID 003 INIT 07FF anyway, so the silence is the absence of MOTION and not the absence of a working driver"

# ===========================================================================
# Step 7 — THE CONTROLS THAT MUST FAIL, RUN, AND SHOWN FAILING.
#
# Every check above concludes something from text being PRESENT or ABSENT. A
# check nobody has watched fail proves nothing, so each of these runs a check
# that MUST report a failure and requires it to.
# ===========================================================================
CONTROLS=0
must_fail() {   # must_fail <what> -- <command...>
  local what="$1"; shift; [[ "$1" == "--" ]] && shift
  if ( "$@" ) >/dev/null 2>&1; then
    fail "NEGATIVE CONTROL FAILED TO FAIL: $what. The check it exercises would pass on a kernel that did not do the thing it claims to check."
  fi
  CONTROLS=$(( CONTROLS + 1 ))
  echo "CONTROL $CONTROLS: pass  $what — observed FAILING, as it must"
}

# C1. The packet grep that finds nothing in the no-pointer boot finds twelve in
#     the main one. Without this pair, CHECK 16 is satisfied by a grep for a
#     string no kernel ever prints.
ck; [[ "$(countof 'MOUSE PKT' "$SERIAL")" -eq 12 ]] \
  || fail "the same grep that found zero packet lines in the no-pointer boot found $(countof 'MOUSE PKT' "$SERIAL") in the main boot, expected 12 — CHECK 16 is vacuous"
must_fail "the no-pointer boot asserted to CONTAIN a packet line" \
  -- grep -qF "MOUSE PKT" "$NSERIAL"

# C2. The derived first packet, off by ONE PIXEL in X, must not be in the
#     transcript. This is what makes CHECK 2 an assertion about a value rather
#     than about a shape.
OFF_BY_ONE=$(python3 -c "
import re, sys
l = sys.argv[1]
m = re.search(r' X ([0-9A-F]{4}) ', l)
print(l[:m.start(1)] + '%04X' % (int(m.group(1), 16) + 1) + l[m.end(1):])
" "$(dm line0)")
ck; [[ "$OFF_BY_ONE" != "$(dm line0)" ]] || fail "the off-by-one control line is identical to the real one"
must_fail "the main boot asserted to contain the first packet with X one greater" \
  -- grep -qF "$OFF_BY_ONE" "$SERIAL"

# C3. The naive sign extension. CHECK 11 asserts this value is absent; if the
#     value were one no transcript could ever contain, that check would be free.
#     So the paired positive is asserted first.
ck; grep -qE "MOUSE STATE X $(dd_ final_x) " "$DSERIAL" \
  || fail "the decoder boot does not end at the correct X, so the absence of the naive one proves nothing"
must_fail "the decoder boot asserted to end at the X a byte-1 sign extension would give" \
  -- grep -qE "MOUSE STATE X $(dd_ naive_x) " "$DSERIAL"

# C4. THE HARNESS'S OWN ASSERTION MACHINERY, BOTH WAYS ROUND. `have` is what
#     most of the checks above are made of, so it is run twice in a subshell
#     with `fail` overridden to return rather than exit: once on a line that IS
#     in the transcript, which must succeed, and once on a line that is not,
#     which must not. Run IN PROCESS rather than through `bash -c`, so that a
#     quoting mistake in this control cannot masquerade as the failure it is
#     supposed to observe.
ck; ( fail() { return 1; }; have "$(dm line0)" "$SERIAL" main ) >/dev/null 2>&1 \
  || fail "have() reported a line that IS in the transcript as missing — the control below would then 'fail' for a reason that has nothing to do with the line it names"
if ( fail() { return 1; }; have "MOUSE PKT 9 ZZ NOT A LINE" "$SERIAL" main ) >/dev/null 2>&1; then
  fail "NEGATIVE CONTROL FAILED TO FAIL: have() accepted a line that is not in the transcript. Every check in this harness built on it is vacuous."
fi
CONTROLS=$(( CONTROLS + 1 ))
echo "CONTROL $CONTROLS: pass  the harness's own have() helper accepts a line that is there and REFUSES one that is not — observed both ways"

# C5. THE STRUCTURAL CHECKS ARE NOT FREE EITHER. The @rodata length checker
#     compares a source literal against a symbol size; this asks it about a
#     table at its real length (must succeed) and then at a wrong one (must
#     not), so "CHECK 2g would notice" is observed rather than assumed.
rodata_len_is() {   # rodata_len_is <symbol> <bytes>
  local got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
        | awk -v s="$1" '$4=="OBJECT" && $8==s {print $3; exit}')
  [[ -n "$got" && "$got" -eq "$2" ]]
}
ck; rodata_len_is mouseStrPkt 10 \
  || fail "mouseStrPkt is not 10 bytes, so the control below would fail for the wrong reason"
must_fail "a mouse @rodata table asserted at a length it does not have" \
  -- rodata_len_is mouseStrPkt 11

# C6. And the disk. The ring-3 witness only proves anything because it RAN; a
#     boot that never loaded it would print no PTR line at all, and CHECK 8
#     would fail rather than pass quietly. The no-pointer boot had no disk
#     attached, so it IS that boot already -- assert the absence, having just
#     asserted the presence in the boot that did have one.
ck; grep -qF "PTR RAW" "$SERIAL" \
  || fail "the main boot has no PTR RAW line, so the absence of one in the no-disk boot proves nothing"
must_fail "the no-disk boot asserted to contain the ring-3 witness's report" \
  -- grep -qF "PTR RAW" "$NSERIAL"

ck; [[ "$CONTROLS" -eq 6 ]] || fail "only $CONTROLS of the 6 negative controls ran"

# ===========================================================================
# Step 8 — the capture, so there is something to look at.
#
# WORKDIR is deleted on exit, so anything worth keeping is copied out HERE
# rather than left in a temp directory the trap removes. Three kinds of
# evidence, and they are deliberately different kinds: the PNG a human looks
# at, the serial transcripts a diff reads, and the monitor capture, which is
# QEMU's own account of the same machine.
# ===========================================================================
CAPTURES="${OSCORTEX_CAPTURES:-$HOME/Desktop/OSCortex/captures}/d1-mouse"
if mkdir -p "$CAPTURES" 2>/dev/null; then
  cp "$SHOT_PNG" "$CAPTURES/cursor-800x600.png"
  cp "$SERIAL" "$CAPTURES/main-serial.txt"
  cp "$DSERIAL" "$CAPTURES/decoder-serial.txt"
  cp "$NSERIAL" "$CAPTURES/no-pointer-serial.txt"
  cp "$MON" "$CAPTURES/main-monitor.txt"
  cp "$DERIVED_MAIN" "$CAPTURES/derived-main.txt"
  cp "$DERIVED_DEC" "$CAPTURES/derived-decode.txt"
  ck; [[ -s "$CAPTURES/cursor-800x600.png" ]] || fail "the capture directory has no screenshot in it"
  echo "CAPTURES: pass  $CAPTURES (screenshot, three transcripts, QEMU's monitor capture, and both derivations)"
else
  echo "CAPTURES: skipped — could not create $CAPTURES (set OSCORTEX_CAPTURES to somewhere writable)"
fi

# ===========================================================================
require_assertions "$ASSERTIONS_REQUIRED"
echo "D1-mouse: PASS — dcc build -> assemble -> link -> 8 structural checks (mouseStore 160 bytes and SECOND-TO-LAST in .bss so ADR-0031 §4.3 rule 5 still holds and twelve harnesses' block arithmetic is accounted for, shellStrHelp 2511, pinned identically by every other harness, mouseInit and mouseEnable silent on EVERY path including failure paths, the four-byte packet size written at exactly one site and only inside the arm that compares the device's own 0xF2 answer against 0x03, every PIC mask change outside picRemap/picMaskAll a read-modify-write of ONE BIT, vector 0x2C acknowledging the slave THEN the master with the handler reading status before data, 29 @rodata length literals against the symbol table, syscall $MOUSE_SYSNO allocated by a registry row) -> verify-freestanding pass on kmain.o, kdata.o, portio.o AND kernel.elf under /bin/bash $BASH_VER with $EXTERN_COUNT declared externs UNCHANGED -> clang + x86_64-elf-ld build a freestanding ring-3 witness that issues exactly syscalls 0, 1 and $MOUSE_SYSNO -> THREE REAL QEMU BOOTS. $(dm lines) POINTER EVENTS INJECTED THROUGH QMP AND DECODED EXACTLY: every raw byte, every nine-bit delta, every accumulated coordinate and every button bitmap matching a line derived on the host from the protocol before the machine booted; a left press, a left release, a right press and a right release as four separate packets; a scroll wheel whose four-byte mode was DETECTED from the device's own 0x03 and whose two clicks arrived as Z FF and Z 01; ZERO resynchronisations across twelve real packets; IRQ2 and IRQ12 still unmasked after a \`ticks\` command according to QEMU's own 8259 model; an arrow drawn on the 800x600 framebuffer and read back as twelve pixels of guest physical memory at the address the kernel named, which is the base the kernel reported plus the offset this harness derived from the deltas it injected; and A PROGRAM AT CPL 3 reading the pointer through syscall $MOUSE_SYSNO and exiting with $(dm exit_code). A SECOND BOOT drives the decoder: three bytes that cannot be first bytes discarded one at a time, a REAL device packet arriving into a one-byte offset producing exactly ONE wrong report before the stream realigns, the nine-bit sign extension shown to come from BYTE 0 by the one input that distinguishes it from byte 1's own high bit, both overflow flags discarding whole packets, and a past-the-edge delta clamping instead of underflowing inside an interrupt handler. A THIRD BOOT injects NO POINTER EVENTS and prints NO PACKET LINE while still reporting SIZE 4 ID 003 INIT 07FF. And $CONTROLS NEGATIVE CONTROLS RUN AND OBSERVED FAILING. Screenshot at $SHOT_PNG"
exit 0
