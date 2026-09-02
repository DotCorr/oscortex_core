#!/usr/bin/env bash
# core/tests/conformance/n3-ping/run.sh
#
# N3 — IPv4 + ICMP echo to 10.0.2.2, and the checksum is proved to matter.
# docs/design/net-stack.md §9 N3, ADR-0076.
#
# Binary: the harness types mac= and net= onto the QEMU line, types
# `nic ping`, and requires:
#   * the pcap contains an ARP pair, then an ICMP echo request to net|2
#     and a reply;
#   * every outbound IPv4 header checksum and every ICMP checksum is
#     correct — arithmetic the kernel did not do;
#   * identifiers and sequence numbers match pairwise (request, reply,
#     printed line, kernel constants);
#   * the IP the kernel printed equals the reply's source IP as read
#     out of the pcap, and equals the four address bytes of net|2.
# romfile= is mandatory: without it the option ROM's DHCP is seven
# frames the kernel did not send.
#
# Negative control: a boot that never types `nic ping` produces a
# zero-packet pcap. Structural: nicIcmpTypeOk accepts type 0 only;
# nicCsum subtracts from 0xFFFF. Anti-vacuity: a zero-packet pcap
# fails the positive assertion.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "N3-ping: FAIL — $1" >&2; exit 1; }
setup_error() { echo "N3-ping: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=58

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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-n3-ping.XXXXXX")" || setup_error "mktemp failed"
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
ck; ! grep -Fqi '52:55' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart contains 52:55 — the dest MAC would not be coming from the wire"
ck; ! grep -Fqi '52550A' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart contains a compact gateway MAC"

ck; ! grep -q 'Bss(' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart declares a Bss — N3 was supposed to take frames from allocFrame"
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
ck; true

ck; ! grep -E 'nic|net' "$CORE_DIR/kernel/shell.dart" | grep -q 'shellStrHelp' \
  || fail "nic or net was added to help"

ck; grep -q 'void nicPing()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicPing"
ck; grep -q 'void nicArp()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicArp — N2 must still exist"
ck; grep -q 'void nicSend()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicSend — N1 must still exist"
ck; grep -q 'nicCsumFold' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicCsumFold — the sum and the complement would be one step"
ck; grep -q 'u64 nicCsum(' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicCsum"
ck; grep -A3 'u64 nicCsum(' "$CORE_DIR/kernel/nic.dart" | grep -q '0xFFFF' \
  || fail "nicCsum does not subtract from 0xFFFF — omit the complement and SLIRP drops the request"
ck; grep -q 'nicIcmpEchoReply = 0' "$CORE_DIR/kernel/nic.dart" \
  || fail "nicIcmpEchoReply is not 0 — the type check would not match a reply"
ck; grep -q 'nicIcmpTypeOk' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart has no nicIcmpTypeOk — the type check is the negative control"
ck; grep -A4 'u64 nicIcmpTypeOk' "$CORE_DIR/kernel/nic.dart" | grep -q 'nicIcmpEchoReply' \
  || fail "nicIcmpTypeOk does not compare against nicIcmpEchoReply — an inverted check would still pass"
ck; grep -q 'pciWrite32' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart does not call pciWrite32 — BME would stay clear under romfile="
ck; grep -q 'allocFrame()' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart does not call allocFrame — the rings would be in .bss"
ck; grep -q 'romfile=' "$SCRIPT_DIR/run.sh" \
  || fail "this harness does not pass romfile= — the pcap assertion would be vacuous"

# Kernel IP / ICMP constants must equal what this harness derived.
python3 - "$NET" "$NIC_SRC" <<'PY' || fail "kernel IP/ICMP constants do not match net= $NET"
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
    m = re.search(r"%s = 0x([0-9A-Fa-f]+)" % name, src)
    if m:
        return int(m.group(1), 16)
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
ident = const("nicIcmpIdent")
seq = const("nicIcmpSeq")
if ident == 0 and seq == 0:
    sys.exit("ident and seq are both zero — the comparison would be vacuous")
print("CONST  us=%s gw=%s ident=%04X seq=%04X match net=%s" %
      (".".join(map(str, us)), ".".join(map(str, gw)), ident, seq, net))
PY
ck; true

echo "STRUCTURAL: pass  no .bss, part order, type==0, csum complement, IPs match net=, romfile="

echo
echo "=== DERIVE (gateway IP from net=, not a typed constant) ==="
GW_HEX=$(python3 - "$NET" <<'PY'
import sys
net = sys.argv[1]
base = net.split("/")[0]
octets = [int(p) for p in base.split(".")]
gw = octets[:3] + [2]
print("".join("%02X" % b for b in gw))
PY
)
ck; [[ -n "$GW_HEX" ]] || fail "derived gateway IP hex is empty — the comparison would be vacuous"
ck; [[ "$GW_HEX" == "0A000202" ]] || fail "derived gateway IP $GW_HEX is not 0A000202 from net=$NET"
echo "DERIVE: net=$NET -> gateway IP $GW_HEX (net|2)"

IDENT_HEX=$(python3 - "$NIC_SRC" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"nicIcmpIdent = 0x([0-9A-Fa-f]+)", src)
if not m:
    sys.exit("missing nicIcmpIdent")
print(m.group(1).upper().zfill(4))
PY
)
SEQ_HEX=$(python3 - "$NIC_SRC" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"nicIcmpSeq = (\d+)", src)
if not m:
    sys.exit("missing nicIcmpSeq")
