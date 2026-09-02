#!/usr/bin/env bash
# core/tests/conformance/de-browse/run.sh
#
# ADR-0115 / ADR-0122 / ADR-0123 — the running OS calls oschrome.h.
# BROWSE.ELF is the thin FRAME client; oschrome_guest.c is the
# ABI + HTML rgb() painter; official linux64 libcef.so supplies
# cef_initialize (not Mac CEF, not a handwritten stub). A data:
# page paints PAGE; --no-init / NONE.ELF is not PAGE. nm of
# BROWSE.ELF (what QEMU runs) names cef_initialize. Stub-only
# (guest painter, no extract) fails that nm check.
# OnPaint is leftover (ADR-0123): prove-onpaint-block.py lists the
# 32 DT_NEEDED. Floor stays 87. Do not raise it on a thunk.
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
# BROWSE does not paint Skia or decode video. The 12MiB CRT heap
# blows vmFineBytes and `proc spawn` refuses (OSGFX_CRT=0).
export OSGFX_SKIA=0
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

BROWSE_C="$CORE_DIR/user/frame/browse.c"
GUEST_C="$CORE_DIR/plat/chrome/oschrome_guest.c"
CEF_C="$CORE_DIR/plat/chrome/oschrome_cef.c"
HDR="$CORE_DIR/plat/chrome/oschrome.h"
FRAME_H="$CORE_DIR/user/frame/osframe.h"
ADR="$CORE_DIR/docs/decisions/0115-the-os-calls-oschrome.md"
ADR122="$CORE_DIR/docs/decisions/0122-official-linux64-cef-is-the-qemu-blob.md"
ADR123="$CORE_DIR/docs/decisions/0123-content-onpaint-needs-process-abi.md"
PROVE="$SCRIPT_DIR/prove-onpaint-block.py"
FETCH64="$CORE_DIR/scripts/fetch-cef-linux64.sh"
EXTRACT="$CORE_DIR/scripts/extract-cef-guest.sh"

fail() { echo "DE-browse: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-browse: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the ADR-0122 green run (raised from 74).
ASSERTIONS_REQUIRED=87

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-browse.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
MOUNTPOINT="$WORKDIR/mnt"
ATTACHED=""
cleanup() {
  [[ -n "${ATTACHED:-}" ]] && hdiutil detach "$ATTACHED" -force >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
ck; [[ -f "$PROBE" ]] || setup_error "probe.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$BROWSE_C" ]] || setup_error "no browse.c"
ck; [[ -f "$GUEST_C" ]] || setup_error "no oschrome_guest.c"
ck; [[ -f "$CEF_C" ]] || setup_error "no oschrome_cef.c"
ck; [[ -f "$HDR" ]] || setup_error "no oschrome.h"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h"
ck; [[ -f "$ADR" ]] || setup_error "no ADR-0115"
ck; [[ -f "$ADR122" ]] || setup_error "no ADR-0122"
ck; [[ -f "$ADR123" ]] || setup_error "no ADR-0123"
ck; [[ -f "$PROVE" ]] || setup_error "no prove-onpaint-block.py"
ck; [[ -f "$FETCH64" ]] || setup_error "no fetch-cef-linux64.sh"
ck; [[ -f "$EXTRACT" ]] || setup_error "no extract-cef-guest.sh"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$BROWSE_C' \
  '$HDR' '$FRAME_H' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

PROBE_X=$(d probe_x); PROBE_Y=$(d probe_y)
PAGE_HEX=$(d page); DESK_HEX=$(d desk)
GO_PAGE=$(d go_page); GO_NONE=$(d go_none)
GO_LINE=$(d go_line)
READY_LINE=$(d ready_line); NONE_LINE=$(d none_line)
SYS_WM=$(d syscall_wm)

