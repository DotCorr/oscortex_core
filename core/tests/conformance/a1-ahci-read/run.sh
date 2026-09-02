#!/usr/bin/env bash
# core/tests/conformance/a1-ahci-read/run.sh
#
# A1 — one AHCI sector read.
# docs/decisions/0077-one-ahci-sector-read.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# The kernel issues READ DMA EXT on the QEMU AHCI HBA (8086:2922) and
# prints the first 16 bytes of LBA 7 plus the HBA-written PRDBC. The
# harness plants those 16 bytes on the disk image at test time — they
# are not a constant in the kernel — and requires the printed hex to
# equal the plant. PRDBC must be 512. An LBA off-by-one cannot pass:
# sectors 0, 6 and 8 hold different decoys.
#
# Anti-vacuity: the plant is 16 non-zero-or-not-all-zero bytes that do
# not appear in ahci.dart. QEMU info pci on the positive boot must
# contain 8086:2922. A missing READ line fails.
#
# Negative control: the same kernel on plain `-M pc` (no `-device ahci`)
# prints `AHCI NONE` and no READ / DATA line.
#
# Coexistence: A1 does not touch ata.dart. IDE PIO remains m6-disk's
# proof. This harness attaches AHCI with `if=none`; it does not replace
# the PIIX3 drive. `ahci` (A0) is still a probe-only command.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "A1-ahci-read: FAIL — $1" >&2; exit 1; }
setup_error() { echo "A1-ahci-read: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=40

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-a1-ahci-read.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
AHCI_SRC="$CORE_DIR/kernel/ahci.dart"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$AHCI_SRC" ]] || setup_error "ahci.dart not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="

ck; [[ -f "$AHCI_SRC" ]] || fail "core/kernel/ahci.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$AHCI_SRC" \
  || fail "ahci.dart is not a part of kmain.dart"
ck; grep -q "^part 'ahci.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'ahci.dart'"

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'ahci.dart';" ]] \
  || fail "part 'ahci.dart' is last in kmain.dart — D7 owns that position"

ck; ! grep -qE '^@bss$|final Bss ' "$AHCI_SRC" \
  || fail "ahci.dart declares a Bss — A1 takes the command list from allocFrame"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — A1 added a help line"
ck; ! grep -q 'ahci' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "A1 added a syscall — the criterion forbids one"

ck; ! grep -qE 'ataRead|ataWrite|ataSelect' "$AHCI_SRC" \
  || fail "ahci.dart calls ATA — IDE is m6-disk's path"
ck; ! grep -q '0x1F0' "$AHCI_SRC" \
  || fail "ahci.dart names port 0x1F0 — a PIO fallback cannot be this path"
ck; grep -q 'void ahciRead()' "$AHCI_SRC" \
  || fail "ahci.dart has no ahciRead"
ck; grep -q 'void ahciReport()' "$AHCI_SRC" \
  || fail "ahci.dart has no ahciReport — A0 must still exist"
ck; grep -q 'ahciAtaReadDmaExt = 0x25' "$AHCI_SRC" \
  || fail "ahci.dart does not name READ DMA EXT 0x25"
ck; grep -q 'ahciPxCi' "$AHCI_SRC" \
  || fail "ahci.dart never names PxCI — the doorbell would be missing"
ck; grep -q 'ahciPxIsTfes' "$AHCI_SRC" \
  || fail "ahci.dart never names PxIS.TFES — a failed command would hang"
ck; grep -q 'pciWrite32' "$AHCI_SRC" \
  || fail "ahci.dart does not call pciWrite32 — BME would stay clear"
ck; grep -q 'allocFrame()' "$AHCI_SRC" \
  || fail "ahci.dart does not call allocFrame — the command list would be in .bss"
ck; grep -q 'vmZeroFrame(mem)' "$AHCI_SRC" \
  || fail "the AHCI frame is not passed to vmZeroFrame"
ck; grep -q 'Volatile<u32>' "$AHCI_SRC" \
  || fail "ahci.dart has no Volatile MMIO — GAP-0071's poll would hoist"
ck; grep -q 'ahciWaitSlot' "$AHCI_SRC" \
  || fail "ahci.dart has no ahciWaitSlot — the completion poll is missing"
ck; grep -q 'ahciReadLba = 7' "$AHCI_SRC" \
  || fail "ahciReadLba is not 7 — the plant would be at the wrong LBA"
ck; grep -q 'ahciStrCmdRead' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch ahci read"

ck; ! grep -q 'ahci' "$CORE_DIR/kernel/ata.dart" \
  || fail "ata.dart mentions ahci — A1 was not supposed to edit the PIO path"

ck; grep -q 'ahciInit();' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain does not call ahciInit"
ck; python3 - "$AHCI_SRC" <<'PY' || fail "ahciInit prints"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void ahciInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("ahciInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc"):
    if token in body:
        print("ahciInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

BSS_AHCI=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /ahci/ {print $6}')
ck; [[ -z "$BSS_AHCI" ]] \
  || fail "kmain.o .bss contains $BSS_AHCI — A1 was not supposed to donate storage"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  ahci.dart is a silent no-@bss part, not last; READ DMA EXT, PxCI+TFES, Volatile, allocFrame, no help, no syscall"

python3 - "$WORKDIR" "$AHCI_SRC" <<'PY' || setup_error "could not create ahci.img"
import os, sys
wd, src_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding="utf-8").read()
magic = os.urandom(16)
if magic == bytes(16):
    sys.exit("planted magic is all zeros — vacuous")
hexmagic = magic.hex().upper()
if hexmagic.lower() in src.lower() or hexmagic in src:
    sys.exit("planted magic already appears in ahci.dart")
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
open(os.path.join(wd, "ahci.img"), "wb").write(img)
open(os.path.join(wd, "magic.hex"), "w").write(hexmagic)
open(os.path.join(wd, "decoy0.hex"), "w").write(decoy0.hex().upper())
print("DERIVE: planted 16 bytes at LBA 7: %s" % hexmagic)
PY
ck; [[ -f "$WORKDIR/ahci.img" ]] || fail "no ahci.img after derive"
ck; [[ -f "$WORKDIR/magic.hex" ]] || fail "no magic.hex after derive"
MAGIC=$(tr -d '\n' < "$WORKDIR/magic.hex")
ck; [[ ${#MAGIC} -eq 32 ]] || fail "planted magic is ${#MAGIC} hex chars, want 32"
ck; ! grep -Fqi "$MAGIC" "$AHCI_SRC" \
  || fail "the planted magic $MAGIC appears in ahci.dart — the expectation would not be coming from outside"

KEYS="a,h,c,i,spc,r,e,a,d,ret,wait:2000"

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
  local -a drive_args=(
    --port "$port" --serial "$ser" --wait-for 'M1 END\n'
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt"
    --monitor-command 'info pci' --monitor-capture "$outdir/info-pci.txt"
    --keys "$KEYS"
  )
  run_status drive_status -- python3 "$DRIVER" "${drive_args[@]}"
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
echo "=== BOOT ahci ==="
drive_session "$WORKDIR/ahci" "ahci" \
  -drive "file=$WORKDIR/ahci.img,if=none,id=a1disk,format=raw" \
  -device ahci,id=ahci \
  -device ide-hd,drive=a1disk,bus=ahci.0
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-ahci"

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/ahci/serial.txt" "$WORKDIR/ahci/info-pci.txt" \
    "$WORKDIR/magic.hex" "$WORKDIR/decoy0.hex" <<'PY' || fail "positive boot did not satisfy A1"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
magic = open(sys.argv[3], "r").read().strip().upper()
decoy0 = open(sys.argv[4], "r").read().strip().upper()
fails = []

if not re.search(r"8086:2922", info, re.I):
    fails.append("QEMU info pci has no 8086:2922 — this is not an ahci boot")
if magic == "0" * 32 or not magic:
    fails.append("planted magic is empty or all zeros — vacuous")
if decoy0 == magic:
    fails.append("decoy at LBA 0 equals the plant")

read_re = re.compile(
    r"^AHCI READ 00000007 PRDBC ([0-9A-F]{8}) DATA ([0-9A-F]{32})$")
reads = [ln for ln in serial.splitlines() if read_re.match(ln)]
nones = [ln for ln in serial.splitlines() if ln == "AHCI NONE"]
if nones:
    fails.append("positive boot printed AHCI NONE — the device was attached")
if len(reads) != 1:
    fails.append("expected one AHCI READ line, found %d: %r" % (len(reads), reads))
    extra = [ln for ln in serial.splitlines() if ln.startswith("AHCI ")]
    if extra:
        fails.append("AHCI lines present: %r" % extra)
else:
    m = read_re.match(reads[0])
    prdbc = m.group(1)
    data = m.group(2)
    if prdbc != "00000200":
        fails.append("PRDBC is %s, expected 00000200 (512) — the HBA did not DMA a sector" % prdbc)
    if data != magic:
        fails.append("DATA %s != planted %s — wrong LBA or not DMA" % (data, magic))
    if data == decoy0:
        fails.append("DATA equals LBA 0's decoy — the LBA did not reach the drive")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    AHCI READ LBA 7 PRDBC 512 DATA %s matches the plant" % magic)
PY
echo "ASSERT: pass  printed DATA equals the host plant at LBA 7; PRDBC is 512"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"8086:2922", info, re.I):
    fails.append("negative boot's info pci still has 8086:2922 — this is not plain -M pc")
if "AHCI NONE" not in serial.splitlines():
    fails.append("negative boot did not print AHCI NONE")
reads = [ln for ln in serial.splitlines() if ln.startswith("AHCI READ")]
if reads:
    fails.append("negative boot printed an AHCI READ line: %r" % reads)
datas = [ln for ln in serial.splitlines() if " DATA " in ln and ln.startswith("AHCI ")]
if datas:
    fails.append("negative boot printed an AHCI DATA line: %r" % datas)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints AHCI NONE and no READ / DATA line"

require_assertions "$ASSERTIONS_REQUIRED"
echo "A1-ahci-read: PASS — ahci read prints LBA 7 DATA matching the host plant and PRDBC 512; plain -M pc prints AHCI NONE; no new .bss, not in help"
exit 0
