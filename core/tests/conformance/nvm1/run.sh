#!/usr/bin/env bash
# core/tests/conformance/nvm1/run.sh
#
# NVM1 — the kernel reads NVMe CAP and VS through BAR0.
# docs/decisions/0074-the-kernel-reads-nvme-cap-and-vs.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# After the NVM0 device and BAR lines, the kernel loads CAP (BAR0+0,
# 8 bytes) and VS (BAR0+8, 4 bytes) and prints them with MQES and TO
# decoded from CAP. The harness takes the BAR from QEMU's own
# `info pci` and CAP/VS from QEMU `xp /3xw` of that BAR — not from
# the kernel, not from a golden of QEMU's defaults.
#
# Anti-vacuity: CAP of 0 is a fail. Printed CAP/VS must equal the
# live xp. MQES and TO must equal the fields in that CAP. VS major
# must be a documented NVM Express version (1 or 2). CAP.CSS bit 0
# (NVM command set) must be set. A canned qword cannot pass.
#
# Negative control: the same kernel on plain `-M pc` (no `-device
# nvme`) prints `NVME NONE` and no CAP line. info pci must lack
# 1b36:0010.
#
# Coexistence: NVM1 does not touch ata.dart. IDE PIO remains
# m6-disk's proof. This harness attaches NVMe with `if=none`; it
# does not replace the PIIX3 drive. NVM0's `NVME BAR <addr>` line
# is unchanged so nvm0 still passes.
#
# Not an I/O queue, not a sector. NVM2 owns Identify (`nvme id`).
# This harness types `nvme` only, so NVM1's CAP/VS line stays a
# register read.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "NVM1: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NVM1: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=28

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-nvm1.XXXXXX")" || setup_error "mktemp failed"
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
  || fail "nvme.dart declares a Bss — NVM1 retains nothing"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — NVM1 added a help line"
ck; ! grep -q 'nvme' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "NVM1 added a syscall — the criterion forbids one"

ck; ! grep -qE 'ataRead|ataWrite|ataSelect' "$CORE_DIR/kernel/nvme.dart" \
  || fail "nvme.dart calls ATA — IDE is m6-disk's path"
# NVM2 writes 0xCFC / AQA / CC.EN from nvmeIdentify. NVM1's print
# path must still be a load: nvmeReport / nvmeReportCap must not
# store through Volatile or programme a queue.
ck; python3 - "$CORE_DIR/kernel/nvme.dart" <<'PY' || fail "nvmeReport writes config space"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void nvmeReport\(\) \{(.*)\n\}", src, re.S)
if not m:
    print("nvmeReport is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nvoid ")[0]