print("%04X" % int(m.group(1)))
PY
)
ck; [[ -n "$IDENT_HEX" ]] || fail "derived ident is empty"
ck; [[ -n "$SEQ_HEX" ]] || fail "derived seq is empty"
echo "DERIVE: ident=$IDENT_HEX seq=$SEQ_HEX from nic.dart"

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
  cp "$ser" "$CORE_DIR/build/n3-ping-$label-serial.txt"
  if [[ -f "$pcap" ]]; then
    cp "$pcap" "$CORE_DIR/build/n3-ping-$label.pcap"
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
echo "=== BOOT (idle, romfile=) — negative: no nic ping ==="
boot_nic idle "ret"
IDLE_PCAP="$WORKDIR/idle/net.pcap"
ck; [[ -f "$IDLE_PCAP" ]] || fail "the idle boot wrote no pcap"
IDLE_N=$(parse_pcap_count "$IDLE_PCAP")
echo "idle pcap packets: $IDLE_N"
ck; [[ "$IDLE_N" == "0" ]] \
  || fail "the idle boot pcap has $IDLE_N packets, want 0 — romfile= is not honest, or the kernel transmitted without nic ping"
echo "ASSERT: pass  idle boot + romfile= produces a zero-packet pcap"

echo
echo "=== BOOT (nic ping, mac=$MAC, net=$NET, romfile=) ==="
boot_nic ping "n,i,c,spc,p,i,n,g,ret,wait:4000"
SER="$WORKDIR/ping/serial.txt"
PING_PCAP="$WORKDIR/ping/net.pcap"
ck; [[ -f "$PING_PCAP" ]] || fail "the ping boot wrote no pcap"
ck; grep -q "NIC MAC $MAC" "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the ping boot did not print NIC MAC $MAC"; }
ck; ! grep -q 'NIC TXTMO' "$SER" \
  || fail "the ping boot printed NIC TXTMO — TX DD never appeared"
ck; ! grep -q 'NIC RXTMO' "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the ping boot printed NIC RXTMO — no frame arrived on the RX ring"; }
ck; ! grep -q 'NIC ICMPMISS' "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the ping boot printed NIC ICMPMISS — a frame arrived but type was not 0"; }
ck; grep -q '^NIC PING ' "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the ping boot did not print a NIC PING line"; }

