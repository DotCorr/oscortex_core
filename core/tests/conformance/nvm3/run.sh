#!/usr/bin/env bash
# core/tests/conformance/nvm3/run.sh
#
# NVM3 — one NVMe I/O-queue sector read.
# docs/decisions/0088-one-nvme-sector-read.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# After Identify, the kernel creates an I/O CQ/SQ pair and issues one
# NVM Read (opcode 02h) of LBA 7. It prints the first 16 bytes of that
# PRP buffer. The harness plants those 16 bytes on the disk image at
# test time — they are not a constant in the kernel — and requires
# the printed hex to equal the plant. An LBA off-by-one cannot pass:
# sectors 0, 6 and 8 hold different decoys. A second image with a
# different plant must print the second plant, not the first.
#
# Anti-vacuity: QEMU info pci on the positive boot must contain
# 1b36:0010. The plant must not appear in nvme.dart. Create I/O CQ
# (05h), Create I/O SQ (01h) and NVM Read (02h) must be named. A
# memcpy of Identify cannot satisfy the plant.
#
# Negative control: the same kernel on plain `-M pc` (no `-device
# nvme`) prints `NVME NONE` and no `NVME RD ` line. info pci must
# lack 1b36:0010.
#
# Coexistence: NVM3 does not touch ata.dart or ahci.dart. IDE PIO
# remains m6-disk's proof. AHCI remains a1-ahci-read's. This harness
# attaches NVMe with `if=none`; it does not replace the PIIX3 drive.
# `nvme` and `nvme id` are unchanged.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "NVM3: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NVM3: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=50

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-nvm3.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
NVME_SRC="$CORE_DIR/kernel/nvme.dart"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$NVME_SRC" ]] || setup_error "nvme.dart not found"

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
  || fail "nvme.dart declares a Bss — NVM3 takes queues from allocFrame"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — NVM3 added a help line"
ck; ! grep -q 'nvme' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "NVM3 added a syscall — the criterion forbids one"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"

ck; ! grep -qE 'ataRead|ataWrite|ataSelect' "$NVME_SRC" \
  || fail "nvme.dart calls ATA — IDE is m6-disk's path"
ck; grep -q 'void nvmeIdentify()' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeIdentify — NVM2 must still exist"
ck; grep -q 'void nvmeReport()' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeReport — NVM0/NVM1 must still exist"
ck; grep -q 'void nvmeRead()' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeRead"
ck; grep -q 'nvmeOpcIdentify = 0x06' "$NVME_SRC" \
  || fail "nvme.dart does not name Identify opcode 06h"
ck; grep -q 'nvmeOpcCreateCq = 0x05' "$NVME_SRC" \
  || fail "nvme.dart does not name Create I/O CQ opcode 05h"
ck; grep -q 'nvmeOpcCreateSq = 0x01' "$NVME_SRC" \
  || fail "nvme.dart does not name Create I/O SQ opcode 01h"
ck; grep -q 'nvmeOpcRead = 0x02' "$NVME_SRC" \
  || fail "nvme.dart does not name NVM Read opcode 02h"
ck; grep -q 'nvmeReadLba = 7' "$NVME_SRC" \
  || fail "nvmeReadLba is not 7 — the plant would be at the wrong LBA"
ck; grep -q 'nvmeRegAqa' "$NVME_SRC" \
  || fail "nvme.dart never names AQA — the admin queue would be missing"
ck; grep -q 'pciWrite32' "$NVME_SRC" \
  || fail "nvme.dart does not call pciWrite32 — BME would stay clear"
ck; grep -q 'allocFrame()' "$NVME_SRC" \
  || fail "nvme.dart does not call allocFrame — the queues would be in .bss"
ck; grep -q 'vmZeroFrame(iosq)' "$NVME_SRC" \
  || fail "the I/O SQ frame is not passed to vmZeroFrame"
ck; grep -q 'vmZeroFrame(iocq)' "$NVME_SRC" \
  || fail "the I/O CQ frame is not passed to vmZeroFrame"
ck; grep -q 'vmZeroFrame(data)' "$NVME_SRC" \
  || fail "the sector frame is not passed to vmZeroFrame"
ck; grep -q 'Volatile<u32>' "$NVME_SRC" \
  || fail "nvme.dart has no Volatile MMIO — GAP-0071's poll would hoist"
