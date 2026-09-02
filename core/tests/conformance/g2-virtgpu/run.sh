#!/usr/bin/env bash
# core/tests/conformance/g2-virtgpu/run.sh
#
# G2 — The device negotiates, and reaches DRIVER_OK.
# docs/design/gpu.md §5/G2, ADR-0067.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# The hidden `virtgpu` command runs VIRTIO §3.1.1 against COMMON_CFG:
# reset-and-poll, ACKNOWLEDGE, DRIVER, read both feature words, accept
# only VIRTIO_F_VERSION_1 (bit 32), FEATURES_OK, re-read, DRIVER_OK.
# It prints the offered feature halves, num_queues, and the final
# device_status.
#
# The harness requires:
#   * final status exactly 0x0F (ACK|DRIVER|FEATURES_OK|DRIVER_OK)
#   * FAILED (0x80) and DEVICE_NEEDS_RESET (0x40) clear
#   * offered feature bit 32 set (VERSION_1)
#   * num_queues >= 2
# Anti-vacuity: both offered-feature words must not be zero (an
# undecoded BAR reads back as zero).
# FEATURES_OK failing to stick must print VIRTIO FEATOK CLEAR; the
# positive boot must not print it.
#
# Negative control: the same kernel on `-vga std` (no VirtIO GPU) must
# print `VIRTIO NONE` and must not print FEAT / QUEUES / STATUS.
# A build that writes DRIVER_OK before FEATURES_OK is rejected by the
# device (FEATURES_OK clear); the source is required to write
# FEATURES_OK first and to carry the refusal string.
#
# Coexistence: `fb` still sets 800x600x32 on both boots. DRIVER_OK is
# not SET_SCANOUT.
#
# This is not G3 (a virtqueue) and not a pixel. xp of a VirtIO BAR is
# not a valid expectation (gpu.md §3.8).
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G2-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G2-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=27

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g2.XXXXXX")" || setup_error "mktemp failed"
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
ck; grep -q 'virtgpuNegotiate' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuNegotiate"
ck; grep -q 'virtgpuStatusFeatOk' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name FEATURES_OK"
ck; grep -q 'virtgpuStatusDriverOk' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name DRIVER_OK"
ck; grep -q 'virtgpuStrFeatOkClear' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no FEATURES_OK refusal string"
ck; grep -q 'virtgpuFeatVersion1' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name VIRTIO_F_VERSION_1"

# FEATURES_OK must be written before DRIVER_OK. A reversed pair is the
# spec's negative control: the device leaves FEATURES_OK clear.
ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "FEATURES_OK is not written before DRIVER_OK"
import sys
src = open(sys.argv[1]).read()
i_ok = src.find("virtgpuStatusOr(cfg, u64(virtgpuStatusFeatOk))")
i_drv = src.find("virtgpuStatusOr(cfg, u64(virtgpuStatusDriverOk))")
if i_ok < 0 or i_drv < 0:
    print("missing status-or of FEATURES_OK or DRIVER_OK", file=sys.stderr)
    sys.exit(1)
if i_ok > i_drv:
    print("DRIVER_OK is written before FEATURES_OK", file=sys.stderr)
    sys.exit(1)
if "virtgpuStrFeatOkClear" not in src[i_ok:i_drv]:
    print("FEATURES_OK read-back refusal is not between the two writes",
          file=sys.stderr)
    sys.exit(1)
PY

