#!/usr/bin/env bash
# core/tests/conformance/g4-virtgpu/run.sh
#
# G4 — A resource is created, backed, scanned out, and one pixel is
# provably on screen. docs/design/gpu.md §5/G4, ADR-0079.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# After GET_DISPLAY_INFO the colour form `virtgpu <hex>` creates a 2D
# resource at the device-reported width×height, attaches a scatter-gather
# of allocFrame() pages, SET_SCANOUT, writes one derived colour into the
# first backing frame, transfers that 1×1 rect, and flushes.
#
# Proof is host-side, not a screenshot comparison:
#   * pmemsave of the first backing frame (address THE KERNEL printed)
#     has the derived colour at word 0
#   * QEMU screendump pixel (0,0) is the same colour
# A second boot with a different derived colour must change both dumps.
#
# Anti-vacuity: colour is not 0 and not fbColorBg; frame count is the
# derived ceil(w*h*4/4096); fewer PIX 0x1100 lines than the five
# commands is a fail.
#
# Negative: `virtgpua` omits attach. SET_SCANOUT must print a PIX error
# (0x1200 or 0x1203), not 0x1100. `-vga std` still prints VIRTIO NONE.
#
# Bare `virtgpu` is unchanged (g0–g3). Forbidden tokens stay absent.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G4-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G4-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=52

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g4.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

# Same derived mode G3 uses. Not QEMU 1280×800, not 800×600, not 1024×768.
XRES=1136
YRES=848
FRAMES=$(( (XRES * YRES * 4 + 4095) / 4096 ))
COLOR_A=$(( ((XRES & 0xFF) << 16) | ((YRES & 0xFF) << 8) | 0x5A ))
COLOR_B=$(( ((YRES & 0xFF) << 16) | ((XRES & 0xFF) << 8) | 0xA5 ))
BG=0x00101018

