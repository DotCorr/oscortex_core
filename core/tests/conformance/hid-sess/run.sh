#!/usr/bin/env bash
# core/tests/conformance/hid-sess/run.sh
#
# ADR-0138 — xHCI HID reaches kbdevent and mouse (session door).
# docs/decisions/0138-xhci-hid-reaches-kbdevent-mouse.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# `proc spawn` leaves a focused client at the idle prompt. COM1
# `usb feed 0004 0000` (no `-device usb-kbd`) pushes HID usage 0x04
# through usbHidApply into kbdq; syscall 24 prints make+break 01E 11E.
# `usb mfeed` pushes a HID boot-mouse report through usbHidMouseApply;
# the pointer moves by the planted signed deltas (HID Y = framebuffer Y).
#
# Structural: this harness and m0/m1/d1/d2/u0/u1/u2 omit usb-kbd.
# qemu-xhci may be present as the class stand-in. No Graphite. No Dell
# SKU. Syscall 11 stays fdwait. Not in help.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "HID-sess: FAIL — $1" >&2; exit 1; }
setup_error() { echo "HID-sess: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=36

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld \
            x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-hid-sess.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$SCRIPT_DIR/hid-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "hid-drive.py not found"
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
  '$CORE_DIR/kernel/wm.dart' '$CORE_DIR/kernel/kbdq.dart' \
  '$CORE_DIR/kernel/usb.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

CLICK_X=$(d click_x); CLICK_Y=$(d click_y)
RELS=$(d rels_to_click)
SEQ=$(d seq)
SEQ_N=$(d seq_n)
MOUSE_HEX=$(d mouse_hex)
MOUSE_DX=$(d mouse_dx)
MOUSE_DY=$(d mouse_dy)
SET1=$(d set1)

ck; [[ -n "$SEQ" ]] || fail "the model emitted no packed sequence"
ck; [[ "$SEQ_N" -eq 2 ]] || fail "the model says SEQ_N $SEQ_N, expected 2"
ck; [[ "$SET1" == "1E" ]] || fail "set-1 for usage 04 is $SET1, expected 1E"
echo "DERIVED: click ($CLICK_X,$CLICK_Y) SEQ=$SEQ mouse=$MOUSE_HEX"

echo
echo "=== PROGRAMS ==="
ck; bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" \
  || fail "the test program could not be built"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/prog.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
LBA=$(python3 -c "import json; print('%X' % json.load(open('$LAYOUT_JSON'))['S']['header_lba'])")
ck; [[ -n "$LBA" ]] || fail "could not read slot LBA"
echo "IMAGE: pass  client at LBA 0x$LBA"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'usbHidMouseApply' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart has no usbHidMouseApply"
ck; grep -q 'usbHidApply' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart has no usbHidApply"
ck; grep -q 'usbStrCmdMfeed' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart has no usb mfeed seam"
ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart declares a Bss"
ck; ! grep -qE 'userSysNo.*= *11|const int .*= 11;' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart took syscall 11"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — hid-sess added a help line"

# This harness and the named 8042 goldens must not attach usb-kbd.
ck; ! grep -qE '^[^#]*-device[= ]usb-kbd' "$SCRIPT_DIR/run.sh" \
  || fail "hid-sess attaches usb-kbd — that steals send-key from the 8042"
for h in m0-boot m1-idt d1-mouse d2-input u0-xhci u1-xhci u2-hid; do
  rs="$CORE_DIR/tests/conformance/$h/run.sh"
  [[ -f "$rs" ]] || continue
  ck; ! grep -qE '^[^#]*-device[= ]usb-kbd' "$rs" \
    || fail "$h attaches usb-kbd — 8042 goldens must not"
done
echo "STRUCTURAL: pass  mouse+kbd translators, no @bss, no help, no usb-kbd on 8042 harnesses"

printf -v WANT 'HID SESS SEQ N %02X %s' "$SEQ_N" "$SEQ"
WANT_NONE="HID SESS NONE"
ck; [[ "$WANT" != "$WANT_NONE" ]] || fail "focused report equals NONE — vacuous"
EXPECT_X=$((CLICK_X + 16#$MOUSE_DX))
EXPECT_Y=$((CLICK_Y + 16#$MOUSE_DY))
printf -v WANT_MOUSE 'USB MOUSE %04X Y %04X B 0' "$EXPECT_X" "$EXPECT_Y"
# A PS/2-axis mistake would subtract DY from the click Y.
WRONG_Y=$((CLICK_Y - 16#$MOUSE_DY))
if [[ "$WRONG_Y" -lt 0 ]]; then WRONG_Y=0; fi
printf -v WRONG_MOUSE 'USB MOUSE %04X Y %04X B 0' "$EXPECT_X" "$WRONG_Y"
ck; [[ "$WANT_MOUSE" != "$WRONG_MOUSE" ]] \
  || fail "HID Y plant equals inverted plant — vacuous"
echo "NEGATIVE: pass  inverted-Y plant would be '$WRONG_MOUSE', not '$WANT_MOUSE'"

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
KEYS="$KEYS,$(typekeys "proc spawn $LBA"),ret"
KEYS="$KEYS,until:HID HOLD"
KEYS="$KEYS,$RELS,wait:400"
KEYS="$KEYS,btn:left:down,wait:400,btn:left:up,wait:400"

FEED_CMD="usb feed 0004 0000"
MFEED_CMD="usb mfeed $MOUSE_HEX"

SER="$WORKDIR/serial.txt"
SHOT="$CORE_DIR/build/hid-sess.png"
mkdir -p "$CORE_DIR/build"
: >"$SER"
qmp_port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
ser_port=$(python3 "$PICKER") || fail "pick-port.py could not find a free serial port"
timeout 240 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -device qemu-xhci,id=xhci \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -chardev "socket,id=com1,host=127.0.0.1,port=$ser_port,server=on,wait=off,logfile=$SER,logappend=off" \
  -serial chardev:com1 \
  -qmp "tcp:127.0.0.1:$qmp_port,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 "$DRIVER" \
  --qmp-port "$qmp_port" --ser-port "$ser_port" --serial "$SER" \
  --wait-for 'M1 END\n' --png "$SHOT" --keys "$KEYS" \
  --feed "$FEED_CMD" --mfeed "$MFEED_CMD"
kill "$qemu_pid" 2>/dev/null || true
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  echo "--- serial ---" >&2
  cat "$SER" >&2
  fail "hid-drive.py exited $drive_status"
fi
cp "$SER" "$CORE_DIR/build/hid-sess-serial.txt"
echo "BOOT: serial captured, screenshot $SHOT"

echo
echo "=== CRITERION ==="
have() { grep -qF -- "$1" "$SER" || { sed -n '/HID /,$p' "$SER" >&2; fail "missing: $1"; }; }
havenot() { ! grep -qF -- "$1" "$SER" || { sed -n '/HID /,$p' "$SER" >&2; fail "unexpected: $1"; }; }

ck; have "HID HOLD"
ck; have "USB FEED"
ck; have "$WANT"
ck; havenot "$WANT_NONE"
# USB FEED must list 001E 011E (set-1), not usage 0004 as a scancode.
ck; python3 - "$SER" <<'PY' || fail "USB FEED did not carry set-1 001E/011E"
import re, sys
ser = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
feeds = [ln for ln in ser.splitlines() if ln.startswith("USB FEED")]
if not feeds:
    raise SystemExit(1)
evs = re.findall(r"([0-9A-F]{4})", feeds[-1][len("USB FEED"):])
if evs != ["001E", "011E"]:
    print("events=%r" % evs, file=sys.stderr)
    raise SystemExit(1)
if "0004" in evs:
    raise SystemExit(1)
PY
ck; have "$WANT_MOUSE"
ck; havenot "$WRONG_MOUSE"
ck; grep -qE '^MOUSE STATE X ' "$SER" \
  || fail "bare mouse did not print after the HID plant"
# The state line must show the same absolute position USB MOUSE announced.
ck; python3 - "$SER" "$EXPECT_X" "$EXPECT_Y" <<'PY' || fail "MOUSE STATE did not match the HID plant"
import re, sys
ser = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
ex, ey = int(sys.argv[2]), int(sys.argv[3])
m = None
for ln in ser.splitlines():
    if ln.startswith("MOUSE STATE X "):
        m = re.match(r"MOUSE STATE X ([0-9A-F]{4}) Y ([0-9A-F]{4}) B ", ln)
if not m:
    raise SystemExit(1)
if int(m.group(1), 16) != ex or int(m.group(2), 16) != ey:
    print("state=(%s,%s) want=(%04X,%04X)" % (m.group(1), m.group(2), ex, ey),
          file=sys.stderr)
    raise SystemExit(1)
PY
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "fault during hid-sess boot"; }
ck; ! grep -qiE '^[^#]*-device[= ]usb-kbd' "$SCRIPT_DIR/run.sh" \
  || fail "run.sh grew a usb-kbd line"
echo "ASSERT: pass  kbdevent saw HID set-1; HID mouse moved pointer; no usb-kbd"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "HID-sess: PASS — usb feed → kbdevent $WANT; usb mfeed → $WANT_MOUSE; 8042 harnesses stay free of usb-kbd"
exit 0
