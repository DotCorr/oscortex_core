#!/usr/bin/env bash
# core/tests/conformance/g9-virtgpu/run.sh
#
# G9 — The OS sends GET_CAPSET_INFO through the VirtIO-GPU control
# queue. docs/design/gpu.md §5/G9, ADR-0097.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# After DRIVER_OK and GET_DISPLAY_INFO, `virtgpui` reads num_capsets
# from DEVICE_CFG +12 and submits GET_CAPSET_INFO (type 0x0108) for
# capset index 0. That is the first command on the virgl / Venus
# ladder. It is not a 2D resource, not SET_SCANOUT, not a CPU paint,
# and not host Graphite / Metal.
#
# This Homebrew QEMU has no virtio-gpu-gl-pci and offers
# num_capsets=0. The device still answers the command (an error
# type in 0x12xx). That is the honest result. A 0x1102 OK would
# also pass — it would mean 3D capsets exist.
#
# The harness requires:
#   * preview-ui.sh, preview_main.m, preview.html are gone
#   * sit-in.sh does not set OSGFX_GUEST=1 (no Mac/Skia-in-kernel)
#   * VIRTIO CAPSETS from the MMIO word (not a constant 0 store)
#   * VIRTIO CAPINFO with a non-zero type that is not GET_DISPLAY_INFO
#   * virtgpuj prints CAPSETS and does not print CAPINFO
#   * -vga std prints VIRTIO NONE and no CAPSETS / CAPINFO
#   * G3 still printed RESP 0x1101 and the derived scanout
#   * no help line, no syscall, no @bss, last .bss untouched
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G9-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G9-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=45

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g9.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
REG="$CORE_DIR/docs/syscall-registry.md"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

# Not QEMU 1280×800, not 800×600, not 1024×768, not G3–G8 modes.
XRES=1088
YRES=784

echo "=== PREVIEW IS GONE ==="
ck; [[ ! -f "$CORE_DIR/scripts/preview-ui.sh" ]] \
  || fail "preview-ui.sh still exists"
ck; [[ ! -f "$CORE_DIR/plat/osgfx/preview_main.m" ]] \
  || fail "preview_main.m still exists"
ck; ! find "$CORE_DIR" -name 'preview.html' | grep -q . \
  || fail "preview.html still exists"
ck; ! grep -q 'OSGFX_GUEST=1' "$CORE_DIR/scripts/sit-in.sh" \
  || fail "sit-in.sh still builds OSGFX_GUEST=1 — CPU Skia is not the product"
ck; grep -q "typekeys 'wm gfx'" "$CORE_DIR/scripts/sit-in.sh" \
  || fail "sit-in.sh does not type wm gfx — compositor must call osgfx"

echo "=== QEMU 3D DEVICES ==="
capture_sh QDEV_OUT QDEV_STATUS -- "qemu-system-x86_64 -device help"
ck; [[ $QDEV_STATUS -eq 0 ]] || fail "qemu -device help failed"
printf '%s\n' "$QDEV_OUT" > "$WORKDIR/qemu-devices.txt"
ck; grep -q 'virtio-gpu-pci' "$WORKDIR/qemu-devices.txt" \
  || fail "this QEMU has no virtio-gpu-pci — G0–G8 would also be dead"
if grep -qE 'virtio-gpu-gl-pci|virtio-gpu-rutabaga' "$WORKDIR/qemu-devices.txt"; then
  echo "    leftover note: this QEMU lists a GL/rutabaga device — virgl may be reachable"
else
  echo "    leftover: no virtio-gpu-gl-pci / rutabaga on this QEMU (virgl/Venus blocked here)"
fi

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
ck; grep -q 'void virtgpuCapset(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuCapset"
ck; grep -q 'virtgpuTypeCapInfo = 0x0108' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name GET_CAPSET_INFO 0x0108"
ck; grep -q 'virtgpuDevNumCap = 12' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name num_capsets offset 12"
ck; grep -q 'virtgpuStrCmdCap' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpui command"
ck; grep -q 'virtgpuStrCmdNoCap' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuj command — that is the negative control"
ck; grep -q 'shellVirtgpuCap' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpui"
ck; grep -q 'shellVirtgpuNoCap' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpuj"
ck; [[ -f "$CORE_DIR/docs/decisions/0097-get-capset-info-is-the-first-3d-command.md" ]] \
  || fail "ADR-0097 is missing"

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "GET_CAPSET_INFO is not a device read"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuCapset\(.*?\n\}", src, re.S)
if not m:
    print("virtgpuCapset is missing", file=sys.stderr); sys.exit(1)
