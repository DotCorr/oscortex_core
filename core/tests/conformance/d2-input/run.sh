#!/usr/bin/env bash
# core/tests/conformance/d2-input/run.sh
#
# D2 — Input is a queue, and ring 3 can read it.
# display-protocol.md §6, ADR-0054.
#
# Binary: with a ring-3 program on the CPU, inject N keys at 50 ms; the
# program reads exactly the derived make+break sequence. Then inject
# depth+3 press-only events; the program reads depth events and a dropped
# count of exactly 3.
#
# Negative control: a host model with depth 1 fails the first assertion.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "D2-input: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D2-input: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=20

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d2-input.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== PROGRAMS ==="
ck; bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" || fail "the test programs could not be built"
PROG_R="$WORKDIR/progR.elf"
PROG_E="$WORKDIR/progE.elf"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROG_R" "$PROG_E" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_R=$(lba_of R)
LBA_E=$(lba_of E)
echo "IMAGE: pass  reader at 0x$LBA_R, exit-at-once at 0x$LBA_E"

echo
echo "=== STRUCTURAL ==="
dartconst() {
  awk -F'= *' -v n="$1" '$0 ~ ("^const int " n " =") { gsub(/;.*/,"",$2); print $2; exit }' \
    "$CORE_DIR/kernel/$2"
}
ck; [[ "$(dartconst kbdqDepth kbdq.dart)" == "32" ]] || fail "kbdqDepth is not 32"
ck; [[ "$(dartconst kbdqStoreBytes kbdq.dart)" == "288" ]] || fail "kbdqStoreBytes is not 288"
ck; [[ "$(dartconst kbdqSysNo kbdq.dart)" == "24" ]] || fail "kbdqSysNo is not 24"
ck; grep -q '^\.global kbd_drain_gate$' "$CORE_DIR/boot/isr.S" \
  || fail "isr.S has no kbd_drain_gate — the drain would be inlined into shellMain"
ck; grep -q 'kbd_drain_gate()' "$CORE_DIR/kernel/shell.dart" \
  || fail "shellMain does not call kbd_drain_gate"
ck; grep -q 'kbdqReset()' "$CORE_DIR/kernel/shell.dart" \
  || fail "shellRecover does not reset the queue"
ck; ! grep -q 'shellKey(' "$CORE_DIR/kernel/keyboard.dart" \
  || fail "kbdHandle still calls shellKey — two input paths"
