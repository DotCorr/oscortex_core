#!/usr/bin/env bash
# core/tests/conformance/nvm2/run.sh
#
# NVM2 — one NVMe Identify Controller command.
# docs/decisions/0087-nvme-identify-controller.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# After CAP/VS, the kernel enables an admin queue and issues Identify
# Controller (opcode 06h, CNS=1). It prints the 20-byte SN field as
# 40 hex digits, plus VID and NN from the same Identify buffer. The
# harness invents the QEMU `serial=` at test time — not a constant
# in the kernel — and requires the printed SN to equal that serial
# space-padded to 20 bytes. VID must equal the PCI vendor QEMU
# reports for 1b36:0010. NN must be at least 1.
#
# Anti-vacuity: QEMU info pci on the positive boot must contain
# 1b36:0010. The derived serial must not appear in nvme.dart. A
# canned SN cannot pass.
#
# Negative control: the same kernel on plain `-M pc` (no `-device
# nvme`) prints `NVME NONE` and no `NVME ID ` line. info pci must
# lack 1b36:0010.
#
# Coexistence: NVM2 does not touch ata.dart. IDE PIO remains
# m6-disk's proof. This harness attaches NVMe with `if=none`; it
# does not replace the PIIX3 drive. `nvme` (NVM0/NVM1) is still a
# probe-only command.
#
# NVM3 owns the I/O-queue sector (`nvme rd`). This harness types
# `nvme id` only.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "NVM2: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NVM2: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=50

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-nvm2.XXXXXX")" || setup_error "mktemp failed"
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
  || fail "nvme.dart declares a Bss — NVM2 takes queues from allocFrame"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — NVM2 added a help line"
ck; ! grep -q 'nvme' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "NVM2 added a syscall — the criterion forbids one"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"

ck; ! grep -qE 'ataRead|ataWrite|ataSelect' "$NVME_SRC" \
  || fail "nvme.dart calls ATA — IDE is m6-disk's path"
ck; grep -q 'void nvmeIdentify()' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeIdentify"
ck; grep -q 'void nvmeReport()' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeReport — NVM0/NVM1 must still exist"
ck; grep -q 'nvmeOpcIdentify = 0x06' "$NVME_SRC" \
  || fail "nvme.dart does not name Identify opcode 06h"
ck; grep -q 'nvmeCnsController = 0x01' "$NVME_SRC" \
  || fail "nvme.dart does not name CNS=1"
ck; grep -q 'nvmeRegAqa' "$NVME_SRC" \
  || fail "nvme.dart never names AQA — the admin queue would be missing"
ck; grep -q 'nvmeRegAsq' "$NVME_SRC" \
  || fail "nvme.dart never names ASQ"
ck; grep -q 'nvmeRegAcq' "$NVME_SRC" \
  || fail "nvme.dart never names ACQ"
ck; grep -q 'nvmeRegCc' "$NVME_SRC" \
  || fail "nvme.dart never names CC — the controller would stay disabled"
ck; grep -q 'pciWrite32' "$NVME_SRC" \
  || fail "nvme.dart does not call pciWrite32 — BME would stay clear"
ck; grep -q 'allocFrame()' "$NVME_SRC" \
  || fail "nvme.dart does not call allocFrame — the queues would be in .bss"
ck; grep -q 'vmZeroFrame(asq)' "$NVME_SRC" \
  || fail "the admin SQ frame is not passed to vmZeroFrame"
ck; grep -q 'vmZeroFrame(acq)' "$NVME_SRC" \
  || fail "the admin CQ frame is not passed to vmZeroFrame"
ck; grep -q 'vmZeroFrame(ident)' "$NVME_SRC" \
  || fail "the Identify frame is not passed to vmZeroFrame"
ck; grep -q 'Volatile<u32>' "$NVME_SRC" \
  || fail "nvme.dart has no Volatile MMIO — GAP-0071's poll would hoist"
ck; grep -q 'nvmeWaitCq' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeWaitCq — the completion poll is missing"
ck; grep -q 'nvmeStrCmdId' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch nvme id"

ck; ! grep -q 'nvme' "$CORE_DIR/kernel/ata.dart" \
  || fail "ata.dart mentions nvme — NVM2 was not supposed to edit the PIO path"

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
  || fail "kmain.o .bss contains $BSS_NVME — NVM2 was not supposed to donate storage"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield "$1" 3; }