hex8() { printf '%08X' "$1"; }
hex_keys() {
  python3 -c "print(','.join(c.lower() for c in '$1'))"
}

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
ck; grep -q 'virtgpuPix' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuPix"
ck; grep -q 'virtgpuTypeRes2d = 0x0101' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name create-2d type 0x0101"
ck; grep -q 'virtgpuTypeSetScan = 0x0103' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name SET_SCANOUT 0x0103"
ck; grep -q 'virtgpuTypeAttach = 0x0106' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name attach type 0x0106"
ck; grep -q 'virtgpuTypeXfer = 0x0105' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name transfer type 0x0105"
ck; grep -q 'virtgpuTypeFlush = 0x0104' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name flush type 0x0104"
ck; grep -q 'virtgpuRespOk = 0x1100' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name RESP_OK_NODATA 0x1100"
ck; grep -q 'virtgpuHdrBytes = 24' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name a 24-byte header"
ck; grep -q 'virtgpuStrCmdArg' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no colour-argument command prefix"
ck; grep -q 'virtgpuStrCmdNoAtt' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no no-attach command — that is the negative control"
ck; grep -q 'shellVirtgpuPix' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no shellVirtgpuPix"
ck; grep -q 'shellVirtgpuNoAtt' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no shellVirtgpuNoAtt"

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc", "pciWrite32", "virtgpuOneCmd", "virtgpuPix"):
    if token in body:
        print("virtgpuInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "G3 still must take three zeroed frames"
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
PY

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'virtgpu.dart';" ]] \
  || fail "part 'virtgpu.dart' is last in kmain.dart — D7 owns that position"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart declares @bss — G4 donates frames, not .bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G4 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G4 added a syscall — the criterion forbids one"
ck; ! grep -qE 'queue_enable\s*=|RESOURCE_CREATE_2D|VIRTIO_GPU_CMD' \
      "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart uses a token g0/g1/g2/g3 forbid — those rungs would go red"
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
ck; [[ "$COLOR_A" -ne 0 ]] || fail "derived colour A is 0 — vacuous against unpainted RAM"
ck; [[ "$COLOR_B" -ne 0 ]] || fail "derived colour B is 0 — vacuous against unpainted RAM"
ck; [[ "$COLOR_A" -ne "$BG" ]] || fail "derived colour A equals fbColorBg"
ck; [[ "$COLOR_B" -ne "$BG" ]] || fail "derived colour B equals fbColorBg"
ck; [[ "$COLOR_A" -ne "$COLOR_B" ]] || fail "derived colours are equal — the second boot would be vacuous"
ck; [[ "$FRAMES" -gt 1 ]] || fail "derived backing frame count is $FRAMES — a one-page resource would not prove w×h"

BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G4 was not supposed to donate storage"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  G4 types named; no help, no .bss; derived mode/colour not defaults; g0–g3 tokens absent"

# ===========================================================================
# Step 3 — boots.
# ===========================================================================

COLOR_A_HEX="$(hex8 "$COLOR_A")"
COLOR_B_HEX="$(hex8 "$COLOR_B")"
KEYS_A="v,i,r,t,g,p,u,spc,$(hex_keys "$COLOR_A_HEX"),ret,wait:12000"
KEYS_B="v,i,r,t,g,p,u,spc,$(hex_keys "$COLOR_B_HEX"),ret,wait:12000"
KEYS_NOATT="v,i,r,t,g,p,u,a,ret,wait:8000"

drive_session() {
  local outdir="$1" label="$2" keys="$3"
  shift 3
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 240 qemu-system-x86_64 \
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
    --addr-from-serial 'VIRTIO BACK ([0-9A-F]{8})' \
    --pmemsave "$outdir/back.bin" --pmemsave-size 4096 \
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
echo "=== BOOT colour A 0x${COLOR_A_HEX} ==="
drive_session "$WORKDIR/a" "colour-A" "$KEYS_A" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"
echo
echo "=== BOOT colour B 0x${COLOR_B_HEX} ==="
drive_session "$WORKDIR/b" "colour-B" "$KEYS_B" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"
echo
echo "=== BOOT no-attach (virtgpua) ==="
# No BACK line, so pmemsave is not requested.
mkdir -p "$WORKDIR/noatt"
: >"$WORKDIR/noatt/serial.txt"
NOATT_PORT=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
ck; [[ -n "$NOATT_PORT" ]]
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}" \
  -serial "file:$WORKDIR/noatt/serial.txt" \
  -display none \
  -no-reboot \
  -qmp "tcp:127.0.0.1:$NOATT_PORT,server,nowait" \
  >"$WORKDIR/noatt/qemu.log" 2>&1 &
NOATT_PID=$!
run_status NOATT_DRIVE -- python3 "$DRIVER" \
  --port "$NOATT_PORT" --serial "$WORKDIR/noatt/serial.txt" --wait-for 'M1 END\n' \
  --png "$WORKDIR/noatt/screen.png" --screen-text "$WORKDIR/noatt/screen.txt" \
  --monitor-command 'info pci' --monitor-capture "$WORKDIR/noatt/info-pci.txt" \
  --keys "$KEYS_NOATT"
await NOATT_QEMU "$NOATT_PID"
ck; [[ $NOATT_DRIVE -eq 0 ]] || { cat "$WORKDIR/noatt/qemu.log" >&2; cat "$WORKDIR/noatt/serial.txt" >&2; fail "qmp-drive.py exited $NOATT_DRIVE for virtgpua"; }
ck; [[ $NOATT_QEMU -eq 0 || $NOATT_QEMU -eq 124 ]] || fail "qemu exited $NOATT_QEMU on virtgpua"

echo
echo "=== BOOT std VGA (negative, no device) ==="
mkdir -p "$WORKDIR/std"
: >"$WORKDIR/std/serial.txt"
STD_PORT=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
ck; [[ -n "$STD_PORT" ]]
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$WORKDIR/std/serial.txt" \
  -display none \
  -no-reboot \
  -qmp "tcp:127.0.0.1:$STD_PORT,server,nowait" \
  >"$WORKDIR/std/qemu.log" 2>&1 &
STD_PID=$!
run_status STD_DRIVE -- python3 "$DRIVER" \
  --port "$STD_PORT" --serial "$WORKDIR/std/serial.txt" --wait-for 'M1 END\n' \
  --png "$WORKDIR/std/screen.png" --screen-text "$WORKDIR/std/screen.txt" \
  --monitor-command 'info pci' --monitor-capture "$WORKDIR/std/info-pci.txt" \
  --keys "$KEYS_A"
await STD_QEMU "$STD_PID"
ck; [[ $STD_DRIVE -eq 0 ]] || { cat "$WORKDIR/std/qemu.log" >&2; cat "$WORKDIR/std/serial.txt" >&2; fail "qmp-drive.py exited $STD_DRIVE for std-vga"; }
ck; [[ $STD_QEMU -eq 0 || $STD_QEMU -eq 124 ]] || fail "qemu exited $STD_QEMU on std-vga"

# ===========================================================================
# Step 4 — criterion.
# ===========================================================================
echo
echo "=== CRITERION ==="

check_positive() {
  local ser="$1" info="$2" back="$3" png="$4" colour="$5" label="$6"
  ck; python3 - "$ser" "$info" "$back" "$png" "$colour" "$XRES" "$YRES" "$FRAMES" "$label" <<'PY' || fail "$6 did not satisfy G4"
import re, struct, sys, zlib

serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
back_path, png_path = sys.argv[3], sys.argv[4]
colour = int(sys.argv[5])
xres, yres, frames = int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8])
label = sys.argv[9]
fails = []

