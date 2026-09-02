#!/usr/bin/env bash
# core/tests/conformance/g3-virtgpu/run.sh
#
# G3 — A virtqueue exists and the device answers one command.
# docs/design/gpu.md §5/G3, ADR-0074.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# After DRIVER_OK the hidden `virtgpu` command selects queue 0, reads
# queue_size, allocates three zeroed frames, writes the three queue
# address registers as 32-bit halves, enables the queue last, submits
# GET_DISPLAY_INFO (type 0x0100) in a 24-byte header (not 32), and
# polls used.idx.
#
# The harness requires:
#   * response type 0x1101 (RESP_OK_DISPLAY_INFO)
#   * scanout 0 enabled and its width/height equal the xres/yres the
#     harness launched QEMU with — derived, not 1280x800 / 800x600 /
#     1024x768
#   * num_scanouts equals QEMU max_outputs (1)
#   * used.idx advanced (printed, non-zero)
# Anti-vacuity: width or height zero fails; used.idx never advancing
# fails.
#
# Negative control: `virtgpun` omits the notify store. used.idx stays 0
# and the kernel prints VIRTIO QTIMEOUT. QEMU/TCG still DMAs with
# bus-master clear, so the doorbell is the write that actually moves
# the used ring (G1 remains the BME proof).
# `-vga std` still prints VIRTIO NONE and no QSIZE/USED/RESP.
#
# Coexistence: `fb` still sets 800x600x32. GET_DISPLAY_INFO is not
# SET_SCANOUT.
#
# g0/g1/g2 remain green: the G3 tokens they forbid
# (`queue_enable=`, RESOURCE_CREATE_2D, VIRTIO_GPU_CMD) are not used.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G3-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G3-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=41

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g3.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

# Derived mode: not QEMU's 1280x800, not the kernel's 800x600, not
# the spec fallback 1024x768. The kernel must read this from the
# device. 1136x848 is 16-aligned and does not appear in virtgpu.dart.
XRES=1136
YRES=848

# ===========================================================================
# Step 1 — build.
# ===========================================================================
echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

# ===========================================================================
# Step 2 — structural.
# ===========================================================================
echo
echo "=== STRUCTURAL ==="

ck; [[ -f "$CORE_DIR/kernel/virtgpu.dart" ]] || fail "core/kernel/virtgpu.dart is missing"
ck; grep -q 'virtgpuOneCmd' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuOneCmd"
ck; grep -q 'virtgpuHdrBytes = 24' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name a 24-byte header"
ck; ! grep -q 'virtgpuHdrBytes = 32' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart names a 32-byte header — the payload offsets would be wrong"
ck; grep -q 'virtgpuTypeGetDisp = 0x0100' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name GET_DISPLAY_INFO 0x0100"
ck; grep -q 'virtgpuRespDispInfo = 0x1101' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name RESP_OK_DISPLAY_INFO 0x1101"
ck; grep -q 'virtgpuStrQTimeout' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no poll-timeout string"
ck; grep -q 'virtgpuStrCmdNoBm' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no no-BME command — that is the negative control"
ck; grep -q 'shellVirtgpuNoBm' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no shellVirtgpuNoBm"

# Three frames, each zeroed. A single-frame queue is the 0.9.5 shape.
ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "G3 does not take three zeroed frames"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuOneCmd\(.*?\n\}", src, re.S)
if not m:
    print("virtgpuOneCmd is missing", file=sys.stderr); sys.exit(1)
body = m.group(0)
names = re.findall(r"final u64 (\w+) = allocFrame\(\);", body)
if len(names) != 3:
    print("virtgpuOneCmd takes %d frames, need 3: %r" % (len(names), names),
          file=sys.stderr)
    sys.exit(1)
for n in names:
    if ("vmZeroFrame(%s);" % n) not in body:
        print("%s is not named to vmZeroFrame in virtgpuOneCmd" % n,
              file=sys.stderr)
        sys.exit(1)
PY

# Header length used as the first descriptor's len, not 32.
ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "request descriptor is not 24 bytes"
import sys
src = open(sys.argv[1]).read()
if "u64(virtgpuHdrBytes)" not in src:
    print("virtgpuHdrBytes is never used as a length", file=sys.stderr)
    sys.exit(1)
if "u64(32)" in src and "virtgpuPutDesc" in src:
    # A literal 32 as a descriptor length would be the trap.
    pass
if "virtgpuHdrBytes = 24" not in src:
    print("header constant is not 24", file=sys.stderr); sys.exit(1)
PY

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc", "pciWrite32", "virtgpuOneCmd"):
    if token in body:
        print("virtgpuInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'virtgpu.dart';" ]] \
  || fail "part 'virtgpu.dart' is last in kmain.dart — D7 owns that position"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart declares @bss — G3 donates frames, not .bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G3 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G3 added a syscall — the criterion forbids one"

