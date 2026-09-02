#!/usr/bin/env bash
# core/tests/conformance/g5-virtgpu/run.sh
#
# G5 — The framebuffer console runs on VirtIO instead of dispi.
# docs/design/gpu.md §5/G5, ADR-0084.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# `virtgpuc` creates a 2D resource at the device-reported width×height,
# attaches contiguous allocFrame() pages, SET_SCANOUT, points fbState at
# the first backing frame, and paints the existing 52-byte banner. Each
# glyph cell issues TRANSFER_TO_HOST_2D + RESOURCE_FLUSH.
#
# Proof is host-side, not a screenshot:
#   * xp of the printed VIRTIO BACK address, one scanline per glyph row,
#     matches glyphs derived from fbFont8x16 in the built ELF (same form
#     as m5-pci/check-pixels.py)
#   * VIRTIO FLUSH equals the committed count: one per glyph cell of the
#     banner (51 — the 52nd byte is newline and draws nothing)
#
# Anti-vacuity: check-font.py / check-pixels.py fail if zero foreground
# pixels were expected. Flush count 0 on the positive boot is a fail.
#
# Negative: `virtgpue` omits the cell flush. Pixel read-back still
# passes (backing is correct) and FLUSH is 0. `-vga std` prints
# VIRTIO NONE. `fb` on virtio-vga still takes the Bochs BAR (ADR-0064).
#
# Bare `virtgpu` / `virtgpu <hex>` are unchanged (g0–g4). No help, no
# last .bss, no forbidden tokens.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G5-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G5-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=52

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-objcopy; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g5.XXXXXX")" || setup_error "mktemp failed"
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

# Not QEMU 1280×800, not 800×600, not 1024×768, not G4's 1136×848.
XRES=1008
YRES=720
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
  || fail "virtgpu.dart has no virtgpuConsole"
ck; grep -q 'void virtgpuCell(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuCell — that is the flush call"
ck; grep -q 'virtgpuStrCmdCon' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuc command"
ck; grep -q 'virtgpuStrCmdNoFlush' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpue command — that is the negative control"
ck; grep -q 'virtgpuStrFlush' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no FLUSH label"
ck; grep -q 'virtgpuRamCeil' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name the low-RAM / BAR split"
ck; grep -q 'virtgpuCell(' "$CORE_DIR/kernel/fb.dart" \
  || fail "fb.dart never calls virtgpuCell — drawing gained no flush"
ck; grep -q 'shellVirtgpuCon' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpuc"
ck; grep -q 'shellVirtgpuNoFlush' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpue"

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
  || fail "virtgpu.dart declares @bss — G5 donates frames, not .bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G5 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G5 added a syscall — the criterion forbids one"
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
  || fail "derived mode is G4's 1136x848 — G5 must pick its own"
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
  || fail "kmain.o .bss contains $BSS_VIRT — G5 was not supposed to donate storage"

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
echo "STRUCTURAL: pass  virtgpuc/virtgpue named; no help, no .bss; last is wmeventStore; derived mode not a default; g0–g4 tokens absent"

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
echo "=== BOOT virtgpuc (console + flush) ==="
fill_dump_args
drive_session "$WORKDIR/con" "virtgpuc" "$KEYS_CON" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT virtgpue (console, no flush) ==="
fill_dump_args
drive_session "$WORKDIR/nof" "virtgpue" "$KEYS_NOFLUSH" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT fb coexistence (Bochs path on virtio-vga) ==="
DUMP_ARGS=()
drive_session "$WORKDIR/fb" "fb-coexist" "$KEYS_FB" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT std VGA (negative, no device) ==="
DUMP_ARGS=()
drive_session "$WORKDIR/std" "std-vga" "$KEYS_CON" \
  -vga std

# ===========================================================================
# Step 4 — criterion.
# ===========================================================================
echo
echo "=== CRITERION ==="

check_console() {
  local ser="$1" info="$2" dump="$3" want_flush="$4" label="$5"
  ck; python3 - "$ser" "$info" "$want_flush" "$XRES" "$YRES" "$FRAMES" "$label" <<'PY' || fail "$5 serial did not satisfy G5"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
want_flush = int(sys.argv[3])
xres, yres, frames = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
label = sys.argv[7]
fails = []

if not re.search(r"1af4:1050", info, re.I):
    fails.append("QEMU info pci has no 1af4:1050")
if "VIRTIO NONE" in serial.splitlines():
    fails.append("printed VIRTIO NONE — the device was attached")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("printed VIRTIO QTIMEOUT")

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
        fails.append("BACK 0x%s is in the PCI hole — that is the BAR, not RAM"
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
    fails.append("G5 printed PIX lines — that is G4's colour form: %r" % pix)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    %s  BACK  FRAMES %d  FLUSH %d" % (label, frames, want_flush))
PY
  ck; python3 "$CHECK_PIX" \
        "$dump" "$WORKDIR/rodata.bin" "$FONT_OFF" \
        "$BANNER" "$FG" "$BG" \
    || fail "$label glyph pixels at BACK do not match fbFont8x16"
}

check_console "$WORKDIR/con/serial.txt" "$WORKDIR/con/info-pci.txt" \
  "$WORKDIR/con/info-pci.txt" "$FLUSH_N" "virtgpuc"
echo "ASSERT: pass  virtgpuc  BACK in low RAM  FRAMES $FRAMES  FLUSH $FLUSH_N  glyphs match font"

check_console "$WORKDIR/nof/serial.txt" "$WORKDIR/nof/info-pci.txt" \
  "$WORKDIR/nof/info-pci.txt" 0 "virtgpue"
echo "ASSERT: pass  virtgpue  backing glyphs match  FLUSH 0 — flush count measures the device round trip"

ck; python3 - "$WORKDIR/fb/serial.txt" "$WORKDIR/fb/info-pci.txt" <<'PY' || fail "fb coexistence did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if not re.search(r"1af4:1050", info, re.I):
    fails.append("fb-coexist info pci has no 1af4:1050")
if not re.search(r"^FB BAR [0-9A-F]{8} MODE 0320x0258x20 OK$", serial, re.M):
    fails.append("fb on virtio-vga did not print FB BAR … MODE 0320x0258x20 OK")
if "VIRTIO BACK " in serial:
    fails.append("bare fb printed VIRTIO BACK — G5 must not steal the Bochs path")
if "VIRTIO FLUSH " in serial:
    fails.append("bare fb printed VIRTIO FLUSH")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  fb on virtio-vga still takes Bochs 800x600 (ADR-0064); G5 is explicit"

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
echo "G5-virtgpu: PASS — console on VirtIO backing; 51 glyph-cell flushes; virtgpue keeps pixels and prints FLUSH 0; fb Bochs path untouched; g0–g4 tokens absent"