ck; [[ "$PROBE_X" -gt 0 && "$PROBE_Y" -gt 0 ]] || fail "derived probe is $PROBE_X,$PROBE_Y"
ck; [[ "$PAGE_HEX" != "$DESK_HEX" ]] || fail "PAGE equals DESK"
echo "DERIVED: probe ($PROBE_X,$PROBE_Y) PAGE $PAGE_HEX DESK $DESK_HEX; $GO_PAGE / $GO_NONE"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '#include "osframe.h"' "$BROWSE_C" \
  || fail "browse.c does not include osframe.h"
ck; grep -q '#include "oschrome.h"' "$BROWSE_C" \
  || fail "browse.c does not include oschrome.h"
ck; ! grep -qE '^#define SYS_' "$BROWSE_C" \
  || fail "browse.c copies SYS_* by hand — include osframe.h"
ck; grep -q 'oschrome_load_url' "$BROWSE_C" \
  || fail "browse.c does not call oschrome_load_url"
ck; grep -q 'oschrome_default_data_url' "$BROWSE_C" \
  || fail "browse.c does not load the default data: URL"
ck; grep -q 'parse_rgb' "$GUEST_C" \
  || fail "oschrome_guest.c has no parse_rgb"
ck; grep -q 'oschrome_backend_chromium' "$GUEST_C" \
  || fail "oschrome_guest.c has no oschrome_backend_chromium"
ck; ! grep -q 'CefInitialize' "$GUEST_C" \
  || fail "oschrome_guest.c names CefInitialize — do not copy the Mac .mm"
ck; ! grep -q 'cef_initialize' "$GUEST_C" \
  || fail "oschrome_guest.c names cef_initialize — that symbol is official libcef"
ck; grep -q 'cef_initialize' "$CEF_C" \
  || fail "oschrome_cef.c does not reference cef_initialize"
ck; ! grep -q 'CefInitialize' "$CEF_C" \
  || fail "oschrome_cef.c names CefInitialize — do not copy the Mac .mm"
ck; grep -q 'linux64' "$FETCH64" \
  || fail "fetch-cef-linux64.sh does not name linux64"
ck; grep -q 'db04c1ebb1f6dc5bb66ee38b7440c36596056937' "$FETCH64" \
  || fail "fetch-cef-linux64.sh lost the pinned sha1"
ck; grep -q '82f0dac25f8ab79701da064984d3c49ef2bedf0b' "$EXTRACT" \
  || fail "extract-cef-guest.sh lost the pinned official-bytes sha1"
ck; grep -q 'OnPaint' "$ADR123" \
  || fail "ADR-0123 does not name OnPaint"
ck; grep -q 'ld-linux-x86-64.so.2' "$ADR123" \
  || fail "ADR-0123 lost the exact missing .so list"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$SCRIPT_DIR/run.sh" \
  || fail "de-browse floor moved off 87 — do not raise it on a thunk"
ck; ! grep -qiE 'guest OS' "$BROWSE_C" "$GUEST_C" "$CEF_C" "$ADR" "$ADR122" "$ADR123" \
  || fail "DE-browse sources say guest OS"
ck; ! grep -qiE 'Flutter' "$BROWSE_C" \
  || fail "browse.c names that embedder"
ck; [[ "$SYS_WM" -eq 23 ]] || fail "derive.py says wmsurface is $SYS_WM"
ck; ! grep -qE 'fdwait|SYS_FDWAIT' "$BROWSE_C" \
  || fail "browse.c names fdwait — 11 stays reserved"
ck; ! grep -F -e 'BROWSE.ELF' -e 'browse.c' -e 'DE-browse' \
      "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel .dart names BROWSE — BROWSE must not touch the kernel"
ck; ! grep -q '  browse  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a browse help line has appeared in shell.dart"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — help moved"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — stolen last place"
ck; ! grep -F -e 'BROWSE.ELF' -e 'browse.c' \
      "$CORE_DIR/kernel/wm.dart" "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wm*.dart was rewritten for BROWSE"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "STRUCTURAL: pass  oschrome.h + osframe.h, no kernel edit, no help, no fdwait"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/browse.elf" ]] || fail "no browse.elf"
