#!/usr/bin/env bash
# core/tests/conformance/n2-arp/run.sh
#
# N2 — a frame arrives, and the kernel understood it as ARP.
# docs/design/net-stack.md §9 N2, ADR-0066.
#
# Binary: the harness types mac= and net= onto the QEMU line, types
# `nic arp`, and requires:
#   * the pcap contains an ARP request from that mac= for net|2,
#     followed by a reply;
#   * the MAC the kernel printed as resolved equals the reply's
#     source MAC as read out of the pcap (not a constant);
#   * that same MAC equals 52:55 concatenated with the four address
#     bytes of net|2 — a second, independent check. Disagreement
#     fails.
# romfile= is mandatory: without it the option ROM's DHCP is seven
# frames the kernel did not send, including a gratuitous ARP.
#
# Negative control: a boot that never types `nic arp` produces a
# zero-packet pcap. Structural: nicArpOpcodeOk accepts opcode 2 only.
# Anti-vacuity: a zero-packet pcap fails the positive assertion.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "N2-arp: FAIL — $1" >&2; exit 1; }
setup_error() { echo "N2-arp: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=48

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf \
            x86_64-elf-objcopy llvm-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# Derived here, typed onto the QEMU line. Not QEMU's default
# 52:54:00:12:34:56, and not a string that appears in the kernel.
MAC="52:54:00:FE:DC:BA"
NET="10.0.2.0/24"
ck; [[ -n "$MAC" ]] || fail "the expected MAC is empty — the comparison would be vacuous"
ck; [[ "$MAC" == *:*:*:*:*:* ]] || fail "the derived MAC $MAC is not six colon-separated octets"
ck; [[ -n "$NET" ]] || fail "the expected net= is empty — the comparison would be vacuous"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
NIC_SRC="$CORE_DIR/kernel/nic.dart"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$NIC_SRC" ]] || setup_error "nic.dart not found"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-n2-arp.XXXXXX")" || setup_error "mktemp failed"
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
# The gateway MAC is 52:55 plus the four address bytes. The kernel
# must learn it from the reply, not from a constant.
ck; ! grep -Fqi '52:55' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart contains 52:55 — the resolved MAC would not be coming from the wire"
ck; ! grep -Fqi '52550A' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart contains a compact gateway MAC"

ck; ! grep -q 'Bss(' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart declares a Bss — N2 was supposed to take frames from allocFrame"
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

ck; grep -q 'void nicArp()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicArp"
ck; grep -q 'void nicSend()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicSend — N1 must still exist"
ck; grep -q 'nicRegRdt' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart never names RDT — the RX ring would not be posted"
ck; grep -q 'nicRegRctl' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart never names RCTL — receive would stay disabled"
ck; grep -q 'pciWrite32' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart does not call pciWrite32 — BME would stay clear under romfile="
ck; grep -q 'allocFrame()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart does not call allocFrame — the rings would be in .bss"
ck; grep -q 'romfile=' "$SCRIPT_DIR/run.sh" \
  || fail "this harness does not pass romfile= — the pcap assertion would be vacuous"
ck; grep -q 'nicArpOperReply = 2' "$CORE_DIR/kernel/nic.dart" \
  || fail "nicArpOperReply is not 2 — the opcode check would not match a reply"
ck; grep -q 'nicArpOpcodeOk' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicArpOpcodeOk — the opcode check is the negative control"
ck; grep -A4 'u64 nicArpOpcodeOk' "$CORE_DIR/kernel/nic.dart" | grep -q 'nicArpOperReply' \
  || fail "nicArpOpcodeOk does not compare against nicArpOperReply — an inverted check would still pass"

# Kernel IP constants must equal net|15 and net|2 as this harness
# derived them. Restate, then assert the kernel copied the same numbers.
python3 - "$NET" "$NIC_SRC" <<'PY' || fail "kernel IP constants do not match net= $NET"
import re, sys
net, src_path = sys.argv[1], sys.argv[2]
base = net.split("/")[0]
octets = [int(p) for p in base.split(".")]
if len(octets) != 4:
    sys.exit("bad net")