ck; grep -q 'nvmeWaitCqOff' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeWaitCqOff — the completion poll is missing"
ck; grep -q 'nvmeStrCmdRd' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch nvme rd"
ck; grep -q 'nvmeStrCmdId' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch nvme id — NVM2 must still exist"

ck; python3 - "$NVME_SRC" <<'PY' || fail "nvmeRead copies Identify into the sector print"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void nvmeRead\(\) \{(.*)\n\}", src, re.S)
if not m:
    print("nvmeRead is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nvoid ")[0]
# The print loop must load from `data`, not from `ident`.
if "ident + i" in body or "ident + u64(i)" in body:
    print("nvmeRead prints from ident — that is Identify, not a sector", file=sys.stderr)
    sys.exit(1)
if "fromAddress(ident" in body.split("uartWrite(Rodata.addressOf(nvmeStrRd)")[-1]:
    print("the DATA print reads ident", file=sys.stderr)
    sys.exit(1)
if "nvmeBuildRead(iosq, data)" not in body:
    print("nvmeRead does not submit NVM Read with the sector frame as PRP1", file=sys.stderr)
    sys.exit(1)
if "nvmeBuildCreateCq" not in body or "nvmeBuildCreateSq" not in body:
    print("nvmeRead does not create an I/O queue pair", file=sys.stderr)
    sys.exit(1)
PY

ck; ! grep -q 'nvme' "$CORE_DIR/kernel/ata.dart" \
  || fail "ata.dart mentions nvme — NVM3 was not supposed to edit the PIO path"
ck; ! grep -qE 'nvmeFind|nvmeRead|nvmeIdentify|nvmeReport|nvmeKick' "$CORE_DIR/kernel/ahci.dart" \
  || fail "ahci.dart calls NVMe — NVM3 was not supposed to edit the AHCI path"

ck; grep -q 'nvmeInit();' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain does not call nvmeInit"
ck; python3 - "$NVME_SRC" <<'PY' || fail "nvmeInit prints"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void nvmeInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("nvmeInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc"):
    if token in body:
        print("nvmeInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

BSS_NVME=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /nvme/ {print $6}')
ck; [[ -z "$BSS_NVME" ]] \
  || fail "kmain.o .bss contains $BSS_NVME — NVM3 was not supposed to donate storage"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield "$1" 3; }