body = m.group(0)
if "virtgpuCfgGet32(dcfg, u64(virtgpuDevNumCap))" not in body:
    print("virtgpuCapset does not read DEVICE_CFG num_capsets", file=sys.stderr)
    sys.exit(1)
if "virtgpuTypeCapInfo" not in body:
    print("virtgpuCapset does not submit GET_CAPSET_INFO", file=sys.stderr)
    sys.exit(1)
if "ncap = u64(0);" in body and "virtgpuCfgGet32" not in body:
    print("num_capsets is a constant", file=sys.stderr); sys.exit(1)
PY

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc", "pciWrite32", "virtgpuOneCmd",
              "virtgpuPix", "virtgpuConsole", "virtgpuCell", "virtgpuFlip",
              "virtgpuCapset"):
    if token in body:
        print("virtgpuInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'virtgpu.dart';" ]] \
  || fail "part 'virtgpu.dart' is last in kmain.dart — D7 owns that position"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart declares @bss — G9 donates no storage"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G9 added a help line"
ck; ! grep -q 'virtgpu' "$REG" \
  || fail "G9 added a syscall — the criterion forbids one"
ck; grep -qE '^\| *11 *\|.*fdwait' "$REG" \
  || fail "syscall 11 is not fdwait"
ck; ! grep -qE 'queue_enable\s*=|RESOURCE_CREATE_2D|VIRTIO_GPU_CMD' \
      "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart uses a token g0/g1/g2/g3 forbid — those rungs would go red"
ck; ! grep -q "$XRES" "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "derived xres $XRES appears in virtgpu.dart — the mode must come from the device"
ck; ! grep -q "$YRES" "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "derived yres $YRES appears in virtgpu.dart — the mode must come from the device"

BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G9 was not supposed to donate storage"

# Last .bss in kmain.o stays wmeventStore.
EV_OFF=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$4=="OBJECT" && $8=="wmeventStore"{print $2; exit}')
EV_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$4=="OBJECT" && $8=="wmeventStore"{print $3+0; exit}')
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ "$EV_SIZE" -eq 384 ]] || fail "wmeventStore is ${EV_SIZE:-missing}"
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in kmain.o .bss"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"

# ===========================================================================
# Step 3 — boots.
# ===========================================================================

KEYS_CAP="v,i,r,t,g,p,u,i,ret,wait:800,f,b,ret,wait:800"
KEYS_NO="v,i,r,t,g,p,u,j,ret,wait:800,f,b,ret,wait:800"

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
echo "=== BOOT virtio-vga xres=${XRES} yres=${YRES} virtgpui ==="
drive_session "$WORKDIR/cap" "virtgpui" "$KEYS_CAP" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"
echo
echo "=== BOOT virtio-vga virtgpuj (no submit) ==="
drive_session "$WORKDIR/nocap" "virtgpuj" "$KEYS_NO" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"
echo
echo "=== BOOT std VGA (negative, no device) ==="
drive_session "$WORKDIR/std" "std-vga" "$KEYS_CAP" -vga std

# ===========================================================================
# Step 4 — criterion.
# ===========================================================================
echo
echo "=== CRITERION ==="

ck; python3 - "$WORKDIR/cap/serial.txt" "$WORKDIR/cap/info-pci.txt" "$XRES" "$YRES" <<'PY' || fail "positive boot did not satisfy G9"
import re, sys

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
xres = int(sys.argv[3])
yres = int(sys.argv[4])
fails = []

if not re.search(r"1af4:1050", info, re.I):
    fails.append("QEMU info pci has no 1af4:1050")
if "VIRTIO NONE" in serial.splitlines():
    fails.append("positive boot printed VIRTIO NONE")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("positive boot printed VIRTIO QTIMEOUT")
if "VIRTIO FEATOK CLEAR" in serial:
    fails.append("FEATURES_OK did not stick")

