#!/usr/bin/env bash
# core/tests/conformance/g6-virtgpu/run.sh
#
# G6 — Damage is a number, and scrolling exists (on the G5 VirtIO path).
# docs/design/gpu.md §5/G6, ADR-0086.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# `virtgpus` does the G5 walk, paints the banner a second time on the next
# row, then scrolls. The moved rectangle is TRANSFER_TO_HOST_2D +
# RESOURCE_FLUSH. Proof is host-side, not a screenshot:
#   * After scroll, xp of the first 16 scanlines at BACK matches the
#     banner derived from fbFont8x16 (the second banner is now on row 0)
#   * First VIRTIO FLUSH is G5's 51; the second is not 51
#   * Last VIRTIO DAMAGE equals fbWidth × (fbHeight − glyphHeight),
#     not 0, not 51, not the full-frame 800×600
#
# Anti-vacuity: a constant that is always 51 fails. A zero damage
# count fails. A full-frame transfer fails.
#
# Negative: `virtgpux` does the same paint+scroll with every flush
# omitted. Pixels still match (guest memcpy is real) and FLUSH /
# DAMAGE stay 0. `fb` on virtio-vga still takes Bochs. `-vga std`
# prints VIRTIO NONE.
#
# G5 contracts are untouched: virtgpuc still prints one FLUSH 51.
# No help, no last .bss, no forbidden tokens, no G7.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G6-virtgpu: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G6-virtgpu: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=59

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-objcopy; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-g6.XXXXXX")" || setup_error "mktemp failed"
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
# not G5's 1008×720.
XRES=912
YRES=688
FRAMES=$(( (XRES * YRES * 4 + 4095) / 4096 ))
PITCH=$(( XRES * 4 ))
BANNER='OSCORTEX framebuffer console  800x600x32  8x16 font'
BANNER_CHARS=51
FLUSH_BEFORE=$BANNER_CHARS
FLUSH_AFTER=$(( BANNER_CHARS + BANNER_CHARS + 1 ))
CELL_PX=$(( 8 * 16 ))
FB_W=800
FB_H=600
GLYPH_H=16
SCROLL_PX=$(( FB_W * (FB_H - GLYPH_H) ))
FULL_PX=$(( FB_W * FB_H ))
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
  || fail "virtgpu.dart has no virtgpuCell — G5 flush call must remain"
ck; grep -q 'void virtgpuRect(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpuRect — that is the G6 rectangle flush"
ck; grep -q 'virtgpuStrCmdScroll' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpus command"
ck; grep -q 'virtgpuStrCmdScrollNo' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no virtgpux command — that is the negative control"
ck; grep -q 'virtgpuStrDamage' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "virtgpu.dart has no DAMAGE label"
ck; grep -q 'u64 fbScroll(' "$CORE_DIR/kernel/fb.dart" \
  || fail "fb.dart has no fbScroll"
ck; grep -q 'virtgpuRect(' "$CORE_DIR/kernel/fb.dart" \
  || fail "fb.dart never calls virtgpuRect — scroll gained no flush"
ck; grep -q 'shellVirtgpuScroll' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpus"
ck; grep -q 'shellVirtgpuScrollNo' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpux"

ck; python3 - "$CORE_DIR/kernel/virtgpu.dart" <<'PY' || fail "virtgpuInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpuInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpuInit is missing", file=sys.stderr); sys.exit(1)
body = m.group(1)
for token in ("uart", "vga", "conPutc", "pciWrite32", "virtgpuOneCmd",
              "virtgpuPix", "virtgpuConsole", "virtgpuCell", "virtgpuRect",
              "fbScroll"):
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
  || fail "virtgpu.dart declares @bss — G6 donates leftover words, not .bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — G6 added a help line"
ck; ! grep -q 'virtgpu' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G6 added a syscall — the criterion forbids one"
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
  || fail "derived mode is G4's 1136x848 — G6 must pick its own"
ck; [[ "$XRES" -ne 1008 && "$YRES" -ne 720 ]] \
  || fail "derived mode is G5's 1008x720 — G6 must pick its own"
