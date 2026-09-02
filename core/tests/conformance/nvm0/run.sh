#!/usr/bin/env bash
# core/tests/conformance/nvm0/run.sh
#
# NVM0 — the kernel finds QEMU NVMe on PCI.
# docs/decisions/0071-nvme-is-recognised.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# The kernel walks bus 0 for class 01/08/02 (NVMe I/O controller) and
# prints `NVME <bdf> <vend>:<dev> 01/08/02` plus `NVME BAR <addr>`.
# The harness takes the function and BAR0 from QEMU's own `info pci`
# — not from the kernel, not from a golden — and requires both to match.
#
# Anti-vacuity: QEMU's info pci on the positive boot must contain
# 1b36:0010. A canned line against a machine with no controller would
# otherwise pass.
#
# Negative control: the same kernel on plain `-M pc` (no `-device nvme`)
# prints `NVME NONE` and no BDF / BAR line. info pci must lack
# 1b36:0010.
#
# Coexistence: NVM0 does not touch ata.dart. IDE PIO remains m6-disk's
# proof. This harness attaches NVMe with `if=none`; it does not replace
# the PIIX3 drive.
#
# Not an I/O queue, not a sector. NVM2 owns Identify (`nvme id`).
# This harness types `nvme` only, so NVM0's device and BAR lines
# stay a read.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "NVM0: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NVM0: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=25

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-nvm0.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="

ck; [[ -f "$CORE_DIR/kernel/nvme.dart" ]] || fail "core/kernel/nvme.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/nvme.dart" \
  || fail "nvme.dart is not a part of kmain.dart"
ck; grep -q "^part 'nvme.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'nvme.dart'"

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'nvme.dart';" ]] \
  || fail "part 'nvme.dart' is last in kmain.dart — D7 owns that position"

ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/nvme.dart" \
  || fail "nvme.dart declares a Bss — NVM0 retains nothing"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — NVM0 added a help line"
ck; ! grep -q 'nvme' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "NVM0 added a syscall — the criterion forbids one"

ck; ! grep -qE 'ataRead|ataWrite|ataSelect' "$CORE_DIR/kernel/nvme.dart" \
  || fail "nvme.dart calls ATA — IDE is m6-disk's path"
# NVM2 writes 0xCFC / AQA / CC.EN from nvmeIdentify. NVM0's print
# path must still be a read: nvmeReport must not do that work.
ck; python3 - "$CORE_DIR/kernel/nvme.dart" <<'PY' || fail "nvmeReport writes config space"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void nvmeReport\(\) \{(.*)\n\}", src, re.S)
if not m:
    print("nvmeReport is missing", file=sys.stderr); sys.exit(1)
