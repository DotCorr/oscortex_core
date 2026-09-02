#!/usr/bin/env bash
# core/tests/conformance/ota0/run.sh
#
# ADR-0140 — OTA signed plant on NIC (RX plant + FAT apply).
# docs/decisions/0140-ota-signed-plant-on-nic.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# Harness derives key, payload, and keyed add/xor signature at test time.
# FAT image plants OTAKEY + SLOT.TXT ("OLD!"). `ota feed <hex>` is the
# RX plant. With an Ethernet class device present, a good signature
# overwrites SLOT.TXT; a flipped signature prints OTA BADSIG and leaves
# OLD! on the volume. `-net none` prints OTA NONIC.
#
# Anti-vacuity: plant bytes are not in ota.dart; bad ≠ good; no NIC
# refuses; host image readback is the judge for the slot. Syscall 11
# stays fdwait. Not in help. Not Wi-Fi. TLS/real host is ota-tls/ota-host.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "OTA0: FAIL — $1" >&2; exit 1; }
setup_error() { echo "OTA0: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=48

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf \
            x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-ota0.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
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
  || fail "ota.dart declares a Bss — OTA takes a frame from allocFrame"
ck; grep -q 'void otaFeed()' "$OTA_SRC" \
  || fail "ota.dart has no otaFeed"
ck; grep -q 'otaStrBadsig' "$OTA_SRC" \
  || fail "ota.dart has no BADSIG path"
ck; grep -q 'otaStrNonic' "$OTA_SRC" \
  || fail "ota.dart has no NONIC path"
ck; grep -q 'pciFindByClass' "$OTA_SRC" \
  || fail "ota.dart does not gate on Ethernet class"
ck; grep -q 'otaDigest' "$OTA_SRC" \
  || fail "ota.dart has no otaDigest — unsigned apply would be a stub"
ck; grep -q 'otaWriteSlot' "$OTA_SRC" \
  || fail "ota.dart has no otaWriteSlot"
ck; grep -q 'shellStartsWith(Rodata.addressOf(otaStrCmdFeed)' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch ota feed"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — ota added a help line"
ck; ! grep -E 'ota' "$CORE_DIR/kernel/shell.dart" | grep -q 'shellStrHelp' \
  || fail "ota was added to help"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; ! grep -qiE 'wifi|802\.11|wlan' "$OTA_SRC" \
  || fail "ota.dart names Wi-Fi — this rung is wired NIC / RX plant"
ck; ! grep -qiE 'graphite|MakeVulkan|Venus|osgfx_skia' "$OTA_SRC" \
  || fail "ota.dart crossed the Graphite fence"
echo "STRUCTURAL: pass  no .bss, part not last, BADSIG+NONIC, digest+slot, no help, fdwait"

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
    # Matches otaDigest: 8-byte XOR mix (no wide arithmetic).
    out = bytearray(8)
    n = len(payload)
    for i in range(8):
        out[i] = key[i] ^ payload[i % n] ^ payload[(i * 3) % n] ^ (n & 0xFF) ^ i
    return bytes(out)

def build_blob(payload, key):
    sig = digest(payload, key)
    return b"OTA1" + len(payload).to_bytes(2, "big") + sig + payload, sig

# Derive until nothing collides with ota.dart source text.
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
# cluster 2 = SLOT.TXT, cluster 3 = OTAKEY
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
open(os.path.join(wd, "blob.hex"), "w").write(blob.hex().upper())
open(os.path.join(wd, "bad.hex"), "w").write(bytearray(bad).hex().upper())
open(os.path.join(wd, "old.bin"), "wb").write(OLD)
meta = {
    "key": key.hex().upper(),
    "payload": payload.hex().upper(),
    "sig": sig.hex().upper(),
    "paylen": len(payload),
    "slot_lba": cluster_lba(2),
    "key_lba": cluster_lba(3),
}
open(os.path.join(wd, "meta.txt"), "w").write(
    "KEY=%s\nPAYLOAD=%s\nSIG=%s\nPAYLEN=%d\nSLOT_LBA=%d\n"
    % (meta["key"], meta["payload"], meta["sig"],
       meta["paylen"], meta["slot_lba"]))
print("DERIVE: paylen=%d key=%s payload=%s sig=%s"
      % (len(payload), meta["key"], meta["payload"], meta["sig"]))
PY

BLOB_HEX=$(tr -d '\n' < "$WORKDIR/blob.hex")
BAD_HEX=$(tr -d '\n' < "$WORKDIR/bad.hex")
PAYLOAD_HEX=$(python3 -c "print(open('$WORKDIR/payload.bin','rb').read().hex().upper())")
OLD_HEX=$(python3 -c "print(open('$WORKDIR/old.bin','rb').read().hex().upper())")
PAYLEN=$(python3 -c "print(len(open('$WORKDIR/payload.bin','rb').read()))")
PAYLEN_HEX=$(printf '%04X' "$PAYLEN")
ck; [[ -n "$BLOB_HEX" ]] || fail "derived blob hex is empty"
ck; [[ -n "$BAD_HEX" ]] || fail "derived bad hex is empty"
ck; [[ "$BLOB_HEX" != "$BAD_HEX" ]] || fail "good and bad plants are identical — BADSIG would be vacuous"
ck; [[ "$PAYLOAD_HEX" != "$OLD_HEX" ]] || fail "payload equals OLD! — apply would be vacuous"
ck; ! grep -Fqi "$PAYLOAD_HEX" "$OTA_SRC" \
  || fail "payload appears in ota.dart — expectation would not be outside"
ck; ! grep -Fqi "$BLOB_HEX" "$OTA_SRC" \
  || fail "blob appears in ota.dart"
echo "DERIVE: blob=${#BLOB_HEX} hex chars; bad differs; payload != OLD!"

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
# directory entry 0 size at root
ROOT_START = 1 + 2 * 16
root = ROOT_START * 512
size = struct.unpack_from("<I", img, root + 28)[0]
off = lba * 512
print(img[off:off + size].hex().upper())
print(size)
PY
}

