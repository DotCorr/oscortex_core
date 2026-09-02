#!/usr/bin/env bash
# core/tests/conformance/g7-virtgpu/run.sh
#
# G7 — virtio-gpu-pci with no VGA-class device at all.
# docs/design/gpu.md §5/G7, ADR-0091.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# The G5 console walk (`virtgpuc`) on `-vga none -device virtio-gpu-pci`
# (class 03/80). There is no linear BAR, no dispi, no VGA BIOS.
# Discovery is vendor 0x1AF4 / device 0x1050; the mode comes from
# GET_DISPLAY_INFO. `fb` prints the ADR-0064 NONE line — this machine
# has no VGA-class BAR, so `FB NOVBE` would be a lie (that string is
# for a VGA BAR whose dispi ID did not answer).
#
# Proof is host-side, not a screenshot:
#   * QEMU `info pci` contains zero "VGA controller" devices and one
#     1af4:1050
#   * kernel device line is class 03/80, not 03/00
#   * xp of the printed VIRTIO BACK address matches fbFont8x16
#   * VIRTIO FLUSH equals 51 (one per banner glyph cell)
#   * `fb` prints `FB NONE -- no VGA-class device with a memory BAR0
#     on bus 0`
#
# Anti-vacuity: a VGA-class device on the bus is a fail. Flush 0 on
# the positive boot is a fail. `FB BAR` / `FB NOVBE` on this machine
# is a fail (quiet substitution).
#
# Negative: `virtgpue` omits the cell flush (pixels still match,
# FLUSH 0). `-vga std` (no virtio-gpu) prints VIRTIO NONE.
#
# g0–g6 stay on virtio-vga / VGA. This harness does not rewrite
# those contracts. No help, no last .bss, no forbidden tokens,
# no two-resource SET_SCANOUT flip.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G7-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G7-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=57

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-objcopy; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g7.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
CHECK_FONT="$CORE_DIR/tests/conformance/m5-pci/check-font.py"
CHECK_PIX="$CORE_DIR/tests/conformance/m5-pci/check-pixels.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$CHECK_FONT" ]] || setup_error "check-font.py not found"
[[ -f "$CHECK_PIX" ]] || setup_error "check-pixels.py not found"

# Not QEMU 1280×800, not 800×600, not 1024×768, not G4's 1136×848,
# not G5's 1008×720, not G6's 912×688.
XRES=864
YRES=640
FRAMES=$(( (XRES * YRES * 4 + 4095) / 4096 ))
PITCH=$(( XRES * 4 ))
BANNER='OSCORTEX framebuffer console  800x600x32  8x16 font'
BANNER_CHARS=51
FLUSH_N=$BANNER_CHARS
FG=0x00C8C8C8
BG=0x00101018

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
ck; grep -q 'void virtgpuConsole(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuConsole — G5 walk must remain"
ck; grep -q 'void virtgpuCell(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuCell — G5 flush call must remain"
ck; grep -q 'const int virtgpuVendor = 0x1AF4;' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name vendor 0x1AF4"
ck; grep -q 'const int virtgpuDevice = 0x1050;' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name device 0x1050"
ck; grep -q 'virtgpuStrCmdCon' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuc command"
ck; grep -q 'virtgpuStrCmdNoFlush' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpue command — that is the negative control"
ck; grep -q 'fbStrNoDev' "$CORE_DIR/kernel/fb.dart" \
  || fail "fb.dart has no fbStrNoDev — G7 must reuse FB NONE, not invent a spelling"
ck; grep -q 'FB NONE' "$CORE_DIR/kernel/fb.dart" \
  || fail "fb.dart lost the FB NONE fallback string"
ck; [[ -f "$CORE_DIR/docs/decisions/0091-virtio-gpu-pci-has-no-vga.md" ]] \
  || fail "ADR-0091 is missing"

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "discovery is not vendor/device — G7 would miss class 03/80"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuGo\(.*?\n\}", src, re.S)
if not m:
    print("virtgpuGo is missing", file=sys.stderr); sys.exit(1)