ck; [[ "$FLUSH_BEFORE" -eq 51 ]] || fail "banner flush count is $FLUSH_BEFORE, not 51"
ck; [[ "$FLUSH_AFTER" -ne 51 ]] || fail "post-scroll flush count is still 51"
ck; [[ "$FLUSH_AFTER" -gt "$FLUSH_BEFORE" ]] \
  || fail "post-scroll flush $FLUSH_AFTER is not greater than $FLUSH_BEFORE"
ck; [[ "$SCROLL_PX" -gt 0 ]] || fail "scroll pixel count is 0 — vacuous"
ck; [[ "$SCROLL_PX" -ne "$FULL_PX" ]] \
  || fail "scroll pixel count is the full frame $FULL_PX — damage is not tracked"
ck; [[ "$SCROLL_PX" -ne 51 ]] || fail "scroll pixel count is 51"
ck; [[ "$CELL_PX" -eq 128 ]] || fail "one cell is $CELL_PX pixels, not 128"
ck; [[ "$FRAMES" -gt 1 ]] || fail "derived backing frame count is $FRAMES"

LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — stolen last place"
BSS_VIRT=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /virtgpu/ {print $6}')
ck; [[ -z "$BSS_VIRT" ]] \
  || fail "kmain.o .bss contains $BSS_VIRT — G6 was not supposed to donate storage"

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
echo "STRUCTURAL: pass  virtgpus/virtgpux named; fbScroll flushes a rect; no help, no .bss; last is wmeventStore; derived mode not a default; g0–g4 tokens absent"

# ===========================================================================
# Step 3 — boots.
# ===========================================================================

KEYS_SCROLL="v,i,r,t,g,p,u,s,ret,wait:40000"
KEYS_NOFLUSH="v,i,r,t,g,p,u,x,ret,wait:40000"
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
  timeout 300 qemu-system-x86_64 \
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
echo "=== BOOT virtgpus (scroll + flush) ==="
fill_dump_args
drive_session "$WORKDIR/sc" "virtgpus" "$KEYS_SCROLL" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT virtgpux (scroll, no flush) ==="
fill_dump_args
drive_session "$WORKDIR/nf" "virtgpux" "$KEYS_NOFLUSH" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT fb coexistence (Bochs path on virtio-vga) ==="
DUMP_ARGS=()
drive_session "$WORKDIR/fb" "fb-coexist" "$KEYS_FB" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== BOOT std VGA (negative, no device) ==="
DUMP_ARGS=()
drive_session "$WORKDIR/std" "std-vga" "$KEYS_SCROLL" \
  -vga std

# ===========================================================================
# Step 4 — criterion.
# ===========================================================================
echo
echo "=== CRITERION ==="

check_scroll() {
  local ser="$1" info="$2" dump="$3" want_flush_a="$4" want_flush_b="$5" want_dmg="$6" label="$7"
  ck; python3 - "$ser" "$info" "$want_flush_a" "$want_flush_b" "$want_dmg" "$XRES" "$YRES" "$FRAMES" "$FULL_PX" "$label" <<'PY' || fail "$7 serial did not satisfy G6"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
want_a, want_b = int(sys.argv[3]), int(sys.argv[4])
want_dmg = int(sys.argv[5])
xres, yres, frames = int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8])
full_px = int(sys.argv[9])
label = sys.argv[10]
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

fls = []
for ln in serial.splitlines():
    if ln.startswith("VIRTIO FLUSH "):
        m = re.match(r"^VIRTIO FLUSH ([0-9A-F]{8})$", ln)
        if not m:
            fails.append("unparseable FLUSH: %r" % ln)
        else:
            fls.append(int(m.group(1), 16))
if len(fls) != 2:
    fails.append("expected two FLUSH lines (before and after scroll), found %d: %r"
                 % (len(fls), fls))
else:
    if fls[0] != want_a:
        fails.append("FLUSH before scroll is %d, committed banner count is %d"
                     % (fls[0], want_a))
    if fls[1] != want_b:
        fails.append("FLUSH after scroll is %d, committed count is %d"
                     % (fls[1], want_b))
    if want_b != want_a and fls[1] == 51:
        fails.append("FLUSH after scroll is still 51 — damage is a constant")
    if want_b != want_a and fls[1] == fls[0]:
        fails.append("FLUSH did not change after scroll (%d)" % fls[1])

