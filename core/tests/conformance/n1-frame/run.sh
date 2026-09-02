#!/usr/bin/env bash
# core/tests/conformance/n1-frame/run.sh
#
# N1 — one Ethernet frame leaves the machine.
# docs/design/net-stack.md §9 N1, ADR-0063.
#
# Binary: the harness types mac= onto the QEMU line, types `nic send`,
# and requires the pcap to contain exactly one packet whose bytes equal
# the 60-byte broadcast frame it built from that mac=, ethertype 0x88B5,
# and the body it read out of nic.dart. Source MAC equals mac=.
# romfile= is mandatory: without it the option ROM's DHCP is seven
# frames the kernel did not send.
#
# Negative control: a boot that never types `nic send` produces a
# zero-packet pcap (the doorbell is load-bearing; romfile= is honest).
# Anti-vacuity: a zero-packet pcap fails the positive assertion, and
# the expected frame must be 60 non-empty bytes.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "N1-frame: FAIL — $1" >&2; exit 1; }
setup_error() { echo "N1-frame: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=40

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf \
            x86_64-elf-objcopy llvm-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# Derived here, typed onto the QEMU line, compared against the pcap.
# Not QEMU's default 52:54:00:12:34:56, and not a string that appears
# in the kernel. The 00 octet is deliberate: a bash string cannot hold
# the frame, so the expectation lives in a file.
MAC="52:54:00:AB:CD:EF"
ck; [[ -n "$MAC" ]] || fail "the expected MAC is empty — the comparison would be vacuous"
ck; [[ "$MAC" == *:*:*:*:*:* ]] || fail "the derived MAC $MAC is not six colon-separated octets"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
NIC_SRC="$CORE_DIR/kernel/nic.dart"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$NIC_SRC" ]] || setup_error "nic.dart not found"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-n1-frame.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="

MAC_COMPACT="${MAC//:/}"
ck; ! grep -Fqi "$MAC" "$CORE_DIR/kernel/nic.dart" "$CORE_DIR/kernel/pci.dart" \
  || fail "the derived MAC $MAC appears in the kernel — the expectation would not be coming from outside"
ck; ! grep -Fqi "$MAC_COMPACT" "$CORE_DIR/kernel/nic.dart" \
  || fail "the compact form $MAC_COMPACT appears in nic.dart"

# ZERO new .bss: DMA buffers are allocFrame(), D7 stays last.
ck; ! grep -q 'Bss(' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart declares a Bss — N1 was supposed to take frames from allocFrame"
ck; grep -q "part 'nic.dart';" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not name nic.dart"
PART_ORDER=$(awk "/part '/{print}" "$CORE_DIR/kernel/kmain.dart" | tr -d "'")
echo "$PART_ORDER" | awk '
  /part kbdq.dart/ { k=NR }
  /part nic.dart/  { n=NR }
  /part wmevent.dart/ { w=NR }
  END {
    if (!k || !n || !w) { print "missing"; exit 1 }
    if (!(k<n && n<w)) { print "order " k " " n " " w; exit 1 }
    print "ok"
  }' >/dev/null \
  || fail "nic.dart is not between kbdq.dart and wmevent.dart — D7 would lose last place"

ck; ! grep -E 'nic|net' "$CORE_DIR/kernel/shell.dart" | grep -q 'shellStrHelp' \
  || fail "nic or net was added to help"

ck; grep -q 'void nicSend()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicSend"
ck; grep -q 'nicRegTdt' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart never names TDT — the doorbell would be missing"
ck; grep -q 'pciWrite32' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart does not call pciWrite32 — BME would stay clear under romfile="
ck; grep -q 'allocFrame()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart does not call allocFrame — the ring would be in .bss"
ck; grep -q 'vmZeroFrame(ring)' "$CORE_DIR/kernel/nic.dart" \
  || fail "the TX ring frame is not passed to vmZeroFrame"
ck; grep -q 'vmZeroFrame(buf)' "$CORE_DIR/kernel/nic.dart" \
  || fail "the TX buffer frame is not passed to vmZeroFrame"
ck; grep -q 'romfile=' "$SCRIPT_DIR/run.sh" \
  || fail "this harness does not pass romfile= — the pcap assertion would be vacuous"
ck; grep -q 'nicEtherTypeHi = 0x88' "$CORE_DIR/kernel/nic.dart" \
  || fail "nicEtherTypeHi is not 0x88 — the harness ethertype would not match the kernel"
ck; grep -q 'nicEtherTypeLo = 0xB5' "$CORE_DIR/kernel/nic.dart" \
  || fail "nicEtherTypeLo is not 0xB5 — the harness ethertype would not match the kernel"

echo "STRUCTURAL: pass  no .bss, part order, TDT, BME write, allocFrame, romfile=, ethertype"

# The expected frame is built HERE, from mac= and the body in nic.dart.
# Written to a file because the MAC contains 0x00 and bash cannot hold it.
python3 - "$MAC" "$NIC_SRC" "$WORKDIR/expected.bin" <<'PY' || fail "could not derive the expected frame from mac= and nic.dart"
import re, sys
mac, src_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path, encoding="utf-8").read()
m = re.search(r"nicFrameBody = const \[([^\]]+)\]", src)
if not m:
    sys.exit("nicFrameBody not found")