bssoff()  { bssfield "$1" 2; }
EV_SIZE=$(bsssize wmeventStore)
EV_OFF=$(bssoff wmeventStore)
ck; [[ "$EV_SIZE" -eq 384 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 384"
ck; [[ -n "$EV_OFF" ]] || fail "wmeventStore has no .bss offset in kmain.o"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss — NVM3 stole D7's slot"

ck; grep -q 'const int pciNameCount = 20;' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciNameCount moved — NVM3 was not supposed to touch pci.dart's table"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  nvme.dart is a silent no-@bss part, not last; Create CQ/SQ + NVM Read 02h of LBA 7, Volatile, allocFrame, no help, no syscall"

python3 - "$WORKDIR" "$NVME_SRC" <<'PY' || setup_error "could not create nvme images / plants"
import os, sys
wd, src_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding="utf-8").read()

def plant_one(name):
    magic = os.urandom(16)
    if magic == bytes(16):
        sys.exit("planted magic is all zeros — vacuous")
    hexmagic = magic.hex().upper()
    if hexmagic.lower() in src.lower() or hexmagic in src:
        sys.exit("planted magic already appears in nvme.dart")
    decoy0 = os.urandom(16)
    decoy6 = os.urandom(16)
    decoy8 = os.urandom(16)
    if decoy0 == magic or decoy6 == magic or decoy8 == magic:
        sys.exit("a decoy collided with the plant")
    img = bytearray(b"\x5A" * (1024 * 1024))
    img[0:16] = decoy0
    img[6 * 512:6 * 512 + 16] = decoy6
    img[7 * 512:7 * 512 + 16] = magic
    img[8 * 512:8 * 512 + 16] = decoy8
    open(os.path.join(wd, name + ".img"), "wb").write(img)
    open(os.path.join(wd, name + ".hex"), "w").write(hexmagic)
    open(os.path.join(wd, name + ".decoy0"), "w").write(decoy0.hex().upper())
    return hexmagic

a = plant_one("plantA")
b = plant_one("plantB")
if a == b:
    sys.exit("the two plants collided")
print("DERIVE: planted 16 bytes at LBA 7 image A: %s" % a)
print("DERIVE: planted 16 bytes at LBA 7 image B: %s" % b)
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

KEYS="n,v,m,e,spc,r,d,ret,wait:3000"

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
echo "=== BOOT nvme plant A ==="
drive_session "$WORKDIR/bootA" "plant-A" \
  -drive "file=$WORKDIR/plantA.img,if=none,id=nvme0,format=raw" \
  -device nvme,serial=nvm3a,drive=nvme0
echo
echo "=== BOOT nvme plant B (wrong image vs A) ==="
drive_session "$WORKDIR/bootB" "plant-B" \
  -drive "file=$WORKDIR/plantB.img,if=none,id=nvme0,format=raw" \
  -device nvme,serial=nvm3b,drive=nvme0
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-nvme"

echo
echo "=== CRITERION ==="

check_read() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY' || return 1
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
magic = open(sys.argv[3], "r").read().strip().upper()
other = open(sys.argv[4], "r").read().strip().upper()
decoy0 = open(sys.argv[5], "r").read().strip().upper()
fails = []

if not re.search(r"1b36:0010", info, re.I):
    fails.append("QEMU info pci has no 1b36:0010 — this is not an nvme boot")
if magic == "0" * 32 or not magic:
    fails.append("planted magic is empty or all zeros — vacuous")
if magic == other:
    fails.append("this plant equals the other image — wrong-image is vacuous")
if decoy0 == magic:
    fails.append("decoy at LBA 0 equals the plant")

read_re = re.compile(r"^NVME RD 00000007 DATA ([0-9A-F]{32})$")
reads = [ln for ln in serial.splitlines() if read_re.match(ln)]
nones = [ln for ln in serial.splitlines() if ln == "NVME NONE"]
tmos = [ln for ln in serial.splitlines() if ln == "NVME TMO"]
stss = [ln for ln in serial.splitlines() if ln.startswith("NVME STS ")]

if nones:
    fails.append("positive boot printed NVME NONE — the device was attached")
if tmos:
    fails.append("positive boot printed NVME TMO — the I/O queue did not complete")
if stss:
    fails.append("positive boot printed a status error: %r" % stss)
if len(reads) != 1:
    fails.append("expected one NVME RD line, found %d: %r" % (len(reads), reads))
    extra = [ln for ln in serial.splitlines() if ln.startswith("NVME ")]
    if extra:
        fails.append("NVME lines present: %r" % extra)
else:
    data = read_re.match(reads[0]).group(1)
    if data != magic:
        fails.append("DATA %s != planted %s — wrong LBA or not a sector DMA" % (data, magic))
    if data == other:
        fails.append("DATA equals the other image's plant — the backing store did not matter")
    if data == decoy0:
        fails.append("DATA equals LBA 0's decoy — the LBA did not reach the drive")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    NVME RD LBA 7 DATA %s matches the plant" % magic)
PY
}

ck; check_read "$WORKDIR/bootA/serial.txt" "$WORKDIR/bootA/info-pci.txt" \
    "$WORKDIR/plantA.hex" "$WORKDIR/plantB.hex" "$WORKDIR/plantA.decoy0" \
  || fail "plant-A boot did not satisfy NVM3"
echo "ASSERT: pass  plant A DATA equals the host plant at LBA 7"

ck; check_read "$WORKDIR/bootB/serial.txt" "$WORKDIR/bootB/info-pci.txt" \
    "$WORKDIR/plantB.hex" "$WORKDIR/plantA.hex" "$WORKDIR/plantB.decoy0" \
  || fail "plant-B boot did not satisfy NVM3 (wrong image vs A)"
echo "ASSERT: pass  plant B DATA equals image B and does not equal image A"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1b36:0010", info, re.I):
    fails.append("negative boot's info pci still has 1b36:0010 — this is not plain -M pc")
if "NVME NONE" not in serial.splitlines():
    fails.append("negative boot did not print NVME NONE")
rds = [ln for ln in serial.splitlines() if ln.startswith("NVME RD ")]
if rds:
    fails.append("negative boot printed an NVME RD success line: %r" % rds)
found = [ln for ln in serial.splitlines() if ln.startswith("NVME ") and ln != "NVME NONE"]
if found:
    fails.append("negative boot printed an NVME line: %r" % found)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints NVME NONE and no RD success line"

require_assertions "$ASSERTIONS_REQUIRED"
echo "NVM3: PASS — nvme rd prints LBA 7 DATA matching the host plant; a second image prints its own plant; plain -M pc prints NVME NONE; no new .bss, not in help"
exit 0