PRINTED=$(grep '^NIC PING ' "$SER" | head -n 1)
PRINTED_IP=$(echo "$PRINTED" | awk '{print $3}')
PRINTED_ID=$(echo "$PRINTED" | awk '{print $4}')
PRINTED_SEQ=$(echo "$PRINTED" | awk '{print $5}')
ck; [[ -n "$PRINTED_IP" ]] || fail "NIC PING line has no IP — the comparison would be vacuous"
ck; [[ -n "$PRINTED_ID" ]] || fail "NIC PING line has no ident — the comparison would be vacuous"
ck; [[ -n "$PRINTED_SEQ" ]] || fail "NIC PING line has no seq — the comparison would be vacuous"
ck; [[ "$PRINTED_IP" == "$GW_HEX" ]] \
  || fail "printed IP $PRINTED_IP != derived net|2 $GW_HEX"
ck; [[ "$PRINTED_ID" == "$IDENT_HEX" ]] \
  || fail "printed ident $PRINTED_ID != kernel nicIcmpIdent $IDENT_HEX"
ck; [[ "$PRINTED_SEQ" == "$SEQ_HEX" ]] \
  || fail "printed seq $PRINTED_SEQ != kernel nicIcmpSeq $SEQ_HEX"

PING_N=$(parse_pcap_count "$PING_PCAP")
echo "ping pcap packets: $PING_N"
ck; [[ "$PING_N" != "0" ]] \
  || fail "the ping pcap contains zero packets — the positive assertion would be vacuous"
ck; [[ "$PING_N" == "4" ]] \
  || fail "the ping pcap has $PING_N packets, want ARP pair + echo pair (4)"

ck; python3 - "$PING_PCAP" "$MAC" "$NET" "$PRINTED_IP" "$PRINTED_ID" "$PRINTED_SEQ" "$GW_HEX" "$IDENT_HEX" "$SEQ_HEX" <<'PY' || fail "pcap ICMP pair does not match the derived expectation"
import struct, sys

def inet_checksum(data):
    if len(data) % 2:
        data = data + b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

def ip_ok(frame, who):
    if len(frame) < 34:
        print("%s shorter than an IP header" % who, file=sys.stderr)
        return False
    if frame[12:14] != b"\x08\x00":
        print("%s ethertype is %s, want 0800" % (who, frame[12:14].hex()), file=sys.stderr)
        return False
    ihl = (frame[14] & 0x0F) * 4
    if ihl < 20:
        print("%s IHL %d" % (who, ihl), file=sys.stderr)
        return False
    tot = (frame[16] << 8) | frame[17]
    if tot < ihl + 8:
        print("%s IP tot %d < ihl+8" % (who, tot), file=sys.stderr)
        return False
    hdr = bytearray(frame[14:14 + ihl])
    stored = (hdr[10] << 8) | hdr[11]
    hdr[10] = 0
    hdr[11] = 0
    calc = inet_checksum(bytes(hdr))
    if stored != calc:
        print("%s IP checksum stored %04X calc %04X" % (who, stored, calc), file=sys.stderr)
        return False
    if stored == 0 and calc == 0:
        print("%s IP checksum is zero and the header sums to zero — vacuous" % who, file=sys.stderr)
        return False
    proto = frame[14 + 9]
    if proto != 1:
        print("%s IP proto %d, want 1" % (who, proto), file=sys.stderr)
        return False
    icmp = bytearray(frame[14 + ihl:14 + tot])
    stored_c = (icmp[2] << 8) | icmp[3]
    icmp[2] = 0
    icmp[3] = 0
    calc_c = inet_checksum(bytes(icmp))
    if stored_c != calc_c:
        print("%s ICMP checksum stored %04X calc %04X" % (who, stored_c, calc_c), file=sys.stderr)
        return False
    return True

path, mac, net, printed_ip, printed_id, printed_seq, derived_ip, ident, seq = sys.argv[1:]
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
if len(frames) != 4:
    print("pcap contains %d packets, want 4" % len(frames), file=sys.stderr)
    for i, f in enumerate(frames):
        print("  #%d len=%d %s" % (i, len(f), f[:14].hex()), file=sys.stderr)
    sys.exit(1)