body = m.group(0)
if "virtgpuVendor" not in body or "virtgpuDevice" not in body:
    print("virtgpuGo does not match virtgpuVendor/virtgpuDevice", file=sys.stderr)
    sys.exit(1)
if "pciSubclassVga" in body:
    print("virtgpuGo filters pciSubclassVga — class 03/80 would print VIRTIO NONE",
          file=sys.stderr)
    sys.exit(1)
PY

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc", "pciWrite32", "virtgpuOneCmd",
              "virtgpuPix", "virtgpuConsole", "virtgpuCell"):
    if token in body:
        print("virtgpuInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'virtgpu.dart';" ]] \
  || fail "part 'virtgpu.dart' is last in kmain.dart — D7 owns that position"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart declares @bss — G7 donates frames, not .bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G7 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G7 added a syscall — the criterion forbids one"
ck; ! grep -qE 'queue_enable\s*=|RESOURCE_CREATE_2D|VIRTIO_GPU_CMD' \
      "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart uses a token g0/g1/g2/g3 forbid — those rungs would go red"
# THE DRIVER MUST NOT BE ECHOING THIS HARNESS'S HINT.
#
# This was two `grep -q "$XRES"` lines over the whole file. Both are wrong now
# and one was always weak. ADR-0189 (accepted, closes GAP-0328) established
# that `pmodes[0]` is a hint about the host window rather than a mode list, so
# the driver now NAMES the mode it drives -- `virtgpuModeWantW`/`H`, 1280x720 --
# and g5's hint height is also 720, so the raw grep fired on a constant the ADR
# put there on purpose. g7's fired on the string "640x480" inside the doc
# comment that EXPLAINS the ADR. And neither would have noticed a driver that
# typed some THIRD resolution it had no business knowing.
#
# So: comments are stripped, and every display-range literal in the remaining
# CODE must be one of a named few. That is strictly more than the old pair of
# greps -- it fails on any resolution baked anywhere in the driver, not just on
# the two numbers this harness happens to pass -- and it still says the thing
# the check was for: the geometry is not this harness's.
capture_sh MODE_OUT MODE_STATUS -- "python3 - '$CORE_DIR/kernel/virtgpu.dart' $XRES $YRES <<'PY'
import re, sys
src, xres, yres = open(sys.argv[1]).read(), int(sys.argv[2]), int(sys.argv[3])
code = re.sub(r'/[*].*?[*]/', '', src, flags=re.S)
code = '\n'.join(l.split('//', 1)[0] for l in code.split('\n'))

# Literals a display dimension could plausibly be, and the ONLY names allowed
# to hold one. Everything else in the range is a size in bytes or a cap, and
# each is listed with what it is, so a new one has to be justified here.
NOT_GEOMETRY = {408: 'virtgpuDispBytes', 1024: 'virtgpuBackCap',
                4095: 'page-round arithmetic', 4096: 'page-round arithmetic'}
MODE_NAMES = ('virtgpuModeWantW', 'virtgpuModeWantH')

bad, mode = [], {}
for n, line in enumerate(code.split('\n'), 1):
    d = re.match(r'\s*const int (virtgpuModeWant[WH]) = (\d+);', line)
    if d:
        mode[d.group(1)] = int(d.group(2))
        continue
    for m in re.finditer(r'\b(\d{3,4})\b', line):
        v = int(m.group(1))
        if 320 <= v <= 7680 and v not in NOT_GEOMETRY:
            bad.append('virtgpu.dart:%d bakes the display-range literal %d: %s'
                       % (n, v, line.strip()[:90]))

for name in MODE_NAMES:
    if name not in mode:
        bad.append('virtgpu.dart declares no %s -- ADR-0189 says the driver '
                   'picks the mode, and it has to say which' % name)
if mode.get('virtgpuModeWantW') == xres and mode.get('virtgpuModeWantH') == yres:
    bad.append('the driver requests %dx%d, which is exactly the xres=/yres= '
               'this harness passed -- the mode came from the hint after all'
               % (xres, yres))