if not re.search(r"1af4:1050", info, re.I):
    fails.append("QEMU info pci has no 1af4:1050")
if "VIRTIO NONE" in serial.splitlines():
    fails.append("printed VIRTIO NONE — the device was attached")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("printed VIRTIO QTIMEOUT")

pix = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO PIX ")]
if len(pix) != 5:
    fails.append("expected 5 PIX lines, found %d: %r" % (len(pix), pix))
else:
    for ln in pix:
        m = re.match(r"^VIRTIO PIX ([0-9A-F]{8})$", ln)
        if not m:
            fails.append("unparseable PIX: %r" % ln)
        elif int(m.group(1), 16) != 0x1100:
            fails.append("PIX is 0x%s, expected 0x1100" % m.group(1))

backs = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO BACK ")]
if len(backs) != 1:
    fails.append("expected one BACK line, found %d: %r" % (len(backs), backs))
else:
    m = re.match(r"^VIRTIO BACK ([0-9A-F]{8})$", backs[0])
    if not m:
        fails.append("unparseable BACK: %r" % backs[0])
    elif int(m.group(1), 16) == 0:
        fails.append("BACK address is 0")

frs = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO FRAMES ")]
if len(frs) != 1:
    fails.append("expected one FRAMES line, found %d: %r" % (len(frs), frs))
else:
    m = re.match(r"^VIRTIO FRAMES ([0-9A-F]{8})$", frs[0])
    if not m:
        fails.append("unparseable FRAMES: %r" % frs[0])
    else:
        got = int(m.group(1), 16)
        if got != frames:
            fails.append("FRAMES is %d, derived ceil(%d*%d*4/4096) is %d"
                         % (got, xres, yres, frames))
        if got < 2:
            fails.append("FRAMES is %d — anti-vacuity (need more than one page)" % got)

cols = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO COLOUR ")]
if len(cols) != 1:
    fails.append("expected one COLOUR line, found %d: %r" % (len(cols), cols))
else:
    m = re.match(r"^VIRTIO COLOUR ([0-9A-F]{8})$", cols[0])
    if not m:
        fails.append("unparseable COLOUR: %r" % cols[0])
    elif int(m.group(1), 16) != colour:
        fails.append("COLOUR is 0x%s, typed 0x%08X" % (m.group(1), colour))

try:
    blob = open(back_path, "rb").read()
except OSError as e:
    fails.append("pmemsave missing: %s" % e)
    blob = b""
if len(blob) != 4096:
    fails.append("pmemsave is %d bytes, expected 4096" % len(blob))
elif blob:
    got = struct.unpack_from("<I", blob, 0)[0]
    if got != colour:
        fails.append("pmemsave word0 is 0x%08X, expected 0x%08X" % (got, colour))