boot_ota() {
  local label="$1"
  local keys="$2"
  local netflags="$3"
  local img="$WORKDIR/$label.img"
  cp "$WORKDIR/disk.img" "$img" || fail "could not clone disk for $label"
  mkdir -p "$WORKDIR/$label"
  local ser="$WORKDIR/$label/serial.txt"
  local png="$WORKDIR/$label/shot.png"
  local screen="$WORKDIR/$label/screen.txt"
  : >"$ser"
  local port
  port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  # shellcheck disable=SC2086
  timeout 120 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -display none \
    -no-reboot \
    -serial "file:$ser" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    -drive "file=$img,format=raw,if=ide,index=0,media=disk" \
    $netflags \
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
  cp "$ser" "$CORE_DIR/build/ota0-$label-serial.txt"
  cp "$img" "$CORE_DIR/build/ota0-$label.img"
}

FEED_GOOD_KEYS="$(typekeys "ota feed $BLOB_HEX"),ret,wait:2000,$(typekeys "cat slot.txt"),ret,wait:1500"
FEED_BAD_KEYS="$(typekeys "ota feed $BAD_HEX"),ret,wait:2000,$(typekeys "cat slot.txt"),ret,wait:1500"
FEED_NONIC_KEYS="$(typekeys "ota feed $BLOB_HEX"),ret,wait:2000"

echo
echo "=== BOOT good (e1000 + good plant) ==="
boot_ota good "$FEED_GOOD_KEYS" \
  "-net none -netdev user,id=n0,net=10.0.2.0/24 -device e1000,netdev=n0,mac=52:54:00:0A:14:00,romfile="
SER_GOOD="$WORKDIR/good/serial.txt"
ck; grep -q "^OTA OK $PAYLEN_HEX\$" "$SER_GOOD" \
  || { echo "--- serial ---" >&2; cat -v "$SER_GOOD" >&2; \
       fail "good boot did not print OTA OK $PAYLEN_HEX"; }
ck; ! grep -q 'OTA BADSIG' "$SER_GOOD" \
  || fail "good boot printed BADSIG"
ck; ! grep -q 'OTA NONIC' "$SER_GOOD" \
  || fail "good boot printed NONIC with an e1000 present"
ck; grep -q "FS CAT SLOT    .TXT BYTES 000000${PAYLEN_HEX: -2}" "$SER_GOOD" \
  || { echo "--- serial ---" >&2; cat -v "$SER_GOOD" >&2; \
       fail "cat slot.txt did not report the applied size"; }
ck; ! grep -qF 'OLD!' "$SER_GOOD" \
  || fail "good boot serial still shows OLD! after apply"
SLOT_GOOD=$(read_slot "$WORKDIR/good.img" | head -n1)
SIZE_GOOD=$(read_slot "$WORKDIR/good.img" | tail -n1)
ck; [[ "$SLOT_GOOD" == "$PAYLOAD_HEX" ]] \
  || fail "host slot after good apply is $SLOT_GOOD, want $PAYLOAD_HEX"
ck; [[ "$SIZE_GOOD" == "$PAYLEN" ]] \
  || fail "host slot size after good apply is $SIZE_GOOD, want $PAYLEN"
echo "ASSERT: pass  good plant → OTA OK; SLOT.TXT host bytes = payload"

echo
echo "=== BOOT bad (e1000 + flipped sig) ==="
boot_ota bad "$FEED_BAD_KEYS" \
  "-net none -netdev user,id=n0,net=10.0.2.0/24 -device e1000,netdev=n0,mac=52:54:00:0A:14:01,romfile="
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
echo "ASSERT: pass  bad sig → OTA BADSIG; SLOT.TXT still OLD!"

echo
echo "=== BOOT nonic (-net none, good plant) ==="
boot_ota nonic "$FEED_NONIC_KEYS" "-net none"
SER_NONIC="$WORKDIR/nonic/serial.txt"
ck; grep -q 'OTA NONIC' "$SER_NONIC" \
  || { echo "--- serial ---" >&2; cat -v "$SER_NONIC" >&2; \
       fail "nonic boot did not print OTA NONIC"; }
ck; ! grep -q 'OTA OK' "$SER_NONIC" \
  || fail "nonic boot printed OTA OK — NIC gate is vacuous"
SLOT_NONIC=$(read_slot "$WORKDIR/nonic.img" | head -n1)
ck; [[ "$SLOT_NONIC" == "$OLD_HEX" ]] \
  || fail "host slot after NONIC is $SLOT_NONIC, want OLD!"
echo "ASSERT: pass  no NIC → OTA NONIC; SLOT.TXT unchanged"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "OTA0: PASS — good plant applies signed payload to SLOT.TXT; bad sig leaves OLD!; no NIC refuses; host TCP is ota-host/ (ADR-0151); TLS is ota-tls/ (ADR-0154)"
exit 0
