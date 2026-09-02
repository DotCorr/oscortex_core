#!/usr/bin/env bash
# core/tests/conformance/g8-virtgpu/run.sh
#
# G8 — Two resources, SET_SCANOUT flips between them.
# docs/design/gpu.md §5/G8, ADR-0093, GAP-0070 item 6.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# `virtgpuf` creates resource 1 and resource 2, attaches a contiguous
# backing run to each, SET_SCANOUT of resource 1, paints the banner
# into resource 1, paints the same banner into resource 2 at the next
# glyph row, then SET_SCANOUT of resource 2.
#
# Proof is host-side, not a screenshot:
#   * two VIRTIO RES lines (00000001 then 00000002)
#   * two distinct VIRTIO BACK addresses in low RAM
#   * VIRTIO FLIP 00000001 00000002
#   * xp of the sixteen banner scanlines at the SECOND BACK, offset
#     one glyph row, matches fbFont8x16 (m5 form, not a PNG)
#
# Anti-vacuity: one BACK, a FLIP of 1 1, or a row-0 dump of resource
# 2 (that would pass a memcpy of resource 1) is a fail.
#
# Negative: `virtgpuy` paints both and never flips. Pixels on
# resource 2 still match; the FLIP line is absent.
#
# `fb` on virtio-vga still takes Bochs. `-vga std` prints VIRTIO NONE.
# G5–G7 commands are not rewritten. No help, no last .bss, no
# forbidden tokens.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G8-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G8-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=57

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-objcopy; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g8.XXXXXX")" || setup_error "mktemp failed"
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
# not G5's 1008×720, not G6's 912×688, not G7's 864×640.
XRES=880
YRES=656
FRAMES=$(( (XRES * YRES * 4 + 4095) / 4096 ))
PITCH=$(( XRES * 4 ))
GLYPH_H=16
ROW1_OFF=$(( GLYPH_H * PITCH ))
BANNER='OSCORTEX framebuffer console  800x600x32  8x16 font'
BANNER_CHARS=51
FLUSH_N=$(( BANNER_CHARS + BANNER_CHARS ))
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
ck; grep -q 'void virtgpuFlip(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuFlip"
ck; grep -q 'u64 virtgpuMake2d(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuMake2d — two resources need a create/attach helper"
ck; grep -q 'void virtgpuConsole(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart lost virtgpuConsole — G5 walk must remain"
ck; grep -q 'void virtgpuCell(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart lost virtgpuCell — G5 flush call must remain"
ck; grep -q 'virtgpuStrCmdFlip' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuf command"
ck; grep -q 'virtgpuStrCmdNoFlip' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuy command — that is the negative control"
ck; grep -q 'const int virtgpuResId2 = 2;' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart does not name resource id 2"
ck; grep -q 'virtgpuStrFlip' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no FLIP label"
ck; grep -q 'shellVirtgpuFlip' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpuf"
ck; grep -q 'shellVirtgpuNoFlip' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpuy"
ck; [[ -f "$CORE_DIR/docs/decisions/0093-two-resources-set-scanout-flip.md" ]] \
  || fail "ADR-0093 is missing"

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc", "pciWrite32", "virtgpuOneCmd",
              "virtgpuPix", "virtgpuConsole", "virtgpuCell", "virtgpuFlip"):
    if token in body:
        print("virtgpuInit mentions %r" % token, file=sys.stderr)
        sys.exit(1)
PY

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "G5–G7 commands were rewritten"
import sys
src = open(sys.argv[1]).read()
for name in ("shellVirtgpuCon", "shellVirtgpuNoFlush",
             "shellVirtgpuScroll", "shellVirtgpuScrollNo"):
    if "void %s(" % name not in src:
        print("%s is missing" % name, file=sys.stderr)
        sys.exit(1)
if "void virtgpuConsole(" not in src:
    print("virtgpuConsole is missing", file=sys.stderr); sys.exit(1)
PY

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'virtgpu.dart';" ]] \
  || fail "part 'virtgpu.dart' is last in kmain.dart — D7 owns that position"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart declares @bss — G8 donates frames, not .bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G8 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G8 added a syscall — the criterion forbids one"
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
ck; [[ "$XRES" -ne 1136 && "$YRES" -ne 848 ]] \
  || fail "derived mode is G4's 1136x848 — G8 must pick its own"
