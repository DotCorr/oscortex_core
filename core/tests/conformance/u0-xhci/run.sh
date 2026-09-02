#!/usr/bin/env bash
# core/tests/conformance/u0-xhci/run.sh
#
# USB0 — the kernel finds qemu-xhci on PCI.
# docs/design/usb-hid.md USB0.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# The kernel walks bus 0 for class 0C/03/30 (xHCI) and prints
# `USB XHCI <bdf> <vend>:<dev> 0C/03/30`. The harness takes the
# function from QEMU's own `info pci` — not from the kernel, not from
# a golden — and requires the printed BDF and vendor:device to match.
#
# Anti-vacuity: QEMU's info pci on the positive boot must contain
# 1b36:000d. A canned line against a machine with no controller would
# otherwise pass.
#
# Negative control: the same kernel on plain `-M pc` (no `-device`)
# prints `USB NONE` and no `USB XHCI` line. info pci must lack
# 1b36:000d.
#
# Coexistence: `usb` is typed on the PS/2 keyboard while xHCI is
# present. `-device usb-kbd` is NOT on this boot: QEMU 11 then
# delivers send-key / input-send-event only to the USB HID device,
# which this kernel does not read, so the command never arrives.
# usb-kbd is USB2's machine. USB0 does not program the device and
# does not touch pci.dart's class-name table or help text (m5-pci).
#
# USB1 (cap/op MMIO) and USB2 (HID→set-1 feed) share usb.dart. This
# harness still only asserts the USB0 find-and-print. USB2 injects
# through `usb feed` on COM1, not through `-device usb-kbd` — QEMU
# then steals send-key from the 8042. This is not a USB stack.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "U0-xhci: FAIL — $1" >&2; exit 1; }
setup_error() { echo "U0-xhci: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=24

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-u0.XXXXXX")" || setup_error "mktemp failed"
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
echo "=== STRUCTURAL ==="

ck; [[ -f "$CORE_DIR/kernel/usb.dart" ]] || fail "core/kernel/usb.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart is not a part of kmain.dart"
ck; grep -q "^part 'usb.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'usb.dart'"

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'usb.dart';" ]] \
  || fail "part 'usb.dart' is last in kmain.dart — D7 owns that position"

ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart declares a Bss — USB0 retains nothing"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — USB0 added a help line"
ck; ! grep -q 'usb' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "USB0 added a syscall — the criterion forbids one"

ck; ! grep -qE 'pciWrite32\(|port_outl\(' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart writes configuration space — USB0/USB1 are reads"
ck; ! grep -vE '^[[:space:]]*//' "$CORE_DIR/kernel/usb.dart" \
      | grep -qE 'SET_PROTOCOL|SET_ADDRESS|GET_DESCRIPTOR' \
  || fail "usb.dart talks control transfers — that is the xHCI bring-up, not USB0"

ck; grep -q 'usbInit();' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain does not call usbInit"
ck; python3 - "$CORE_DIR/kernel/usb.dart" <<'PY' || fail "usbInit prints"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void usbInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("usbInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc"):
    if token in body:
        print("usbInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

BSS_USB=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /usb/ {print $6}')
ck; [[ -z "$BSS_USB" ]] \
  || fail "kmain.o .bss contains $BSS_USB — USB0 was not supposed to donate storage"

# m5-pci pins the class-name table. USB0 must not add a record.
ck; grep -q 'const int pciNameCount = 20;' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciNameCount moved — USB0 was not supposed to touch pci.dart's table"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  usb.dart is a silent no-@bss part, not last; no help, no syscall, no device programming"

KEYS="u,s,b,ret"

drive_session() {
  local outdir="$1" label="$2"
  shift 2
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 120 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    "$@" \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for 'M1 END\n' \
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt" \
    --monitor-command 'info pci' --monitor-capture "$outdir/info-pci.txt" \
    --keys "$KEYS"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status unexpectedly on the $label boot"
  fi
}

echo
echo "=== BOOT qemu-xhci ==="
drive_session "$WORKDIR/xhci" "qemu-xhci" \
  -device qemu-xhci,id=xhci
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-xhci"

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/xhci/serial.txt" "$WORKDIR/xhci/info-pci.txt" <<'PY' || fail "positive boot did not satisfy USB0"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []

if not re.search(r"1b36:000d", info, re.I):
    fails.append("QEMU info pci has no 1b36:000d — this is not a qemu-xhci boot")

# QEMU prints "Bus  0, device   4, function 0:" then "USB controller: PCI device 1b36:000d"
bdf = None
cur_bus = cur_dev = cur_fn = None
for ln in info.splitlines():
    bm = re.search(r"Bus\s+(\d+),\s+device\s+(\d+),\s+function\s+(\d+)", ln, re.I)
    if bm:
        cur_bus, cur_dev, cur_fn = int(bm.group(1)), int(bm.group(2)), int(bm.group(3))
        continue
    if cur_bus is None:
        continue
    if re.search(r"PCI device 1b36:000d", ln, re.I):
        bdf = (cur_bus, cur_dev, cur_fn)
        break

if bdf is None:
    fails.append("could not parse BDF for 1b36:000d out of info pci")

line_re = re.compile(
    r"^USB XHCI ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) "
    r"([0-9A-F]{2})/([0-9A-F]{2})/([0-9A-F]{2})$")

found = [ln for ln in serial.splitlines() if ln.startswith("USB XHCI ")]
nones = [ln for ln in serial.splitlines() if ln == "USB NONE"]

if nones:
    fails.append("positive boot printed USB NONE — the device was attached")
if len(found) != 1:
    fails.append("expected one USB XHCI line, found %d: %r" % (len(found), found))
else:
    m = line_re.match(found[0])
    if not m:
        fails.append("unparseable USB XHCI line: %r" % found[0])
    else:
        bus, dev, fn = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)
        ven, did = m.group(4), m.group(5)
        cls, sub, pif = m.group(6), m.group(7), m.group(8)
        if ven != "1B36" or did != "000D":
            fails.append("device line is %s:%s, expected 1B36:000D" % (ven, did))
        if (cls, sub, pif) != ("0C", "03", "30"):
            fails.append("class triple is %s/%s/%s, expected 0C/03/30" % (cls, sub, pif))
        if bdf is not None and (bus, dev, fn) != bdf:
            fails.append("printed BDF %02X:%02X.%X != QEMU %02X:%02X.%X"
                         % (bus, dev, fn, bdf[0], bdf[1], bdf[2]))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    USB XHCI matches QEMU 1b36:000d at %02x:%02x.%x" % bdf)
PY
echo "ASSERT: pass  printed BDF and 1B36:000D equal QEMU info pci; class 0C/03/30"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1b36:000d", info, re.I):
    fails.append("negative boot's info pci still has 1b36:000d — this is not plain -M pc")
if "USB NONE" not in serial.splitlines():
    fails.append("negative boot did not print USB NONE")
xhci = [ln for ln in serial.splitlines() if ln.startswith("USB XHCI ")]
if xhci:
    fails.append("negative boot printed a USB XHCI line: %r" % xhci)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints USB NONE and no USB XHCI line"

require_assertions "$ASSERTIONS_REQUIRED"
echo "U0-xhci: PASS — qemu-xhci prints USB XHCI matching info pci 1b36:000d; plain -M pc prints USB NONE; no new .bss, not in help"
exit 0
