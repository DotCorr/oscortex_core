#!/usr/bin/env bash
# core/tests/conformance/a0-ahci/run.sh
#
# A0 — the kernel finds QEMU AHCI on PCI and reads CAP through ABAR.
# docs/decisions/0069-the-kernel-finds-the-ahci-hba.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# The kernel walks bus 0 for class 01/06/01 (or 8086:2922 / 1B36:0001)
# and prints `AHCI <bdf> <vend>:<dev> 01/06/01` plus
# `AHCI BAR <abar> CAP <cap> PORTS <n>`. The harness takes BDF and BAR5
# from QEMU's own `info pci` — not from the kernel, not from a golden —
# and requires both to match. CAP must equal QEMU `xp` of that BAR.
# PORTS must equal CAP.NP + 1.
#
# Anti-vacuity: QEMU's info pci on the positive boot must contain
# 8086:2922. A canned line against a machine with no controller would
# otherwise pass. CAP of 0 is a fail.
#
# Negative control: the same kernel on plain `-M pc` (no `-device ahci`)
# prints `AHCI NONE` and no BDF / BAR line. info pci must lack
# 8086:2922.
#
# Coexistence: A0 does not touch ata.dart. IDE PIO remains m6-disk's
# proof. This harness attaches AHCI with `if=none`; it does not replace
# the PIIX3 drive.
#
# Not a port start, not a command list, not a sector.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "A0-ahci: FAIL — $1" >&2; exit 1; }
setup_error() { echo "A0-ahci: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=25

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-a0-ahci.XXXXXX")" || setup_error "mktemp failed"
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

ck; [[ -f "$CORE_DIR/kernel/ahci.dart" ]] || fail "core/kernel/ahci.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/ahci.dart" \
  || fail "ahci.dart is not a part of kmain.dart"
ck; grep -q "^part 'ahci.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'ahci.dart'"

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'ahci.dart';" ]] \
  || fail "part 'ahci.dart' is last in kmain.dart — D7 owns that position"

ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/ahci.dart" \
  || fail "ahci.dart declares a Bss — A0 retains nothing"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — A0 added a help line"
ck; ! grep -q 'ahci' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "A0 added a syscall — the criterion forbids one"

ck; ! grep -qE 'ataRead|ataWrite|ataSelect' "$CORE_DIR/kernel/ahci.dart" \
  || fail "ahci.dart calls ATA — IDE is m6-disk's path"
ck; grep -q 'void ahciReport()' "$CORE_DIR/kernel/ahci.dart" \
  || fail "ahci.dart has no ahciReport — A0's probe command is missing"

ck; grep -q 'ahciInit();' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain does not call ahciInit"
ck; python3 - "$CORE_DIR/kernel/ahci.dart" <<'PY' || fail "ahciInit prints"
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
  || fail "kmain.o .bss contains $BSS_AHCI — A0 was not supposed to donate storage"

# m5-pci pins the class-name table. A0 must not add a record
# (01/06 already names "sata storage").
ck; grep -q 'const int pciNameCount = 20;' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciNameCount moved — A0 was not supposed to touch pci.dart's table"

ck; ! grep -q 'ahci' "$CORE_DIR/kernel/ata.dart" \
  || fail "ata.dart mentions ahci — A0 was not supposed to edit the PIO path"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  ahci.dart is a silent no-@bss part, not last; no help, no syscall, no command list"

python3 - "$WORKDIR/ahci.img" <<'PY' || setup_error "could not create ahci.img"
import sys
open(sys.argv[1], "wb").write(b"\x00" * (1024 * 1024))
PY

KEYS="a,h,c,i,ret"

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
  if [[ "$label" == "ahci" ]]; then
    drive_args+=(
      --addr-from-serial 'AHCI BAR ([0-9A-F]{8})'
      --monitor-command 'xp /1xw {addr}'
    )
  fi
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
  -drive "file=$WORKDIR/ahci.img,if=none,id=a0disk,format=raw" \
  -device ahci,id=ahci \
  -device ide-hd,drive=a0disk,bus=ahci.0
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-ahci"

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/ahci/serial.txt" "$WORKDIR/ahci/info-pci.txt" <<'PY' || fail "positive boot did not satisfy A0"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []

if not re.search(r"8086:2922", info, re.I):
    fails.append("QEMU info pci has no 8086:2922 — this is not an ahci boot")

bdf = None
bar5 = None
cur_bus = cur_dev = cur_fn = None
cur_is_ahci = False
for ln in info.splitlines():
    bm = re.search(r"Bus\s+(\d+),\s+device\s+(\d+),\s+function\s+(\d+)", ln, re.I)
    if bm:
        cur_bus, cur_dev, cur_fn = int(bm.group(1)), int(bm.group(2)), int(bm.group(3))
        cur_is_ahci = False
        continue
    if cur_bus is None:
        continue
    if re.search(r"PCI device 8086:2922", ln, re.I):
        bdf = (cur_bus, cur_dev, cur_fn)
        cur_is_ahci = True
        continue
    if not cur_is_ahci:
        continue
    bar = re.search(
        r"BAR5:\s+32 bit(?: prefetchable)? memory at 0x([0-9a-f]+)",
        ln, re.I)
    if bar:
        bar5 = int(bar.group(1), 16)

if bdf is None:
    fails.append("could not parse BDF for 8086:2922 out of info pci")
if bar5 is None:
    fails.append("could not parse BAR5 for 8086:2922 out of info pci")

xp_cap = None
for ln in info.splitlines():
    xm = re.search(r"^[0-9a-f]+:\s+0x([0-9a-f]{8})\s*$", ln, re.I)
    if xm:
        xp_cap = int(xm.group(1), 16)
        break

dev_re = re.compile(
    r"^AHCI ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) "
    r"([0-9A-F]{2})/([0-9A-F]{2})/([0-9A-F]{2})$")
bar_re = re.compile(
    r"^AHCI BAR ([0-9A-F]{8}) CAP ([0-9A-F]{8}) PORTS ([0-9A-F]{2})$")

found = [ln for ln in serial.splitlines() if dev_re.match(ln)]
bars = [ln for ln in serial.splitlines() if bar_re.match(ln)]
nones = [ln for ln in serial.splitlines() if ln == "AHCI NONE"]

if nones:
    fails.append("positive boot printed AHCI NONE — the device was attached")
if len(found) != 1:
    fails.append("expected one AHCI device line, found %d: %r" % (len(found), found))
else:
    m = dev_re.match(found[0])
    bus, dev, fn = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)
    ven, did = m.group(4), m.group(5)
    cls, sub, pif = m.group(6), m.group(7), m.group(8)
    if ven != "8086" or did != "2922":
        fails.append("device line is %s:%s, expected 8086:2922" % (ven, did))
    if (cls, sub, pif) != ("01", "06", "01"):
        fails.append("class triple is %s/%s/%s, expected 01/06/01" % (cls, sub, pif))
    if bdf is not None and (bus, dev, fn) != bdf:
        fails.append("printed BDF %02X:%02X.%X != QEMU %02X:%02X.%X"
                     % (bus, dev, fn, bdf[0], bdf[1], bdf[2]))