ck; [[ -s "$WORKDIR/none.elf" ]] || fail "no none.elf"

NM=$(x86_64-elf-nm "$WORKDIR/browse.elf")
ck; echo "$NM" | grep -q 'oschrome_backend_chromium' \
  || fail "browse.elf has no oschrome_backend_chromium"
ck; echo "$NM" | grep -q 'oschrome_load_url' \
  || fail "browse.elf has no oschrome_load_url"
ck; echo "$NM" | grep -E 'cef_initialize' >/dev/null \
  || fail "browse.elf has no cef_initialize — QEMU would not run official CEF"
ck; echo "$NM" | grep -E '[Tt] cef_initialize' >/dev/null \
  || fail "browse.elf cef_initialize is not a defined text symbol"
NMN=$(x86_64-elf-nm "$WORKDIR/none.elf")
ck; echo "$NMN" | grep -q 'oschrome_backend_chromium' \
  || fail "none.elf dropped oschrome_backend_chromium"
ck; echo "$NMN" | grep -E 'cef_initialize' >/dev/null \
  || fail "none.elf dropped cef_initialize"

echo
echo "=== ONPAINT LEFTOVER (ADR-0123) ==="
# Floor stays 87. This is the leftover proof, not a new PASS.
capture_sh PROVE_OUT PROVE_STATUS -- "python3 '$PROVE'"
echo "$PROVE_OUT"
ck; [[ $PROVE_STATUS -eq 0 ]] || { echo "$PROVE_OUT" >&2; fail "prove-onpaint-block.py exited $PROVE_STATUS — leftover claim stale"; }
ck; echo "$PROVE_OUT" | grep -q 'OnPaint did not run' \
  || fail "prove-onpaint-block.py did not say OnPaint did not run"
ck; echo "$PROVE_OUT" | grep -q 'libc.so.6' \
  || fail "prove-onpaint-block.py dropped libc.so.6 from the missing .so list"
echo "ONPAINT: leftover  Content did not paint; 32 DT_NEEDED; floor stays 87"

DISK_IMG="$WORKDIR/disk.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/browse.elf" "$WORKDIR/none.elf" \
  || fail "make-image.py could not produce the image"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
  ck; [[ $ATTACH_STATUS -eq 0 ]] \
    || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount the image"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  ck; [[ -f "$MOUNTPOINT/BROWSE.ELF" ]] || fail "mounted volume has no BROWSE.ELF"
  ck; [[ -f "$MOUNTPOINT/NINIT.ELF" ]] || fail "mounted volume has no NINIT.ELF"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  BROWSE.ELF + NINIT.ELF on FAT"
else
  fail "hdiutil not found; this harness will not certify a volume macOS has not mounted"
fi

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

drive_boot() {
  local outdir="$1" keys="$2" settle="$3" label="$4"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local fb="$outdir/fb.bin"
  local png="$outdir/shot.png"
  local disk="$outdir/disk.img"
  cp "$DISK_IMG" "$disk" || fail "could not clone the FAT volume for $label"
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
    -drive "file=$disk,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" \
    --serial "$ser" \
    --wait-for 'M1 END\n' \
    --keys "$keys" \
    --settle-for "$settle" \
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
    fail "comp-drive.py exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
  ck; [[ -s "$ser" ]] || fail "the $label boot captured no serial"
  ck; [[ -s "$fb" ]] || fail "the $label boot produced no framebuffer dump"
}

KEYS_PAGE="$(typekeys 'fb'),ret,wait:1500"
KEYS_PAGE="$KEYS_PAGE,$(typekeys 'wm on'),ret,wait:2500"
KEYS_PAGE="$KEYS_PAGE,$(typekeys "$GO_PAGE"),ret"

