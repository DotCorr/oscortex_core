#!/usr/bin/env bash
# core/tests/conformance/u3-xhci/run.sh
#
# USB3 — one xHCI transfer ring: port reset, address, GET_DESCRIPTOR /
# SET_CONFIGURATION / SET_PROTOCOL(0), one interrupt IN, one HID boot
# report on the wire into kbdq.
# docs/design/usb-hid.md USB3, ADR-0085.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# `usb hid` (COM1, not `usb feed`) brings up qemu-xhci, resets a
# connected port, addresses the device, runs the control transfers,
# posts a Normal TRB on the interrupt ring, prints USB HID WAIT, then
# applies the 8-byte report that arrives after QMP `down:a` (HID
# usage 0x04). The translator is usbHidApply: set-1 0x1E, drain `a`.
#
# `-device usb-kbd` is ON this boot only. QEMU then delivers
# send-key / input-send-event to the USB HID device, not the 8042
# (usb-hid.md §1). The command is typed on COM1 so the 8042 is not
# required. u0/u1/u2 and every 8042 harness stay without usb-kbd.
#
# Anti-vacuity: the printed report must contain usage 0x04, the
# kbdq event must be 001E (not 0004), and the drain character must
# be `a` (not `3`). A kernel that skips the wire and calls
# usbHidApply(0, 4, ...) still has to have posted WAIT after a
# real doorbell; the empty-port boot forbids a canned report.
#
# Negative: qemu-xhci with no usb-kbd (empty ports) prints
# USB HID NONE, no WAIT, no RPT, no 001E, no drain `a`.
# No-controller: USB NONE, same forbidden lines.
#
# Structural: usb3.dart is a no-@bss appended part; usb.dart still
# has no pciWrite32 / SET_PROTOCOL / Volatile store; wmeventStore
# still last; kbdq still 288 and still abuts wmevent; no help line;
# no USB syscall; this harness may attach usb-kbd, the others must
# not.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "U3-xhci: FAIL — $1" >&2; exit 1; }
setup_error() { echo "U3-xhci: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=40

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-u3.XXXXXX")" || setup_error "mktemp failed"
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

ck; [[ -f "$CORE_DIR/kernel/usb3.dart" ]] || fail "core/kernel/usb3.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart is not a part of kmain.dart"
ck; grep -q "^part 'usb3.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'usb3.dart'"

# APPEND-ONLY, not "usb3.dart is last". usb3.dart was last when U3 landed and
# the pin recorded the position rather than the property; ADR-0145's
# virtnet.dart and then virtab.dart were appended after it, which is exactly
# what append-only permits, and the pin went red for it.
LAST_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" | tail -1)
PART_LIST=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" | sed -E "s/^part '(.*)';/\\1/")
USB3_IX=$(grep -n '^usb3.dart$' <<<"$PART_LIST" | cut -d: -f1)
ck; [[ -n "$USB3_IX" ]] || fail "usb3.dart is not in kmain.dart's part list at all"
AFTER=$(tail -n +$(( USB3_IX + 1 )) <<<"$PART_LIST")
for p in $AFTER; do
  ck; [[ -f "$CORE_DIR/kernel/$p" ]] || fail "kmain.dart parts $p, which does not exist"
done
# This used to be an allow-list of file NAMES for the last part, which every
# newly added part broke on sight without anything having actually moved
# (ADR-0145's virtnet.dart, then virtab.dart, are the ones that broke it). The
# property it was proxying for is that NOTHING lands in .bss after
# wmevent.dart's block: every harness that measures "from my block to the end
# of .bss" depends on it, and a trailing part with no @bss cannot hurt it.
# Assert that property directly, from the source side, so it holds for any
# part list -- and additionally that usb3.dart itself does not end up last,
# which is the half of the old check that was about THIS milestone.
LAST_BSS_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" \
  | sed -E "s/^part '(.*)';/\\1/" \
  | while read -r p; do grep -q '^@bss' "$CORE_DIR/kernel/$p" && echo "$p"; done \
  | tail -1)
ck; [[ "$LAST_BSS_PART" == "wmevent.dart" ]] \
  || fail "the last part that declares @bss is ${LAST_BSS_PART:-none}, expected wmevent.dart — a part after it now owns mutable static storage, so wmeventStore is no longer the last block in .bss and every harness that measures to the end of .bss has silently moved"
ck; [[ "$LAST_PART" != "part 'usb.dart';" ]] \
  || fail "part 'usb.dart' is last — USB0/1/2 must not steal D7"

ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart declares a Bss — USB3 takes rings from allocFrame"
ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart declares a Bss — USB0/1/2 contracts forbid it"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — USB3 added a help line"
ck; ! grep -q 'usb' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "USB3 added a syscall — the criterion forbids one"

ck; grep -q 'pciWrite32' "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart does not call pciWrite32 — BME would stay clear"
ck; grep -q 'allocFrame()' "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart does not call allocFrame — the rings would be in .bss"
ck; grep -q 'usbHidApply' "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart does not call usbHidApply — the translator would be a second table"
ck; grep -q '0x00000B21' "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart has no SET_PROTOCOL(0) setup packet"
ck; grep -q 'usb3TrbNormal' "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart has no Normal TRB — the interrupt transfer is missing"
ck; grep -q 'usb3StrWait' "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart has no WAIT line — the harness could not sync a live TRB"
ck; ! grep -q 'usbFeed' "$CORE_DIR/kernel/usb3.dart" \
  || fail "usb3.dart calls usbFeed — that is USB2, not a transfer"

# USB0/USB1 contracts: usb.dart still does not program the device.
ck; ! grep -qE 'pciWrite32\(|port_outl\(' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart writes configuration space — USB0/USB1 are reads"
ck; ! grep -vE '^[[:space:]]*//' "$CORE_DIR/kernel/usb.dart" \
      | grep -qE 'SET_PROTOCOL|SET_ADDRESS|GET_DESCRIPTOR' \
  || fail "usb.dart talks control transfers — that is USB3, not USB0/USB1"
ck; ! grep -qE 'Volatile<.*>\.fromAddress\([^)]+\)\.value\s*=' "$CORE_DIR/kernel/usb.dart" \
  || fail "usb.dart stores through Volatile — USB1 must not set Run/Stop"

ck; grep -q 'usb3StrCmdHid' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch usb hid"
ck; grep -q 'usb3Init();' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain does not call usb3Init"

# This harness MAY attach usb-kbd. The USB0/1/2 harnesses must not.
ck; ! grep -qE '^[^#]*-device[= ]usb-kbd' \
      "$CORE_DIR/tests/conformance/u0-xhci/run.sh" \
      "$CORE_DIR/tests/conformance/u1-xhci/run.sh" \
      "$CORE_DIR/tests/conformance/u2-hid/run.sh" \
  || fail "a USB0/1/2 harness attaches usb-kbd — that steals send-key from the 8042"
ck; grep -qE -- '-device usb-kbd' "$SCRIPT_DIR/run.sh" \
  || fail "this harness does not attach usb-kbd — USB3 has no device on the wire"

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
  || fail "wmeventStore is not last in .bss — USB3 stole the slot"
ck; [[ $(( 16#$KBDQ_OFF + KBDQ_SIZE )) -eq $(( 16#$EV_OFF )) ]] \
  || fail "kbdqStore is not immediately before wmeventStore"

BSS_USB3=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /usb3/ {print $6}')
ck; [[ -z "$BSS_USB3" ]] \
  || fail "kmain.o .bss contains $BSS_USB3 — USB3 was not supposed to donate storage"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  usb3.dart is a no-@bss appended part; usb.dart contracts hold; wmeventStore last; no help, no syscall"

drive_hid() {
  local outdir="$1"
  local expect="$2"
  shift 2
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local qlog="$outdir/qemu.log"
  local ports
  ck; ports=$(python3 "$PICKER" 2) || fail "pick-port.py could not find two free TCP ports"
  local qmp_port ser_port
  qmp_port=$(echo "$ports" | sed -n '1p')
  ser_port=$(echo "$ports" | sed -n '2p')
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -display none \
    -no-reboot \
    "$@" \
    -chardev "socket,id=com1,host=127.0.0.1,port=$ser_port,server=on,wait=off,logfile=$ser,logappend=off" \
    -serial chardev:com1 \
    -qmp "tcp:127.0.0.1:$qmp_port,server,nowait" \
    >"$qlog" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 - "$ser" "$ser_port" "$qmp_port" "$expect" <<'PY'
import json, os, socket, sys, time

ser_path, ser_port, qmp_port, expect = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
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
time.sleep(0.5)

end = time.time() + 10
sock = None
last = None
while time.time() < end:
    try:
        sock = socket.create_connection(("127.0.0.1", ser_port), timeout=1)
        break
    except OSError as e:
        last = e
        time.sleep(0.05)
if sock is None:
    print("serial connect failed: %s" % last, file=sys.stderr)
    sys.exit(1)

payload = b"usb hid\n"
off = 0
while off < len(payload):
    sock.sendall(payload[off:off + 8])
    off += 8
    time.sleep(0.03)

if expect == "wait":
    if not wait_file(ser_path, b"USB HID WAIT\n", 40):
        print("command produced no USB HID WAIT", file=sys.stderr)
        print(open(ser_path, "rb").read().decode("latin-1", "replace"), file=sys.stderr)
        sock.close()
        sys.exit(1)
    # QMP: send HID 'a' (usage 0x04) to usb-kbd. send-key would also
    # make+break; down:a leaves the key held so the first interrupt
    # IN is the make report.
    qmp = None
    end = time.time() + 10
    while time.time() < end:
        try:
            qmp = socket.create_connection(("127.0.0.1", qmp_port), timeout=1)
            break
        except OSError:
            time.sleep(0.05)
    if qmp is None:
        print("qmp connect failed", file=sys.stderr)
        sock.close()
        sys.exit(1)
    qf = qmp.makefile("rw", encoding="utf-8", newline="\n")
    greet = qf.readline()
    if "QMP" not in greet:
        print("bad qmp greeting: %r" % greet, file=sys.stderr)
        sock.close()
        sys.exit(1)

    def qcmd(name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        qf.write(json.dumps(msg) + "\n")
        qf.flush()
        while True:
            line = qf.readline()
            if not line:
                raise SystemExit("qmp closed")
            obj = json.loads(line)
            if "event" in obj:
                continue
            if "error" in obj:
                raise SystemExit("qmp %s failed: %s" % (name, obj["error"]))
            return obj.get("return")

    qcmd("qmp_capabilities")
    qcmd("human-monitor-command", **{"command-line": "info usb"})
    qcmd("input-send-event", events=[{
        "type": "key",
        "data": {"down": True, "key": {"type": "qcode", "data": "a"}},
    }])
    end = time.time() + 20
    while time.time() < end:
        data = open(ser_path, "rb").read()
        if b"USB HID RPT" in data or b"USB HID 00" in data:
            time.sleep(0.5)
            qmp.close()
            sock.close()
            sys.exit(0)
        time.sleep(0.05)
    qmp.close()
    sock.close()
    print("no USB HID report after down:a", file=sys.stderr)
    print(open(ser_path, "rb").read().decode("latin-1", "replace"), file=sys.stderr)
    sys.exit(1)

end = time.time() + 20
while time.time() < end:
    data = open(ser_path, "rb").read()
    if b"USB HID NONE" in data or b"USB NONE" in data:
        time.sleep(0.3)
        sock.close()
        sys.exit(0)
    time.sleep(0.05)
sock.close()
print("negative boot produced no USB NONE / USB HID NONE", file=sys.stderr)
print(open(ser_path, "rb").read().decode("latin-1", "replace"), file=sys.stderr)
sys.exit(1)
PY
  local qemu_status
  kill "$qemu_pid" >/dev/null 2>&1 || true
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$qlog" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "drive exited $drive_status for $expect"
  fi
}

echo
echo "=== BOOT qemu-xhci + usb-kbd (positive) ==="
drive_hid "$WORKDIR/kbd" wait \
  -device qemu-xhci,id=xhci -device usb-kbd
echo
echo "=== BOOT qemu-xhci empty ports (negative) ==="
drive_hid "$WORKDIR/empty" none \
  -device qemu-xhci,id=xhci
echo
echo "=== BOOT default pc (no controller) ==="
drive_hid "$WORKDIR/none" none

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/kbd/serial.txt" <<'PY' || fail "positive boot did not satisfy USB3"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []

if "USB FEED" in serial:
    fails.append("positive boot printed USB FEED — that is the USB2 seam, not a transfer")
if "usb feed" in serial:
    fails.append("positive boot ran usb feed")

ports = [ln for ln in serial.splitlines() if ln.startswith("USB HID PORT ")]
if len(ports) != 1:
    fails.append("expected one USB HID PORT line, found %d: %r" % (len(ports), ports))
else:
    m = re.match(r"^USB HID PORT ([0-9A-F]{2}) ([0-9A-F])$", ports[0])
    if not m:
        fails.append("unparseable PORT line: %r" % ports[0])
    elif int(m.group(1), 16) < 1:
        fails.append("PORT is 0 — no port was reset")

descs = [ln for ln in serial.splitlines() if ln.startswith("USB HID DESC ")]
if len(descs) != 1:
    fails.append("expected one USB HID DESC line, found %d: %r" % (len(descs), descs))
else:
    m = re.match(r"^USB HID DESC ([0-9A-F]{2}) ([0-9A-F]{2}) ([0-9A-F]{4}):([0-9A-F]{4})$", descs[0])
    if not m:
        fails.append("unparseable DESC line: %r" % descs[0])
    else:
        blen, btype, vid, pid = m.group(1), m.group(2), m.group(3), m.group(4)
        if blen != "12":
            fails.append("bLength is %s, expected 12 — GET_DESCRIPTOR did not land" % blen)
        if btype != "01":
            fails.append("bDescriptorType is %s, expected 01" % btype)
        if vid == "0000" and pid == "0000":
            fails.append("idVendor:idProduct is 0000:0000 — not a device descriptor")

if "USB HID WAIT" not in serial.splitlines():
    fails.append("no USB HID WAIT — the interrupt TRB was never posted")

rpts = [ln for ln in serial.splitlines() if ln.startswith("USB HID RPT ")]
if len(rpts) != 1:
    fails.append("expected one USB HID RPT line, found %d: %r" % (len(rpts), rpts))
else:
    m = re.match(r"^USB HID RPT ([0-9A-F]{16})$", rpts[0])
    if not m:
        fails.append("unparseable RPT line: %r" % rpts[0])
    else:
        raw = m.group(1)
        usage = raw[4:6]
        if usage != "04":
            fails.append("report usage is %s, expected 04 (HID a) — not the QMP key" % usage)
        if raw == "0000000000000000":
            fails.append("report is all zeros — empty port / no key")

hids = [ln for ln in serial.splitlines() if ln.startswith("USB HID") and " " in ln[7:8] or False]
evlines = [ln for ln in serial.splitlines() if re.match(r"^USB HID(?: [0-9A-F]{4})+$", ln)]
if len(evlines) != 1:
    fails.append("expected one USB HID event line, found %d: %r" % (len(evlines), evlines))
else:
    evs = re.findall(r"([0-9A-F]{4})", evlines[0][len("USB HID"):])
    if evs != ["001E"]:
        fails.append("events are %s, expected ['001E'] (set-1 make a)" % evs)
    if "0004" in evs:
        fails.append("printed HID usage 0x04 as if it were a scancode")

idx = serial.find("USB HID")
tail = serial[idx:] if idx >= 0 else ""
if "oscortex> a" not in tail:
    fails.append("next prompt did not type 'a' — kbdqPush did not land or drain skipped it")
if re.search(r"oscortex> 3", tail):
    fails.append("next prompt typed '3' — usage was treated as a scancode")

if "USB HID NONE" in serial.splitlines():
    fails.append("positive boot printed USB HID NONE — a keyboard was attached")
if "USB NONE" in serial.splitlines():
    fails.append("positive boot printed USB NONE — qemu-xhci was attached")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial ----", file=sys.stderr)
    print(serial, file=sys.stderr)
    sys.exit(1)
print("    USB HID PORT + DESC + WAIT + RPT ..04.... ; event 001E; drain typed a")
PY
echo "ASSERT: pass  wire report usage 0x04 → set-1 0x1E on kbdq; drain types a; not usb feed"

ck; python3 - "$WORKDIR/empty/serial.txt" <<'PY' || fail "empty-port negative did not hold"
import sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "USB HID NONE" not in serial.splitlines():
    fails.append("empty-port boot did not print USB HID NONE")
if "USB HID WAIT" in serial:
    fails.append("empty-port boot printed WAIT — a TRB was posted with no device")
rpts = [ln for ln in serial.splitlines() if ln.startswith("USB HID RPT")]
if rpts:
    fails.append("empty-port boot printed a report: %r" % rpts)
if "001E" in serial:
    fails.append("empty-port boot mentioned 001E — a canned scancode")
if "oscortex> a" in serial:
    fails.append("empty-port boot drained an 'a'")
if "USB FEED" in serial:
    fails.append("empty-port boot printed USB FEED")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial ----", file=sys.stderr)
    print(serial, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  empty ports → USB HID NONE, no WAIT, no report, no a"

ck; python3 - "$WORKDIR/none/serial.txt" <<'PY' || fail "no-controller negative did not hold"
import sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "USB NONE" not in serial.splitlines():
    fails.append("no-controller boot did not print USB NONE")
if "USB HID WAIT" in serial:
    fails.append("no-controller boot printed WAIT")
rpts = [ln for ln in serial.splitlines() if ln.startswith("USB HID RPT")]
if rpts:
    fails.append("no-controller boot printed a report: %r" % rpts)
if "oscortex> a" in serial:
    fails.append("no-controller boot drained an 'a'")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial ----", file=sys.stderr)
    print(serial, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  no xHCI → USB NONE, no report"

require_assertions "$ASSERTIONS_REQUIRED"
echo "U3-xhci: PASS — qemu-xhci+usb-kbd usb hid → wire report 04 → kbdq 001E, drain a; empty port / no device ≠ a report; no usb feed"
exit 0