def png_pixel00(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = None
    raw = b""
    while pos + 8 <= len(data):
        ln = struct.unpack_from(">I", data, pos)[0]
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if ctype == b"IHDR":
            width, height, bit, color, *_ = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"IDAT":
            raw += chunk
        elif ctype == b"IEND":
            break
    if width is None:
        raise ValueError("no IHDR")
    rows = zlib.decompress(raw)
    bpp = {2: 3, 6: 4}.get(color)
    if bit != 8 or bpp is None:
        raise ValueError("unsupported PNG %d-bit type %d" % (bit, color))
    stride = 1 + width * bpp
    if len(rows) < stride:
        raise ValueError("truncated IDAT")
    # Unfilter row 0 only.
    ftype = rows[0]
    src = bytearray(rows[1:stride])
    if ftype == 1:
        for i in range(bpp, len(src)):
            src[i] = (src[i] + src[i - bpp]) & 255
    elif ftype == 2:
        pass
    elif ftype not in (0,):
        # Paeth / average on an all-zero previous row.
        prev = bytes(len(src))
        if ftype == 3:
            for i, v in enumerate(src):
                a = src[i - bpp] if i >= bpp else 0
                src[i] = (v + ((a + prev[i]) // 2)) & 255
        elif ftype == 4:
            def paeth(a, b, c):
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                if pa <= pb and pa <= pc:
                    return a
                if pb <= pc:
                    return b
                return c
            for i, v in enumerate(src):
                a = src[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                src[i] = (v + paeth(a, b, c)) & 255
        else:
            raise ValueError("filter %d" % ftype)
    r, g, b = src[0], src[1], src[2]
    return width, height, (r << 16) | (g << 8) | b

try:
    pw, ph, pix00 = png_pixel00(png_path)
except Exception as e:
    fails.append("screendump: %s" % e)
    pw = ph = pix00 = None
if pix00 is not None:
    if (pix00 & 0xFFFFFF) != (colour & 0xFFFFFF):
        fails.append("screendump (0,0) is 0x%06X, expected 0x%06X (png %dx%d)"
                     % (pix00 & 0xFFFFFF, colour & 0xFFFFFF, pw, ph))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    %s  PIX×5 0x1100  BACK  FRAMES %d  COLOUR 0x%08X  pmemsave+screendump match"
      % (label, frames, colour))
PY
}

check_positive "$WORKDIR/a/serial.txt" "$WORKDIR/a/info-pci.txt" \
  "$WORKDIR/a/back.bin" "$WORKDIR/a/screen.png" "$COLOR_A" "colour-A"
echo "ASSERT: pass  colour A 0x${COLOR_A_HEX}: five PIX 0x1100; pmemsave and screendump (0,0) match"

check_positive "$WORKDIR/b/serial.txt" "$WORKDIR/b/info-pci.txt" \
  "$WORKDIR/b/back.bin" "$WORKDIR/b/screen.png" "$COLOR_B" "colour-B"
echo "ASSERT: pass  colour B 0x${COLOR_B_HEX}: five PIX 0x1100; pmemsave and screendump (0,0) match"

ck; python3 - "$WORKDIR/a/back.bin" "$WORKDIR/b/back.bin" "$COLOR_A" "$COLOR_B" <<'PY' || fail "the two backing dumps did not change with the colour"
import struct, sys
a = struct.unpack_from("<I", open(sys.argv[1], "rb").read(), 0)[0]
b = struct.unpack_from("<I", open(sys.argv[2], "rb").read(), 0)[0]
ca, cb = int(sys.argv[3]), int(sys.argv[4])
if a == b:
    print("backing dumps are equal 0x%08X — colour did not move" % a, file=sys.stderr)
    sys.exit(1)
if a != ca or b != cb:
    print("dumps 0x%08X / 0x%08X, typed 0x%08X / 0x%08X" % (a, b, ca, cb),
          file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  second boot changed the backing word (0x${COLOR_A_HEX} → 0x${COLOR_B_HEX})"

ck; python3 - "$WORKDIR/noatt/serial.txt" "$WORKDIR/noatt/info-pci.txt" <<'PY' || fail "virtgpua negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if not re.search(r"1af4:1050", info, re.I):
    fails.append("virtgpua info pci has no 1af4:1050")
if "VIRTIO BACK " in serial:
    fails.append("virtgpua printed BACK — attach was supposed to be omitted")
if "VIRTIO FRAMES " in serial:
    fails.append("virtgpua printed FRAMES — attach was supposed to be omitted")
pix = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO PIX ")]
if len(pix) < 2:
    fails.append("virtgpua expected create+SET_SCANOUT PIX lines, found %r" % pix)
else:
    last = pix[-1]
    m = re.match(r"^VIRTIO PIX ([0-9A-F]{8})$", last)
    if not m:
        fails.append("unparseable last PIX: %r" % last)
    else:
        t = int(m.group(1), 16)
        if t == 0x1100:
            fails.append("virtgpua SET_SCANOUT returned 0x1100 — omitting attach must error")
        if t not in (0x1200, 0x1203, 0x1205):
            fails.append("virtgpua SET_SCANOUT is 0x%08X, want ERR_UNSPEC/INVALID_RESOURCE/INVALID_PARAMETER" % t)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtgpua SET_SCANOUT errors without attach (no BACK)"

ck; python3 - "$WORKDIR/std/serial.txt" "$WORKDIR/std/info-pci.txt" <<'PY' || fail "std-vga negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1af4:1050", info, re.I):
    fails.append("std-vga info pci still has 1af4:1050")
if "VIRTIO NONE" not in serial.splitlines():
    fails.append("std-vga did not print VIRTIO NONE")
for prefix in ("VIRTIO PIX ", "VIRTIO BACK ", "VIRTIO FRAMES ", "VIRTIO COLOUR "):
    hits = [ln for ln in serial.splitlines() if ln.startswith(prefix)]
    if hits:
        fails.append("std-vga printed %s: %r" % (prefix.strip(), hits))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO NONE and no PIX/BACK"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G4-virtgpu: PASS — RESOURCE create + SET_SCANOUT; pmemsave and screendump show derived colour; second colour moves the pixel; virtgpua errors; g0–g3 tokens absent"