# Stop at the next top-level function so NVM2's body is excluded.
body = m.group(1).split("\n@bare")[0].split("\nvoid ")[0]
for token in ("pciWrite32", "port_outl"):
    if token in body:
        print("nvmeReport mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY
ck; python3 - "$CORE_DIR/kernel/nvme.dart" <<'PY' || fail "nvmeReport programmes a queue"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void nvmeReport\(\) \{(.*)\n\}", src, re.S)
if not m:
    print("nvmeReport is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nvoid ")[0]
for token in ("nvmeRegAqa", "nvmeRegAsq", "nvmeRegAcq", "nvmeRegCc"):
    if token in body:
        print("nvmeReport mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

ck; grep -q 'nvmeInit();' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain does not call nvmeInit"
ck; python3 - "$CORE_DIR/kernel/nvme.dart" <<'PY' || fail "nvmeInit prints"
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
  || fail "kmain.o .bss contains $BSS_NVME — NVM0 was not supposed to donate storage"

# m5-pci pins the class-name table. NVM0 must not add a record
# (01/08 already names "nvme storage").
ck; grep -q 'const int pciNameCount = 20;' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciNameCount moved — NVM0 was not supposed to touch pci.dart's table"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  nvme.dart is a silent no-@bss part, not last; no help, no syscall, no queues"

# QEMU requires a backing store and a serial. if=none so this is not
# the PIIX3 IDE drive m6-disk owns.
python3 - "$WORKDIR/nvme.img" <<'PY' || setup_error "could not create nvme.img"
import sys
open(sys.argv[1], "wb").write(b"\x00" * (1024 * 1024))
PY

KEYS="n,v,m,e,ret"

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
echo "=== BOOT nvme ==="
drive_session "$WORKDIR/nvme" "nvme" \
  -drive "file=$WORKDIR/nvme.img,if=none,id=nvme0,format=raw" \
  -device nvme,serial=foo,drive=nvme0
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-nvme"

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/nvme/serial.txt" "$WORKDIR/nvme/info-pci.txt" <<'PY' || fail "positive boot did not satisfy NVM0"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []

if not re.search(r"1b36:0010", info, re.I):
    fails.append("QEMU info pci has no 1b36:0010 — this is not an nvme boot")

bdf = None
bar0 = None
cur_bus = cur_dev = cur_fn = None
cur_is_nvme = False
for ln in info.splitlines():
    bm = re.search(r"Bus\s+(\d+),\s+device\s+(\d+),\s+function\s+(\d+)", ln, re.I)
    if bm:
        cur_bus, cur_dev, cur_fn = int(bm.group(1)), int(bm.group(2)), int(bm.group(3))
        cur_is_nvme = False
        continue
    if cur_bus is None:
        continue
    if re.search(r"PCI device 1b36:0010", ln, re.I):
        bdf = (cur_bus, cur_dev, cur_fn)
        cur_is_nvme = True
        continue
    if not cur_is_nvme:
        continue
    bar = re.search(
        r"BAR0:\s+(?:64 bit(?: prefetchable)?|32 bit(?: prefetchable)?) memory at 0x([0-9a-f]+)",
        ln, re.I)
    if bar:
        bar0 = int(bar.group(1), 16)

if bdf is None:
    fails.append("could not parse BDF for 1b36:0010 out of info pci")
if bar0 is None:
    fails.append("could not parse BAR0 for 1b36:0010 out of info pci")

dev_re = re.compile(
    r"^NVME ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) "
    r"([0-9A-F]{2})/([0-9A-F]{2})/([0-9A-F]{2})$")
bar_re = re.compile(r"^NVME BAR ([0-9A-F]{8})$")

found = [ln for ln in serial.splitlines() if dev_re.match(ln)]
bars = [ln for ln in serial.splitlines() if bar_re.match(ln)]
nones = [ln for ln in serial.splitlines() if ln == "NVME NONE"]

if nones:
    fails.append("positive boot printed NVME NONE — the device was attached")
if len(found) != 1:
    fails.append("expected one NVME device line, found %d: %r" % (len(found), found))
else:
    m = dev_re.match(found[0])
    bus, dev, fn = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)
    ven, did = m.group(4), m.group(5)
    cls, sub, pif = m.group(6), m.group(7), m.group(8)
    if ven != "1B36" or did != "0010":
        fails.append("device line is %s:%s, expected 1B36:0010" % (ven, did))
    if (cls, sub, pif) != ("01", "08", "02"):
        fails.append("class triple is %s/%s/%s, expected 01/08/02" % (cls, sub, pif))
    if bdf is not None and (bus, dev, fn) != bdf:
        fails.append("printed BDF %02X:%02X.%X != QEMU %02X:%02X.%X"
                     % (bus, dev, fn, bdf[0], bdf[1], bdf[2]))
if len(bars) != 1:
    fails.append("expected one NVME BAR line, found %d: %r" % (len(bars), bars))
else:
    kbar = int(bar_re.match(bars[0]).group(1), 16)
    if bar0 is not None and kbar != bar0:
        fails.append("printed BAR %08X != QEMU BAR0 %08X" % (kbar, bar0))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    NVME matches QEMU 1b36:0010 at %02x:%02x.%x BAR %08x" % (bdf + (bar0,)))
PY
echo "ASSERT: pass  printed BDF and BAR0 equal QEMU info pci; class 01/08/02"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1b36:0010", info, re.I):
    fails.append("negative boot's info pci still has 1b36:0010 — this is not plain -M pc")
if "NVME NONE" not in serial.splitlines():
    fails.append("negative boot did not print NVME NONE")
found = [ln for ln in serial.splitlines() if ln.startswith("NVME ") and ln != "NVME NONE"]
if found:
    fails.append("negative boot printed an NVME line: %r" % found)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints NVME NONE and no BDF / BAR line"

require_assertions "$ASSERTIONS_REQUIRED"
echo "NVM0: PASS — nvme prints NVME matching info pci 1b36:0010 BAR0; plain -M pc prints NVME NONE; no new .bss, not in help"
exit 0