ck; [[ "$XRES" -ne 1008 && "$YRES" -ne 720 ]] \
  || fail "derived mode is G5's 1008x720 — G8 must pick its own"
ck; [[ "$XRES" -ne 912 && "$YRES" -ne 688 ]] \
  || fail "derived mode is G6's 912x688 — G8 must pick its own"
ck; [[ "$XRES" -ne 864 && "$YRES" -ne 640 ]] \
  || fail "derived mode is G7's 864x640 — G8 must pick its own"
ck; [[ "$FLUSH_N" -eq 102 ]] || fail "committed flush count is $FLUSH_N, not 102"
ck; [[ "$FLUSH_N" -gt 51 ]] || fail "committed flush count is $FLUSH_N — one paint only"
ck; [[ "$FRAMES" -gt 1 ]] || fail "derived backing frame count is $FRAMES"

LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — stolen last place"
BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G8 was not supposed to donate storage"

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
echo "STRUCTURAL: pass  virtgpuf/virtgpuy named; two resource ids; no help, no .bss; last is wmeventStore; derived mode not a default; G5–G7 walks remain"

# ===========================================================================
# Step 3 — boots.
# ===========================================================================

KEYS_FLIP="v,i,r,t,g,p,u,f,ret,wait:25000"
KEYS_NOFLIP="v,i,r,t,g,p,u,y,ret,wait:25000"
KEYS_FB="f,b,ret,wait:1500"
DUMP_ARGS=()

fill_dump_args() {
  # Second resource's BACK. Banner is on glyph row 1 so a memcpy of
  # resource 1 (banner on row 0) cannot pass.
  DUMP_ARGS=(--addr-from-serial 'VIRTIO RES 00000002\r?\nVIRTIO BACK ([0-9A-F]{8})')
  local scanline
  for scanline in $(seq 0 15); do
    DUMP_ARGS+=(--monitor-command "xp/$(( BANNER_CHARS * 8 ))wx {addr}+$(( ROW1_OFF + scanline * PITCH ))")
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
echo "=== BOOT virtgpuf (two resources + SET_SCANOUT flip) ==="
fill_dump_args
drive_session "$WORKDIR/flip" "virtgpuf" "$KEYS_FLIP" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT virtgpuy (two paints, no flip) ==="
fill_dump_args
drive_session "$WORKDIR/nof" "virtgpuy" "$KEYS_NOFLIP" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT fb coexistence (Bochs path on virtio-vga) ==="
DUMP_ARGS=()
drive_session "$WORKDIR/fb" "fb-coexist" "$KEYS_FB" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT std VGA (negative, no device) ==="
DUMP_ARGS=()
drive_session "$WORKDIR/std" "std-vga" "$KEYS_FLIP" \
  -vga std

# ===========================================================================
# Step 4 — criterion.
# ===========================================================================
echo
echo "=== CRITERION ==="

check_pair() {
  local ser="$1" info="$2" dump="$3" want_flip="$4" label="$5"
  ck; python3 - "$ser" "$info" "$want_flip" "$XRES" "$YRES" "$FRAMES" "$FLUSH_N" "$label" <<'PY' || fail "$5 serial did not satisfy G8"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
want_flip = int(sys.argv[3])
xres, yres, frames = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
flush_n = int(sys.argv[7])
label = sys.argv[8]
fails = []

if not re.search(r"1af4:1050", info, re.I):
    fails.append("QEMU info pci has no 1af4:1050")
if "VIRTIO NONE" in serial.splitlines():
    fails.append("printed VIRTIO NONE — the device was attached")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("printed VIRTIO QTIMEOUT")

ress = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO RES ")]
if len(ress) != 2:
    fails.append("expected two RES lines, found %d: %r" % (len(ress), ress))
else:
    ids = []
    for ln in ress:
        m = re.match(r"^VIRTIO RES ([0-9A-F]{8})$", ln)
        if not m:
            fails.append("unparseable RES: %r" % ln)
        else:
            ids.append(int(m.group(1), 16))
    if ids == [1, 2]:
        pass
    elif ids:
        fails.append("RES ids are %r, want [1, 2]" % ids)

backs = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO BACK ")]
if len(backs) != 2:
    fails.append("expected two BACK lines, found %d: %r" % (len(backs), backs))
else:
    addrs = []
    for ln in backs:
        m = re.match(r"^VIRTIO BACK ([0-9A-F]{8})$", ln)
        if not m:
            fails.append("unparseable BACK: %r" % ln)
        else:
            a = int(m.group(1), 16)
            if a == 0:
                fails.append("BACK address is 0")
            elif a >= 0x8000000:
                fails.append("BACK 0x%s is in the PCI hole — that is a BAR, not RAM"
                             % m.group(1))
            addrs.append(a)
    if len(addrs) == 2 and addrs[0] == addrs[1]:
        fails.append("both BACK addresses are 0x%08X — one resource, not two"
                     % addrs[0])

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
        if got != flush_n:
            fails.append("FLUSH is %d, committed two-paint count is %d"
                         % (got, flush_n))

flips = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO FLIP ")]
if want_flip:
    if len(flips) != 1:
        fails.append("expected one FLIP line, found %d: %r" % (len(flips), flips))
    else:
        m = re.match(r"^VIRTIO FLIP ([0-9A-F]{8}) ([0-9A-F]{8})$", flips[0])
        if not m:
            fails.append("unparseable FLIP: %r" % flips[0])
        else:
            a, b = int(m.group(1), 16), int(m.group(2), 16)
            if a == b:
                fails.append("FLIP names the same id twice (%d) — scanout did not change"
                             % a)
            if a != 1 or b != 2:
                fails.append("FLIP is %d %d, want 1 2" % (a, b))
else:
    if flips:
        fails.append("virtgpuy printed FLIP — that is the scanout change: %r"
                     % flips)

pix = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO PIX ")]
if pix:
    fails.append("G8 printed PIX lines — that is G4's colour form: %r" % pix)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    %s  RES 1+2  two BACK  FRAMES %d  FLUSH %d  flip=%d"
      % (label, frames, flush_n, want_flip))
PY
  ck; python3 "$CHECK_PIX" \
        "$dump" "$WORKDIR/rodata.bin" "$FONT_OFF" \
        "$BANNER" "$FG" "$BG" \
    || fail "$label glyph pixels at resource-2 row 1 do not match fbFont8x16"
}

