#!/usr/bin/env bash
# core/tests/conformance/g0-virtgpu/run.sh
#
# G0 — The VirtIO GPU is found and its capabilities are read.
# docs/design/gpu.md §5/G0, ADR-0059.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# The kernel walks PCI for vendor 0x1AF4 device 0x1050, follows the
# capability list at offset 0x34, and prints each vendor capability's
# cfg_type, BAR index, offset, length, and (for NOTIFY_CFG) the
# notify_off_multiplier. The harness takes BAR bases from QEMU's own
# `info pci` — not from the kernel, not from a golden — and requires
# every printed AT address to sit inside that BAR.
#
# Anti-vacuity: fewer than five vendor capabilities is a fail; cfg_type
# 1–5 must each appear exactly once; notify_off_multiplier must be 4.
#
# Negative control: the same kernel on `-vga std` (no VirtIO GPU) must
# print `VIRTIO NONE` and must not print a capability table.
#
# Coexistence: `fb` still sets 800x600x32 on BOTH boots. G1 sets
# bus-master from the same command; that does not leave VGA
# compatibility mode, so the Bochs/dispi path — including sit-in — is
# not a casualty of recognising the device.
#
# This is not G1's criterion (that is g1-virtgpu), not G2 (DRIVER_OK),
# not G4 (a pixel), and not a claim that virtio-gpu-pci (class 03/80)
# has a framebuffer.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G0-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G0-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=25

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g0.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

# ===========================================================================
# Step 1 — build.
# ===========================================================================
echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

# ===========================================================================
# Step 2 — structural. Everything answerable without booting.
# ===========================================================================
echo
echo "=== STRUCTURAL ==="

ck; [[ -f "$CORE_DIR/kernel/virtgpu.dart" ]] || fail "core/kernel/virtgpu.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart is not a part of kmain.dart"
ck; grep -q "^part 'virtgpu.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'virtgpu.dart'"

# Not last: D2 owns kbdq.dart at the end of the part list.
LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'virtgpu.dart';" ]] \
  || fail "part 'virtgpu.dart' is last in kmain.dart — D2 owns that position"

# No donated .bss. A new block would move every harness that measures
# "from my block to the end".
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart declares @bss — G0 retains nothing"

# Hidden command: no help line, no new syscall.
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G0 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G0 added a syscall — the criterion forbids one"

# G1 owns pciWrite32. G2 writes device_status. G0/G1/G2 still forbid
# virtqueues and 2D commands.
ck; grep -q 'void pciWrite32' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciWrite32 is missing from pci.dart — G1"
ck; ! grep -qE 'queue_enable\s*=|RESOURCE_CREATE_2D|VIRTIO_GPU_CMD' \
      "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart programs a virtqueue or a 2D command — that is G3/G4"