if bad:
    raise SystemExit('\n'.join(bad))
print('    (the only display-range literals in virtgpu.dart CODE are '
      'virtgpuModeWantW=%d and virtgpuModeWantH=%d, ADR-0189\'s request, and '
      'that pair is not this harness\'s %dx%d hint)'
      % (mode['virtgpuModeWantW'], mode['virtgpuModeWantH'], xres, yres))
PY"
echo "$MODE_OUT"
ck; [[ -n "$MODE_OUT" ]] || fail "the display-geometry census printed nothing — it did not run"
ck; [[ $MODE_STATUS -eq 0 ]] || fail "virtgpu.dart bakes display geometry: $MODE_OUT"
ck; [[ "$XRES" -ne 1280 && "$YRES" -ne 800 ]] \
  || fail "derived mode is QEMU's default 1280x800"
ck; [[ "$XRES" -ne 800 && "$YRES" -ne 600 ]] \
  || fail "derived mode is the kernel's compiled-in 800x600"
ck; [[ "$XRES" -ne 1024 && "$YRES" -ne 768 ]] \
  || fail "derived mode is the spec fallback 1024x768"
ck; [[ "$XRES" -ne 1136 && "$YRES" -ne 848 ]] \
  || fail "derived mode is G4's 1136x848 — G7 must pick its own"
ck; [[ "$XRES" -ne 1008 && "$YRES" -ne 720 ]] \
  || fail "derived mode is G5's 1008x720 — G7 must pick its own"
ck; [[ "$XRES" -ne 912 && "$YRES" -ne 688 ]] \
  || fail "derived mode is G6's 912x688 — G7 must pick its own"
ck; [[ "$FLUSH_N" -eq 51 ]] || fail "committed flush count is $FLUSH_N, not 51"
ck; [[ "$FLUSH_N" -gt 0 ]] || fail "committed flush count is 0 — vacuous"
ck; [[ "$FRAMES" -gt 1 ]] || fail "derived backing frame count is $FRAMES"

LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — stolen last place"
BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G7 was not supposed to donate storage"

ck; x86_64-elf-objcopy -O binary --only-section=.rodata \
      "$CORE_DIR/build/kmain.o" "$WORKDIR/rodata.bin" \
  || fail "could not extract .rodata from kmain.o"
