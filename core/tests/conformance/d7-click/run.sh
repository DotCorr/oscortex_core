#!/usr/bin/env bash
# core/tests/conformance/d7-click/run.sh
#
# D7 — A click reaches the surface under the pointer.
# display-protocol.md §6, ADR-0055.
#
# Binary: two overlapping surfaces (red behind, blue on top). A click in
# the overlap is reported by the TOP client with host-derived
# surface-relative coordinates, and by no other. A click outside both
# surfaces is reported by neither.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "D7-click: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D7-click: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=33

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d7-click.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$SCRIPT_DIR/d7-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "d7-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$SCRIPT_DIR/prog.c' \
  '$CORE_DIR/kernel/wm.dart' '$CORE_DIR/kernel/wmevent.dart' \
  '$CORE_DIR/kernel/mouse.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

CLICK_X=$(d click_x); CLICK_Y=$(d click_y)
TOP_RX=$(d top_rx); TOP_RY=$(d top_ry)
BOT_RX=$(d bot_rx); BOT_RY=$(d bot_ry)
OVERLAP=$(d overlap_area)
SYSNO=$(d syscall)
RELS1=$(d rels_to_click)
RELS2=$(d rels_to_desk)
STORE=$(d store_bytes)

ck; [[ "$OVERLAP" -gt 0 ]] || fail "the model says overlap area $OVERLAP — D7 would be vacuous"
ck; [[ "$TOP_RX" != "$BOT_RX" || "$TOP_RY" != "$BOT_RY" ]] \
  || fail "top and bottom relative coordinates are identical — the wrong-owner check is vacuous"
echo "DERIVED: overlap $OVERLAP px, click ($CLICK_X,$CLICK_Y) -> top-rel ($TOP_RX,$TOP_RY), bottom would be ($BOT_RX,$BOT_RY)"

echo
echo "=== PROGRAMS ==="
ck; bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" \
  || fail "the test program could not be built"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/wm.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['slots'][sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_A=$(lba_of A)
LBA_B=$(lba_of B)
echo "IMAGE: pass  the same program at 0x$LBA_A and 0x$LBA_B"

echo
echo "=== STRUCTURAL ==="
dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

E_SYS=$(dartconst wmeventSysNo wmevent.dart)
E_STORE=$(dartconst wmeventStoreBytes wmevent.dart)
E_SLOTS=$(dartconst wmeventSlots wmevent.dart)
E_DEPTH=$(dartconst wmeventDepth wmevent.dart)
E_SLOTB=$(dartconst wmeventSlotBytes wmevent.dart)
W_MAX=$(dartconst wmMaxWindows wm.dart)
PROG_SYS=$(grep -m1 '^#define SYS_WMEVENT ' "$SCRIPT_DIR/prog.c" | awk '{print $3}')

ck; [[ "$E_SYS" -eq 25 ]] || fail "wmeventSysNo is $E_SYS, expected 25"
ck; [[ "$PROG_SYS" -eq "$E_SYS" ]] || fail "prog.c says SYS_WMEVENT is $PROG_SYS and the kernel says $E_SYS"
ck; [[ "$E_SYS" -eq "$SYSNO" ]] || fail "the model and the kernel disagree about the syscall number"
ck; [[ "$E_SLOTS" -eq 8 ]] || fail "wmeventSlots is $E_SLOTS, expected 8 (event ring, not one per wmMaxWindows=$W_MAX)"
ck; [[ $(( E_SLOTS * E_SLOTB )) -eq "$E_STORE" ]] \
  || fail "wmeventSlots * wmeventSlotBytes = $(( E_SLOTS * E_SLOTB )), store is $E_STORE"
ck; [[ "$E_STORE" -eq 768 ]] || fail "wmeventStoreBytes is $E_STORE, expected 768"
ck; [[ "$E_DEPTH" -eq 8 ]] || fail "wmeventDepth is $E_DEPTH, expected 8"

capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh' 2>&1"
echo "$REG_OUT"
ck; [[ $REG_STATUS -eq 0 ]] || fail "the syscall registry does not accept $E_SYS"

# No help line (GAP-0304).
ck; ! grep -qF "wmevent" <(x86_64-elf-objdump -s -j .rodata "$CORE_DIR/build/kmain.o" | cut -c53-) \
  || fail "the kernel's .rodata contains wmevent — a help line would move goldens"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield "$1" 3; }
