#!/usr/bin/env bash
# core/tests/conformance/u1-xhci/run.sh
#
# USB1 — the kernel reads qemu-xhci capability and operational registers.
# docs/design/usb-hid.md USB1, ADR-0068.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# After the USB0 device line, the kernel maps BAR0 (64-bit pair, upper
# dword refused if non-zero) and prints CAPLENGTH, HCIVERSION, max
# slots / interrupters / ports, DBOFF, RTSOFF, USBCMD, USBSTS. The
# harness takes the BAR from QEMU's own `info pci` and the port count
# from the `p2`/`p3` it typed on the QEMU line — not from the kernel,
# not from a golden of QEMU's defaults.
#
# Anti-vacuity: CAPLENGTH of 0 or DBOFF of 0 is a fail. Printed PORTS
# must equal p2+p3 for a non-default attach (2+3=5). A canned
# `PORTS 08` (qemu-xhci's default 4+4) cannot pass.
#
# Negative control: the same kernel on plain `-M pc` (no `-device`)
# prints `USB NONE` and no capability / operational line. info pci
# must lack 1b36:000d.
#
# Coexistence: `usb` is typed on the PS/2 keyboard while xHCI is
# present. `-device usb-kbd` is NOT on this boot: QEMU 11 then
# delivers send-key / input-send-event only to the USB HID device,
# which this kernel does not read, so the command never arrives.
# USB2 injects through `usb feed` on COM1, not through usb-kbd —
# QEMU then steals send-key from the 8042. USB1 does not write
# USBCMD, does not reset, and does not touch pci.dart's table or help.
#
# This is not USB2 (a HID report) and not a USB stack.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "U1-xhci: FAIL — $1" >&2; exit 1; }
setup_error() { echo "U1-xhci: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=28

# Non-default port counts. qemu-xhci defaults are p2=4 p3=4 (8 ports).
# The sum is what HCSPARAMS1 MaxPorts reports. A kernel that prints a
# canned 08 cannot satisfy PORTS == P2+P3 on this boot.
P2=2
P3=3
PORTS_EXPECT=$((P2 + P3))

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-u1.XXXXXX")" || setup_error "mktemp failed"
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
  || fail "usb.dart declares a Bss — USB1 retains nothing"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — USB1 added a help line"
ck; ! grep -q 'usb' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "USB1 added a syscall — the criterion forbids one"

ck; ! grep -qE 'pciWrite32\(|port_outl\(' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart writes configuration space — USB1 is a read"
ck; ! grep -vE '^[[:space:]]*//' "$CORE_DIR/kernel/usb.dart" \
      | grep -qE 'SET_PROTOCOL|SET_ADDRESS|GET_DESCRIPTOR' \
  || fail "usb.dart talks control transfers — that is the xHCI bring-up, not USB1"
ck; ! grep -qE 'Volatile<.*>\.fromAddress\([^)]+\)\.value\s*=' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart stores through Volatile — USB1 must not set Run/Stop or reset"
ck; grep -q 'usbCapDboff' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart has no doorbell-offset constant — USB1 did not land"
ck; grep -q 'Volatile<u32>' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart has no Volatile MMIO load — USB1 is a register read"

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
  || fail "kmain.o .bss contains $BSS_USB — USB1 was not supposed to donate storage"

ck; grep -q 'const int pciNameCount = 20;' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciNameCount moved — USB1 was not supposed to touch pci.dart's table"

ck; ! grep -qE '^[^#]*-device[= ]usb-kbd' "$SCRIPT_DIR/run.sh" \
  || fail "this harness attaches a USB keyboard device — that steals send-key from the 8042"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  usb.dart is a silent no-@bss part, not last; no help, no syscall, MMIO read only"

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
echo "=== BOOT qemu-xhci p2=$P2 p3=$P3 ==="
drive_session "$WORKDIR/xhci" "qemu-xhci" \
  -device qemu-xhci,id=xhci,p2="$P2",p3="$P3"
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-xhci"

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/xhci/serial.txt" "$WORKDIR/xhci/info-pci.txt" "$PORTS_EXPECT" <<'PY' || fail "positive boot did not satisfy USB1"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
ports_expect = int(sys.argv[3])
fails = []

if not re.search(r"1b36:000d", info, re.I):
    fails.append("QEMU info pci has no 1b36:000d — this is not a qemu-xhci boot")

bdf = None
bar0 = None
bar0_end = None
cur_bus = cur_dev = cur_fn = None
cur_is_xhci = False
for ln in info.splitlines():
    bm = re.search(r"Bus\s+(\d+),\s+device\s+(\d+),\s+function\s+(\d+)", ln, re.I)
    if bm:
        cur_bus, cur_dev, cur_fn = int(bm.group(1)), int(bm.group(2)), int(bm.group(3))
        cur_is_xhci = False
        continue
    if cur_bus is None:
        continue
    if re.search(r"PCI device 1b36:000d", ln, re.I):
        bdf = (cur_bus, cur_dev, cur_fn)
        cur_is_xhci = True
        continue
    if not cur_is_xhci:
        continue
    bar = re.search(
        r"BAR0:\s+64 bit(?: prefetchable)? memory at 0x([0-9a-f]+)\s+\[0x([0-9a-f]+)\]",
        ln, re.I)
    if bar:
        bar0 = int(bar.group(1), 16)
        bar0_end = int(bar.group(2), 16)

if bdf is None:
    fails.append("could not parse BDF for 1b36:000d out of info pci")
if bar0 is None or bar0_end is None or bar0_end < bar0:
    fails.append("could not parse BAR0 for 1b36:000d out of info pci")
    bar_size = 0
else:
    bar_size = bar0_end - bar0 + 1
    if bar_size < 0x1000:
        fails.append("QEMU BAR0 size is %#x, expected at least 4 KiB" % bar_size)

dev_re = re.compile(
    r"^USB XHCI ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) "
    r"([0-9A-F]{2})/([0-9A-F]{2})/([0-9A-F]{2})$")
cap_re = re.compile(
    r"^USB BAR ([0-9A-F]{8}) CAPLENGTH ([0-9A-F]{2}) HCIVERSION ([0-9A-F]{4}) "
    r"SLOTS ([0-9A-F]{2}) INTRS ([0-9A-F]{4}) PORTS ([0-9A-F]{2})$")
off_re = re.compile(
    r"^USB DBOFF ([0-9A-F]{8}) RTSOFF ([0-9A-F]{8}) "
    r"USBCMD ([0-9A-F]{8}) USBSTS ([0-9A-F]{8})$")

found = [ln for ln in serial.splitlines() if ln.startswith("USB XHCI ")]
caps = [ln for ln in serial.splitlines() if ln.startswith("USB BAR ")]
offs = [ln for ln in serial.splitlines() if ln.startswith("USB DBOFF ")]
nones = [ln for ln in serial.splitlines() if ln == "USB NONE"]

if nones:
    fails.append("positive boot printed USB NONE — the device was attached")
if len(found) != 1:
    fails.append("expected one USB XHCI line, found %d: %r" % (len(found), found))
else:
    m = dev_re.match(found[0])
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

if len(caps) != 1:
    fails.append("expected one USB BAR line, found %d: %r" % (len(caps), caps))
    cap = None
else:
    cap = cap_re.match(caps[0])
    if not cap:
        fails.append("unparseable USB BAR line: %r" % caps[0])

if len(offs) != 1:
    fails.append("expected one USB DBOFF line, found %d: %r" % (len(offs), offs))
    off = None
else:
    off = off_re.match(offs[0])
    if not off:
        fails.append("unparseable USB DBOFF line: %r" % offs[0])

if cap:
    kbar = int(cap.group(1), 16)
    caplength = int(cap.group(2), 16)
    hciver = int(cap.group(3), 16)
    ports = int(cap.group(6), 16)
    if bar0 is not None and kbar != bar0:
        fails.append("printed BAR %08X != QEMU BAR0 %08X" % (kbar, bar0))
    if caplength == 0:
        fails.append("CAPLENGTH is 0 — not a capability table")
    if caplength < 0x20 or (caplength & 3) != 0:
        fails.append("CAPLENGTH %#x is not a documented operational offset" % caplength)
    if hciver not in (0x0100, 0x0110, 0x0120):
        fails.append("HCIVERSION %04X is not a documented xHCI BCD" % hciver)
    if ports != ports_expect:
        fails.append("PORTS %02X != harness p2+p3 %02X — not a real HCSPARAMS1 read"
                     % (ports, ports_expect))
    if bar_size and caplength + 8 > bar_size:
        fails.append("operational registers at +%#x sit outside BAR size %#x"
                     % (caplength, bar_size))

if off:
    dboff = int(off.group(1), 16)
    rtsoff = int(off.group(2), 16)
    usbcmd = int(off.group(3), 16)
    if dboff == 0:
        fails.append("DBOFF is 0 — not a doorbell array")
    if rtsoff == 0:
        fails.append("RTSOFF is 0 — not a runtime register block")
    if bar_size:
        if dboff >= bar_size:
            fails.append("DBOFF %#x is outside BAR size %#x" % (dboff, bar_size))
        if rtsoff >= bar_size:
            fails.append("RTSOFF %#x is outside BAR size %#x" % (rtsoff, bar_size))
    if usbcmd & 1:
        fails.append("USBCMD Run/Stop is set — USB1 must not start the controller")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    USB BAR %08X CAPLENGTH %02X HCIVERSION %04X PORTS %02X (p2+p3)"
      % (kbar, caplength, hciver, ports))
print("    DBOFF %08X RTSOFF %08X inside QEMU BAR0 size %#x"
      % (dboff, rtsoff, bar_size))
PY
echo "ASSERT: pass  cap/op numbers match QEMU BAR0 and harness p2+p3; HCIVERSION is a spec BCD"

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
caps = [ln for ln in serial.splitlines() if ln.startswith("USB BAR ")]
if caps:
    fails.append("negative boot printed a capability line: %r" % caps)
offs = [ln for ln in serial.splitlines() if ln.startswith("USB DBOFF ")]
if offs:
    fails.append("negative boot printed an operational line: %r" % offs)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints USB NONE and no capability line"

require_assertions "$ASSERTIONS_REQUIRED"
echo "U1-xhci: PASS — qemu-xhci prints cap/op registers matching info pci BAR0 and harness p2+p3; plain -M pc prints USB NONE; no new .bss, not in help"
exit 0