check_pair "$WORKDIR/flip/serial.txt" "$WORKDIR/flip/info-pci.txt" \
  "$WORKDIR/flip/info-pci.txt" 1 "virtgpuf"
echo "ASSERT: pass  virtgpuf  RES 1+2  two BACK  FLIP 1 2  FRAMES $FRAMES  FLUSH $FLUSH_N  row-1 glyphs match font"

check_pair "$WORKDIR/nof/serial.txt" "$WORKDIR/nof/info-pci.txt" \
  "$WORKDIR/nof/info-pci.txt" 0 "virtgpuy"
echo "ASSERT: pass  virtgpuy  paints both  no FLIP — the line measures SET_SCANOUT, not the blit"

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
    fails.append("bare fb printed VIRTIO BACK — G8 must not steal the Bochs path")
if "VIRTIO FLIP " in serial:
    fails.append("bare fb printed VIRTIO FLIP")
if "VIRTIO FLUSH " in serial:
    fails.append("bare fb printed VIRTIO FLUSH")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  fb on virtio-vga still takes Bochs 800x600 (ADR-0064); G8 is explicit"

ck; python3 - "$WORKDIR/std/serial.txt" "$WORKDIR/std/info-pci.txt" <<'PY' || fail "std-vga negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1af4:1050", info, re.I):
    fails.append("std-vga info pci still has 1af4:1050")
if "VIRTIO NONE" not in serial.splitlines():
    fails.append("std-vga did not print VIRTIO NONE")
for prefix in ("VIRTIO BACK ", "VIRTIO FRAMES ", "VIRTIO FLUSH ", "VIRTIO FLIP ",
               "VIRTIO RES "):
    hits = [ln for ln in serial.splitlines() if ln.startswith(prefix)]
    if hits:
        fails.append("std-vga printed %s: %r" % (prefix.strip(), hits))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO NONE and no RES/BACK/FLIP"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G8-virtgpu: PASS — two resources; SET_SCANOUT flip 1→2; row-1 glyphs on the new scanout match the font; virtgpuy paints both and prints no FLIP; fb Bochs path untouched"