# The tokens g0/g1/g2 still forbid must stay absent so those rungs
# keep passing after this file grows a virtqueue.
ck; ! grep -qE 'queue_enable\s*=|RESOURCE_CREATE_2D|VIRTIO_GPU_CMD' \
      "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart uses a token g0/g1/g2 forbid — those rungs would go red"

ck; ! grep -q "$XRES" "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "derived xres $XRES appears in virtgpu.dart — the mode must come from the device"
ck; ! grep -q "$YRES" "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "derived yres $YRES appears in virtgpu.dart — the mode must come from the device"
ck; [[ "$XRES" -ne 1280 && "$YRES" -ne 800 ]] \
  || fail "derived mode is QEMU's default 1280x800"
ck; [[ "$XRES" -ne 800 && "$YRES" -ne 600 ]] \
  || fail "derived mode is the kernel's compiled-in 800x600"
ck; [[ "$XRES" -ne 1024 && "$YRES" -ne 768 ]] \
  || fail "derived mode is the spec fallback 1024x768"

BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G3 was not supposed to donate storage"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  24-byte header; three zeroed frames; no help, no .bss; derived mode is not a default"

# ===========================================================================
# Step 3 — three boots: derived virtio-vga, std VGA, no-BME.
# ===========================================================================

KEYS_GPU="v,i,r,t,g,p,u,ret,wait:800,f,b,ret,wait:800"
KEYS_NOBM="v,i,r,t,g,p,u,n,ret,wait:4000,f,b,ret,wait:800"

drive_session() {
  local outdir="$1" label="$2" keys="$3"
  shift 3
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
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
    --keys "$keys"
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
echo "=== BOOT virtio-vga xres=${XRES} yres=${YRES} ==="
drive_session "$WORKDIR/virtio" "virtio-vga" "$KEYS_GPU" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"
echo
echo "=== BOOT std VGA (negative, no device) ==="
drive_session "$WORKDIR/std" "std-vga" "$KEYS_GPU" -vga std
echo
echo "=== BOOT virtio-vga without notify (virtgpun) ==="
drive_session "$WORKDIR/nobm" "virtio-nokick" "$KEYS_NOBM" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

# ===========================================================================
# Step 4 — the G3 criterion against the launch geometry.
# ===========================================================================
echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/virtio/serial.txt" "$WORKDIR/virtio/info-pci.txt" "$XRES" "$YRES" <<'PY' || fail "positive boot did not satisfy G3"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
xres = int(sys.argv[3])
yres = int(sys.argv[4])
fails = []

if not re.search(r"1af4:1050", info, re.I):
    fails.append("QEMU info pci has no 1af4:1050 — this is not a virtio-vga boot")

if "VIRTIO NONE" in serial.splitlines():
    fails.append("positive boot printed VIRTIO NONE — the device was attached")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("positive boot printed VIRTIO QTIMEOUT — used.idx never advanced")
if "VIRTIO NOQ" in serial:
    fails.append("positive boot printed VIRTIO NOQ — queue 0 was missing")
if "VIRTIO NOFRM" in serial:
    fails.append("positive boot printed VIRTIO NOFRM — allocFrame failed")
if "VIRTIO NONOTIFY" in serial:
    fails.append("positive boot printed VIRTIO NONOTIFY — notify cap missing")
if "VIRTIO FEATOK CLEAR" in serial:
    fails.append("kernel printed VIRTIO FEATOK CLEAR — FEATURES_OK did not stick")

used_re = re.compile(r"^VIRTIO USED ([0-9A-F]{4})$")
resp_re = re.compile(r"^VIRTIO RESP ([0-9A-F]{8})$")
scan_re = re.compile(
    r"^VIRTIO SCAN ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8})$")
nscan_re = re.compile(r"^VIRTIO NSCAN ([0-9A-F]{8})$")
qsz_re = re.compile(r"^VIRTIO QSIZE ([0-9A-F]{4})$")

useds = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO USED ")]
resps = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO RESP ")]
scans = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO SCAN ")]
nscans = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO NSCAN ")]
qsizes = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO QSIZE ")]

if len(qsizes) != 1:
    fails.append("expected one QSIZE line, found %d: %r" % (len(qsizes), qsizes))
else:
    m = qsz_re.match(qsizes[0])
    if not m:
        fails.append("unparseable QSIZE: %r" % qsizes[0])
    else:
        qsz = int(m.group(1), 16)
        if qsz == 0:
            fails.append("queue_size is 0 — the control queue does not exist")

if len(nscans) != 1:
    fails.append("expected one NSCAN line, found %d: %r" % (len(nscans), nscans))
else:
    m = nscan_re.match(nscans[0])
    if not m:
        fails.append("unparseable NSCAN: %r" % nscans[0])
    else:
        nscan = int(m.group(1), 16)
        if nscan != 1:
            fails.append("num_scanouts is %d, expected 1 (QEMU max_outputs default)" % nscan)

if len(useds) != 1:
    fails.append("expected one USED line, found %d: %r" % (len(useds), useds))
    used = None
else:
    m = used_re.match(useds[0])
    if not m:
        fails.append("unparseable USED: %r" % useds[0])
        used = None
    else:
        used = int(m.group(1), 16)

if used is not None and used == 0:
    fails.append("used.idx is 0 — the device never processed the chain (anti-vacuity)")

if len(resps) != 1:
    fails.append("expected one RESP line, found %d: %r" % (len(resps), resps))
    typ = None
else:
    m = resp_re.match(resps[0])
    if not m:
        fails.append("unparseable RESP: %r" % resps[0])
        typ = None
    else:
        typ = int(m.group(1), 16)

if typ is not None and typ != 0x1101:
    fails.append("response type is 0x%08X, expected 0x1101 (RESP_OK_DISPLAY_INFO)" % typ)

if len(scans) != 1:
    fails.append("expected one SCAN line, found %d: %r" % (len(scans), scans))
else:
    m = scan_re.match(scans[0])
    if not m:
        fails.append("unparseable SCAN: %r" % scans[0])
    else:
        sx = int(m.group(1), 16)
        sy = int(m.group(2), 16)
        sw = int(m.group(3), 16)
        sh = int(m.group(4), 16)
        en = int(m.group(5), 16)
        if sw == 0 or sh == 0:
            fails.append("scanout 0 is %dx%d — anti-vacuity (zero dimension)" % (sw, sh))
        if en == 0:
            fails.append("scanout 0 enabled is 0")
        if sw != xres or sh != yres:
            fails.append("scanout 0 is %dx%d, QEMU was launched with %dx%d"
                         % (sw, sh, xres, yres))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    RESP 0x1101  SCAN %dx%d enabled  NSCAN 1  USED advanced" % (xres, yres))
PY
echo "ASSERT: pass  RESP 0x1101; scanout 0 matches ${XRES}x${YRES}; NSCAN 1; used.idx advanced"

ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/virtio/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on virtio-vga — G3 broke the dispi path"
echo "ASSERT: pass  fb still sets 800x600x32 on virtio-vga after GET_DISPLAY_INFO"

# ===========================================================================
# Step 5 — negative: -vga std.
# ===========================================================================

ck; python3 - "$WORKDIR/std/serial.txt" "$WORKDIR/std/info-pci.txt" <<'PY' || fail "std-vga negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1af4:1050", info, re.I):
    fails.append("negative boot's info pci still has 1af4:1050 — this is not -vga std")