# Boot path is silent.
ck; grep -q 'virtgpuInit();' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain does not call virtgpuInit"
ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit prints"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc"):
    if token in body:
        print("virtgpuInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

# G0 donates no .bss. D7 owns the last block (`wmeventStore`); do not
# steal that position and do not require any particular earlier block
# to be last — that is someone else's merge.
BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G0 was not supposed to donate storage"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  virtgpu.dart is a silent no-@bss part, not last; no help, no syscall, no device programming"

# ===========================================================================
# Step 3 — two boots: virtio-vga (positive) and std VGA (negative).
# ===========================================================================

# virtgpu then fb. fb is the coexistence claim: G0 must not steal scanout.
KEYS="v,i,r,t,g,p,u,ret,wait:400,f,b,ret,wait:800"

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
echo "=== BOOT virtio-vga ==="
drive_session "$WORKDIR/virtio" "virtio-vga" -vga virtio
echo
echo "=== BOOT std VGA (negative) ==="
drive_session "$WORKDIR/std" "std-vga" -vga std

# ===========================================================================
# Step 4 — the G0 criterion against QEMU's own info pci.
# ===========================================================================
echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/virtio/serial.txt" "$WORKDIR/virtio/info-pci.txt" <<'PY' || fail "positive boot did not satisfy G0"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []

# QEMU must actually have attached the device. A kernel that printed a
# canned table against -vga std would otherwise look like a pass if this
# check were skipped.
if not re.search(r"1af4:1050", info, re.I):
    fails.append("QEMU info pci has no 1af4:1050 — this is not a virtio-vga boot")

# Parse BAR bases and inclusive ends out of the virtio function only.
bars = {}
cur = None
for ln in info.splitlines():
    dm = re.search(r"PCI device ([0-9a-f]+):([0-9a-f]+)", ln, re.I)
    if dm:
        cur = (dm.group(1).lower(), dm.group(2).lower())
        continue
    if cur != ("1af4", "1050"):
        continue
    bm = re.search(
        r"BAR(\d+):\s+(?:32|64) bit(?: prefetchable)? memory at 0x([0-9a-f]+)\s+\[0x([0-9a-f]+)\]",
        ln, re.I)
    if not bm:
        continue
    idx = int(bm.group(1))
    base = int(bm.group(2), 16)
    end = int(bm.group(3), 16)
    if base == 0xFFFFFFFFFFFFFFFF or end < base:
        continue
    bars[idx] = (base, end - base + 1)

if len(bars) < 1:
    fails.append("parsed no memory BARs for 1af4:1050 out of info pci")

dev_re = re.compile(
    r"^VIRTIO ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) "
    r"([0-9A-F]{2})/([0-9A-F]{2})/([0-9A-F]{2})$")
cap_re = re.compile(
    r"^VIRTIO CAP ([0-9A-F]{2}) BAR ([0-9A-F]{2}) "
    r"OFF ([0-9A-F]{8}) LEN ([0-9A-F]{8})"
    r"(?: MUL ([0-9A-F]{8}))? AT ([0-9A-F]{8})$")

# Device line only. G1 prints CMD; G2 prints FEAT / QUEUES / STATUS
# (and refusals). Those must not count as a second device.
devs = [ln for ln in serial.splitlines() if dev_re.match(ln)]
caps = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CAP ")]

if "VIRTIO NONE" in serial.splitlines():
    fails.append("positive boot printed VIRTIO NONE — the device was attached")

if len(devs) != 1:
    fails.append("expected one VIRTIO device line, found %d: %r" % (len(devs), devs))
else:
    m = dev_re.match(devs[0])
    if not m:
        fails.append("unparseable VIRTIO device line: %r" % devs[0])
    else:
        ven, did = m.group(4), m.group(5)
        if ven != "1AF4" or did != "1050":
            fails.append("device line is %s:%s, expected 1AF4:1050" % (ven, did))

# Anti-vacuity: fewer than five vendor capabilities is a fail.
if len(caps) < 5:
    fails.append("printed %d vendor capabilities, need at least 5" % len(caps))

types = []
for ln in caps:
    m = cap_re.match(ln)
    if not m:
        fails.append("unparseable VIRTIO CAP line: %r" % ln)
        continue
    cfg = int(m.group(1), 16)
    bar = int(m.group(2), 16)
    mul = m.group(5)
    at = int(m.group(6), 16)
    types.append(cfg)
    if cfg == 2:
        if mul is None:
            fails.append("NOTIFY_CFG line has no MUL: %r" % ln)
        elif int(mul, 16) != 4:
            fails.append("notify_off_multiplier is 0x%s, expected 4" % mul)
    if bar not in bars:
        fails.append("CAP type %d names BAR %d, which info pci does not give "
                     "a memory BAR for (have %s)" % (cfg, bar, sorted(bars)))
        continue
    base, length = bars[bar]
    if at < base or at >= base + length:
        fails.append("CAP type %d AT %08X is outside BAR %d [%08X, %08X)"
                     % (cfg, at, bar, base, base + length))

from collections import Counter
c = Counter(types)
for t in (1, 2, 3, 4, 5):
    n = c.get(t, 0)
    if n != 1:
        fails.append("cfg_type %d appeared %d time(s), expected exactly once" % (t, n))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    device 1AF4:1050, %d vendor caps, types 1-5 once each, MUL 4," % len(caps))
print("    every AT inside the BAR QEMU reported")
PY
echo "ASSERT: pass  capability table names QEMU's BARs; types 1-5 once each; MUL 4"

# Existing fb path still works on the same virtio-vga device.
ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/virtio/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on virtio-vga — G0 broke the dispi path"
echo "ASSERT: pass  fb still sets 800x600x32 on virtio-vga (existing Bochs path, zero programming from G0)"

# ===========================================================================
# Step 5 — negative control: -vga std, no VirtIO GPU.
# ===========================================================================

ck; python3 - "$WORKDIR/std/serial.txt" "$WORKDIR/std/info-pci.txt" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1af4:1050", info, re.I):
    fails.append("negative boot's info pci still has 1af4:1050 — this is not -vga std")
if "VIRTIO NONE" not in serial.splitlines():
    fails.append("negative boot did not print VIRTIO NONE")
caps = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CAP ")]
if caps:
    fails.append("negative boot printed a capability table: %r" % caps)
dev_re = re.compile(
    r"^VIRTIO ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) ")
devs = [ln for ln in serial.splitlines() if dev_re.match(ln)]
if devs:
    fails.append("negative boot printed a VIRTIO device line: %r" % devs)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO NONE and no capability table"

ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/std/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on -vga std — G0 broke Bochs"
echo "ASSERT: pass  fb / Bochs still works on -vga std (sit-in's machine)"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G0-virtgpu: PASS — probe virtio-vga, five vendor caps match QEMU info pci, MUL 4; -vga std prints VIRTIO NONE; fb still works on both boots"
