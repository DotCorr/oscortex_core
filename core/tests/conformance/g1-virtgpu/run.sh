#!/usr/bin/env bash
# core/tests/conformance/g1-virtgpu/run.sh
#
# G1 — Bus mastering is on, and the kernel can prove it.
# docs/design/gpu.md §5/G1, ADR-0065.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# pciWrite32 exists. The hidden `virtgpu` command sets bit 2 of the
# command register and prints the dword before and after. The harness
# derives the "before" value from QEMU: it dumps configuration offset
# 0x04 through the q35 ECAM window (`xp/1xw` at
# 0xb0000000 + (dev << 15) + 4) BEFORE the kernel writes.
#
# Anti-vacuity: the two printed values must differ; before must have
# bit 2 clear; after must have it set.
#
# Negative control: the same kernel on `-vga std` (no VirtIO GPU) must
# print `VIRTIO NONE`, must not print a CMD line, and must not print
# STUCK. A kernel that never writes cannot pass the after-bit assertion.
#
# Coexistence: `fb` still sets 800x600x32 on both boots. BME is a bus
# bit, not SET_SCANOUT.
#
# This is not G2 (DRIVER_OK / features), not G3 (a virtqueue), and not
# a pixel.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G1-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G1-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=26

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g1.XXXXXX")" || setup_error "mktemp failed"
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
ck; grep -q 'void pciWrite32' "$CORE_DIR/kernel/pci.dart" \
  || fail "pci.dart has no pciWrite32"
ck; grep -q 'pciWrite32(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not call pciWrite32"
ck; grep -q 'virtgpuEnableMaster' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuEnableMaster"
ck; grep -q 'virtgpuStrStuck' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no read-back refusal string"
ck; grep -q 'virtgpuCmdMaster' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name the bus-master bit"

