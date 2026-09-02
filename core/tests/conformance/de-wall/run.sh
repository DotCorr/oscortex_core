#!/usr/bin/env bash
# core/tests/conformance/de-wall/run.sh
#
# ADR-0182 — wallpaper menu on right-click under `wm de`.
# Binary: menu rows + Regen/Image labels; Regenerate bumps seed
# (serial WM WALL REGEN); Set image loads WALL.RAW solid colour.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

fail() { echo "DE-wall: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-wall: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=40

for tool in qemu-system-x86_64 python3 clang; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-wall.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
SESSION_C="$CORE_DIR/plat/osgfx/osgfx_session.c"
POP_D="$CORE_DIR/kernel/wmpop.dart"
GUEST_H="$CORE_DIR/plat/osgfx/osgfx_guest.h"

echo "=== STRUCTURAL ==="
ck; [[ -f "$POP_D" ]] || fail "wmpop.dart missing"
ck; grep -q 'wmWallRegen' "$POP_D" || fail "wmpop.dart lost wmWallRegen"
ck; grep -q 'wmStrPopRegen' "$POP_D" || fail "Regen label missing"
ck; grep -q 'wmStrPopImage' "$POP_D" || fail "Image label missing"
ck; grep -q 'WALL.DAT' "$POP_D" || fail "WALL.DAT path missing"
ck; grep -q 'WALL.RAW' "$POP_D" || fail "WALL.RAW path missing"
ck; ! grep -q '^@bss' "$POP_D" || fail "wmpop.dart grew an @bss"
ck; grep -q 'wmPopWallClick' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmGrab does not call wmPopWallClick"
ck; grep -q 'wmWallLoad' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wm de does not load WALL.DAT"
ck; grep -q 'uint64_t desk' "$GUEST_H" || fail "mailbox lost desk word"
ck; grep -q 'OSGFX_GUEST_WALL_IMG' "$GUEST_H" || fail "WALL_IMG flag missing"
ck; grep -q 'paint_wall_menu' "$SESSION_C" \
  || fail "osgfx_session.c does not paint wallpaper menu"
ck; grep -q 'Regen' "$SESSION_C" || fail "session menu lost Regen glyph string"
ck; grep -q 'osgfx_fill_desk_generative' "$SESSION_C" \
  || fail "session lost generative desk"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
low = blob.lower()
if b'wall' in low or b'regen' in low:
    raise SystemExit('wallpaper appeared inside shellStrHelp')
print('    shellStrHelp has no wallpaper line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "wallpaper in help (GAP-0304)"; }
echo "$HELP_OUT"
echo "STRUCTURAL: pass  menu + WALL.DAT + mailbox desk"

echo
echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "OSMEDIA_FFMPEG=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
elf_has() { python3 -c "import sys; sys.exit(0 if open(sys.argv[1],'rb').read().find(sys.argv[2].encode())>=0 else 1)" "$1" "$2"; }
ck; elf_has "$KERNEL_ELF" "WM WALL REGEN" \
  || fail "kernel.elf lost WM WALL REGEN"
ck; elf_has "$KERNEL_ELF" "WM WALL MENU" \
  || fail "kernel.elf lost WM WALL MENU"
ck; elf_has "$KERNEL_ELF" "osgfx-desk-gen" \
  || fail "kernel.elf lost osgfx-desk-gen"
echo "BUILD: pass  wall tokens linked"

echo
echo "=== IMAGE ==="
python3 - "$WORKDIR/wall.dat" <<'PY'
import struct, sys
open(sys.argv[1], "wb").write(struct.pack("<IIII", 0x4C4C4157, 0, 0, 0))
PY
ck; [[ -f "$WORKDIR/wall.dat" ]] || fail "could not write WALL.DAT plant"
python3 - "$WORKDIR/wall.raw" <<'PY'
import struct, sys
open(sys.argv[1], "wb").write(struct.pack("<I", 0x00C04020))
PY
ck; [[ -f "$WORKDIR/wall.raw" ]] || fail "could not write WALL.RAW plant"
DISK_IMG="$WORKDIR/disk.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "WALL.DAT=$WORKDIR/wall.dat" "WALL.RAW=$WORKDIR/wall.raw" \
  || fail "make-image.py failed"
echo "IMAGE: pass  WALL.DAT + WALL.RAW"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' \
  '$CORE_DIR/kernel/wmpop.dart' \
  '$CORE_DIR/kernel/wm.dart' \
  '$CORE_DIR/kernel/mouse.dart' \
  '$CORE_DIR/kernel/fb.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py failed"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }
CLICK_X=$(d click_x); CLICK_Y=$(d click_y)
ROW0_X=$(d row0_x); ROW0_Y=$(d row0_y)
ROW1_X=$(d row1_x); ROW1_Y=$(d row1_y)
ROW0_C=$(d row0_color); ROW1_C=$(d row1_color)
DESK_SX=$(d desk_sx); DESK_SY=$(d desk_sy)
WALL_RAW=$(d wall_raw)
RELS_CLICK=$(d rels_to_click)
RELS_REGEN=$(d rels_to_regen)
RELS_IMAGE=$(d rels_to_image)
RELS_BACK=$(d rels_back_click)
FB_W=$(d fb_w); FB_H=$(d fb_h)
ck; [[ -n "$RELS_CLICK" && -n "$ROW0_C" ]] || fail "derive model incomplete"
echo "DERIVED: right-click ($CLICK_X,$CLICK_Y) rows ($ROW0_X,$ROW0_Y)/($ROW1_X,$ROW1_Y)"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

BASE_KEYS="$(typekeys 'fb'),ret,wait:1500,$(typekeys 'wm on'),ret,wait:2000"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm gfx'),ret,wait:800"
BASE_KEYS="$BASE_KEYS,$(typekeys 'wm de'),ret,wait:800"

echo
echo "=== MENU ==="
SER="$WORKDIR/menu-serial.txt"
FB1="$WORKDIR/menu-fb.bin"
PNG="$CORE_DIR/build/de-wall.png"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
MENU_KEYS2="$RELS_CLICK,wait:200,btn:right:down,wait:100,btn:right:up,wait:400"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/menu-qemu.log" 2>&1 &
QEMU_PID=$!
run_status MENU_DRIVE -- python3 "$DRIVER" \
  --port "$PORT" \
  --serial "$SER" \
  --wait-for 'M1 END\n' \
  --keys "$BASE_KEYS" \
  --settle-for "WM DE ON" \
  --settle-timeout 60 \
  --keys2 "$MENU_KEYS2" \
  --settle2-for "WM WALL MENU" \
  --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
  --fb-out "$WORKDIR/pre-menu.bin" \
  --fb-height "$FB_H" \
  --png "$WORKDIR/pre-menu.png" \
  --fb-out2 "$FB1" \
  --png2 "$PNG"
await MENU_QEMU "$QEMU_PID"
ck; if [[ $MENU_DRIVE -ne 0 ]]; then
  tail -80 "$SER" >&2
  fail "menu driver exited $MENU_DRIVE"
fi
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON missing"
ck; grep -q 'WM DE ON' "$SER" || fail "WM DE ON missing"
ck; grep -q 'WM WALL MENU' "$SER" || fail "WM WALL MENU missing — menu did not show"
ck; grep -q 'OSGFX DESK GEN' "$SER" || fail "OSGFX DESK GEN missing"
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-Fa-f]+ PITCH ([0-9A-Fa-f]+)' "$SER" | awk '{print $NF}')))
ck; python3 "$PROBE" "$FB1" "$PITCH" "$ROW0_X" "$ROW0_Y" "0x$ROW0_C" "menu_row0" \
  || fail "row0 fill is not wmPopRow0"
ck; python3 "$PROBE" "$FB1" "$PITCH" "$ROW1_X" "$ROW1_Y" "0x$ROW1_C" "menu_row1" \
  || fail "row1 fill is not wmPopRow1"
echo "MENU: pass  rows + WM WALL MENU"

echo
echo "=== REGEN ==="
SER2="$WORKDIR/regen-serial.txt"
FB2="$WORKDIR/regen-fb.bin"
: >"$SER2"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port for regen"
# Two Regens: seed A then seed B must differ.
REGEN_KEYS2="$RELS_CLICK,wait:200,btn:right:down,wait:100,btn:right:up,wait:300"
REGEN_KEYS2="$REGEN_KEYS2,$RELS_REGEN,wait:150,btn:left:down,wait:100,btn:left:up,wait:600"
REGEN_KEYS2="$REGEN_KEYS2,$RELS_BACK,wait:150,btn:right:down,wait:100,btn:right:up,wait:300"
REGEN_KEYS2="$REGEN_KEYS2,$RELS_REGEN,wait:150,btn:left:down,wait:100,btn:left:up,wait:600"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER2" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/regen-qemu.log" 2>&1 &
QEMU_PID=$!
run_status REGEN_DRIVE -- python3 "$DRIVER" \
  --port "$PORT" \
  --serial "$SER2" \
  --wait-for 'M1 END\n' \
  --keys "$BASE_KEYS" \
  --settle-for "WM DE ON" \
  --settle-timeout 60 \
  --keys2 "$REGEN_KEYS2" \
  --settle2-for "WM WALL REGEN" \
  --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
  --fb-out "$WORKDIR/pre-regen.bin" \
  --fb-height "$FB_H" \
  --png "$WORKDIR/pre-regen.png" \
  --fb-out2 "$FB2" \
  --png2 "$WORKDIR/regen.png"
await REGEN_QEMU "$QEMU_PID"
ck; if [[ $REGEN_DRIVE -ne 0 ]]; then
  if [[ $(grep -c 'WM WALL REGEN' "$SER2") -lt 1 ]]; then
    tail -80 "$SER2" >&2
    fail "regen driver exited $REGEN_DRIVE without WM WALL REGEN"
  fi
fi
NREGEN=$(grep -c 'WM WALL REGEN' "$SER2" || true)
ck; [[ "$NREGEN" -ge 2 ]] || fail "expected two WM WALL REGEN lines, got $NREGEN"
SEED_A=$(grep -oE 'WM WALL REGEN [0-9A-Fa-f]{8}' "$SER2" | sed -n '1p' | awk '{print $NF}')
SEED_B=$(grep -oE 'WM WALL REGEN [0-9A-Fa-f]{8}' "$SER2" | sed -n '2p' | awk '{print $NF}')
ck; [[ -n "$SEED_A" && -n "$SEED_B" ]] || fail "could not parse regen seeds"
ck; [[ "$SEED_A" != "$SEED_B" ]] || fail "regen seeds identical ($SEED_A)"
echo "REGEN: pass  $SEED_A -> $SEED_B"

echo
echo "=== IMAGE ==="
SER3="$WORKDIR/img-serial.txt"
FB4="$WORKDIR/img-fb.bin"
: >"$SER3"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port for image"
IMG_KEYS2="$RELS_CLICK,wait:200,btn:right:down,wait:100,btn:right:up,wait:300"
IMG_KEYS2="$IMG_KEYS2,$RELS_IMAGE,wait:150,btn:left:down,wait:100,btn:left:up,wait:800"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER3" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/img-qemu.log" 2>&1 &
QEMU_PID=$!
run_status IMG_DRIVE -- python3 "$DRIVER" \
  --port "$PORT" \
  --serial "$SER3" \
  --wait-for 'M1 END\n' \
  --keys "$BASE_KEYS" \
  --settle-for "WM DE ON" \
  --settle-timeout 60 \
  --keys2 "$IMG_KEYS2" \
  --settle2-for "WM WALL IMG" \
  --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
  --fb-out "$WORKDIR/pre-img.bin" \
  --fb-height "$FB_H" \
  --png "$WORKDIR/pre-img.png" \
  --fb-out2 "$FB4" \
  --png2 "$CORE_DIR/build/de-wall-img.png"
await IMG_QEMU "$QEMU_PID"
ck; if [[ $IMG_DRIVE -ne 0 ]]; then
  if ! grep -q 'WM WALL IMG' "$SER3"; then
    tail -100 "$SER3" >&2
    fail "image driver exited $IMG_DRIVE without WM WALL IMG"
  fi
fi
ck; grep -q 'WM WALL IMG' "$SER3" || fail "WM WALL IMG missing"
ck; ! grep -q 'WM WALL MISS' "$SER3" || fail "WALL.RAW was MISS"
PITCH3=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-Fa-f]+ PITCH ([0-9A-Fa-f]+)' "$SER3" | awk '{print $NF}')))
ck; python3 "$PROBE" "$FB4" "$PITCH3" "$DESK_SX" "$DESK_SY" "0x$WALL_RAW" "wall_solid" \
  || fail "desktop is not WALL.RAW solid after Set image"
echo "IMAGE: pass  WALL.RAW solid $WALL_RAW"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-wall: PASS — wallpaper menu + regen + FAT image ($ASSERTIONS checks)"
exit 0