FONT_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="fbFont8x16" {print $2; exit}')
ck; [[ -n "$FONT_OFF_HEX" ]] || fail "fbFont8x16 has no symbol value in kmain.o"
FONT_OFF=$((16#$FONT_OFF_HEX))
ck; python3 "$CHECK_FONT" "$WORKDIR/rodata.bin" "$FONT_OFF" \
  || fail "fbFont8x16 is not a well-formed 96-glyph 8x16 font"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  virtio-gpu-pci discovery is vendor/device; FB NONE reused; no help, no .bss; last is wmeventStore; derived mode not a default"

# ===========================================================================
# Step 3 — boots.
# ===========================================================================

KEYS_CON="v,i,r,t,g,p,u,c,ret,wait:20000"
KEYS_NOFLUSH="v,i,r,t,g,p,u,e,ret,wait:15000"
KEYS_FB="f,b,ret,wait:1500"
DUMP_ARGS=()

fill_dump_args() {
  DUMP_ARGS=(--addr-from-serial 'VIRTIO BACK ([0-9A-F]{8})')
  local scanline
  for scanline in $(seq 0 15); do
    DUMP_ARGS+=(--monitor-command "xp/$(( BANNER_CHARS * 8 ))wx {addr}+$(( scanline * PITCH ))")
  done
}

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
  local -a extra=()
  if [[ ${#DUMP_ARGS[@]} -gt 0 ]]; then
    extra=("${DUMP_ARGS[@]}")
  fi
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for 'M1 END\n' \
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt" \
    --monitor-command 'info pci' --monitor-capture "$outdir/info-pci.txt" \
    "${extra[@]}" \
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
echo "=== BOOT virtio-gpu-pci virtgpuc (console + flush, no VGA) ==="
fill_dump_args
drive_session "$WORKDIR/con" "virtgpuc" "$KEYS_CON" \
  -vga none -device "virtio-gpu-pci,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT virtio-gpu-pci virtgpue (console, no flush) ==="
fill_dump_args
drive_session "$WORKDIR/nof" "virtgpue" "$KEYS_NOFLUSH" \
  -vga none -device "virtio-gpu-pci,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT virtio-gpu-pci fb (ADR-0064 NONE) ==="
DUMP_ARGS=()
drive_session "$WORKDIR/fb" "fb-none" "$KEYS_FB" \
  -vga none -device "virtio-gpu-pci,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT std VGA (negative, no virtio-gpu) ==="
DUMP_ARGS=()
drive_session "$WORKDIR/std" "std-vga" "$KEYS_CON" \
  -vga std

# ===========================================================================
# Step 4 — criterion.
# ===========================================================================
echo
echo "=== CRITERION ==="

check_no_vga() {
  local info="$1" label="$2"
  ck; python3 - "$info" "$label" <<'PY' || fail "$2 info pci still has a VGA-class device"
import re, sys
info = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
label = sys.argv[2]
fails = []
if re.search(r"VGA controller", info, re.I):
    fails.append("%s info pci lists a VGA controller — this is not a no-VGA boot" % label)
if not re.search(r"1af4:1050", info, re.I):
    fails.append("%s info pci has no 1af4:1050" % label)
if re.search(r"virtio-vga", info, re.I):
    fails.append("%s info pci names virtio-vga" % label)
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
}

check_console() {
  local ser="$1" info="$2" dump="$3" want_flush="$4" label="$5"
  check_no_vga "$info" "$label"
  ck; python3 - "$ser" "$info" "$want_flush" "$XRES" "$YRES" "$FRAMES" "$label" <<'PY' || fail "$5 serial did not satisfy G7"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
want_flush = int(sys.argv[3])
xres, yres, frames = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
label = sys.argv[7]
fails = []

if "VIRTIO NONE" in serial.splitlines():
    fails.append("printed VIRTIO NONE — virtio-gpu-pci was attached")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("printed VIRTIO QTIMEOUT")

dev_re = re.compile(
    r"^VIRTIO ([0-9A-F]{2}):([0-9A-F]{2})\.([0-9A-F]) "
    r"([0-9A-F]{4}):([0-9A-F]{4}) "
    r"([0-9A-F]{2})/([0-9A-F]{2})/([0-9A-F]{2})$")
devs = [ln for ln in serial.splitlines() if dev_re.match(ln)]
if len(devs) != 1:
    fails.append("expected one VIRTIO device line, found %d: %r" % (len(devs), devs))
else:
    m = dev_re.match(devs[0])
    clas, sub = m.group(6), m.group(7)
    if clas != "03" or sub != "80":
        fails.append("device class is %s/%s, expected 03/80 (virtio-gpu-pci, not virtio-vga)"
                     % (clas, sub))
    if m.group(4) != "1AF4" or m.group(5) != "1050":
        fails.append("device line is %s:%s, expected 1AF4:1050" % (m.group(4), m.group(5)))

backs = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO BACK ")]
if len(backs) != 1:
    fails.append("expected one BACK line, found %d: %r" % (len(backs), backs))
else:
    m = re.match(r"^VIRTIO BACK ([0-9A-F]{8})$", backs[0])
    if not m:
        fails.append("unparseable BACK: %r" % backs[0])
    elif int(m.group(1), 16) == 0:
        fails.append("BACK address is 0")
    elif int(m.group(1), 16) >= 0x8000000:
        fails.append("BACK 0x%s is in the PCI hole — that is a BAR, not RAM"
                     % m.group(1))

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

fls = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO FLUSH ")]
if len(fls) != 1:
    fails.append("expected one FLUSH line, found %d: %r" % (len(fls), fls))
else:
    m = re.match(r"^VIRTIO FLUSH ([0-9A-F]{8})$", fls[0])
    if not m:
        fails.append("unparseable FLUSH: %r" % fls[0])
    else:
        got = int(m.group(1), 16)
        if got != want_flush:
            fails.append("FLUSH is %d, committed count is %d" % (got, want_flush))

pix = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO PIX ")]
if pix:
    fails.append("G7 printed PIX lines — that is G4's colour form: %r" % pix)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    %s  class 03/80  BACK  FRAMES %d  FLUSH %d" % (label, frames, want_flush))
PY
  ck; python3 "$CHECK_PIX" \
        "$dump" "$WORKDIR/rodata.bin" "$FONT_OFF" \
        "$BANNER" "$FG" "$BG" \
    || fail "$label glyph pixels at BACK do not match fbFont8x16"
}

check_console "$WORKDIR/con/serial.txt" "$WORKDIR/con/info-pci.txt" \
  "$WORKDIR/con/info-pci.txt" "$FLUSH_N" "virtgpuc"
echo "ASSERT: pass  virtio-gpu-pci virtgpuc  no VGA  class 03/80  BACK in low RAM  FRAMES $FRAMES  FLUSH $FLUSH_N  glyphs match font"

check_console "$WORKDIR/nof/serial.txt" "$WORKDIR/nof/info-pci.txt" \
  "$WORKDIR/nof/info-pci.txt" 0 "virtgpue"
echo "ASSERT: pass  virtio-gpu-pci virtgpue  backing glyphs match  FLUSH 0 — flush count measures the device round trip"

check_no_vga "$WORKDIR/fb/info-pci.txt" "fb-none"
ck; python3 - "$WORKDIR/fb/serial.txt" "$WORKDIR/fb/info-pci.txt" <<'PY' || fail "fb on virtio-gpu-pci did not print FB NONE"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
none = [ln for ln in serial.splitlines()
        if ln.startswith("FB NONE -- no VGA-class device with a memory BAR0 on bus 0")]
if len(none) != 1:
    fails.append("expected one FB NONE line, found %d: %r" % (len(none), none))
if re.search(r"^FB BAR ", serial, re.M):
    fails.append("fb printed FB BAR — a VGA-class BAR answered on a no-VGA machine")
if re.search(r"^FB NOVBE ", serial, re.M):
    fails.append("fb printed FB NOVBE — that string is for a VGA BAR without dispi; this machine has no VGA class")
if re.search(r"^FB GOP ", serial, re.M):
    fails.append("fb printed FB GOP — -kernel has no GOP tag")
if "VIRTIO BACK " in serial:
    fails.append("bare fb printed VIRTIO BACK — G7 must not steal fb into the VirtIO walk")
if "VIRTIO FLUSH " in serial:
    fails.append("bare fb printed VIRTIO FLUSH")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  fb on virtio-gpu-pci prints FB NONE (ADR-0064); no BAR, no NOVBE, no GOP"

ck; python3 - "$WORKDIR/std/serial.txt" "$WORKDIR/std/info-pci.txt" <<'PY' || fail "std-vga negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1af4:1050", info, re.I):
    fails.append("std-vga info pci still has 1af4:1050")
if "VIRTIO NONE" not in serial.splitlines():
    fails.append("std-vga did not print VIRTIO NONE")
for prefix in ("VIRTIO BACK ", "VIRTIO FRAMES ", "VIRTIO FLUSH "):
    hits = [ln for ln in serial.splitlines() if ln.startswith(prefix)]
    if hits:
        fails.append("std-vga printed %s: %r" % (prefix.strip(), hits))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO NONE and no BACK/FLUSH"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G7-virtgpu: PASS — virtio-gpu-pci with no VGA-class device; FB NONE; G5 console+flush on backing; virtgpue FLUSH 0; -vga std is VIRTIO NONE"