echo "STRUCTURAL: pass  depth 32, 288-byte block, syscall 24, drain gate, recover resets, IRQ does not poke the shell"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$3" -v f="$1" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield 3 x "$1"; }
bssoff()  { bssfield 2 x "$1"; }
KBDQ_SIZE=$(bsssize kbdqStore)
WM_SIZE=$(bsssize wmStore)
EV_SIZE=$(bsssize wmeventStore)
KBDQ_OFF=$(bssoff kbdqStore)
WM_OFF=$(bssoff wmStore)
EV_OFF=$(bssoff wmeventStore)
ck; [[ "$KBDQ_SIZE" -eq 288 ]] || fail "kbdqStore is ${KBDQ_SIZE:-missing} bytes, expected 288"
ck; [[ "$WM_SIZE" -eq 704 ]] || fail "wmStore is ${WM_SIZE:-missing} bytes, expected 704"
ck; [[ "$EV_SIZE" -eq 768 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 768"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss"
ck; [[ $(( 16#$KBDQ_OFF + KBDQ_SIZE )) -eq $(( 16#$EV_OFF )) ]] \
  || fail "kbdqStore is not immediately before wmeventStore"
ck; [[ $(( 16#$WM_OFF + WM_SIZE )) -eq $(( 16#$KBDQ_OFF )) ]] \
  || fail "wmStore is not immediately before kbdqStore"
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
TOTAL_BSS=$(( DART_BSS + 16#$ASM_BSS_HEX ))
ck; [[ "$TOTAL_BSS" -eq 36576 ]] \
  || fail "the kernel's mutable static storage is $TOTAL_BSS bytes, expected 36576 — ADR-0109's 23264, plus ADR-0155's doubling of `pmmMaxFrames` to 65536 (`pmmStore` 4672 -> 8768 and `shmStore` 4480 -> 8576, because `shmPlaneFrames` must equal `pmmMaxFrames`), plus ADR-0189's larger fine map (`vmStore` 128 -> 240), plus the two geometry words ADR-0064's fallback chain needs (`fbStateBlock` 32 -> 48)"
echo "STRUCTURAL: pass  wmeventStore is last ($EV_SIZE bytes), kbdqStore immediately before it; total .bss $TOTAL_BSS"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o && bash scripts/verify-freestanding.sh build/kdata.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
EXTERN_COUNT=$(sed -n 's/.*(\([0-9]*\) declared extern(s).*/\1/p' <<<"$VERIFY_OUT" | head -1)
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
ck; [[ "$EXTERN_COUNT" -eq 47 ]] || fail "kmain.o declares ${EXTERN_COUNT:-no} externs, expected 47 (46 plus kbd_drain_gate)"
echo "FREESTANDING: pass  $EXTERN_COUNT declared externs (kbd_drain_gate)"

capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
echo "$REG_OUT"
ck; [[ $REG_STATUS -eq 0 ]] || fail "verify-syscall-registry.sh failed"

echo
echo "=== NEGATIVE CONTROL (host model, depth 1) ==="
python3 - <<'PY' || fail "the host model with depth 1 stored the whole sequence — the test is vacuous"
# Scan-code set 1 make codes, derived from the XT chart the 8042 emits
# under QEMU (translation on). Not imported from the kernel.
SET1 = {
    "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12,
    "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24,
    "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18,
    "p": 0x19, "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14,
    "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15,
    "z": 0x2C,
    "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06,
    "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A,
}

def pack(make, brk):
    return make | (0x100 if brk else 0)

seq = []
for k in "abcde":
    seq.append(pack(SET1[k], 0))
    seq.append(pack(SET1[k], 1))

def replay(events, depth):
    q, dropped = [], 0
    for e in events:
        if len(q) >= depth:
            dropped += 1
        else:
            q.append(e)
    return q, dropped

q1, d1 = replay(seq, 1)
if len(q1) == len(seq):
    raise SystemExit("depth-1 model kept all %d events" % len(seq))
if len(q1) != 1 or d1 != len(seq) - 1:
    raise SystemExit("depth-1 model is not a queue of depth 1")
print("    host model depth=1 keeps 1 of %d and drops %d — first assertion would fail" % (len(seq), d1))
PY
echo "NEGATIVE: pass  a depth-1 host model cannot satisfy the sequence check"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

# 35 press-only events: a-z then 1-9. Derived, not typed as a golden.
BURST_KEYS=$(python3 -c "
keys = [chr(c) for c in range(ord('a'), ord('z')+1)] + [str(i) for i in range(1, 10)]
assert len(keys) == 35
print(','.join('down:' + k for k in keys))
")

SEQ_KEYS="a,b,c,d,e"
KEYS="$(typekeys "proc run $LBA_R $LBA_E"),ret,wait:1200"
KEYS="$KEYS,$SEQ_KEYS,wait:800"
KEYS="$KEYS,$BURST_KEYS,wait:3000"

echo
echo "=== BOOT ==="
mkdir -p "$WORKDIR/boot"
SER="$WORKDIR/boot/serial.txt"
: >"$SER"
SHOT="$CORE_DIR/build/d2-input.png"
mkdir -p "$CORE_DIR/build"
port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" \
  >"$WORKDIR/boot/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$SER" \
  --wait-for 'M1 END\n' --png "$SHOT" --screen-text "$WORKDIR/boot/screen.txt" \
  --keys "$KEYS"
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/boot/qemu.log" >&2
  echo "--- serial ---" >&2
  cat "$SER" >&2
  fail "qmp-drive.py exited $drive_status"
fi
cp "$SER" "$CORE_DIR/build/d2-input-serial.txt"
echo "BOOT: serial captured, screenshot $SHOT"

echo
echo "=== DERIVED EXPECTATIONS ==="
python3 - "$SER" <<'PY' || fail "the program did not read the derived sequence, or overflow was not exactly 3"
import re, sys

SET1 = {
    "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12,
    "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24,
    "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18,
    "p": 0x19, "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14,
    "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15,
    "z": 0x2C,
    "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06,
    "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A,
}

def pack(make, brk):
    return make | (0x100 if brk else 0)

want_seq = []
for k in "abcde":
    want_seq.append(pack(SET1[k], 0))
    want_seq.append(pack(SET1[k], 1))

burst = [chr(c) for c in range(ord("a"), ord("z") + 1)] + [str(i) for i in range(1, 10)]
want_burst = [pack(SET1[k], 0) for k in burst]
assert len(want_burst) == 35

blob = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
# USER WRITE prefixes every write() line.
def find(prefix):
    for line in blob.splitlines():
        if prefix in line:
            return line
    return None

ready = find("READY")
seq_line = find("SEQ N ")
hold = find("HOLD")
ovf_line = find("OVF N ")
ev0_line = find("EV0 ")
ev1_line = find("EV1 ")
if ready is None:
    raise SystemExit("program never printed READY\n--- serial ---\n" + blob[-2000:])
if seq_line is None:
    raise SystemExit("program never printed SEQ\n--- serial ---\n" + blob[-2000:])
if hold is None:
    raise SystemExit("program never printed HOLD")
if ovf_line is None:
    raise SystemExit("program never printed OVF\n--- serial ---\n" + blob[-2000:])
if ev0_line is None or ev1_line is None:
    raise SystemExit("program never printed EV0/EV1\n--- serial ---\n" + blob[-2000:])

def hex_words(line, after):
    i = line.index(after) + len(after)
    return [int(t, 16) for t in line[i:].split() if re.fullmatch(r"[0-9A-Fa-f]+", t)]

# SEQ N XX <events...>
m = re.search(r"SEQ N ([0-9A-Fa-f]{2})", seq_line)
if not m:
    raise SystemExit("SEQ line is not parseable: %r" % seq_line)
got_n = int(m.group(1), 16)
got_seq = hex_words(seq_line, "SEQ N %s " % m.group(1))
if got_n != 10 or got_seq != want_seq:
    raise SystemExit("sequence: got N=%d %s, want N=10 %s"
                     % (got_n, [hex(x) for x in got_seq], [hex(x) for x in want_seq]))

m = re.search(r"OVF N ([0-9A-Fa-f]{2}) DROP ([0-9A-Fa-f]{2})", ovf_line)
if not m:
    raise SystemExit("OVF line is not parseable: %r" % ovf_line)
got_on = int(m.group(1), 16)
got_drop = int(m.group(2), 16)
if got_on != 32 or got_drop != 3:
    raise SystemExit("overflow: got N=%d DROP=%d, want N=32 DROP=3" % (got_on, got_drop))

got_ev = hex_words(ev0_line, "EV0 ") + hex_words(ev1_line, "EV1 ")
if got_ev != want_burst[:32]:
    raise SystemExit("overflow events: got %s, want first 32 of %s"
                     % ([hex(x) for x in got_ev], [hex(x) for x in want_burst[:32]]))

print("    SEQ: 10 events match the derived make+break of a,b,c,d,e")
print("    OVF: 32 events kept, 3 dropped, first 32 downs match a-z,1-6")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "D2-input: PASS — queue depth 32, syscall 24, IRQ produces, shell consumes, ring 3 reads the derived sequence, overflow drops exactly 3"
exit 0
