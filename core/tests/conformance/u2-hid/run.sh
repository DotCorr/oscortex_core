#!/usr/bin/env bash
# core/tests/conformance/u2-hid/run.sh
#
# USB2 — one HID boot-protocol report becomes a set-1 scancode on kbdq.
# docs/design/usb-hid.md USB2, ADR-0073.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# `usb feed 0004 0000` (packed HID: usage 0x04 = `a`, then all keys up)
# is sent on COM1. The kernel translates and [kbdqPush]es set-1 make
# 0x1E then the matching break (bit 8). The printed dump is
# `USB FEED 001E 011E`. After the command, the shell drain types `a`
# onto the next prompt — that is the queue, not the print.
#
# Injection is the serial command. `-device usb-kbd` is NOT attached:
# QEMU 11 then delivers send-key / input-send-event only to the USB
# HID device, which this kernel does not read, and the 8042 goes
# silent (usb-hid.md §1). This is not a transfer-ring proof.
#
# Anti-vacuity: HID 0x04 as a scancode would type `3`
# (kbdSet1Ascii[0x04]). The printed event must be 001E, not 0004,
# and the drain character must be `a`, not `3`.
#
# Negative control: the same kernel, same COM1 path, command `usb`
# only — no feed — prints USB NONE (plain -M pc) and does not enqueue
# a synthetic key. No USB FEED line, no drain `a`.
#
# Structural: no @bss, not last, not in help, no usb-kbd on this
# harness, wmeventStore still last, kbdq still 288 and still global.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "U2-hid: FAIL — $1" >&2; exit 1; }
setup_error() { echo "U2-hid: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=28

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-u2.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
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
  || fail "part 'usb.dart' is last in kmain.dart — D7 owns last .bss"
# This used to be an allow-list of file NAMES for the last part, which every
# newly added part broke on sight without anything having actually moved
# (ADR-0145's virtnet.dart, then virtab.dart, are the ones that broke it). The
# property it was proxying for is that NOTHING lands in .bss after
# wmevent.dart's block: every harness that measures "from my block to the end
# of .bss" depends on it, and a trailing part with no @bss cannot hurt it.
# Assert that property directly, from the source side, so it holds for any
# part list -- and additionally that usb.dart itself does not end up last,
# which is the half of the old check that was about THIS milestone.
LAST_BSS_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" \
  | sed -E "s/^part '(.*)';/\\1/" \
  | while read -r p; do grep -q '^@bss' "$CORE_DIR/kernel/$p" && echo "$p"; done \
  | tail -1)
ck; [[ "$LAST_BSS_PART" == "wmevent.dart" ]] \
  || fail "the last part that declares @bss is ${LAST_BSS_PART:-none}, expected wmevent.dart — a part after it now owns mutable static storage, so wmeventStore is no longer the last block in .bss and every harness that measures to the end of .bss has silently moved"

ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart declares a Bss — USB2 keeps previous-report state in feed locals"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — USB2 added a help line"
ck; ! grep -q 'usb' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "USB2 added a syscall — the criterion forbids one"

ck; grep -q 'kbdqPush' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart does not call kbdqPush — USB2 is an enqueue"
ck; grep -q 'usbHidToSet1' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart has no HID→set-1 translator"
ck; grep -q 'usbStrCmdFeed' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart has no usb feed seam"

ck; ! grep -qE '^[^#]*-device[= ]usb-kbd' "$SCRIPT_DIR/run.sh" \
  || fail "this harness attaches a USB keyboard device — that steals send-key from the 8042"
ck; grep -q 'usbHidUsageSet1' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart has no HID usage table"

# Anti-vacuity of the table itself: usage 0x04 must be set-1 0x1E,
# derived here from the source, and kbdSet1Ascii[0x04] must not be 'a'.
ck; python3 - "$CORE_DIR/kernel/usb.dart" "$CORE_DIR/kernel/keyboard.dart" <<'PY' || fail "HID table / set-1 alphabet disagree with the criterion"
import re, sys

def rodata_bytes(path, name):
    src = open(path).read()
    m = re.search(r"final List<u8> %s = const \[(.*?)\];" % name, src, re.S)
    if not m:
        print("missing %s" % name, file=sys.stderr)
        sys.exit(1)
    return [int(x, 16) for x in re.findall(r"u8\(0x([0-9A-Fa-f]+)\)", m.group(1))]

hid = rodata_bytes(sys.argv[1], "usbHidUsageSet1")
set1 = rodata_bytes(sys.argv[2], "kbdSet1Ascii")
if len(hid) != 128:
    print("usbHidUsageSet1 is %d bytes, expected 128" % len(hid), file=sys.stderr)
    sys.exit(1)
if hid[0x04] != 0x1E:
    print("HID 0x04 maps to %#x, not set-1 0x1E" % hid[0x04], file=sys.stderr)
    sys.exit(1)
if set1[0x1E] != 0x61:
    print("kbdSet1Ascii[0x1E] is %#x, not 'a'" % set1[0x1E], file=sys.stderr)
    sys.exit(1)
if set1[0x04] == 0x61:
    print("kbdSet1Ascii[0x04] is 'a' — the anti-vacuity collapsed", file=sys.stderr)
    sys.exit(1)
if set1[0x04] != 0x33:
    print("kbdSet1Ascii[0x04] is %#x, expected '3'" % set1[0x04], file=sys.stderr)
    sys.exit(1)
print("    HID 0x04 → set-1 0x1E → 'a'; usage-as-scancode would type '3'")
PY

BSS_USB=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /usb/ {print $6}')
ck; [[ -z "$BSS_USB" ]] \
  || fail "kmain.o .bss contains $BSS_USB — USB2 was not supposed to donate storage"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$3" -v f="$1" '$4=="OBJECT" && $8==n {print $f; exit}'; }
KBDQ_SIZE=$(bssfield 3 x kbdqStore)
EV_SIZE=$(bssfield 3 x wmeventStore)
KBDQ_OFF=$(bssfield 2 x kbdqStore)
EV_OFF=$(bssfield 2 x wmeventStore)
ck; [[ "$KBDQ_SIZE" -eq 288 ]] || fail "kbdqStore is ${KBDQ_SIZE:-missing} bytes, expected 288"
ck; [[ "$EV_SIZE" -eq 1920 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 1920"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss"
ck; [[ $(( 16#$KBDQ_OFF + KBDQ_SIZE )) -eq $(( 16#$EV_OFF )) ]] \
  || fail "kbdqStore is not immediately before wmeventStore — USB2 stole the slot"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  translator + feed seam, no @bss, not last, not in help, no usb-kbd"

drive_serial() {
  local outdir="$1"
  local line="$2"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local qlog="$outdir/qemu.log"
  local ports
  ck; ports=$(python3 "$PICKER" 2) || fail "pick-port.py could not find two free TCP ports"
  local qmp_port ser_port
  qmp_port=$(echo "$ports" | sed -n '1p')
  ser_port=$(echo "$ports" | sed -n '2p')
  timeout 120 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -display none \
    -no-reboot \
    -chardev "socket,id=com1,host=127.0.0.1,port=$ser_port,server=on,wait=off,logfile=$ser,logappend=off" \
    -serial chardev:com1 \
    -qmp "tcp:127.0.0.1:$qmp_port,server,nowait" \
    >"$qlog" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 - "$ser" "$ser_port" "$line" <<'PY'
import os, socket, sys, time

ser_path, port, line = sys.argv[1], int(sys.argv[2]), sys.argv[3]
marker = b"M1 END\n"

def wait_file(path, needle, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path):
            data = open(path, "rb").read()
            if needle in data:
                return True
        time.sleep(0.05)
    return False

if not wait_file(ser_path, marker, 25):
    print("kernel never printed M1 END", file=sys.stderr)
    sys.exit(1)

# Same settle qmp-drive uses: M1 END is printed before IRQ1/IRQ4 unmask.
time.sleep(0.5)

end = time.time() + 10
sock = None
last = None
while time.time() < end:
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=1)
        break
    except OSError as e:
        last = e
        time.sleep(0.05)
if sock is None:
    print("serial connect failed: %s" % last, file=sys.stderr)
    sys.exit(1)

payload = (line + "\n").encode("latin-1")
# 16550 RX FIFO is 14 bytes; a whole line longer than that is sent
# in chunks so one IRQ cannot leave the tail sitting with no edge.
off = 0
while off < len(payload):
    sock.sendall(payload[off:off + 8])
    off += 8
    time.sleep(0.03)

# Wait for the command to print and the next prompt to drain.
end = time.time() + 10
while time.time() < end:
    data = open(ser_path, "rb").read()
    if b"USB FEED" in data or (line == "usb" and b"USB NONE" in data):
        time.sleep(0.4)
        sock.close()
        sys.exit(0)
    time.sleep(0.05)
sock.close()
print("command produced no USB line", file=sys.stderr)
sys.exit(1)
PY
  local qemu_status
  kill "$qemu_pid" >/dev/null 2>&1 || true
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$qlog" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "serial drive exited $drive_status for '$line'"
  fi
}

echo
echo "=== BOOT feed (COM1, no usb-kbd) ==="
drive_serial "$WORKDIR/feed" "usb feed 0004 0000"
echo
echo "=== BOOT no-feed (negative) ==="
drive_serial "$WORKDIR/none" "usb"

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/feed/serial.txt" <<'PY' || fail "feed boot did not satisfy USB2"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []

feeds = [ln for ln in serial.splitlines() if ln.startswith("USB FEED")]
if len(feeds) != 1:
    fails.append("expected one USB FEED line, found %d: %r" % (len(feeds), feeds))
else:
    # Packed events, four hex digits each, space-separated after the label.
    m = re.match(r"^USB FEED(?: ([0-9A-F]{4}))+$", feeds[0])
    if not m:
        fails.append("unparseable USB FEED line: %r" % feeds[0])
    else:
        evs = re.findall(r"([0-9A-F]{4})", feeds[0][len("USB FEED"):])
        if evs != ["001E", "011E"]:
            fails.append("events are %s, expected ['001E', '011E'] (make 0x1E, break 0x1E)"
                         % evs)
        if "0004" in evs:
            fails.append("printed HID usage 0x04 as if it were a scancode")

# Drain proof: after the command the next prompt consumes the make.
# kbdSet1Ascii[0x1E] is 'a'; kbdSet1Ascii[0x04] is '3'.
idx = serial.find("USB FEED")
tail = serial[idx:] if idx >= 0 else ""
if "oscortex> a" not in tail:
    fails.append("next prompt did not type 'a' — kbdqPush did not land or drain skipped it")
if re.search(r"oscortex> 3", tail):
    fails.append("next prompt typed '3' — usage was treated as a scancode")

if "USB NONE" in serial.splitlines():
    fails.append("feed boot printed USB NONE — the command was usb, not usb feed")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial ----", file=sys.stderr)
    print(serial, file=sys.stderr)
    sys.exit(1)
print("    USB FEED 001E 011E; drain typed 'a'")
PY
echo "ASSERT: pass  HID 0x04 → set-1 0x1E make+break on kbdq; drain types a"

ck; python3 - "$WORKDIR/none/serial.txt" <<'PY' || fail "negative control did not hold"
import sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "USB NONE" not in serial.splitlines():
    fails.append("no-feed boot did not print USB NONE")
feeds = [ln for ln in serial.splitlines() if ln.startswith("USB FEED")]
if feeds:
    fails.append("no-feed boot printed a USB FEED line: %r" % feeds)
if "oscortex> a" in serial:
    fails.append("no-feed boot drained an 'a' — a synthetic key was enqueued without a report")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial ----", file=sys.stderr)
    print(serial, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  no feed → USB NONE, no USB FEED, no synthetic a"

require_assertions "$ASSERTIONS_REQUIRED"
echo "U2-hid: PASS — COM1 usb feed 0004 0000 → kbdq 001E/011E, drain types a; no usb-kbd; no new .bss"
exit 0