body = bytes(int(x, 16) for x in re.findall(r"u8\(0x([0-9A-Fa-f]+)\)", m.group(1)))
if len(body) != 8:
    sys.exit("nicFrameBody is %d bytes, want 8" % len(body))
octets = [int(p, 16) for p in mac.split(":")]
if len(octets) != 6:
    sys.exit("bad mac")
frame = bytes([0xFF] * 6) + bytes(octets) + bytes([0x88, 0xB5]) + body + bytes(38)
if len(frame) != 60:
    sys.exit("expected frame is %d bytes" % len(frame))
if frame == bytes(60):
    sys.exit("expected frame is all zeros — vacuous")
open(out_path, "wb").write(frame)
print("DERIVE: 60-byte broadcast frame from mac=%s + 0x88B5 + nicFrameBody" % mac)
PY
ck; [[ -f "$WORKDIR/expected.bin" ]] || fail "no expected.bin after derive"
EXP_LEN=$(wc -c < "$WORKDIR/expected.bin" | tr -d ' ')
ck; [[ "$EXP_LEN" -eq 60 ]] || fail "the derived frame is $EXP_LEN bytes, want 60 — the comparison would be vacuous"

boot_nic() {
  local label="$1"
  local keys="$2"
  mkdir -p "$WORKDIR/$label"
  local ser="$WORKDIR/$label/serial.txt"
  local png="$WORKDIR/$label/shot.png"
  local screen="$WORKDIR/$label/screen.txt"
  local pcap="$WORKDIR/$label/net.pcap"
  : >"$ser"
  local port
  port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 120 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -display none \
    -no-reboot \
    -serial "file:$ser" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    -net none \
    -netdev user,id=n0 \
    -device "e1000,netdev=n0,mac=$MAC,romfile=" \
    -object "filter-dump,id=f0,netdev=n0,file=$pcap" \
    >"$WORKDIR/$label/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$ser" \
    --wait-for 'M1 END\n' --png "$png" --screen-text "$screen" \
    --keys "$keys"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$WORKDIR/$label/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status on the $label boot"
  fi
  cp "$ser" "$CORE_DIR/build/n1-frame-$label-serial.txt"
  if [[ -f "$pcap" ]]; then
    cp "$pcap" "$CORE_DIR/build/n1-frame-$label.pcap"
  fi
}

parse_pcap_count() {
  python3 - "$1" <<'PY'
import struct, sys
path = sys.argv[1]
data = open(path, "rb").read()
if len(data) < 24:
    print("SHORT")
    sys.exit(0)
magic, _vmaj, _vmin, _tz, _sig, _snap, link = struct.unpack_from("<IHHIIII", data, 0)
if magic != 0xA1B2C3D4:
    print("MAGIC")
    sys.exit(0)
if link != 1:
    print("LINK")
    sys.exit(0)
off = 24
n = 0
while off + 16 <= len(data):
    _ts, _tu, incl, _orig = struct.unpack_from("<IIII", data, off)
    off += 16 + incl
    n += 1
print(n)
PY
}

echo
echo "=== BOOT (idle, romfile=) — negative: no nic send ==="
# A boot that never types the command must produce a zero-packet pcap.
# That is the proof romfile= removed the option ROM, and that a kernel
# which does not write TDT transmits nothing.
boot_nic idle "ret"
IDLE_PCAP="$WORKDIR/idle/net.pcap"
ck; [[ -f "$IDLE_PCAP" ]] || fail "the idle boot wrote no pcap"
IDLE_N=$(parse_pcap_count "$IDLE_PCAP")
echo "idle pcap packets: $IDLE_N"
ck; [[ "$IDLE_N" == "0" ]] \
  || fail "the idle boot pcap has $IDLE_N packets, want 0 — romfile= is not honest, or the kernel transmitted without nic send"