for token in ("pciWrite32", "port_outl", "nvmeRegPut"):
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
ck; python3 - "$CORE_DIR/kernel/nvme.dart" <<'PY' || fail "nvmeReportCap stores through Volatile"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void nvmeReportCap\(u64 bar\) \{(.*?)\n\}", src, re.S)
if not m:
    print("nvmeReportCap is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
if re.search(r"\.value\s*=", body):
    print("nvmeReportCap stores through Volatile", file=sys.stderr)
    sys.exit(1)
PY
ck; grep -q 'nvmeRegVs' "$CORE_DIR/kernel/nvme.dart" \
  || fail "nvme.dart has no VS offset — NVM1 did not land"
ck; grep -q 'Volatile<u32>' "$CORE_DIR/kernel/nvme.dart" \
  || fail "nvme.dart has no Volatile MMIO load — NVM1 is a register read"

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
  || fail "kmain.o .bss contains $BSS_NVME — NVM1 was not supposed to donate storage"

ck; grep -q 'const int pciNameCount = 20;' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciNameCount moved — NVM1 was not supposed to touch pci.dart's table"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  nvme.dart is a silent no-@bss part, not last; no help, no syscall, CAP/VS MMIO read only"

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
  local -a drive_args=(
    --port "$port" --serial "$ser" --wait-for 'M1 END\n'
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt"
    --monitor-command 'info pci' --monitor-capture "$outdir/info-pci.txt"
    --keys "$KEYS"
  )
  if [[ "$label" == "nvme" ]]; then
    drive_args+=(
      --addr-from-serial 'NVME BAR ([0-9A-F]{8})'
      --monitor-command 'xp /3xw {addr}'
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
echo "=== BOOT nvme ==="
drive_session "$WORKDIR/nvme" "nvme" \
  -drive "file=$WORKDIR/nvme.img,if=none,id=nvme0,format=raw" \
  -device nvme,serial=foo,drive=nvme0
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-nvme"

echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/nvme/serial.txt" "$WORKDIR/nvme/info-pci.txt" <<'PY' || fail "positive boot did not satisfy NVM1"
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

# xp /3xw: CAP lo, CAP hi, VS. QEMU prints one or more 0xXXXXXXXX
# words after the address.
xp_words = []
for ln in info.splitlines():
    if re.match(r"^=== ", ln):
        continue
    if re.search(r"\b0x[0-9a-f]{8}\b", ln, re.I) and re.search(r"^[0-9a-f]+:", ln, re.I):
        xp_words.extend(int(x, 16) for x in re.findall(r"0x([0-9a-f]{8})", ln, re.I))

if len(xp_words) < 3:
    fails.append("info-pci capture has no xp /3xw of BAR0 (need CAP lo/hi and VS)")
    xp_cap = None
    xp_vs = None
else:
    xp_cap = xp_words[0] | (xp_words[1] << 32)
    xp_vs = xp_words[2]

dev_re = re.compile(
    r"^NVME ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) "
    r"([0-9A-F]{2})/([0-9A-F]{2})/([0-9A-F]{2})$")
bar_re = re.compile(r"^NVME BAR ([0-9A-F]{8})$")
cap_re = re.compile(
    r"^NVME CAP ([0-9A-F]{16}) VS ([0-9A-F]{8}) "
    r"MQES ([0-9A-F]{4}) TO ([0-9A-F]{2})$")

found = [ln for ln in serial.splitlines() if dev_re.match(ln)]
bars = [ln for ln in serial.splitlines() if bar_re.match(ln)]
caps = [ln for ln in serial.splitlines() if cap_re.match(ln)]
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

if len(caps) != 1:
    fails.append("expected one NVME CAP line, found %d: %r" % (len(caps), caps))
else:
    m = cap_re.match(caps[0])
    kcap = int(m.group(1), 16)
    kvs = int(m.group(2), 16)
    kmqes = int(m.group(3), 16)
    kto = int(m.group(4), 16)
    if kcap == 0:
        fails.append("printed CAP is 0 — the controller was not read")
    if kvs == 0:
        fails.append("printed VS is 0 — the controller was not read")
    vs_major = (kvs >> 16) & 0xFFFF
    if vs_major not in (1, 2):
        fails.append("VS major %04X is not a documented NVM Express version" % vs_major)
    want_mqes = kcap & 0xFFFF
    want_to = (kcap >> 24) & 0xFF
    if kmqes != want_mqes:
        fails.append("printed MQES %04X != CAP bits 15:0 %04X" % (kmqes, want_mqes))
    if kto != want_to:
        fails.append("printed TO %02X != CAP bits 31:24 %02X" % (kto, want_to))
    if want_mqes < 1:
        fails.append("CAP.MQES is 0 — not a usable admin-queue size")
    if want_to == 0:
        fails.append("CAP.TO is 0 — spec timeout is missing")
    css = (kcap >> 37) & 0xFF
    if (css & 1) == 0:
        fails.append("CAP.CSS bit 0 is clear — NVM command set is not supported")
    mpsmin = (kcap >> 48) & 0x0F
    mpsmax = (kcap >> 52) & 0x0F
    if mpsmin > mpsmax:
        fails.append("CAP.MPSMIN %X > MPSMAX %X" % (mpsmin, mpsmax))
    if xp_cap is not None and kcap != xp_cap:
        fails.append("printed CAP %016X != QEMU xp %016X" % (kcap, xp_cap))
    if xp_vs is not None and kvs != xp_vs:
        fails.append("printed VS %08X != QEMU xp %08X" % (kvs, xp_vs))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    NVME CAP %016X VS %08X MQES %04X TO %02X (matches QEMU xp)"
      % (kcap, kvs, kmqes, kto))
PY
echo "ASSERT: pass  CAP/VS equal QEMU xp of BAR0; MQES/TO match CAP; VS is a spec version"

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
echo "ASSERT: pass  plain -M pc prints NVME NONE and no BDF / BAR / CAP line"

require_assertions "$ASSERTIONS_REQUIRED"
echo "NVM1: PASS — nvme prints CAP/VS matching QEMU xp of 1b36:0010 BAR0; MQES/TO match CAP; VS is a spec version; plain -M pc prints NVME NONE; no new .bss, not in help"
exit 0