# The write is the command, not boot. Init stays silent and empty.
ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc", "pciWrite32", "virtgpuNegotiate"):
    if token in body:
        print("virtgpuInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

# Not last, no donated .bss, no help line, no syscall, no G3/G4.
LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'virtgpu.dart';" ]] \
  || fail "part 'virtgpu.dart' is last in kmain.dart — D7 owns that position"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart declares @bss — G2 retains nothing"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G2 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G2 added a syscall — the criterion forbids one"
ck; ! grep -qE 'queue_enable\s*=|RESOURCE_CREATE_2D|VIRTIO_GPU_CMD' \
      "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart programs a virtqueue or a 2D command — that is G3/G4"

BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G2 was not supposed to donate storage"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  negotiate on the command; FEATURES_OK before DRIVER_OK; no help, no .bss, no G3"

# ===========================================================================
# Step 3 — two boots: virtio-vga (positive) and std VGA (negative).
# ===========================================================================

# virtgpu then fb. fb is the coexistence claim: DRIVER_OK must not steal scanout.
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
# Step 4 — the G2 criterion. Expectations from the spec, not from xp.
# ===========================================================================
echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/virtio/serial.txt" "$WORKDIR/virtio/info-pci.txt" <<'PY' || fail "positive boot did not satisfy G2"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []

if not re.search(r"1af4:1050", info, re.I):
    fails.append("QEMU info pci has no 1af4:1050 — this is not a virtio-vga boot")

if "VIRTIO NONE" in serial.splitlines():
    fails.append("positive boot printed VIRTIO NONE — the device was attached")
if "VIRTIO FEATOK CLEAR" in serial:
    fails.append("kernel printed VIRTIO FEATOK CLEAR — FEATURES_OK did not stick")
if "VIRTIO NOCFG" in serial:
    fails.append("kernel printed VIRTIO NOCFG — COMMON_CFG was not found")
if "VIRTIO RESET" in serial:
    fails.append("kernel printed VIRTIO RESET — reset poll expired")

feat_re = re.compile(r"^VIRTIO FEAT ([0-9A-F]{8}) ([0-9A-F]{8})$")
q_re = re.compile(r"^VIRTIO QUEUES ([0-9A-F]{4})$")
st_re = re.compile(r"^VIRTIO STATUS ([0-9A-F]{2})$")

feats = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO FEAT ")]
queues = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO QUEUES ")]
statuses = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO STATUS ")]

if len(feats) != 1:
    fails.append("expected one FEAT line, found %d: %r" % (len(feats), feats))
    lo = hi = None
else:
    m = feat_re.match(feats[0])
    if not m:
        fails.append("unparseable FEAT: %r" % feats[0])
        lo = hi = None
    else:
        lo = int(m.group(1), 16)
        hi = int(m.group(2), 16)

if lo is not None:
    if lo == 0 and hi == 0:
        fails.append("both offered-feature words are zero — anti-vacuity (undecoded BAR)")
    if (hi & 1) == 0:
        fails.append("offered feature bit 32 is clear — this is not a VirtIO 1.0 device (hi=0x%08X)" % hi)

if len(queues) != 1:
    fails.append("expected one QUEUES line, found %d: %r" % (len(queues), queues))
    nq = None
else:
    m = q_re.match(queues[0])
    if not m:
        fails.append("unparseable QUEUES: %r" % queues[0])
        nq = None
    else:
        nq = int(m.group(1), 16)

if nq is not None and nq < 2:
    fails.append("num_queues is %d, need >= 2" % nq)

if len(statuses) != 1:
    fails.append("expected one STATUS line, found %d: %r" % (len(statuses), statuses))
    st = None
else:
    m = st_re.match(statuses[0])
    if not m:
        fails.append("unparseable STATUS: %r" % statuses[0])
        st = None
    else:
        st = int(m.group(1), 16)

if st is not None:
    if st != 0x0F:
        fails.append("device_status is 0x%02X, expected 0x0F (ACK|DRIVER|FEATURES_OK|DRIVER_OK)" % st)
    if (st & 0x80) != 0:
        fails.append("FAILED (0x80) is set in status 0x%02X" % st)
    if (st & 0x40) != 0:
        fails.append("DEVICE_NEEDS_RESET (0x40) is set in status 0x%02X" % st)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    FEAT 0x%08X 0x%08X  QUEUES %d  STATUS 0x%02X" % (lo, hi, nq, st))
PY
echo "ASSERT: pass  status 0x0F; VERSION_1 offered; queues >= 2; features not both zero"

ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/virtio/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on virtio-vga — G2 broke the dispi path"
echo "ASSERT: pass  fb still sets 800x600x32 on virtio-vga after DRIVER_OK"

# ===========================================================================
# Step 5 — negative control: -vga std, no VirtIO GPU, no status write.
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
for prefix in ("VIRTIO FEAT ", "VIRTIO QUEUES ", "VIRTIO STATUS "):
    hits = [ln for ln in serial.splitlines() if ln.startswith(prefix)]
    if hits:
        fails.append("negative boot printed %s: %r" % (prefix.strip(), hits))
for exact in ("VIRTIO FEATOK CLEAR", "VIRTIO NOCFG", "VIRTIO RESET"):
    if exact in serial.splitlines():
        fails.append("negative boot printed %s" % exact)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO NONE and no FEAT/QUEUES/STATUS"

ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/std/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on -vga std — G2 broke Bochs"
echo "ASSERT: pass  fb / Bochs still works on -vga std (sit-in's machine)"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G2-virtgpu: PASS — device_status 0x0F; VERSION_1 offered; queues >= 2; -vga std writes nothing; fb still works"
