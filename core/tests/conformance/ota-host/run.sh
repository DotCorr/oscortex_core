#!/usr/bin/env bash
# core/tests/conformance/ota-host/run.sh
#
# ADR-0151 — OTA signed blob fetched from a real host over plain TCP.
# docs/decisions/0151-ota-host-tcp-fetch.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# Harness derives key/payload/signature outside the kernel, plants
# OTAKEY + SLOT.TXT on a FAT16 IDE image, and starts a host TCP
# listener the QEMU user-net guest reaches at 10.0.2.2:<port>.
# `ota get <port>` pulls the OTA1 blob, verifies, and applies.
#
# Good listener → OTA OK; SLOT.TXT host bytes = payload.
# Bad-sig listener → OTA BADSIG; SLOT.TXT still OLD!.
# No listener → OTA NOHOST; SLOT.TXT unchanged (anti-vacuity).
#
# TLS is ota-tls/ (ADR-0154). Not COM1 hex plant (ota0/). Not
# plat-tls / FSGS. Not Wi-Fi. Syscall 11 stays fdwait. Not in help.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "OTA-HOST: FAIL — $1" >&2; exit 1; }
setup_error() { echo "OTA-HOST: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=55

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf \
            x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-ota-host.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
LISTEN_PID=""
cleanup() {
  if [[ -n "${LISTEN_PID:-}" ]]; then
    kill "$LISTEN_PID" >/dev/null 2>&1 || true
    wait "$LISTEN_PID" 2>/dev/null || true
  fi
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
OTA_SRC="$CORE_DIR/kernel/ota.dart"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$OTA_SRC" ]] || setup_error "ota.dart not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
cp "$KERNEL_ELF" "$WORKDIR/kernel.elf" || fail "could not snapshot kernel.elf"
KERNEL_ELF="$WORKDIR/kernel.elf"

echo
echo "=== STRUCTURAL ==="
ck; grep -q "^part of 'kmain.dart';$" "$OTA_SRC" \
  || fail "ota.dart is not a part of kmain.dart"
ck; grep -q "^part 'ota.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'ota.dart'"
LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'ota.dart';" ]] \
  || fail "part 'ota.dart' is last — D7 owns that position"
ck; ! grep -qE '^@bss$|final Bss ' "$OTA_SRC" \
  || fail "ota.dart declares a Bss — OTA takes frames from allocFrame"
ck; grep -q 'void otaGet()' "$OTA_SRC" \
  || fail "ota.dart has no otaGet"
ck; grep -q 'void otaFeed()' "$OTA_SRC" \
  || fail "ota.dart lost otaFeed — ota0 plant must still exist"
ck; grep -q 'void otaApplyPlant(' "$OTA_SRC" \
  || fail "ota.dart has no shared otaApplyPlant"
ck; grep -q 'otaStrNohost' "$OTA_SRC" \
  || fail "ota.dart has no NOHOST path — unreachable would be vacuous"
ck; grep -q 'otaStrBadsig' "$OTA_SRC" \
  || fail "ota.dart has no BADSIG path"
ck; grep -q 'otaIpProtoTcp' "$OTA_SRC" \
  || fail "ota.dart has no TCP proto — this rung is a host TCP fetch"
ck; grep -q '10.0.2.2\|nicIpGw' "$OTA_SRC" \
  || fail "ota.dart does not target the SLIRP host"
ck; grep -q 'shellStartsWith(Rodata.addressOf(otaStrCmdGet)' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch ota get"
ck; grep -q 'shellStartsWith(Rodata.addressOf(otaStrCmdFeed)' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart lost ota feed dispatch"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — ota added a help line"
ck; ! grep -E 'ota' "$CORE_DIR/kernel/shell.dart" | grep -q 'shellStrHelp' \
  || fail "ota was added to help"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -qiE 'wifi|802\.11|wlan' "$OTA_SRC" \
  || fail "ota.dart names Wi-Fi"
# Fence words only fail when they appear outside comments.
ck; ! grep -vE '^[[:space:]]*//' "$OTA_SRC" | grep -qiE 'graphite|MakeVulkan|Venus|osgfx_skia' \
  || fail "ota.dart crossed the Graphite fence"
ck; ! grep -vE '^[[:space:]]*//' "$OTA_SRC" | grep -qiE 'setfs|FSGS|IA32_FS_BASE|wrfsbase' \
  || fail "ota.dart collided with plat-tls / FSGS"
# ADR-0154 owns TLS (`ota tls`); ota get must stay cleartext.
ck; ! awk '/void otaGet\(/,/^}/' "$OTA_SRC" | grep -qiE 'ClientHello|otatls|0x16' \
  || fail "otaGet gained TLS bytes — cleartext path must stay plain TCP"
ck; grep -q 'void otaTls()' "$OTA_SRC" \
  || fail "ota.dart lost otaTls — TLS leftover must stay implemented"
ck; [[ -f "$CORE_DIR/docs/decisions/0154-ota-tls-record-layer.md" ]] \
  || fail "ADR-0154 missing"
ck; [[ -f "$CORE_DIR/docs/decisions/0151-ota-host-tcp-fetch.md" ]] \
  || fail "ADR-0151 missing"
ck; [[ -f "$CORE_DIR/tests/conformance/ota0/run.sh" ]] \
  || fail "ota0 harness missing — plant rung must remain"
echo "STRUCTURAL: pass  otaGet cleartext, otaTls present, feed kept, no help, fdwait, not plat-tls"

echo
echo "=== DERIVE (key, payload, signature — outside the kernel) ==="
python3 - "$WORKDIR" "$OTA_SRC" <<'PY' || setup_error "could not derive plant / FAT image"
import os, struct, sys

wd, ota_src = sys.argv[1], sys.argv[2]
src = open(ota_src, encoding="utf-8").read()

SECTOR = 512
BPS = 512
SPC = 1
RESERVED = 1
NUM_FATS = 2
FAT_SECTORS = 16
ROOT_ENTRIES = 512
CLUSTERS = 4085
ROOT_SECTORS = (ROOT_ENTRIES * 32) // BPS
FAT_START = RESERVED
ROOT_START = RESERVED + NUM_FATS * FAT_SECTORS
DATA_START = ROOT_START + ROOT_SECTORS
TOTAL = DATA_START + CLUSTERS
OLD = b"OLD!"

def boot_sector():
    b = bytearray(SECTOR)
    b[0:3] = b"\xEB\x3C\x90"
    b[3:11] = b"OSCORTEX"
    struct.pack_into("<H", b, 11, BPS)
    b[13] = SPC
    struct.pack_into("<H", b, 14, RESERVED)
    b[16] = NUM_FATS
    struct.pack_into("<H", b, 17, ROOT_ENTRIES)
    struct.pack_into("<H", b, 19, TOTAL)
    b[21] = 0xF8
    struct.pack_into("<H", b, 22, FAT_SECTORS)
    struct.pack_into("<H", b, 24, 63)
    struct.pack_into("<H", b, 26, 16)
    b[36] = 0x80
    b[38] = 0x29
    struct.pack_into("<I", b, 39, 0x0A014000)
    b[43:54] = b"OSCORTEX   "
    b[54:62] = b"FAT16   "
    b[510:512] = b"\x55\xAA"
    return bytes(b)

def put_fat(img, cluster, value):
    for n in range(NUM_FATS):
        at = (FAT_START + n * FAT_SECTORS) * SECTOR + cluster * 2
        struct.pack_into("<H", img, at, value)

def cluster_lba(c):
    return DATA_START + (c - 2) * SPC

def dir_ent(raw11, first, size):
    e = bytearray(32)
    e[0:11] = raw11
    e[11] = 0x20
    struct.pack_into("<H", e, 26, first)
    struct.pack_into("<I", e, 28, size)
    struct.pack_into("<H", e, 24, ((2026 - 1980) << 9) | (1 << 5) | 1)
    return bytes(e)

def digest(payload, key):
    out = bytearray(8)
    n = len(payload)
    for i in range(8):
        out[i] = key[i] ^ payload[i % n] ^ payload[(i * 3) % n] ^ (n & 0xFF) ^ i
    return bytes(out)

def build_blob(payload, key):
    sig = digest(payload, key)
    return b"OTA1" + len(payload).to_bytes(2, "big") + sig + payload, sig

for _ in range(64):
    key = os.urandom(8)
    payload = os.urandom(16)
    if payload == OLD or payload == bytes(16) or key == bytes(8):
        continue
    blob, sig = build_blob(payload, key)
    bad = bytearray(blob)
    bad[6] ^= 0x01
    if bad[6] == blob[6]:
        bad[7] ^= 0x01
    texts = [key.hex(), payload.hex(), sig.hex(), blob.hex()]
    if any(t.lower() in src.lower() for t in texts):
        continue
    if payload.hex().upper() == OLD.hex().upper():
        continue
    break
else:
    sys.exit("could not derive a plant absent from ota.dart")

img = bytearray(TOTAL * SECTOR)
img[0:SECTOR] = boot_sector()
put_fat(img, 0, 0xFFF8)
put_fat(img, 1, 0xFFFF)
put_fat(img, 2, 0xFFFF)
put_fat(img, 3, 0xFFFF)
root = ROOT_START * SECTOR
img[root:root + 32] = dir_ent(b"SLOT    TXT", 2, len(OLD))
img[root + 32:root + 64] = dir_ent(b"OTAKEY     ", 3, len(key))
slot_off = cluster_lba(2) * SECTOR
key_off = cluster_lba(3) * SECTOR
img[slot_off:slot_off + len(OLD)] = OLD
img[key_off:key_off + len(key)] = key

open(os.path.join(wd, "disk.img"), "wb").write(img)
open(os.path.join(wd, "key.bin"), "wb").write(key)
open(os.path.join(wd, "payload.bin"), "wb").write(payload)
open(os.path.join(wd, "blob.bin"), "wb").write(blob)
open(os.path.join(wd, "bad.bin"), "wb").write(bytes(bad))
open(os.path.join(wd, "old.bin"), "wb").write(OLD)
open(os.path.join(wd, "meta.txt"), "w").write(
    "KEY=%s\nPAYLOAD=%s\nSIG=%s\nPAYLEN=%d\nSLOT_LBA=%d\n"
    % (key.hex().upper(), payload.hex().upper(), sig.hex().upper(),
       len(payload), cluster_lba(2)))
print("DERIVE: paylen=%d key=%s payload=%s sig=%s"
      % (len(payload), key.hex().upper(), payload.hex().upper(),
         sig.hex().upper()))
PY

PAYLOAD_HEX=$(python3 -c "print(open('$WORKDIR/payload.bin','rb').read().hex().upper())")
OLD_HEX=$(python3 -c "print(open('$WORKDIR/old.bin','rb').read().hex().upper())")
PAYLEN=$(python3 -c "print(len(open('$WORKDIR/payload.bin','rb').read()))")
PAYLEN_HEX=$(printf '%04X' "$PAYLEN")
ck; [[ -n "$PAYLOAD_HEX" ]] || fail "derived payload is empty"
ck; [[ "$PAYLOAD_HEX" != "$OLD_HEX" ]] || fail "payload equals OLD! — apply would be vacuous"
ck; ! grep -Fqi "$PAYLOAD_HEX" "$OTA_SRC" \
  || fail "payload appears in ota.dart — expectation would not be outside"
ck; [[ "$(wc -c < "$WORKDIR/blob.bin" | tr -d ' ')" -eq $((14 + PAYLEN)) ]] \
  || fail "blob length is not hdr+payload"
echo "DERIVE: payload != OLD!; blob not in ota.dart"

typekeys() { python3 -c "
import sys
s=sys.argv[1]
out=[]
for c in s:
    if c==' ': out.append('spc')
    elif c=='.': out.append('dot')
    elif c=='-': out.append('minus')
    else: out.append(c.lower())
print(','.join(out))
" "$1"; }

read_slot() {
  python3 - "$1" "$WORKDIR/meta.txt" <<'PY'
import struct, sys
img = open(sys.argv[1], "rb").read()
meta = dict(ln.strip().split("=", 1) for ln in open(sys.argv[2]) if "=" in ln)
lba = int(meta["SLOT_LBA"])
ROOT_START = 1 + 2 * 16
root = ROOT_START * 512
size = struct.unpack_from("<I", img, root + 28)[0]
off = lba * 512
print(img[off:off + size].hex().upper())
print(size)
PY
}

start_listener() {
  local blob="$1"
  local portfile="$2"
  local logfile="$3"
  rm -f "$portfile"
  : >"$logfile"
  python3 - "$blob" "$portfile" "$logfile" "$PICKER" <<'PY' &
import socket, sys, time
blob_path, portfile, logfile, picker = sys.argv[1:5]
import subprocess
port = int(subprocess.check_output(["python3", picker], text=True).strip())
blob = open(blob_path, "rb").read()
log = open(logfile, "w")
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(5)
srv.settimeout(1.0)
open(portfile, "w").write(str(port))
log.write("LISTEN %d bytes=%d\n" % (port, len(blob)))
log.flush()
# Serve until killed: self-check and the guest each get a connection.
deadline = time.time() + 120.0
while time.time() < deadline:
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        continue
    except Exception as e:
        log.write("ACCEPT-ERR %s\n" % e)
        break
    log.write("ACCEPT %s\n" % (addr,))
    log.flush()
    try:
        conn.sendall(blob)
        conn.shutdown(socket.SHUT_WR)
        time.sleep(0.05)
    except Exception as e:
        log.write("SEND-ERR %s\n" % e)
    finally:
        conn.close()
        log.write("SENT\n")
        log.flush()
srv.close()
log.close()
PY
  LISTEN_PID=$!
  local i=0
  while [[ ! -s "$portfile" && $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  [[ -s "$portfile" ]] || fail "host listener did not publish a port"
}

stop_listener() {
  if [[ -n "${LISTEN_PID:-}" ]]; then
    kill "$LISTEN_PID" >/dev/null 2>&1 || true
    wait "$LISTEN_PID" 2>/dev/null || true
    LISTEN_PID=""
  fi
}

boot_ota() {
  local label="$1"
  local keys="$2"
  local img="$WORKDIR/$label.img"
  cp "$WORKDIR/disk.img" "$img" || fail "could not clone disk for $label"
  mkdir -p "$WORKDIR/$label"
  local ser="$WORKDIR/$label/serial.txt"
  local png="$WORKDIR/$label/shot.png"
  local screen="$WORKDIR/$label/screen.txt"
  : >"$ser"
  local qmp
  qmp=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -display none \
    -no-reboot \
    -serial "file:$ser" \
    -qmp "tcp:127.0.0.1:$qmp,server,nowait" \
    -drive "file=$img,format=raw,if=ide,index=0,media=disk" \
    -net none \
    -netdev user,id=n0,net=10.0.2.0/24 \
    -device e1000,netdev=n0,mac=52:54:00:0A:14:49,romfile= \
    >"$WORKDIR/$label/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" --port "$qmp" --serial "$ser" \
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
  cp "$ser" "$CORE_DIR/build/ota-host-$label-serial.txt"
  cp "$img" "$CORE_DIR/build/ota-host-$label.img"
}

echo
echo "=== BOOT good (host TCP serves signed blob) ==="
start_listener "$WORKDIR/blob.bin" "$WORKDIR/good.port" "$WORKDIR/good-listen.log"
GOOD_PORT=$(tr -d '[:space:]' < "$WORKDIR/good.port")
ck; [[ "$GOOD_PORT" -gt 0 ]] || fail "good listener port is empty"
# Prove the listener is reachable on the host before blaming the guest.
python3 - "$GOOD_PORT" "$WORKDIR/blob.bin" <<'PY' || fail "host self-fetch of good blob failed"
import socket, sys
port, path = int(sys.argv[1]), sys.argv[2]
want = open(path, "rb").read()
s = socket.create_connection(("127.0.0.1", port), timeout=5)
got = b""
while len(got) < len(want):
    chunk = s.recv(4096)
    if not chunk:
        break
    got += chunk
s.close()
assert got == want, (len(got), len(want))
print("HOST-SELF: got %d bytes on port %d" % (len(got), port))
PY
GET_GOOD_KEYS="$(typekeys "ota get $GOOD_PORT"),ret,wait:8000,$(typekeys "cat slot.txt"),ret,wait:1500"
boot_ota good "$GET_GOOD_KEYS"
stop_listener
SER_GOOD="$WORKDIR/good/serial.txt"
ck; grep -q "^OTA OK $PAYLEN_HEX\$" "$SER_GOOD" \
  || { echo "--- serial ---" >&2; cat -v "$SER_GOOD" >&2; \
       echo "--- listen ---" >&2; cat "$WORKDIR/good-listen.log" >&2; \
       fail "good boot did not print OTA OK $PAYLEN_HEX"; }
ck; ! grep -q 'OTA BADSIG' "$SER_GOOD" \
  || fail "good boot printed BADSIG"
ck; ! grep -q 'OTA NOHOST' "$SER_GOOD" \
  || fail "good boot printed NOHOST with a live listener"
ck; ! grep -qF 'OLD!' "$SER_GOOD" \
  || fail "good boot serial still shows OLD! after apply"
SLOT_GOOD=$(read_slot "$WORKDIR/good.img" | head -n1)
SIZE_GOOD=$(read_slot "$WORKDIR/good.img" | tail -n1)
ck; [[ "$SLOT_GOOD" == "$PAYLOAD_HEX" ]] \
  || fail "host slot after good fetch is $SLOT_GOOD, want $PAYLOAD_HEX"
ck; [[ "$SIZE_GOOD" == "$PAYLEN" ]] \
  || fail "host slot size after good fetch is $SIZE_GOOD, want $PAYLEN"
echo "ASSERT: pass  host TCP good blob → OTA OK; SLOT.TXT = payload"

echo
echo "=== BOOT bad (host TCP serves flipped sig) ==="
start_listener "$WORKDIR/bad.bin" "$WORKDIR/bad.port" "$WORKDIR/bad-listen.log"
BAD_PORT=$(tr -d '[:space:]' < "$WORKDIR/bad.port")
GET_BAD_KEYS="$(typekeys "ota get $BAD_PORT"),ret,wait:8000,$(typekeys "cat slot.txt"),ret,wait:1500"
boot_ota bad "$GET_BAD_KEYS"
stop_listener
SER_BAD="$WORKDIR/bad/serial.txt"
ck; grep -q 'OTA BADSIG' "$SER_BAD" \
  || { echo "--- serial ---" >&2; cat -v "$SER_BAD" >&2; \
       fail "bad boot did not print OTA BADSIG"; }
ck; ! grep -q 'OTA OK' "$SER_BAD" \
  || fail "bad boot printed OTA OK — signature check is vacuous"
SLOT_BAD=$(read_slot "$WORKDIR/bad.img" | head -n1)
ck; [[ "$SLOT_BAD" == "$OLD_HEX" ]] \
  || fail "host slot after bad sig is $SLOT_BAD, want OLD! ($OLD_HEX)"
ck; grep -qF 'OLD!' "$SER_BAD" \
  || fail "cat after bad sig did not still show OLD!"
echo "ASSERT: pass  bad-sig host blob → OTA BADSIG; SLOT.TXT still OLD!"

echo
echo "=== BOOT nohost (closed port, no listener) ==="
CLOSED_PORT=$(python3 "$PICKER") || fail "could not pick a closed port"
# Confirm nothing accepts on that port.
python3 -c "
import socket, sys
p=int(sys.argv[1])
s=socket.socket(); s.settimeout(1.0)
try:
    s.connect(('127.0.0.1', p))
except (ConnectionRefusedError, OSError):
    sys.exit(0)
sys.exit('port %d accepted — not a nohost control' % p)
" "$CLOSED_PORT" || fail "closed-port control is not closed"
GET_NONE_KEYS="$(typekeys "ota get $CLOSED_PORT"),ret,wait:8000"
boot_ota nohost "$GET_NONE_KEYS"
SER_NONE="$WORKDIR/nohost/serial.txt"
ck; grep -q 'OTA NOHOST' "$SER_NONE" \
  || { echo "--- serial ---" >&2; cat -v "$SER_NONE" >&2; \
       fail "nohost boot did not print OTA NOHOST"; }
ck; ! grep -q 'OTA OK' "$SER_NONE" \
  || fail "nohost boot printed OTA OK — unreachable refusal is vacuous"
SLOT_NONE=$(read_slot "$WORKDIR/nohost.img" | head -n1)
ck; [[ "$SLOT_NONE" == "$OLD_HEX" ]] \
  || fail "host slot after NOHOST is $SLOT_NONE, want OLD!"
echo "ASSERT: pass  no listener → OTA NOHOST; SLOT.TXT unchanged"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "OTA-HOST: PASS — TCP fetch from real host applies signed blob; bad sig and no listener leave SLOT.TXT; TLS is ota-tls/ (ADR-0154)"
exit 0
