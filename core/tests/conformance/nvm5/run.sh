#!/usr/bin/env bash
# core/tests/conformance/nvm5/run.sh
#
# NVM5 — FAT sectors move through the NVMe I/O queue.
# docs/decisions/0090-fat-sectors-move-through-nvme.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# A FAT16 volume is attached as QEMU `-device nvme`. The kernel mounts
# it and `cat plant.txt` prints a file whose bytes the harness planted
# at test time. Those sectors move through the NVM I/O queue, not ATA
# PIO: this boot has no IDE drive, so a PIO fallback cannot produce
# the plant.
#
# The file is two clusters with a hole. Cluster 2 holds a 512-byte
# filler; cluster 20 holds 16 random bytes. A reader that ignores the
# FAT and walks forward, or that still reads NVM3's LBA 7, cannot
# pass. A second image must print its own plant, not the first.
#
# Anti-vacuity: QEMU info pci on the positive boot must contain
# 1b36:0010. The plant must not appear in fat.dart or nvme.dart.
# fatDiskRead must name both nvmeIoRead and ataReadInto. FAT NVME
# must print. Derived file bytes are not a kernel constant.
#
# Negative control: the same kernel on plain `-M pc` (no NVMe, no
# IDE disk) prints FS ERR 01 and no FAT NVME line. info pci must
# lack 1b36:0010. The plant must not appear in that serial.
#
# Coexistence: NVM5 does not take m6-disk / m14-fat / m15 / m16 off
# ATA PIO. Those machines have no NVMe, so fatDiskPick chooses ATA.
# nvm0–nvm4 and both AHCI harnesses stay the proofs they were.
# `nvme`, `nvme id`, `nvme rd` and `nvme wr` are unchanged.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "NVM5: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NVM5: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=60

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-nvm5.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
NVME_SRC="$CORE_DIR/kernel/nvme.dart"
FAT_SRC="$CORE_DIR/kernel/fat.dart"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$NVME_SRC" ]] || setup_error "nvme.dart not found"
[[ -f "$FAT_SRC" ]] || setup_error "fat.dart not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="

ck; [[ -f "$NVME_SRC" ]] || fail "core/kernel/nvme.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$NVME_SRC" \
  || fail "nvme.dart is not a part of kmain.dart"
ck; grep -q "^part 'nvme.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'nvme.dart'"

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'nvme.dart';" ]] \
  || fail "part 'nvme.dart' is last in kmain.dart — D7 owns that position"

ck; ! grep -qE '^@bss$|final Bss ' "$NVME_SRC" \
  || fail "nvme.dart declares a Bss — NVM5 takes queues from allocFrame"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — NVM5 added a help line"
ck; ! grep -q 'nvme' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "NVM5 added a syscall — the criterion forbids one"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"

ck; grep -q 'u64 fatDiskRead(' "$FAT_SRC" \
  || fail "fat.dart has no fatDiskRead — FAT would still call ATA only"
ck; grep -q 'u64 fatDiskPick(' "$FAT_SRC" \
  || fail "fat.dart has no fatDiskPick — the NVMe vs ATA choice is missing"
ck; grep -q 'nvmeIoRead' "$FAT_SRC" \
  || fail "fat.dart does not call nvmeIoRead"
ck; grep -q 'nvmeIoWrite' "$FAT_SRC" \
  || fail "fat.dart does not call nvmeIoWrite"
ck; grep -q 'ataReadInto' "$FAT_SRC" \
  || fail "fat.dart no longer names ataReadInto — the ATA fallback is gone"
ck; grep -q 'ataWriteFrom(lba, src)' "$FAT_SRC" \
  || fail "fatWriteSector lost ataWriteFrom(lba, src) — m16's grep would fail"
ck; grep -q 'nvmeFind()' "$FAT_SRC" \
  || fail "fatDiskPick does not call nvmeFind — the choice would be a constant"
ck; grep -q 'nvmeIoSetup()' "$FAT_SRC" \
  || fail "fatDiskPick does not call nvmeIoSetup"
ck; grep -q 'u64 nvmeIoRead(' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeIoRead"
ck; grep -q 'u64 nvmeIoWrite(' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeIoWrite"
ck; grep -q 'u64 nvmeIoSetup()' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeIoSetup"
ck; grep -q 'void nvmeBuildIo(' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeBuildIo — FAT would be stuck on LBA 7/11"
ck; grep -q 'nvmeOpcRead = 0x02' "$NVME_SRC" \
  || fail "nvme.dart does not name NVM Read opcode 02h"
ck; grep -q 'nvmeOpcWrite = 0x01' "$NVME_SRC" \
  || fail "nvme.dart does not name NVM Write opcode 01h"