KEYS_NONE="$(typekeys 'fb'),ret,wait:1500"
KEYS_NONE="$KEYS_NONE,$(typekeys 'wm on'),ret,wait:2500"
KEYS_NONE="$KEYS_NONE,$(typekeys "$GO_NONE"),ret"

mkdir -p "$CORE_DIR/build"

drive_boot "$WORKDIR/page" "$KEYS_PAGE" "USER WRITE $READY_LINE" "PAGE"
SER_PAGE="$WORKDIR/page/serial.txt"
FB_PAGE="$WORKDIR/page/fb.bin"
cp "$WORKDIR/page/shot.png" "$CORE_DIR/build/de-browse-page.png" 2>/dev/null || true

drive_boot "$WORKDIR/none" "$KEYS_NONE" "USER WRITE $NONE_LINE" "NONE"
SER_NONE="$WORKDIR/none/serial.txt"
FB_NONE="$WORKDIR/none/fb.bin"
cp "$WORKDIR/none/shot.png" "$CORE_DIR/build/de-browse-none.png" 2>/dev/null || true

echo
echo "=== PAGE ==="
have() { ck; grep -qF -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the transcript does not contain: $1"; }; }
havenot() { ck; grep -qF -- "$1" "$2" && fail "the transcript contains what it must not: $1"; }
havere() { ck; grep -qE -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the transcript matches nothing against: $1"; }; }

havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$' "$SER_PAGE"
have "$GO_LINE" "$SER_PAGE"
havere '^PROC SPAWN ' "$SER_PAGE"
have "USER WRITE $READY_LINE" "$SER_PAGE"
havenot "USER WRITE $NONE_LINE" "$SER_PAGE"
havere '^WM ATTACH W ' "$SER_PAGE"
havere '^WM COMMIT W ' "$SER_PAGE"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_PAGE" \
  || { sed -n '/M1 END/,$p' "$SER_PAGE" >&2; fail "something faulted during the PAGE boot"; }

PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_PAGE" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"

ck; python3 "$PROBE" "$FB_PAGE" "$PITCH" "$PROBE_X" "$PROBE_Y" "$PAGE_HEX" "page_body" \
  || fail "PAGE probe ($PROBE_X,$PROBE_Y) is not $PAGE_HEX — data: did not paint"
# Outside the window must not be PAGE. `wm on` without osgfx_sw may
# leave the corner 0 rather than DESK — both are a negative.
if python3 "$PROBE" "$FB_PAGE" "$PITCH" 8 8 "$PAGE_HEX" "desk_must_fail"; then
  fail "desktop (8,8) is PAGE $PAGE_HEX — the page filled the screen"
fi
ck; true
echo "    desktop                (  8,  8) is not PAGE"

echo
echo "=== NONE (anti-vacuity) ==="
havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$' "$SER_NONE"
have "$GO_LINE" "$SER_NONE"
havere '^PROC SPAWN ' "$SER_NONE"
have "USER WRITE $NONE_LINE" "$SER_NONE"
havenot "USER WRITE $READY_LINE" "$SER_NONE"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_NONE" \
  || { sed -n '/M1 END/,$p' "$SER_NONE" >&2; fail "something faulted during the NONE boot"; }

PITCH_N=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_NONE" | awk '{print $NF}')))
ck; [[ "$PITCH_N" -gt 0 ]] || fail "could not read the none-boot pitch"

if python3 "$PROBE" "$FB_NONE" "$PITCH_N" "$PROBE_X" "$PROBE_Y" "$PAGE_HEX" "none_must_fail"; then
  fail "NONE probe ($PROBE_X,$PROBE_Y) is PAGE $PAGE_HEX — Chromium was not required"
fi
ck; true
echo "    none_body              ($PROBE_X,$PROBE_Y) is not PAGE — negative holds"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-browse: PASS — BROWSE.ELF links official cef_initialize; data: pixel is PAGE; --no-init is not ($ASSERTIONS checks). OnPaint leftover ADR-0123 (floor 87)."
exit 0