echo "ASSERT: pass  idle boot + romfile= produces a zero-packet pcap"

echo
echo "=== BOOT (nic send, mac=$MAC, romfile=) ==="
boot_nic send "n,i,c,spc,s,e,n,d,ret,wait:500"
SER="$WORKDIR/send/serial.txt"
SEND_PCAP="$WORKDIR/send/net.pcap"
ck; [[ -f "$SEND_PCAP" ]] || fail "the send boot wrote no pcap"
ck; grep -q "NIC MAC $MAC" "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the send boot did not print NIC MAC $MAC"; }
ck; grep -q "NIC TX 003C" "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the send boot did not print NIC TX 003C — the kernel did not claim a 60-byte transmit"; }
ck; ! grep -q 'NIC TXTMO' "$SER" \
  || fail "the send boot printed NIC TXTMO — DD never appeared"

SEND_N=$(parse_pcap_count "$SEND_PCAP")
echo "send pcap packets: $SEND_N"
ck; [[ "$SEND_N" != "0" ]] \
  || fail "the send pcap contains zero packets — the positive assertion would be vacuous"
ck; [[ "$SEND_N" == "1" ]] \
  || fail "the send pcap has $SEND_N packets, want exactly 1"

ck; python3 - "$SEND_PCAP" "$WORKDIR/expected.bin" "$MAC" <<'PY' || fail "pcap bytes do not equal the derived frame"
import struct, sys
data = open(sys.argv[1], "rb").read()
expected = open(sys.argv[2], "rb").read()
mac = sys.argv[3]
if len(expected) != 60:
    print("expected is %d bytes, not 60 — vacuous" % len(expected), file=sys.stderr)
    sys.exit(1)
if len(data) < 24:
    print("pcap shorter than a header", file=sys.stderr)
    sys.exit(1)
magic, _vmaj, _vmin, _tz, _sig, _snap, link = struct.unpack_from("<IHHIIII", data, 0)
if magic != 0xA1B2C3D4:
    print("bad pcap magic %08X" % magic, file=sys.stderr)
    sys.exit(1)
if link != 1:
    print("pcap linktype %d, want 1 (Ethernet)" % link, file=sys.stderr)
    sys.exit(1)
off = 24
frames = []
while off + 16 <= len(data):
    _ts, _tu, incl, _orig = struct.unpack_from("<IIII", data, off)
    off += 16
    frames.append(data[off:off + incl])
    off += incl
if len(frames) == 0:
    print("pcap contains zero packets — the positive assertion fails", file=sys.stderr)
    sys.exit(1)
if len(frames) != 1:
    print("pcap contains %d packets, want exactly 1" % len(frames), file=sys.stderr)
    for i, f in enumerate(frames):
        print("  #%d len=%d %s" % (i, len(f), f[:14].hex()), file=sys.stderr)
    sys.exit(1)
got = frames[0]
if got != expected:
    print("frame mismatch", file=sys.stderr)
    print("  got  (%d) %s" % (len(got), got.hex()), file=sys.stderr)
    print("  want (%d) %s" % (len(expected), expected.hex()), file=sys.stderr)
    sys.exit(1)
src = got[6:12]
want_src = bytes(int(p, 16) for p in mac.split(":"))
if src != want_src:
    print("source MAC %s != mac= %s" % (src.hex(":"), mac), file=sys.stderr)
    sys.exit(1)
if got[0:6] != b"\xff\xff\xff\xff\xff\xff":
    print("dest is not broadcast", file=sys.stderr)
    sys.exit(1)
if got[12:14] != b"\x88\xb5":
    print("ethertype is %s, want 88b5" % got[12:14].hex(), file=sys.stderr)
    sys.exit(1)
print("MATCH 60 src=%s eth=88b5" % mac)
PY

echo "ASSERT: pass  pcap has exactly one 60-byte frame; bytes equal the frame this harness built from mac=$MAC; src MAC is $MAC"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "N1-frame: PASS — one TX frame; pcap bytes equal the frame this harness built from mac=$MAC; idle boot is zero packets; romfile=; no new .bss"
exit 0