bssoff()  { bssfield "$1" 2; }
EV_SIZE=$(bsssize wmeventStore)
EV_OFF=$(bssoff wmeventStore)
ck; [[ "$EV_SIZE" -eq 768 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 768"
ck; [[ -n "$EV_OFF" ]] || fail "wmeventStore has no .bss offset in kmain.o"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss — NVM2 stole D7's slot"

ck; grep -q 'const int pciNameCount = 20;' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciNameCount moved — NVM2 was not supposed to touch pci.dart's table"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  nvme.dart is a silent no-@bss part, not last; Identify 06h CNS=1, AQA/ASQ/ACQ, Volatile, allocFrame, no help, no syscall"

python3 - "$WORKDIR" "$NVME_SRC" <<'PY' || setup_error "could not create nvme.img / serial"
import os, sys
wd, src_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding="utf-8").read()
serial = os.urandom(4).hex().upper()
if serial.lower() in src.lower() or serial in src:
    sys.exit("derived serial already appears in nvme.dart")
open(os.path.join(wd, "nvme.img"), "wb").write(b"\x00" * (1024 * 1024))
open(os.path.join(wd, "serial.txt"), "w").write(serial)
want = (serial.encode("ascii") + (b" " * 12))[:20].hex().upper()
open(os.path.join(wd, "sn.hex"), "w").write(want)
print("DERIVE: QEMU nvme serial=%s  Identify SN %s" % (serial, want))
PY
ck; [[ -f "$WORKDIR/nvme.img" ]] || fail "no nvme.img after derive"
ck; [[ -f "$WORKDIR/serial.txt" ]] || fail "no serial.txt after derive"
ck; [[ -f "$WORKDIR/sn.hex" ]] || fail "no sn.hex after derive"
SERIAL=$(tr -d '\n' < "$WORKDIR/serial.txt")
SNHEX=$(tr -d '\n' < "$WORKDIR/sn.hex")
ck; [[ ${#SERIAL} -eq 8 ]] || fail "derived serial is ${#SERIAL} chars, want 8"
ck; [[ ${#SNHEX} -eq 40 ]] || fail "derived SN hex is ${#SNHEX} chars, want 40"
ck; ! grep -Fqi "$SERIAL" "$NVME_SRC" \
  || fail "the derived serial $SERIAL appears in nvme.dart — the expectation would not be coming from outside"

KEYS="n,v,m,e,spc,i,d,ret,wait:2000"

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
  -device "nvme,serial=$SERIAL,drive=nvme0"
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-nvme"

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/nvme/serial.txt" "$WORKDIR/nvme/info-pci.txt" "$SNHEX" <<'PY' || fail "positive boot did not satisfy NVM2"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
want_sn = sys.argv[3].strip().upper()
fails = []

if not re.search(r"1b36:0010", info, re.I):
    fails.append("QEMU info pci has no 1b36:0010 — this is not an nvme boot")

pci_vid = None
for ln in info.splitlines():
    m = re.search(r"PCI device ([0-9a-f]{4}):0010", ln, re.I)
    if m:
        pci_vid = m.group(1).upper()
        break
if pci_vid is None:
    fails.append("could not parse PCI vendor for 1b36:0010 out of info pci")

id_re = re.compile(
    r"^NVME ID SN ([0-9A-F]{40}) VID ([0-9A-F]{4}) NN ([0-9A-F]{8})$")
found = [ln for ln in serial.splitlines() if id_re.match(ln)]
nones = [ln for ln in serial.splitlines() if ln == "NVME NONE"]
tmos = [ln for ln in serial.splitlines() if ln == "NVME TMO"]
stss = [ln for ln in serial.splitlines() if ln.startswith("NVME STS ")]

if nones:
    fails.append("positive boot printed NVME NONE — the device was attached")
if tmos:
    fails.append("positive boot printed NVME TMO — the admin queue did not complete")
if stss:
    fails.append("positive boot printed a status error: %r" % stss)
if len(found) != 1:
    fails.append("expected one NVME ID line, found %d: %r" % (len(found), found))
else:
    m = id_re.match(found[0])
    sn, vid, nn = m.group(1), m.group(2), int(m.group(3), 16)
    if sn != want_sn:
        fails.append("printed SN %s != derived Identify SN %s" % (sn, want_sn))
    if pci_vid is not None and vid != pci_vid:
        fails.append("printed VID %s != QEMU PCI vendor %s" % (vid, pci_vid))
    if nn < 1:
        fails.append("printed NN %08X is 0 — Identify did not return a namespace count" % nn)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    NVME ID SN %s VID %s NN %08X (SN matches QEMU serial=)"
      % (want_sn, pci_vid, nn))
PY
echo "ASSERT: pass  Identify SN equals derived QEMU serial; VID equals info pci; NN >= 1"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1b36:0010", info, re.I):
    fails.append("negative boot's info pci still has 1b36:0010 — this is not plain -M pc")
if "NVME NONE" not in serial.splitlines():
    fails.append("negative boot did not print NVME NONE")
ids = [ln for ln in serial.splitlines() if ln.startswith("NVME ID ")]
if ids:
    fails.append("negative boot printed an Identify success line: %r" % ids)
found = [ln for ln in serial.splitlines() if ln.startswith("NVME ") and ln != "NVME NONE"]
if found:
    fails.append("negative boot printed an NVME line: %r" % found)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints NVME NONE and no Identify success line"

require_assertions "$ASSERTIONS_REQUIRED"
echo "NVM2: PASS — nvme id prints Identify SN matching QEMU serial=; VID matches info pci; NN >= 1; plain -M pc prints NVME NONE; no new .bss, not in help"
exit 0