ck; grep -q 'void nvmeWrite()' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeWrite — NVM4 must still exist"
ck; grep -q 'void nvmeRead()' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeRead — NVM3 must still exist"
ck; ! grep -qE 'ataRead|ataWrite|ataSelect' "$NVME_SRC" \
  || fail "nvme.dart calls ATA — IDE is m6-disk's path"
ck; ! grep -qE 'nvmeFind|nvmeRead|nvmeWrite|nvmeIdentify|nvmeReport|nvmeIo' "$CORE_DIR/kernel/ahci.dart" \
  || fail "ahci.dart calls NVMe — NVM5 was not supposed to edit the AHCI path"
ck; grep -q 'const int fatStoreBytes = 1824;' "$FAT_SRC" \
  || fail "fat_store is no longer 1824 — NVM5 was not supposed to grow it"
ck; grep -q 'const int fatMetaDev = 30;' "$FAT_SRC" \
  || fail "fatMetaDev is not spare word 30"
ck; grep -q 'const int fatMetaNvme = 31;' "$FAT_SRC" \
  || fail "fatMetaNvme is not spare word 31"

ck; python3 - "$FAT_SRC" <<'PY' || fail "fatDiskRead does not dispatch NVMe then ATA"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"u64 fatDiskRead\(u64 lba, u64 dst\) \{(.*)", src, re.S)
if not m:
    print("fatDiskRead is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nu64 ")[0]
if "nvmeIoRead(fatMeta(u64(fatMetaNvme)), lba, dst)" not in body:
    print("fatDiskRead does not call nvmeIoRead with the session word", file=sys.stderr)
    sys.exit(1)
if "ataReadInto(lba, dst)" not in body:
    print("fatDiskRead does not fall back to ataReadInto", file=sys.stderr)
    sys.exit(1)
if "fatDiskPick()" not in body:
    print("fatDiskRead does not call fatDiskPick", file=sys.stderr)
    sys.exit(1)
PY

ck; python3 - "$FAT_SRC" <<'PY' || fail "fatWriteSector lost the ATA write or the NVMe write"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"u64 fatWriteSector\(u64 lba, u64 src\) \{(.*)", src, re.S)
if not m:
    print("fatWriteSector is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nu64 ")[0]
if "ataWriteFrom(lba, src)" not in body:
    print("fatWriteSector does not call ataWriteFrom(lba, src)", file=sys.stderr)
    sys.exit(1)
if "nvmeIoWrite(fatMeta(u64(fatMetaNvme)), lba, src)" not in body:
    print("fatWriteSector does not call nvmeIoWrite", file=sys.stderr)
    sys.exit(1)
PY

FAT_STORE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="fatStore"{print $3+0; exit}')
ck; [[ "$FAT_STORE" -eq 1824 ]] || fail "fatStore is ${FAT_STORE:-missing} bytes, expected 1824"

BSS_NVME=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /nvme/ {print $6}')
ck; [[ -z "$BSS_NVME" ]] \
  || fail "kmain.o .bss contains $BSS_NVME — NVM5 was not supposed to donate storage"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield "$1" 3; }