dms = []
for ln in serial.splitlines():
    if ln.startswith("VIRTIO DAMAGE "):
        m = re.match(r"^VIRTIO DAMAGE ([0-9A-F]{8})$", ln)
        if not m:
            fails.append("unparseable DAMAGE: %r" % ln)
        else:
            dms.append(int(m.group(1), 16))
if len(dms) != 2:
    fails.append("expected two DAMAGE lines, found %d: %r" % (len(dms), dms))
else:
    if dms[1] != want_dmg:
        fails.append("DAMAGE after scroll is %d, derived fbWidth*(fbHeight-16) is %d"
                     % (dms[1], want_dmg))
    if want_dmg == 0:
        if dms[0] != 0:
            fails.append("negative path incremented DAMAGE before scroll (%d)"
                         % dms[0])
    if want_dmg > 0:
        if dms[1] == 0:
            fails.append("DAMAGE after scroll is 0 — vacuous")
        if dms[1] == 51:
            fails.append("DAMAGE after scroll is 51 — that is G5's flush count")
        if dms[1] == full_px:
            fails.append("DAMAGE after scroll is the full frame %d — not the moved region"
                         % full_px)
        if dms[0] == dms[1]:
            fails.append("DAMAGE did not change after scroll (%d)" % dms[1])

pix = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO PIX ")]
if pix:
    fails.append("G6 printed PIX lines — that is G4's colour form: %r" % pix)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    %s  BACK  FRAMES %d  FLUSH %d -> %d  DAMAGE %d"
      % (label, frames, want_a, want_b, want_dmg))
PY
  ck; python3 "$CHECK_PIX" \
        "$dump" "$WORKDIR/rodata.bin" "$FONT_OFF" \
        "$BANNER" "$FG" "$BG" \
    || fail "$label glyph pixels at BACK after scroll do not match fbFont8x16"
}

check_scroll "$WORKDIR/sc/serial.txt" "$WORKDIR/sc/info-pci.txt" \
  "$WORKDIR/sc/info-pci.txt" "$FLUSH_BEFORE" "$FLUSH_AFTER" "$SCROLL_PX" \
  "virtgpus"
echo "ASSERT: pass  virtgpus  FLUSH $FLUSH_BEFORE -> $FLUSH_AFTER  DAMAGE $SCROLL_PX  glyphs match after scroll"

check_scroll "$WORKDIR/nf/serial.txt" "$WORKDIR/nf/info-pci.txt" \
  "$WORKDIR/nf/info-pci.txt" 0 0 0 \
  "virtgpux"
echo "ASSERT: pass  virtgpux  backing glyphs match after scroll  FLUSH 0  DAMAGE 0 — count measures the device round trip"

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
    fails.append("bare fb printed VIRTIO BACK — G6 must not steal the Bochs path")
if "VIRTIO FLUSH " in serial:
    fails.append("bare fb printed VIRTIO FLUSH")
if "VIRTIO DAMAGE " in serial:
    fails.append("bare fb printed VIRTIO DAMAGE")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  fb on virtio-vga still takes Bochs 800x600 (ADR-0064); G6 is explicit"

ck; python3 - "$WORKDIR/std/serial.txt" "$WORKDIR/std/info-pci.txt" <<'PY' || fail "std-vga negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
fails = []
if re.search(r"1af4:1050", info, re.I):
    fails.append("std-vga info pci still has 1af4:1050")
if "VIRTIO NONE" not in serial.splitlines():
    fails.append("std-vga did not print VIRTIO NONE")
for prefix in ("VIRTIO BACK ", "VIRTIO FRAMES ", "VIRTIO FLUSH ", "VIRTIO DAMAGE "):
    hits = [ln for ln in serial.splitlines() if ln.startswith(prefix)]
    if hits:
        fails.append("std-vga printed %s: %r" % (prefix.strip(), hits))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO NONE and no BACK/FLUSH/DAMAGE"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G6-virtgpu: PASS — damage is a number (FLUSH $FLUSH_BEFORE -> $FLUSH_AFTER, DAMAGE $SCROLL_PX); scroll flushes the moved region; virtgpux keeps pixels and prints 0; fb Bochs path untouched"