resp_re = re.compile(r"^VIRTIO RESP ([0-9A-F]{8})$")
scan_re = re.compile(
    r"^VIRTIO SCAN ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8})$")
ncap_re = re.compile(r"^VIRTIO CAPSETS ([0-9A-F]{8})$")
cinfo_re = re.compile(
    r"^VIRTIO CAPINFO ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8})$")

resps = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO RESP ")]
scans = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO SCAN ")]
ncaps = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CAPSETS ")]
cinfos = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CAPINFO ")]

if len(resps) != 1:
    fails.append("expected one RESP line, found %d: %r" % (len(resps), resps))
else:
    m = resp_re.match(resps[0])
    if not m:
        fails.append("unparseable RESP: %r" % resps[0])
    elif int(m.group(1), 16) != 0x1101:
        fails.append("G3 RESP is 0x%s, expected 0x1101" % m.group(1))

if len(scans) != 1:
    fails.append("expected one SCAN line, found %d: %r" % (len(scans), scans))
else:
    m = scan_re.match(scans[0])
    if not m:
        fails.append("unparseable SCAN: %r" % scans[0])
    else:
        w, h = int(m.group(3), 16), int(m.group(4), 16)
        if w != xres or h != yres:
            fails.append("SCAN %dx%d != launch %dx%d" % (w, h, xres, yres))

if len(ncaps) != 1:
    fails.append("expected one CAPSETS line, found %d: %r" % (len(ncaps), ncaps))
else:
    m = ncap_re.match(ncaps[0])
    if not m:
        fails.append("unparseable CAPSETS: %r" % ncaps[0])

if len(cinfos) != 1:
    fails.append("expected one CAPINFO line, found %d: %r" % (len(cinfos), cinfos))
else:
    m = cinfo_re.match(cinfos[0])
    if not m:
        fails.append("unparseable CAPINFO: %r" % cinfos[0])
    else:
        typ = int(m.group(1), 16)
        if typ == 0:
            fails.append("CAPINFO type is 0 — the device never wrote a reply")
        if typ == 0x1101:
            fails.append("CAPINFO type is GET_DISPLAY_INFO — the 3D command was not sent")
        if typ == 0x0108:
            fails.append("CAPINFO type is the request 0x0108 — response was not written")
        # 0x1102 OK or 0x12xx error are both a device reply to GET_CAPSET_INFO.

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    virtgpui  RESP 1101  SCAN %dx%d  CAPSETS+CAPINFO" % (xres, yres))
PY

ck; python3 - "$WORKDIR/nocap/serial.txt" <<'PY' || fail "virtgpuj did not hold the negative"
import sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "VIRTIO NONE" in serial.splitlines():
    fails.append("virtgpuj printed VIRTIO NONE")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("virtgpuj timed out on GET_DISPLAY_INFO")
ncaps = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CAPSETS ")]
cinfos = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO CAPINFO ")]
if len(ncaps) != 1:
    fails.append("virtgpuj expected one CAPSETS, found %d: %r" % (len(ncaps), ncaps))
if cinfos:
    fails.append("virtgpuj printed CAPINFO — that is the submit: %r" % cinfos)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    virtgpuj  CAPSETS only — CAPINFO measures the virtqueue submit")
PY

ck; python3 - "$WORKDIR/std/serial.txt" <<'PY' || fail "std VGA negative did not hold"
import sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "VIRTIO NONE" not in serial.splitlines():
    fails.append("std VGA did not print VIRTIO NONE")
if any(ln.startswith("VIRTIO CAPSETS ") for ln in serial.splitlines()):
    fails.append("std VGA printed CAPSETS")
if any(ln.startswith("VIRTIO CAPINFO ") for ln in serial.splitlines()):
    fails.append("std VGA printed CAPINFO")
if "VIRTIO RESP " in serial:
    fails.append("std VGA printed RESP")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    std VGA  VIRTIO NONE  no CAPSETS/CAPINFO")
PY

ck; grep -qE '^FB BAR ' "$WORKDIR/cap/serial.txt" \
  || fail "fb coexistence lost on the virtgpui boot"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G9-virtgpu: PASS — GET_CAPSET_INFO on the GPU virtqueue; virtgpuj has no CAPINFO; preview gone ($ASSERTIONS checks)"