bssoff()  { bssfield "$1" 2; }
EV_SIZE=$(bsssize wmeventStore)
KBDQ_SIZE=$(bsssize kbdqStore)
WM_SIZE=$(bsssize wmStore)
EV_OFF=$(bssoff wmeventStore)
KBDQ_OFF=$(bssoff kbdqStore)
WM_OFF=$(bssoff wmStore)
ck; [[ "$EV_SIZE" -eq 768 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 768"
ck; [[ "$KBDQ_SIZE" -eq 288 ]] || fail "kbdqStore is ${KBDQ_SIZE:-missing} bytes, expected 288"
ck; [[ "$WM_SIZE" -eq 1472 ]] || fail "wmStore is ${WM_SIZE:-missing} bytes, expected 1472"
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
ck; [[ "$TOTAL_BSS" -eq 50784 ]] \
  || fail "the kernel's mutable static storage is $TOTAL_BSS bytes, expected 50784 — ADR-0109's 23264, plus four authorised growths that all sit BELOW this milestone: pmmStore +4096 (ADR-0155 doubled pmmMaxFrames to 65536 and pmmBoundMib to 256), shmStore +4096 (the bit-plane must describe exactly pmmMaxFrames, asserted in m21-shmem), vmStore +112 (ADR-0189 took vmFineBytes to 32MiB, vmMapBytes to 256MiB, vmFrameCount to 20) and fbStateBlock +16 (ADR-0064's scanout geometry words). See GAP-0053's ledger. D7 itself must still add nothing."
echo "STRUCTURAL: pass  wmeventStore is last ($EV_SIZE bytes), kbdqStore immediately before it; total .bss $TOTAL_BSS"

# Negative control on the HOST: delivering the click to the bottom surface
# produces a different line than the one this harness will require.
printf -v WANT_TOP 'D7 B PRESS %04X %04X' "$TOP_RX" "$TOP_RY"
printf -v WANT_BOT 'D7 A PRESS %04X %04X' "$BOT_RX" "$BOT_RY"
ck; [[ "$WANT_TOP" != "$WANT_BOT" ]] \
  || fail "the host model of a bottom-owner report equals the top-owner line"
echo "NEGATIVE: pass  a bottom-owner report would be '$WANT_BOT', not '$WANT_TOP'"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:3000"
KEYS="$KEYS,$RELS1,wait:400"
KEYS="$KEYS,$(typekeys "proc coop $LBA_A $LBA_B"),ret"
KEYS="$KEYS,until:D7 HOLD1"
KEYS="$KEYS,btn:left:down,wait:400,btn:left:up"
KEYS="$KEYS,until:D7 B PRESS"
KEYS="$KEYS,$RELS2,wait:400"
KEYS="$KEYS,btn:left:down,wait:400,btn:left:up"
KEYS="$KEYS,until:D7 B2"
KEYS="$KEYS,until:D7 A"

SER="$WORKDIR/serial.txt"
SHOT="$CORE_DIR/build/d7-click.png"
mkdir -p "$CORE_DIR/build"
: >"$SER"
port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 240 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$SER" \
  --wait-for 'M1 END\n' --png "$SHOT" --keys "$KEYS"
kill "$qemu_pid" 2>/dev/null || true
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  echo "--- serial ---" >&2
  cat "$SER" >&2
  fail "d7-drive.py exited $drive_status"
fi
cp "$SER" "$CORE_DIR/build/d7-click-serial.txt"
echo "BOOT: serial captured, screenshot $SHOT"

echo
echo "=== SERIAL ==="
# USER WRITE prefixes every write() line.
have() { grep -qF -- "$1" "$SER" || { sed -n '/D7 /,$p' "$SER" >&2; fail "the transcript does not contain: $1"; }; }
havenot() { ! grep -qF -- "$1" "$SER" || { sed -n '/D7 /,$p' "$SER" >&2; fail "the transcript unexpectedly contains: $1"; }; }

ck; have "D7 HOLD1"
ck; have "$WANT_TOP"
ck; have "D7 B2 NONE"
ck; have "D7 A NONE"
ck; havenot "$WANT_BOT"
ck; havenot "D7 A PRESS"
ck; havenot "D7 B2 PRESS"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "something faulted during the D7 boot"; }
echo "SERIAL: pass  top client reported $WANT_TOP; bottom reported NONE; desktop click reported by neither"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "D7-click: PASS — syscall 25, overlap click reached only the top client at derived ($TOP_RX,$TOP_RY), desktop click reached neither"
exit 0