req_arp, rep_arp, req, rep = frames
our = bytes(int(p, 16) for p in mac.split(":"))
base = [int(p) for p in net.split("/")[0].split(".")]
gw_ip = bytes(base[:3] + [2])
us_ip = bytes(base[:3] + [15])
if req_arp[12:14] != b"\x08\x06":
    print("frame 0 ethertype is %s, want 0806" % req_arp[12:14].hex(), file=sys.stderr)
    sys.exit(1)
if req_arp[20:22] != b"\x00\x01":
    print("frame 0 ARP opcode is %s, want 0001" % req_arp[20:22].hex(), file=sys.stderr)
    sys.exit(1)
if not ip_ok(req, "echo request"):
    sys.exit(1)
if not ip_ok(rep, "echo reply"):
    sys.exit(1)
if req[26:30] != us_ip:
    print("request SIP %s != net|15 %s" % (list(req[26:30]), list(us_ip)), file=sys.stderr)
    sys.exit(1)
if req[30:34] != gw_ip:
    print("request DIP %s != net|2 %s" % (list(req[30:34]), list(gw_ip)), file=sys.stderr)
    sys.exit(1)
ihl_req = (req[14] & 0x0F) * 4
ihl_rep = (rep[14] & 0x0F) * 4
if req[14 + ihl_req] != 8:
    print("request ICMP type %d, want 8" % req[14 + ihl_req], file=sys.stderr)
    sys.exit(1)
if rep[14 + ihl_rep] != 0:
    print("reply ICMP type %d, want 0" % rep[14 + ihl_rep], file=sys.stderr)
    sys.exit(1)
req_id = req[14 + ihl_req + 4:14 + ihl_req + 6].hex().upper()
req_seq = req[14 + ihl_req + 6:14 + ihl_req + 8].hex().upper()
rep_id = rep[14 + ihl_rep + 4:14 + ihl_rep + 6].hex().upper()
rep_seq = rep[14 + ihl_rep + 6:14 + ihl_rep + 8].hex().upper()
rep_sip = rep[26:30].hex().upper()
if req_id != ident:
    print("request ident %s != kernel %s" % (req_id, ident), file=sys.stderr)
    sys.exit(1)
if req_seq != seq:
    print("request seq %s != kernel %s" % (req_seq, seq), file=sys.stderr)
    sys.exit(1)
if rep_id != req_id or rep_seq != req_seq:
    print("reply ident/seq %s %s != request %s %s" % (rep_id, rep_seq, req_id, req_seq), file=sys.stderr)
    sys.exit(1)
if printed_id != rep_id or printed_seq != rep_seq:
    print("printed ident/seq %s %s != reply %s %s" % (printed_id, printed_seq, rep_id, rep_seq), file=sys.stderr)
    sys.exit(1)
if printed_ip != rep_sip:
    print("printed IP %s != reply SIP %s" % (printed_ip, rep_sip), file=sys.stderr)
    sys.exit(1)
if printed_ip != derived_ip:
    print("printed IP %s != derived net|2 %s — two observers disagree" % (printed_ip, derived_ip), file=sys.stderr)
    sys.exit(1)
if rep[26:30] != gw_ip:
    print("reply SIP %s != net|2 %s" % (list(rep[26:30]), list(gw_ip)), file=sys.stderr)
    sys.exit(1)
print("MATCH sip=%s ident=%s seq=%s printed=%s %s %s checksums ok" %
      (rep_sip, rep_id, rep_seq, printed_ip, printed_id, printed_seq))
PY

echo "ASSERT: pass  ARP+echo pair; checksums host-verified; printed IP equals pcap reply src and derived $GW_HEX"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "N3-ping: PASS — ICMP echo to net|2; printed IP equals pcap reply src and $GW_HEX; ident/seq pairwise; host checksums; idle boot is zero packets; romfile=; no new .bss"
exit 0