if len(bars) != 1:
    fails.append("expected one AHCI BAR line, found %d: %r" % (len(bars), bars))
else:
    m = bar_re.match(bars[0])
    kbar = int(m.group(1), 16)
    kcap = int(m.group(2), 16)
    kports = int(m.group(3), 16)
    if bar5 is not None and kbar != bar5:
        fails.append("printed BAR %08X != QEMU BAR5 %08X" % (kbar, bar5))
    if kcap == 0:
        fails.append("printed CAP is 0 — the HBA was not read")
    want_ports = (kcap & 0x1F) + 1
    if kports != want_ports:
        fails.append("printed PORTS %02X != CAP.NP+1 %02X" % (kports, want_ports))
    if xp_cap is not None and kcap != xp_cap:
        fails.append("printed CAP %08X != QEMU xp %08X" % (kcap, xp_cap))
    elif xp_cap is None:
        fails.append("info-pci capture has no xp dword of ABAR")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    AHCI matches QEMU 8086:2922 at %02x:%02x.%x BAR %08x CAP %08x PORTS %02x"
      % (bdf[0], bdf[1], bdf[2], bar5, xp_cap, (xp_cap & 0x1F) + 1))
PY
echo "ASSERT: pass  printed BDF/BAR5 equal info pci; CAP equals QEMU xp; class 01/06/01"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"8086:2922", info, re.I):
    fails.append("negative boot's info pci still has 8086:2922 — this is not plain -M pc")
if "AHCI NONE" not in serial.splitlines():
    fails.append("negative boot did not print AHCI NONE")
found = [ln for ln in serial.splitlines() if ln.startswith("AHCI ") and ln != "AHCI NONE"]
if found:
    fails.append("negative boot printed an AHCI line: %r" % found)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints AHCI NONE and no BDF / BAR line"

require_assertions "$ASSERTIONS_REQUIRED"
echo "A0-ahci: PASS — ahci prints AHCI matching info pci 8086:2922 BAR5/CAP; plain -M pc prints AHCI NONE; no new .bss, not in help"
exit 0