gw = octets[:3] + [2]
us = octets[:3] + [15]
src = open(src_path, encoding="utf-8").read()
def const(name):
    m = re.search(r"%s = (\d+)" % name, src)
    if not m:
        sys.exit("missing " + name)
    return int(m.group(1))
got_us = [const("nicIpUs0"), const("nicIpUs1"), const("nicIpUs2"), const("nicIpUs3")]
got_gw = [const("nicIpGw0"), const("nicIpGw1"), const("nicIpGw2"), const("nicIpGw3")]
if got_us != us:
    sys.exit("nicIpUs %s != net|15 %s" % (got_us, us))
if got_gw != gw:
    sys.exit("nicIpGw %s != net|2 %s" % (got_gw, gw))
print("CONST  us=%s gw=%s match net=%s" % (".".join(map(str, us)),
                                           ".".join(map(str, gw)), net))
PY
ck; true

echo "STRUCTURAL: pass  no .bss, part order, RDT/RCTL, opcode==2, IPs match net=, romfile="

echo
echo "=== DERIVE (gateway MAC from net=, not a typed constant) ==="
GW_MAC=$(python3 - "$NET" <<'PY'
import sys
net = sys.argv[1]
base = net.split("/")[0]
octets = [int(p) for p in base.split(".")]
gw = octets[:3] + [2]
# slirp: 52:55 followed by the four address bytes (net-stack.md §0.2 fact 9).
mac = [0x52, 0x55] + gw
print(":".join("%02X" % b for b in mac))
PY
)
ck; [[ -n "$GW_MAC" ]] || fail "derived gateway MAC is empty — the comparison would be vacuous"
ck; [[ "$GW_MAC" == *:*:*:*:*:* ]] || fail "derived gateway MAC $GW_MAC is not six octets"
echo "DERIVE: net=$NET -> gateway MAC $GW_MAC (52:55 || net|2)"

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
    -netdev "user,id=n0,net=$NET" \
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
  cp "$ser" "$CORE_DIR/build/n2-arp-$label-serial.txt"
  if [[ -f "$pcap" ]]; then
    cp "$pcap" "$CORE_DIR/build/n2-arp-$label.pcap"
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
echo "=== BOOT (idle, romfile=) — negative: no nic arp ==="
boot_nic idle "ret"
IDLE_PCAP="$WORKDIR/idle/net.pcap"
ck; [[ -f "$IDLE_PCAP" ]] || fail "the idle boot wrote no pcap"
IDLE_N=$(parse_pcap_count "$IDLE_PCAP")
echo "idle pcap packets: $IDLE_N"
ck; [[ "$IDLE_N" == "0" ]] \
  || fail "the idle boot pcap has $IDLE_N packets, want 0 — romfile= is not honest, or the kernel transmitted without nic arp"
echo "ASSERT: pass  idle boot + romfile= produces a zero-packet pcap"

echo
echo "=== BOOT (nic arp, mac=$MAC, net=$NET, romfile=) ==="
boot_nic arp "n,i,c,spc,a,r,p,ret,wait:2000"
SER="$WORKDIR/arp/serial.txt"
ARP_PCAP="$WORKDIR/arp/net.pcap"
ck; [[ -f "$ARP_PCAP" ]] || fail "the arp boot wrote no pcap"
ck; grep -q "NIC MAC $MAC" "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the arp boot did not print NIC MAC $MAC"; }
ck; ! grep -q 'NIC TXTMO' "$SER" \
  || fail "the arp boot printed NIC TXTMO — TX DD never appeared"
ck; ! grep -q 'NIC RXTMO' "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the arp boot printed NIC RXTMO — no frame arrived on the RX ring"; }
ck; ! grep -q 'NIC ARPMISS' "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the arp boot printed NIC ARPMISS — a frame arrived but opcode was not 2"; }
ck; grep -q '^NIC ARP ' "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the arp boot did not print a NIC ARP line"; }

PRINTED=$(grep '^NIC ARP ' "$SER" | head -n 1 | awk '{print $3}')
ck; [[ -n "$PRINTED" ]] || fail "NIC ARP line has no MAC — the comparison would be vacuous"