bssoff()  { bssfield "$1" 2; }
EV_SIZE=$(bsssize wmeventStore)
EV_OFF=$(bssoff wmeventStore)
ck; [[ "$EV_SIZE" -eq 1920 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 1920"
ck; [[ -n "$EV_OFF" ]] || fail "wmeventStore has no .bss offset in kmain.o"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss — NVM5 stole D7's slot"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  FAT chooses NVMe via nvmeFind else ATA; fat_store 1824; no new .bss; wmeventStore last; no help; no syscall"

python3 - "$WORKDIR" "$NVME_SRC" "$FAT_SRC" <<'PY' || setup_error "could not create FAT-on-NVMe images / plants"
import os, struct, sys

wd, nvme_src, fat_src = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(nvme_src, encoding="utf-8").read() + open(fat_src, encoding="utf-8").read()

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
CLUS2 = 2
CLUS20 = 20
FILE_SIZE = 512 + 16

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
    struct.pack_into("<I", b, 39, 0x05C0FFEE)
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

def plant_one(name):
    magic = os.urandom(16)
    filler = os.urandom(512)
    decoy3 = os.urandom(16)
    if magic == bytes(16) or filler[:16] == magic or decoy3 == magic:
        sys.exit("plant collided with filler/decoy or is all zeros")
    hexmagic = magic.hex().upper()
    if hexmagic.lower() in src.lower() or hexmagic in src:
        sys.exit("planted magic already appears in fat.dart/nvme.dart")
    img = bytearray(TOTAL * SECTOR)
    img[0:SECTOR] = boot_sector()
    put_fat(img, 0, 0xFFF8)
    put_fat(img, 1, 0xFFFF)
    put_fat(img, CLUS2, CLUS20)
    put_fat(img, CLUS20, 0xFFFF)
    # directory: PLANT.TXT at index 0
    e = bytearray(32)
    e[0:11] = b"PLANT   TXT"
    e[11] = 0x20
    struct.pack_into("<H", e, 26, CLUS2)
    struct.pack_into("<I", e, 28, FILE_SIZE)
    struct.pack_into("<H", e, 24, ((2026 - 1980) << 9) | (1 << 5) | 1)
    root = ROOT_START * SECTOR
    img[root:root + 32] = e
    img[cluster_lba(CLUS2) * SECTOR:cluster_lba(CLUS2) * SECTOR + 512] = filler
    img[cluster_lba(CLUS20) * SECTOR:cluster_lba(CLUS20) * SECTOR + 16] = magic
    img[cluster_lba(3) * SECTOR:cluster_lba(3) * SECTOR + 16] = decoy3
    open(os.path.join(wd, name + ".img"), "wb").write(img)
    open(os.path.join(wd, name + ".hex"), "w").write(hexmagic)
    open(os.path.join(wd, name + ".filler"), "wb").write(filler)
    open(os.path.join(wd, name + ".decoy3"), "w").write(decoy3.hex().upper())
    open(os.path.join(wd, name + ".meta"), "w").write(
        "data_start=%d clus2_lba=%d clus20_lba=%d clus3_lba=%d\n"
        % (DATA_START, cluster_lba(CLUS2), cluster_lba(CLUS20), cluster_lba(3)))
    return hexmagic

a = plant_one("plantA")
b = plant_one("plantB")
if a == b:
    sys.exit("the two plants collided")
print("DERIVE: planted 16 bytes at cluster 20 image A: %s" % a)
print("DERIVE: planted 16 bytes at cluster 20 image B: %s" % b)
print("DERIVE: PLANT.TXT is clusters 2 -> 20, size 528")
PY
ck; [[ -f "$WORKDIR/plantA.img" ]] || fail "no plantA.img after derive"
ck; [[ -f "$WORKDIR/plantB.img" ]] || fail "no plantB.img after derive"
MAGIC_A=$(tr -d '\n' < "$WORKDIR/plantA.hex")
MAGIC_B=$(tr -d '\n' < "$WORKDIR/plantB.hex")
ck; [[ ${#MAGIC_A} -eq 32 ]] || fail "plant A is ${#MAGIC_A} hex chars, want 32"
ck; [[ ${#MAGIC_B} -eq 32 ]] || fail "plant B is ${#MAGIC_B} hex chars, want 32"
ck; [[ "$MAGIC_A" != "$MAGIC_B" ]] || fail "plant A equals plant B — wrong-image would be vacuous"
ck; ! grep -Fqi "$MAGIC_A" "$NVME_SRC" \
  || fail "plant A $MAGIC_A appears in nvme.dart — the expectation would not be coming from outside"
ck; ! grep -Fqi "$MAGIC_B" "$NVME_SRC" \
  || fail "plant B $MAGIC_B appears in nvme.dart — the expectation would not be coming from outside"
ck; ! grep -Fqi "$MAGIC_A" "$FAT_SRC" \
  || fail "plant A $MAGIC_A appears in fat.dart — the expectation would not be coming from outside"
ck; ! grep -Fqi "$MAGIC_B" "$FAT_SRC" \
  || fail "plant B $MAGIC_B appears in fat.dart — the expectation would not be coming from outside"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

KEYS="$(typekeys "cat plant.txt"),ret,wait:8000"

drive_session() {
  local outdir="$1" label="$2"
  shift 2
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
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
echo "=== BOOT nvme plant A ==="
drive_session "$WORKDIR/bootA" "plant-A" \
  -drive "file=$WORKDIR/plantA.img,if=none,id=nvme0,format=raw,cache=writeback" \
  -device nvme,serial=nvm5a,drive=nvme0
echo
echo "=== BOOT nvme plant B (wrong image vs A) ==="
drive_session "$WORKDIR/bootB" "plant-B" \
  -drive "file=$WORKDIR/plantB.img,if=none,id=nvme0,format=raw,cache=writeback" \
  -device nvme,serial=nvm5b,drive=nvme0
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-nvme"

echo
echo "=== CRITERION ==="

check_cat() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY' || return 1
import re, sys

serial = open(sys.argv[1], "rb").read()
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
magic = open(sys.argv[3], "r").read().strip().upper()
other = open(sys.argv[4], "r").read().strip().upper()
filler = open(sys.argv[5], "rb").read()
decoy3 = open(sys.argv[6], "r").read().strip().upper()
meta = open(sys.argv[7], "r").read().strip()
fails = []

text = serial.decode("latin-1")
if not re.search(r"1b36:0010", info, re.I):
    fails.append("QEMU info pci has no 1b36:0010 — this is not an nvme boot")
if magic == "0" * 32 or not magic:
    fails.append("planted magic is empty or all zeros — vacuous")
if magic == other:
    fails.append("this plant equals the other image — wrong-image is vacuous")
if "data_start=65" not in meta and "clus20_lba=" not in meta:
    fails.append("image meta missing")
m = re.search(r"clus20_lba=(\d+)", meta)
if m and int(m.group(1)) == 7:
    fails.append("cluster 20 landed at LBA 7 — NVM3's plant would be vacuous here")

if "FAT NVME" not in text.splitlines() and "FAT NVME" not in text:
    # printed as FAT NVME\n
    if b"FAT NVME\n" not in serial:
        fails.append("positive boot did not print FAT NVME — ATA would also be silent")
if "NVME NONE" in text.splitlines():
    fails.append("positive boot printed NVME NONE — the device was attached")

if b"FS OPEN PLANT   .TXT" not in serial and "FS OPEN PLANT" not in text:
    fails.append("positive boot did not open PLANT.TXT: missing FS OPEN")

# File bytes sit between the FS CAT header line and FS CAT END.
start = serial.find(b"FS CAT PLANT")
end = serial.find(b"FS CAT END ")
if start < 0 or end < 0 or end <= start:
    fails.append("missing FS CAT / FS CAT END framing")
    extra = [ln for ln in text.splitlines() if ln.startswith("FS ") or ln.startswith("FAT ")]
    if extra:
        fails.append("FS/FAT lines present: %r" % extra[:20])
else:
    nl = serial.find(b"\n", start)
    if nl < 0 or nl >= end:
        fails.append("FS CAT header has no newline before FS CAT END")
    else:
        payload = serial[nl + 1:end]
        if len(payload) != 528:
            fails.append("cat payload is %d bytes, want 528" % len(payload))
        else:
            if payload[:512] != filler:
                fails.append("first cluster (filler) did not come back — chain or transport is wrong")
            got = payload[512:].hex().upper()
            if got != magic:
                fails.append("second cluster is %s, want planted %s — FAT did not follow 2 -> 20" % (got, magic))
            if got == other:
                fails.append("second cluster equals the other image's plant")
            if got == decoy3:
                fails.append("second cluster equals cluster 3's decoy — the hole was not walked")
            if payload[:16].hex().upper() == magic:
                fails.append("plant appears at the start of the file — it should be in cluster 20")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    FS CAT payload matches filler + plant %s" % magic)
PY
}

ck; check_cat "$WORKDIR/bootA/serial.txt" "$WORKDIR/bootA/info-pci.txt" \
    "$WORKDIR/plantA.hex" "$WORKDIR/plantB.hex" \
    "$WORKDIR/plantA.filler" "$WORKDIR/plantA.decoy3" "$WORKDIR/plantA.meta" \
  || fail "plant-A boot did not satisfy NVM5"
echo "ASSERT: pass  plant A cat equals filler + host plant through NVMe"

ck; check_cat "$WORKDIR/bootB/serial.txt" "$WORKDIR/bootB/info-pci.txt" \
    "$WORKDIR/plantB.hex" "$WORKDIR/plantA.hex" \
    "$WORKDIR/plantB.filler" "$WORKDIR/plantB.decoy3" "$WORKDIR/plantB.meta" \
  || fail "plant-B boot did not satisfy NVM5 (wrong image vs A)"
echo "ASSERT: pass  plant B cat equals image B and does not equal image A"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" \
    "$WORKDIR/plantA.hex" "$WORKDIR/plantB.hex" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read()
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
magic_a = bytes.fromhex(open(sys.argv[3]).read().strip())
magic_b = bytes.fromhex(open(sys.argv[4]).read().strip())
text = serial.decode("latin-1")
fails = []
if re.search(r"1b36:0010", info, re.I):
    fails.append("negative boot's info pci still has 1b36:0010 — this is not plain -M pc")
if b"FAT NVME" in serial:
    fails.append("negative boot printed FAT NVME — there is no NVMe")
if "FS ERR 01" not in text:
    fails.append("negative boot did not print FS ERR 01 (boot sector unreadable)")
opens = [ln for ln in text.splitlines() if ln.startswith("FS OPEN ")]
if opens:
    fails.append("negative boot opened a file: %r" % opens)
cats = [ln for ln in text.splitlines() if ln.startswith("FS CAT ")]
if cats:
    fails.append("negative boot printed an FS CAT line: %r" % cats)
if magic_a in serial or magic_b in serial:
    fails.append("negative boot serial contains a plant — that is a canned constant")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints FS ERR 01 and no FAT NVME / no plant"

require_assertions "$ASSERTIONS_REQUIRED"
echo "NVM5: PASS — cat plant.txt on an NVMe FAT volume prints derived filler+plant; a second image prints its own; plain -M pc is FS ERR 01; ATA fallback stays for machines with no NVMe"
exit 0
