#!/usr/bin/env bash
# core/tests/conformance/ota-tls/run.sh
#
# ADR-0154 — OTA signed blob fetched from a real host over TLS 1.2.
# docs/decisions/0154-ota-tls-record-layer.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# Harness derives key/payload/signature and a 2048-bit leaf outside the
# kernel, plants OTAKEY + OTACERT + SLOT.TXT, and starts a TLS 1.2
# listener (AES128-SHA) the QEMU user-net guest reaches at 10.0.2.2:<port>.
# `ota tls <port>` pulls the OTA1 blob through the record layer, verifies,
# and applies.
#
# Good TLS → OTA OK; SLOT.TXT host bytes = payload.
# Bad-sig TLS → OTA BADSIG; SLOT.TXT still OLD!.
# Bad leaf cert → OTA BADCERT; slot unchanged.
# No listener → OTA NOHOST.
# Plain TCP on the port → not OTA OK (anti-vacuity: must not stub TLS).
#
# Not plat-tls / FSGS. Not Wi-Fi. Syscall 11 stays fdwait. Not in help.
# ota get stays cleartext (ota-host/).
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "OTA-TLS: FAIL — $1" >&2; exit 1; }
setup_error() { echo "OTA-TLS: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=59

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf \
            x86_64-elf-nm openssl; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
# Prefer Homebrew OpenSSL 3 when present (LibreSSL rejects rsa:2048 for s_server
# in some builds; Python ssl is the listener anyway).
OPENSSL_BIN="$(command -v openssl)"
if [[ -x /opt/homebrew/bin/openssl ]]; then
  OPENSSL_BIN=/opt/homebrew/bin/openssl
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-ota-tls.XXXXXX")" || setup_error "mktemp failed"
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
TLS_SRC="$CORE_DIR/plat/otatls/otatls.c"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$OTA_SRC" ]] || setup_error "ota.dart not found"
ck; [[ -f "$TLS_SRC" ]] || setup_error "otatls.c not found"

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
ck; grep -q 'void otaTls()' "$OTA_SRC" \
  || fail "ota.dart has no otaTls"
ck; grep -q 'void otaGet()' "$OTA_SRC" \
  || fail "ota.dart lost otaGet — cleartext path must remain"
ck; grep -q 'void otaFeed()' "$OTA_SRC" \
  || fail "ota.dart lost otaFeed"
ck; grep -q 'otaStrBadcert' "$OTA_SRC" \
  || fail "ota.dart has no BADCERT path"
ck; grep -q 'shellStartsWith(Rodata.addressOf(otaStrCmdTls)' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch ota tls"
ck; grep -q 'TLS_RSA_WITH_AES_128_CBC_SHA\|0x002f' "$TLS_SRC" \
  || fail "otatls.c has no AES128-SHA suite"
ck; grep -q '0x16' "$TLS_SRC" \
  || fail "otatls.c has no TLS record type 0x16 (handshake)"
ck; grep -q 'ClientHello\|t\[5\] = 0x01' "$TLS_SRC" \
  || fail "otatls.c has no ClientHello"
TLS_SYM=$(x86_64-elf-nm "$CORE_DIR/build/kernel.elf" | grep 'otatls_guest_cmd' || true)
ck; [[ -n "$TLS_SYM" ]] || fail "kernel.elf has no otatls_guest_cmd"
OTA_OFF=$(x86_64-elf-nm "$CORE_DIR/build/kernel.elf" | python3 -c '
import sys
d=o=None
for ln in sys.stdin:
  p=ln.split()
  if len(p)>=3 and p[-1]=="__data_start": d=int(p[0],16)
  if len(p)>=3 and p[-1]=="otatls_guest_cmd": o=int(p[0],16)
print((o-d) if d is not None and o is not None else -1)
')
ck; [[ "$OTA_OFF" -eq 32960 ]] \
  || fail "otatls_guest_cmd offset is $OTA_OFF, expected 32960"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -qiE 'wifi|802\.11|wlan' "$OTA_SRC" \
  || fail "ota.dart names Wi-Fi"
ck; ! grep -vE '^[[:space:]]*//' "$OTA_SRC" | grep -qiE 'graphite|MakeVulkan|Venus|osgfx_skia' \
  || fail "ota.dart crossed the Graphite fence"
ck; ! grep -vE '^[[:space:]]*//' "$OTA_SRC" | grep -qiE 'setfs|FSGS|IA32_FS_BASE|wrfsbase' \
  || fail "ota.dart collided with plat-tls / FSGS"
ck; ! grep -vE '^[[:space:]]*//' "$TLS_SRC" | grep -qiE 'setfs|FSGS|IA32_FS_BASE' \
  || fail "otatls.c collided with plat-tls / FSGS"
ck; [[ -f "$CORE_DIR/docs/decisions/0154-ota-tls-record-layer.md" ]] \
  || fail "ADR-0154 missing"
ck; [[ -f "$CORE_DIR/tests/conformance/ota-host/run.sh" ]] \
  || fail "ota-host harness missing"
ck; ! grep -q '@bss' "$OTA_SRC" \
  || fail "ota.dart declares @bss"
echo "STRUCTURAL: pass  otaTls+BADCERT+ClientHello, otatls linked@32960, fdwait, not plat-tls"

echo
echo "=== DERIVE (key, payload, cert, signature — outside the kernel) ==="
python3 - "$WORKDIR" "$OTA_SRC" "$OPENSSL_BIN" <<'PY' || setup_error "could not derive plant / cert / FAT image"
import os, struct, sys, subprocess, hashlib

wd, ota_src, openssl = sys.argv[1], sys.argv[2], sys.argv[3]
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

def make_cert(path_key, path_cert, cn):
    subprocess.check_call([
        openssl, "req", "-x509", "-newkey", "rsa:2048",
        "-keyout", path_key, "-out", path_cert, "-days", "1", "-nodes",
        "-subj", "/CN=%s" % cn,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    der = subprocess.check_output([
        openssl, "x509", "-in", path_cert, "-outform", "DER"])
    return der

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
    break
else:
    sys.exit("could not derive a plant absent from ota.dart")

good_der = make_cert(os.path.join(wd, "good-key.pem"),
                     os.path.join(wd, "good-cert.pem"), "ota-good")
bad_der = make_cert(os.path.join(wd, "bad-key.pem"),
                    os.path.join(wd, "bad-cert.pem"), "ota-bad")
trust = hashlib.sha256(good_der).digest()
bad_trust = hashlib.sha256(bad_der).digest()
assert trust != bad_trust

img = bytearray(TOTAL * SECTOR)
img[0:SECTOR] = boot_sector()
put_fat(img, 0, 0xFFF8)
put_fat(img, 1, 0xFFFF)
put_fat(img, 2, 0xFFFF)
put_fat(img, 3, 0xFFFF)
put_fat(img, 4, 0xFFFF)
root = ROOT_START * SECTOR
img[root:root + 32] = dir_ent(b"SLOT    TXT", 2, len(OLD))
img[root + 32:root + 64] = dir_ent(b"OTAKEY     ", 3, len(key))
img[root + 64:root + 96] = dir_ent(b"OTACERT    ", 4, len(trust))
slot_off = cluster_lba(2) * SECTOR
key_off = cluster_lba(3) * SECTOR
cert_off = cluster_lba(4) * SECTOR
img[slot_off:slot_off + len(OLD)] = OLD
img[key_off:key_off + len(key)] = key
img[cert_off:cert_off + len(trust)] = trust

open(os.path.join(wd, "disk.img"), "wb").write(img)
open(os.path.join(wd, "key.bin"), "wb").write(key)
open(os.path.join(wd, "payload.bin"), "wb").write(payload)
open(os.path.join(wd, "blob.bin"), "wb").write(blob)
open(os.path.join(wd, "bad.bin"), "wb").write(bytes(bad))
open(os.path.join(wd, "old.bin"), "wb").write(OLD)
open(os.path.join(wd, "trust.bin"), "wb").write(trust)
open(os.path.join(wd, "meta.txt"), "w").write(
    "KEY=%s\nPAYLOAD=%s\nSIG=%s\nPAYLEN=%d\nSLOT_LBA=%d\nTRUST=%s\n"
    % (key.hex().upper(), payload.hex().upper(), sig.hex().upper(),
       len(payload), cluster_lba(2), trust.hex().upper()))
print("DERIVE: paylen=%d trust=%s" % (len(payload), trust.hex().upper()[:16]))
PY

PAYLOAD_HEX=$(python3 -c "print(open('$WORKDIR/payload.bin','rb').read().hex().upper())")
OLD_HEX=$(python3 -c "print(open('$WORKDIR/old.bin','rb').read().hex().upper())")
PAYLEN=$(python3 -c "print(len(open('$WORKDIR/payload.bin','rb').read()))")
PAYLEN_HEX=$(printf '%04X' "$PAYLEN")
ck; [[ -n "$PAYLOAD_HEX" ]] || fail "derived payload is empty"
ck; [[ "$PAYLOAD_HEX" != "$OLD_HEX" ]] || fail "payload equals OLD!"
ck; ! grep -Fqi "$PAYLOAD_HEX" "$OTA_SRC" \
  || fail "payload appears in ota.dart"
echo "DERIVE: payload != OLD!; cert planted"

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

start_tls_listener() {
  local blob="$1"
  local cert="$2"
  local key="$3"
  local portfile="$4"
  local logfile="$5"
  rm -f "$portfile"
  : >"$logfile"
  python3 - "$blob" "$cert" "$key" "$portfile" "$logfile" "$PICKER" <<'PY' &
import ssl, socket, sys, time, subprocess
blob_path, cert, key, portfile, logfile, picker = sys.argv[1:7]
port = int(subprocess.check_output(["python3", picker], text=True).strip())
blob = open(blob_path, "rb").read()
log = open(logfile, "w")
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.maximum_version = ssl.TLSVersion.TLSv1_2
ctx.set_ciphers("AES128-SHA")
ctx.load_cert_chain(cert, key)
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(5)
srv.settimeout(1.0)
open(portfile, "w").write(str(port))
log.write("LISTEN %d bytes=%d\n" % (port, len(blob)))
log.flush()
deadline = time.time() + 180.0
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
        tls = ctx.wrap_socket(conn, server_side=True)
        log.write("NEG %s %s\n" % (tls.version(), tls.cipher()))
        log.flush()
        tls.sendall(blob)
        tls.shutdown(socket.SHUT_WR)
        time.sleep(0.05)
        tls.close()
        log.write("SENT\n")
        log.flush()
    except Exception as e:
        log.write("TLS-ERR %s\n" % e)
        log.flush()
        try:
            conn.close()
        except Exception:
            pass
srv.close()
log.close()
PY
  LISTEN_PID=$!
  local i=0
  while [[ ! -s "$portfile" && $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  [[ -s "$portfile" ]] || fail "TLS listener did not publish a port"
}

start_plain_listener() {
  local blob="$1"
  local portfile="$2"
  local logfile="$3"
  rm -f "$portfile"
  : >"$logfile"
  python3 - "$blob" "$portfile" "$logfile" "$PICKER" <<'PY' &
import socket, sys, time, subprocess
blob_path, portfile, logfile, picker = sys.argv[1:5]
port = int(subprocess.check_output(["python3", picker], text=True).strip())
blob = open(blob_path, "rb").read()
log = open(logfile, "w")
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(5)
srv.settimeout(1.0)
open(portfile, "w").write(str(port))
log.write("PLAIN %d\n" % port)
log.flush()
deadline = time.time() + 120.0
while time.time() < deadline:
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        continue
    except Exception:
        break
    try:
        conn.sendall(blob)
        conn.shutdown(socket.SHUT_WR)
    finally:
        conn.close()
srv.close()
log.close()
PY
  LISTEN_PID=$!
  local i=0
  while [[ ! -s "$portfile" && $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  [[ -s "$portfile" ]] || fail "plain listener did not publish a port"
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
  timeout 240 qemu-system-x86_64 \
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
  cp "$ser" "$CORE_DIR/build/ota-tls-$label-serial.txt"
  cp "$img" "$CORE_DIR/build/ota-tls-$label.img"
}

echo
echo "=== BOOT good (TLS serves signed blob) ==="
start_tls_listener "$WORKDIR/blob.bin" "$WORKDIR/good-cert.pem" \
  "$WORKDIR/good-key.pem" "$WORKDIR/good.port" "$WORKDIR/good-listen.log"
GOOD_PORT=$(tr -d '[:space:]' < "$WORKDIR/good.port")
ck; [[ "$GOOD_PORT" -gt 0 ]] || fail "good listener port is empty"
# Host self-check over real TLS before blaming the guest.
python3 - "$GOOD_PORT" "$WORKDIR/blob.bin" "$WORKDIR/good-cert.pem" <<'PY' \
  || fail "host self-fetch of good TLS blob failed"
import ssl, socket, sys
port, path, cert = int(sys.argv[1]), sys.argv[2], sys.argv[3]
want = open(path, "rb").read()
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.maximum_version = ssl.TLSVersion.TLSv1_2
ctx.set_ciphers("AES128-SHA")
s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=5),
                    server_hostname="ota")
got = b""
while len(got) < len(want):
    chunk = s.recv(4096)
    if not chunk:
        break
    got += chunk
s.close()
assert got == want, (len(got), len(want))
print("HOST-SELF-TLS: got %d bytes on port %d cipher=%s" % (len(got), port, "AES128-SHA"))
PY
GET_GOOD_KEYS="$(typekeys "ota tls $GOOD_PORT"),ret,wait:20000,$(typekeys "cat slot.txt"),ret,wait:1500"
boot_ota good "$GET_GOOD_KEYS"
stop_listener
SER_GOOD="$WORKDIR/good/serial.txt"
ck; grep -q "^OTA OK $PAYLEN_HEX\$" "$SER_GOOD" \
  || { echo "--- serial ---" >&2; cat -v "$SER_GOOD" >&2; \
       echo "--- listen ---" >&2; cat "$WORKDIR/good-listen.log" >&2; \
       fail "good boot did not print OTA OK $PAYLEN_HEX"; }
ck; ! grep -q 'OTA BADSIG' "$SER_GOOD" || fail "good boot printed BADSIG"
ck; ! grep -q 'OTA BADCERT' "$SER_GOOD" || fail "good boot printed BADCERT"
ck; ! grep -q 'OTA NOHOST' "$SER_GOOD" || fail "good boot printed NOHOST"
SLOT_GOOD=$(read_slot "$WORKDIR/good.img" | head -n1)
SIZE_GOOD=$(read_slot "$WORKDIR/good.img" | tail -n1)
ck; [[ "$SLOT_GOOD" == "$PAYLOAD_HEX" ]] \
  || fail "host slot after good TLS is $SLOT_GOOD, want $PAYLOAD_HEX"
ck; [[ "$SIZE_GOOD" == "$PAYLEN" ]] \
  || fail "host slot size after good TLS is $SIZE_GOOD, want $PAYLEN"
echo "ASSERT: pass  TLS good blob → OTA OK; SLOT.TXT = payload"

echo
echo "=== BOOT bad sig (TLS serves flipped sig) ==="
start_tls_listener "$WORKDIR/bad.bin" "$WORKDIR/good-cert.pem" \
  "$WORKDIR/good-key.pem" "$WORKDIR/bad.port" "$WORKDIR/bad-listen.log"
BAD_PORT=$(tr -d '[:space:]' < "$WORKDIR/bad.port")
GET_BAD_KEYS="$(typekeys "ota tls $BAD_PORT"),ret,wait:20000,$(typekeys "cat slot.txt"),ret,wait:1500"
boot_ota bad "$GET_BAD_KEYS"
stop_listener
SER_BAD="$WORKDIR/bad/serial.txt"
ck; grep -q 'OTA BADSIG' "$SER_BAD" \
  || { echo "--- serial ---" >&2; cat -v "$SER_BAD" >&2; \
       fail "bad boot did not print OTA BADSIG"; }
ck; ! grep -q 'OTA OK' "$SER_BAD" || fail "bad boot printed OTA OK"
SLOT_BAD=$(read_slot "$WORKDIR/bad.img" | head -n1)
ck; [[ "$SLOT_BAD" == "$OLD_HEX" ]] \
  || fail "host slot after bad sig is $SLOT_BAD, want OLD!"
echo "ASSERT: pass  bad-sig TLS → OTA BADSIG; SLOT.TXT still OLD!"

echo
echo "=== BOOT badcert (TLS leaf not in OTACERT) ==="
start_tls_listener "$WORKDIR/blob.bin" "$WORKDIR/bad-cert.pem" \
  "$WORKDIR/bad-key.pem" "$WORKDIR/badcert.port" "$WORKDIR/badcert-listen.log"
BC_PORT=$(tr -d '[:space:]' < "$WORKDIR/badcert.port")
GET_BC_KEYS="$(typekeys "ota tls $BC_PORT"),ret,wait:20000,$(typekeys "cat slot.txt"),ret,wait:1500"
boot_ota badcert "$GET_BC_KEYS"
stop_listener
SER_BC="$WORKDIR/badcert/serial.txt"
ck; grep -q 'OTA BADCERT' "$SER_BC" \
  || { echo "--- serial ---" >&2; cat -v "$SER_BC" >&2; \
       echo "--- listen ---" >&2; cat "$WORKDIR/badcert-listen.log" >&2; \
       fail "badcert boot did not print OTA BADCERT"; }
ck; ! grep -q 'OTA OK' "$SER_BC" || fail "badcert boot printed OTA OK"
SLOT_BC=$(read_slot "$WORKDIR/badcert.img" | head -n1)
ck; [[ "$SLOT_BC" == "$OLD_HEX" ]] \
  || fail "host slot after BADCERT is $SLOT_BC, want OLD!"
echo "ASSERT: pass  bad leaf → OTA BADCERT; SLOT.TXT unchanged"

echo
echo "=== BOOT nohost (closed port) ==="
CLOSED_PORT=$(python3 "$PICKER") || fail "could not pick a closed port"
python3 -c "
import socket, sys
p=int(sys.argv[1])
s=socket.socket(); s.settimeout(1.0)
try:
    s.connect(('127.0.0.1', p))
except (ConnectionRefusedError, OSError):
    sys.exit(0)
sys.exit('port %d accepted' % p)
" "$CLOSED_PORT" || fail "closed-port control is not closed"
GET_NONE_KEYS="$(typekeys "ota tls $CLOSED_PORT"),ret,wait:12000"
boot_ota nohost "$GET_NONE_KEYS"
SER_NONE="$WORKDIR/nohost/serial.txt"
ck; grep -q 'OTA NOHOST' "$SER_NONE" \
  || { echo "--- serial ---" >&2; cat -v "$SER_NONE" >&2; \
       fail "nohost boot did not print OTA NOHOST"; }
ck; ! grep -q 'OTA OK' "$SER_NONE" || fail "nohost boot printed OTA OK"
SLOT_NONE=$(read_slot "$WORKDIR/nohost.img" | head -n1)
ck; [[ "$SLOT_NONE" == "$OLD_HEX" ]] \
  || fail "host slot after NOHOST is $SLOT_NONE, want OLD!"
echo "ASSERT: pass  no listener → OTA NOHOST"

echo
echo "=== BOOT plain TCP anti-vacuity (must not stub as TLS) ==="
start_plain_listener "$WORKDIR/blob.bin" "$WORKDIR/plain.port" "$WORKDIR/plain-listen.log"
PLAIN_PORT=$(tr -d '[:space:]' < "$WORKDIR/plain.port")
GET_PLAIN_KEYS="$(typekeys "ota tls $PLAIN_PORT"),ret,wait:20000"
boot_ota plain "$GET_PLAIN_KEYS"
stop_listener
SER_PLAIN="$WORKDIR/plain/serial.txt"
ck; ! grep -q 'OTA OK' "$SER_PLAIN" \
  || fail "plain TCP listener produced OTA OK — TLS was stubbed"
ck; grep -qE 'OTA (TLSFAIL|NOHOST|BADCERT|BADMAGIC|SHORT)' "$SER_PLAIN" \
  || { echo "--- serial ---" >&2; cat -v "$SER_PLAIN" >&2; \
       fail "plain TCP boot did not refuse without OTA OK"; }
SLOT_PLAIN=$(read_slot "$WORKDIR/plain.img" | head -n1)
ck; [[ "$SLOT_PLAIN" == "$OLD_HEX" ]] \
  || fail "host slot after plain anti-vacuity is $SLOT_PLAIN, want OLD!"
echo "ASSERT: pass  plain TCP is not accepted as TLS"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "OTA-TLS: PASS — TLS 1.2 fetch from real host applies signed blob; bad sig / bad cert / no listener / plain TCP leave SLOT.TXT; leftover closed by ota-cert/ + ota-tls13/"
exit 0