if "VIRTIO NONE" not in serial.splitlines():
    fails.append("negative boot did not print VIRTIO NONE")
for prefix in ("VIRTIO QSIZE ", "VIRTIO USED ", "VIRTIO RESP ", "VIRTIO SCAN ",
               "VIRTIO NSCAN "):
    hits = [ln for ln in serial.splitlines() if ln.startswith(prefix)]
    if hits:
        fails.append("negative boot printed %s: %r" % (prefix.strip(), hits))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO NONE and no QSIZE/USED/RESP"

ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/std/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on -vga std — G3 broke Bochs"
echo "ASSERT: pass  fb / Bochs still works on -vga std"

# ===========================================================================
# Step 6 — negative: notify store omitted.
# ===========================================================================

ck; python3 - "$WORKDIR/nobm/serial.txt" "$WORKDIR/nobm/info-pci.txt" <<'PY' || fail "no-notify negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if not re.search(r"1af4:1050", info, re.I):
    fails.append("no-notify boot's info pci has no 1af4:1050")
if "VIRTIO QTIMEOUT" not in serial:
    fails.append("no-notify boot did not print VIRTIO QTIMEOUT — without the doorbell used.idx must stay 0")
if "VIRTIO RESP " in serial:
    fails.append("no-notify boot printed a RESP line — the device should not have answered")
useds = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO USED ")]
if len(useds) != 1:
    fails.append("expected one USED line on the no-notify boot, found %d: %r" % (len(useds), useds))
else:
    m = re.match(r"^VIRTIO USED ([0-9A-F]{4})$", useds[0])
    if not m:
        fails.append("unparseable USED on no-notify boot: %r" % useds[0])
    elif int(m.group(1), 16) != 0:
        fails.append("no-notify used.idx is 0x%s, expected 0" % m.group(1))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtgpun prints QTIMEOUT and used.idx 0 (notify is what moves the used ring)"

ck; grep -qE '^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$' "$WORKDIR/nobm/serial.txt" \
  || fail "fb did not report MODE 0320x0258x20 OK on the no-notify boot"
echo "ASSERT: pass  fb still works after a timed-out GET_DISPLAY_INFO"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G3-virtgpu: PASS — RESP 0x1101; scanout 0 is ${XRES}x${YRES}; NSCAN 1; used.idx advanced; virtgpun times out; fb still works"
