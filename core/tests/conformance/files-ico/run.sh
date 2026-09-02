#!/usr/bin/env bash
# core/tests/conformance/files-ico/run.sh
#
# ADR-0154 — FILES list icons through osxui_icon_fb / osgfx_icon_rows.
# docs/decisions/0154-files-icons-are-osxui-glyphs.md
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# FILES.ELF paints a document icon (osgfx_icon_rows in .rodata) on each
# listed FAT name band via osxui_icon_fb. A framebuffer probe hits the
# icon foreground. FILES_NO_ICON=1 leaves the band colour — pixel miss.
# Host osxui-headless --icon / --no-icon mirrors the same anti-vacuity.
# 11 stays fdwait. No help line. Does not break copy/move/rename.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
FILES_C="$CORE_DIR/user/frame/files.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"
UI_H="$CORE_DIR/plat/osxui/osxui.h"
UI_C="$CORE_DIR/plat/osxui/osxui.c"
GLYPH_C="$CORE_DIR/plat/osgfx/osgfx_glyph.c"
GFX_H="$CORE_DIR/plat/osgfx/osgfx.h"
ADR="$CORE_DIR/docs/decisions/0154-files-icons-are-osxui-glyphs.md"

fail() { echo "FILES-ICO: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FILES-ICO: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=79

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-files-ico.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
BUILD_OSXUI="$CORE_DIR/scripts/build-osxui.sh"
HEADLESS="$CORE_DIR/build/osxui-headless"

ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
ck; [[ -f "$PROBE" ]] || setup_error "probe.py not found"
ck; [[ -f "$FILES_C" ]] || setup_error "no files.c"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h"
ck; [[ -f "$ADR" ]] || fail "ADR-0154 is missing"
ck; [[ -f "$GLYPH_C" ]] || fail "no osgfx_glyph.c"
ck; [[ -f "$UI_H" ]] || fail "no osxui.h"
ck; [[ -f "$UI_C" ]] || fail "no osxui.c"

echo "=== STRUCTURAL ==="
ck; grep -q 'osxui_icon_fb' "$FILES_C" \
  || fail "files.c does not call osxui_icon_fb"
ck; grep -q 'FILES ICON' "$FILES_C" \
  || fail "files.c has no FILES ICON line"
ck; grep -q 'osgfx_icon_rows' "$GFX_H" \
  || fail "osgfx.h has no osgfx_icon_rows"
ck; grep -q 'osgfx_icon_doc' "$GLYPH_C" \
  || fail "osgfx_glyph.c has no osgfx_icon_doc"
ck; grep -q 'void osxui_icon_fb' "$GLYPH_C" \
  || fail "osgfx_glyph.c has no osxui_icon_fb"
ck; grep -q 'void osxui_icon' "$UI_C" \
  || fail "osxui.c has no osxui_icon"
ck; grep -q 'osgfx_fill_glyph' "$UI_C" \
  || fail "osxui_icon path lost osgfx_fill_glyph"
ck; grep -q 'OSXUI_ICON_FG = 0x00F8F0E0' "$UI_H" \
  || fail "osxui.h ICON_FG moved"
ck; grep -q 'ICON_FG 0x00F8F0E0UL' "$FILES_C" \
  || fail "files.c ICON_FG moved"
ck; ! grep -qiE '\bPNG\b|theme pack' "$GLYPH_C" \
  || fail "icon path mentions PNG/theme pack"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" 2>/dev/null \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
if [[ -z "$HELP_SIZE" ]]; then
  # kmain.o may not exist yet; build first later. Soft here.
  HELP_SIZE=0
fi
ck; grep -q 'SYS_RENAME' "$FILES_C" \
  || fail "files.c lost SYS_RENAME — do not break files-mv2"
ck; grep -q 'SYS_FDWRITE' "$FILES_C" \
  || fail "files.c lost SYS_FDWRITE — do not break files-fm"
echo "STRUCTURAL: pass  icon through osxui/osgfx; rename/fdwrite kept"

echo
echo "=== BUILD KERNEL ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
cp "$KERNEL_ELF" "$WORKDIR/kernel.elf" || fail "could not snapshot kernel.elf"
KERNEL_ELF="$WORKDIR/kernel.elf"
KERN_END=$(x86_64-elf-nm "$KERNEL_ELF" | awk '$3=="__kernel_end"{print $1; exit}')
ck; [[ -n "$KERN_END" ]] || fail "snapshot kernel has no __kernel_end"
ck; [[ $((16#$KERN_END)) -le 4194304 ]] \
  || fail "snapshot kernel __kernel_end is 0x$KERN_END, above vmFineBytes 4MiB"
capture_sh KNM KNM_ST -- "nm '$KERNEL_ELF'"
ck; [[ $KNM_ST -eq 0 ]] || fail "nm kernel.elf failed"
printf '%s\n' "$KNM" > "$WORKDIR/knm.txt"
ck; grep -q 'osxui_icon_fb' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osxui_icon_fb"
ck; grep -q 'osgfx_icon_rows' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osgfx_icon_rows"
ck; grep -q 'osxui_icon' "$WORKDIR/knm.txt" \
  || fail "kernel.elf has no osxui_icon"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "KERNEL: pass  icon symbols linked; help 2511; fdwait 11"

echo
echo "=== HOST (osxui --icon / --no-icon) ==="
capture_sh BO_OUT BO_ST -- "bash '$BUILD_OSXUI' 2>&1"
echo "$BO_OUT"
ck; [[ $BO_ST -eq 0 ]] || fail "build-osxui.sh exited $BO_ST"
ck; [[ -x "$HEADLESS" ]] || fail "no osxui-headless"
capture_sh HI_OUT HI_ST -- "'$HEADLESS' --icon -o '$WORKDIR/icon.ppm'"
echo "$HI_OUT"
ck; [[ $HI_ST -eq 0 ]] || fail "headless --icon exited $HI_ST"
ck; echo "$HI_OUT" | grep -q 'ICON 0xF8F0E0' || fail "headless did not print ICON colour"
capture_sh HN_OUT HN_ST -- "'$HEADLESS' --no-icon -o '$WORKDIR/noicon.ppm'"
echo "$HN_OUT"
ck; [[ $HN_ST -eq 0 ]] || fail "headless --no-icon exited $HN_ST"

NAMES=3
MODEL="$WORKDIR/model.txt"
ck; python3 "$SCRIPT_DIR/derive.py" geometry \
  "$FILES_C" "$UI_H" "$GLYPH_C" "$NAMES" > "$MODEL" \
  || fail "derive.py failed"
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }
ICON_FG=$(d icon_fg); BAND0=$(d band0)
HOST_IX=$(d host_ix); HOST_IY=$(d host_iy)
HOST_BX=$(d host_band_x); HOST_BY=$(d host_band_y)
ICON_SX=$(d icon_sx); ICON_SY=$(d icon_sy)
BAND_SX=$(d band_sx); BAND_SY=$(d band_sy)

# PPM probe: convert via python (same packing as de-osxui derive ppm).
ppm_rgb() {
  python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
path, x, y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
raw = open(path, "rb").read()
assert raw.startswith(b"P6\n"), "not P6"
rest = raw[3:]
nl = rest.index(b"\n"); hdr = rest[:nl].decode(); body = rest[nl+1:]
w, h = map(int, hdr.split()); nl2 = body.index(b"\n"); body = body[nl2+1:]
off = (y * w + x) * 3
r, g, b = body[off], body[off+1], body[off+2]
print("%02X%02X%02X" % (r, g, b))
PY
}
HOST_ICON=$(ppm_rgb "$WORKDIR/icon.ppm" "$HOST_IX" "$HOST_IY")
HOST_MISS=$(ppm_rgb "$WORKDIR/noicon.ppm" "$HOST_IX" "$HOST_IY")
ck; [[ "$HOST_ICON" == "$ICON_FG" ]] \
  || fail "host --icon pixel is $HOST_ICON, want $ICON_FG"
ck; [[ "$HOST_MISS" == "$BAND0" ]] \
  || fail "host --no-icon pixel is $HOST_MISS, want band $BAND0 (pixel miss)"
ck; [[ "$HOST_ICON" != "$HOST_MISS" ]] \
  || fail "host icon and no-icon pixels match — vacuous"
echo "HOST: pass  --icon=$HOST_ICON; --no-icon=$HOST_MISS (band)"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR/ico" 0
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs (icons) exited $BP_STATUS"
capture BUILD_NO_OUT BN_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR/noico" 1
echo "$BUILD_NO_OUT"
ck; [[ $BN_STATUS -eq 0 ]] || fail "build-progs (no-icon) exited $BN_STATUS"
ck; [[ -s "$WORKDIR/ico/files.elf" ]] || fail "no icon files.elf"
ck; [[ -s "$WORKDIR/noico/files.elf" ]] || fail "no no-icon files.elf"

echo
echo "=== PLANTS ==="
python3 - "$WORKDIR" "$FILES_C" <<'PY' || fail "could not derive plants"
import os, random, string, sys
wd, files_c = sys.argv[1:]
src = open(files_c, encoding="utf-8").read()
used_names = set()
used_hex = set()

def one(tag):
    while True:
        stem = "P" + "".join(random.choice(string.ascii_uppercase + string.digits) for _ in range(4))
        name = stem + ".DAT"
        blob = os.urandom(16)
        hx = blob.hex().upper()
        if name in ("FILES.ELF", "GHOST.DAT") or name in used_names:
            continue
        if hx.lower() in src.lower() or name in src or hx in used_hex:
            continue
        if blob == bytes(16) or blob[:3] == b"\x00\x00\x00":
            continue
        used_names.add(name)
        used_hex.add(hx)
        open(os.path.join(wd, tag + ".name"), "w").write(name)
        open(os.path.join(wd, tag + ".hex"), "w").write(hx)
        return

one("plantA")
one("plantC")
print("DERIVE: ok")
PY
NAME_A=$(tr -d '\n' < "$WORKDIR/plantA.name")
HEX_A=$(tr -d '\n' < "$WORKDIR/plantA.hex")
NAME_C=$(tr -d '\n' < "$WORKDIR/plantC.name")
HEX_C=$(tr -d '\n' < "$WORKDIR/plantC.hex")

IMG_ICO="$WORKDIR/ico.img"
IMG_NO="$WORKDIR/noico.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$IMG_ICO" "$WORKDIR/ico/files.elf" \
  --variant=full --plant-name="$NAME_A" --plant-hex="$HEX_A" \
  --plant2-name="$NAME_C" --plant2-hex="$HEX_C" \
  || fail "make-image ico failed"
ck; python3 "$SCRIPT_DIR/make-image.py" "$IMG_NO" "$WORKDIR/noico/files.elf" \
  --variant=full --plant-name="$NAME_A" --plant-hex="$HEX_A" \
  --plant2-name="$NAME_C" --plant2-hex="$HEX_C" \
  || fail "make-image noico failed"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn files.elf'),ret"

drive_boot() {
  local outdir="$1" img="$2" label="$3"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local fb="$outdir/fb.bin"
  local png="$outdir/shot.png"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$img,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" \
    --serial "$ser" \
    --wait-for 'M1 END\n' \
    --keys "$KEYS" \
    --settle-for 'USER WRITE FILES READY' \
    --settle-timeout 60 \
    --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
    --fb-out "$fb" \
    --png "$png"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -80 "$ser" >&2
    fail "session driver exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
  ck; [[ -s "$ser" ]] || fail "the $label boot captured no serial"
  ck; [[ -s "$fb" ]] || fail "the $label boot produced no framebuffer dump"
}

echo
echo "=== BOOT ICO ==="
drive_boot "$WORKDIR/bootI" "$IMG_ICO" "icon"
SER_I="$WORKDIR/bootI/serial.txt"
FB_I="$WORKDIR/bootI/fb.bin"

echo
echo "=== BOOT NO-ICO (anti-vacuity) ==="
drive_boot "$WORKDIR/bootN" "$IMG_NO" "no-icon"
SER_N="$WORKDIR/bootN/serial.txt"
FB_N="$WORKDIR/bootN/fb.bin"

echo
echo "=== ASSERT ==="
have() { ck; grep -qF -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "missing in $3: $1"; }; }
havenot() { ck; grep -qF -- "$1" "$2" && fail "must not contain in $3: $1"; }

have "PROC SPAWN" "$SER_I" "ico"
have "USER WRITE FILES STRIP" "$SER_I" "ico"
have "USER WRITE FILES ICON" "$SER_I" "ico"
have "USER WRITE FILES READY" "$SER_I" "ico"
have "USER WRITE FILES NAME $NAME_A" "$SER_I" "ico"
havenot "USER WRITE FILES ICON" "$SER_N" "no-icon"
have "USER WRITE FILES STRIP" "$SER_N" "no-icon"
have "USER WRITE FILES READY" "$SER_N" "no-icon"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_I" \
  || { sed -n '/M1 END/,$p' "$SER_I" >&2; fail "fault during ico boot"; }
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_N" \
  || { sed -n '/M1 END/,$p' "$SER_N" >&2; fail "fault during no-icon boot"; }

PITCH_I=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_I" | awk '{print $NF}')))
PITCH_N=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_N" | awk '{print $NF}')))
ck; [[ "$PITCH_I" -gt 0 ]] || fail "could not read ico pitch"
ck; [[ "$PITCH_N" -gt 0 ]] || fail "could not read no-icon pitch"

ck; python3 "$PROBE" "$FB_I" "$PITCH_I" "$ICON_SX" "$ICON_SY" "$ICON_FG" "ico_bit" \
  || fail "icon boot missing icon foreground at ($ICON_SX,$ICON_SY)"
ck; python3 "$PROBE" "$FB_N" "$PITCH_N" "$ICON_SX" "$ICON_SY" "$BAND0" "noico_band" \
  || fail "no-icon boot is not band colour at icon coords — expected pixel miss"
# Control: must NOT match icon fg on the no-icon boot.
if python3 "$PROBE" "$FB_N" "$PITCH_N" "$ICON_SX" "$ICON_SY" "$ICON_FG" "noico_must_miss" \
     >/dev/null 2>&1; then
  fail "no-icon boot still has icon foreground — vacuous"
fi
echo "ASSERT: pass  ico pixel=$ICON_FG; no-icon=$BAND0 (pixel miss)"

require_assertions "$ASSERTIONS_REQUIRED"
echo "FILES-ICO: PASS — FILES.ELF paints osxui_icon_fb document icons; FILES_NO_ICON misses ($ASSERTIONS checks)"