ARP_N=$(parse_pcap_count "$ARP_PCAP")
echo "arp pcap packets: $ARP_N"
ck; [[ "$ARP_N" != "0" ]] \
  || fail "the arp pcap contains zero packets — the positive assertion would be vacuous"
ck; [[ "$ARP_N" == "2" ]] \
  || fail "the arp pcap has $ARP_N packets, want request+reply (2)"

ck; python3 - "$ARP_PCAP" "$MAC" "$NET" "$PRINTED" "$GW_MAC" <<'PY' || fail "pcap ARP pair does not match the derived expectation"
import struct, sys
path, mac, net, printed, derived = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
data = open(path, "rb").read()
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
if len(frames) != 2:
    print("pcap contains %d packets, want 2" % len(frames), file=sys.stderr)
    for i, f in enumerate(frames):
        print("  #%d len=%d %s" % (i, len(f), f[:14].hex()), file=sys.stderr)
    sys.exit(1)
req, rep = frames[0], frames[1]
our = bytes(int(p, 16) for p in mac.split(":"))
base = [int(p) for p in net.split("/")[0].split(".")]
gw_ip = bytes(base[:3] + [2])
us_ip = bytes(base[:3] + [15])
if req[0:6] != b"\xff\xff\xff\xff\xff\xff":
    print("request dest is not broadcast", file=sys.stderr)
    sys.exit(1)
if req[6:12] != our:
    print("request src %s != mac= %s" % (req[6:12].hex(":"), mac), file=sys.stderr)
    sys.exit(1)
if req[12:14] != b"\x08\x06":
    print("request ethertype is %s, want 0806" % req[12:14].hex(), file=sys.stderr)
    sys.exit(1)
if req[20:22] != b"\x00\x01":
    print("request opcode is %s, want 0001" % req[20:22].hex(), file=sys.stderr)
    sys.exit(1)
if req[38:42] != gw_ip:
    print("request TPA %s != net|2 %s" % (list(req[38:42]), list(gw_ip)), file=sys.stderr)
    sys.exit(1)
if len(rep) < 42:
    print("reply is %d bytes, want >= 42" % len(rep), file=sys.stderr)
    sys.exit(1)
if rep[12:14] != b"\x08\x06":
    print("reply ethertype is %s, want 0806" % rep[12:14].hex(), file=sys.stderr)
    sys.exit(1)
if rep[20:22] != b"\x00\x02":
    print("reply opcode is %s, want 0002" % rep[20:22].hex(), file=sys.stderr)
    sys.exit(1)
if rep[28:32] != gw_ip:
    print("reply SPA %s != net|2 %s" % (list(rep[28:32]), list(gw_ip)), file=sys.stderr)
    sys.exit(1)
reply_src = rep[6:12]
reply_sha = rep[22:28]
printed_b = bytes(int(p, 16) for p in printed.split(":"))
derived_b = bytes(int(p, 16) for p in derived.split(":"))
if printed_b != reply_src:
    print("printed MAC %s != reply src %s" % (printed, reply_src.hex(":")), file=sys.stderr)
    sys.exit(1)
if printed_b != reply_sha:
    print("printed MAC %s != reply SHA %s" % (printed, reply_sha.hex(":")), file=sys.stderr)
    sys.exit(1)
if reply_src != derived_b:
    print("reply src %s != derived 52:55||net|2 %s — two observers disagree" %
          (reply_src.hex(":"), derived), file=sys.stderr)
    sys.exit(1)
print("MATCH req TPA=%s reply SHA=%s printed=%s derived=%s" %
      (".".join(str(b) for b in gw_ip), reply_sha.hex(":"), printed, derived))
PY

echo "ASSERT: pass  ARP request+reply; printed MAC equals pcap reply src; that MAC equals derived $GW_MAC"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "N2-arp: PASS — ARP request for net|2; resolved MAC equals pcap reply src and 52:55||net|2 ($GW_MAC); idle boot is zero packets; romfile=; no new .bss"
exit 0