# The write is the command, not boot. Init stays silent and empty.
ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc", "pciWrite32", "virtgpuEnableMaster"):
    if token in body:
        print("virtgpuInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

# Not last, no donated .bss, no help line, no syscall, no G3/G4.
LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'virtgpu.dart';" ]] \
  || fail "part 'virtgpu.dart' is last in kmain.dart — D7 owns that position"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart declares @bss — G1 retains nothing"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G1 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G1 added a syscall — the criterion forbids one"
ck; ! grep -qE 'queue_enable\s*=|RESOURCE_CREATE_2D|VIRTIO_GPU_CMD' \
      "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart programs a virtqueue or a 2D command — that is G3/G4"

BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G1 was not supposed to donate storage"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  pciWrite32 in pci.dart; command-path BME; no help, no .bss, no G2/G3"

# ===========================================================================
# Step 3 — two boots: q35+virtio (positive) and std VGA (negative).
# ===========================================================================

# virtgpu then fb. fb is the coexistence claim: BME must not steal scanout.
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
  local extra=()
  if [[ "$label" == "virtio-q35" ]]; then
    # q35 ECAM: command register of bus 0 fn 0 device D is
    # 0xb0000000 + (D << 15) + 4. Dump every slot BEFORE the keys so
    # the harness does not need the slot number in advance.
    extra+=(--monitor-command-before "info pci")
    local d=0
    while [[ $d -lt 32 ]]; do
      extra+=(--monitor-command-before "$(printf 'xp/1xw 0x%x' $((0xb0000000 + (d << 15) + 4)))")
      d=$((d + 1))
    done
    extra+=(--monitor-command "info pci" --monitor-capture "$outdir/monitor.txt")
  else
    extra+=(--monitor-command "info pci" --monitor-capture "$outdir/info-pci.txt")
  fi
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for 'M1 END\n' \
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt" \
    "${extra[@]+"${extra[@]}"}" \
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
echo "=== BOOT q35 + virtio-vga ==="
drive_session "$WORKDIR/virtio" "virtio-q35" -machine q35 -vga virtio
echo
echo "=== BOOT std VGA (negative) ==="
drive_session "$WORKDIR/std" "std-vga" -vga std

# ===========================================================================
# Step 4 — the G1 criterion against QEMU's own ECAM dump.
# ===========================================================================
echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/virtio/serial.txt" "$WORKDIR/virtio/monitor.txt" <<'PY' || fail "positive boot did not satisfy G1"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
mon = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []

# Split the capture at the first after-keystroke marker so "before"
# info pci is QEMU's view before the kernel wrote.
before_blob = mon
after_idx = mon.find("\n=== info pci ===")
if after_idx < 0:
    after_idx = mon.find("=== info pci ===")
if after_idx >= 0:
    before_blob = mon[:after_idx]

if not re.search(r"1af4:1050", before_blob, re.I):
    fails.append("QEMU info pci (before) has no 1af4:1050 — this is not a virtio-vga boot")

# Slot of 1af4:1050 from the before-keys info pci.
slot = None
cur_dev = None
for ln in before_blob.splitlines():
    sm = re.search(r"Bus\s+(\d+),\s+device\s+(\d+),\s+function\s+(\d+):", ln)
    if sm:
        cur_dev = int(sm.group(2))
        continue
    if cur_dev is None:
        continue
    if re.search(r"PCI device 1af4:1050", ln, re.I):
        slot = cur_dev
        break

if slot is None:
    fails.append("could not parse 1af4:1050 slot out of before-keys info pci")
    slot = -1

ecam_addr = 0xB0000000 + (slot << 15) + 4
ecam_re = re.compile(
    r"=== before: xp/1xw 0x%x ===\s*\n[0-9a-fA-F]+:\s+0x([0-9a-fA-F]+)"
    % ecam_addr, re.I)
em = ecam_re.search(before_blob)
if not em:
    fails.append("no before-keys xp of ECAM 0x%X (slot %d)" % (ecam_addr, slot))
    ecam_before = None
else:
    ecam_before = int(em.group(1), 16)

before_re = re.compile(r"^VIRTIO CMD BEFORE ([0-9A-F]{8})$")
after_re = re.compile(r"^VIRTIO CMD AFTER ([0-9A-F]{8})$")
befores = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CMD BEFORE ")]
afters = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CMD AFTER ")]

if "VIRTIO NONE" in serial.splitlines():
    fails.append("positive boot printed VIRTIO NONE — the device was attached")
if "VIRTIO CMD STUCK" in serial:
    fails.append("kernel printed VIRTIO CMD STUCK — bit 2 did not stick")

if len(befores) != 1:
    fails.append("expected one CMD BEFORE line, found %d: %r" % (len(befores), befores))
    k_before = None
else:
    m = before_re.match(befores[0])
    if not m:
        fails.append("unparseable CMD BEFORE: %r" % befores[0])
        k_before = None
    else:
        k_before = int(m.group(1), 16)

if len(afters) != 1:
    fails.append("expected one CMD AFTER line, found %d: %r" % (len(afters), afters))
    k_after = None
else:
    m = after_re.match(afters[0])
    if not m:
        fails.append("unparseable CMD AFTER: %r" % afters[0])
        k_after = None
    else:
        k_after = int(m.group(1), 16)

if k_before is not None and k_after is not None:
    if k_before == k_after:
        fails.append("CMD BEFORE and AFTER are equal (0x%08X) — anti-vacuity" % k_before)
    if (k_before & 4) != 0:
        fails.append("CMD BEFORE 0x%08X has bit 2 set — firmware should leave BME clear" % k_before)
    if (k_after & 4) == 0:
        fails.append("CMD AFTER 0x%08X has bit 2 clear — bus-master did not land" % k_after)
    if ecam_before is not None and k_before != ecam_before:
        fails.append("CMD BEFORE 0x%08X != ECAM 0x%08X at 0x%X"
                     % (k_before, ecam_before, ecam_addr))
    if ecam_before is not None and (ecam_before & 4) != 0:
        fails.append("ECAM before 0x%08X already has BME — the write is not what set it"
                     % ecam_before)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    slot %d ECAM 0x%X before 0x%08X; kernel before 0x%08X after 0x%08X"
      % (slot, ecam_addr, ecam_before, k_before, k_after))
PY
echo "ASSERT: pass  ECAM before has BME clear; kernel after has it set; values differ"

ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/virtio/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on q35 virtio — G1 broke the dispi path"
echo "ASSERT: pass  fb still sets 800x600x32 on virtio-vga after BME"

# ===========================================================================
# Step 5 — negative control: -vga std, no VirtIO GPU, no write.
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
cmds = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CMD")]
if cmds:
    fails.append("negative boot printed a CMD line: %r" % cmds)
if "VIRTIO CMD STUCK" in serial:
    fails.append("negative boot printed STUCK with no device")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO NONE and no CMD line"

ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/std/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on -vga std — G1 broke Bochs"
echo "ASSERT: pass  fb / Bochs still works on -vga std (sit-in's machine)"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G1-virtgpu: PASS — pciWrite32 sets BME; ECAM before has bit 2 clear; kernel after has it set; -vga std writes nothing; fb still works"
