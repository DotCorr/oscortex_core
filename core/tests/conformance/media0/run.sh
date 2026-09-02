#!/usr/bin/env bash
# MEDIA0 — FFmpeg as a platform media module (Android MediaCodec shape).
# docs/design/c-modules.md, ADR-0103.
#
# Platform clang. Not an app ELF. Not Flutter. Not in kernel.elf.
# Not a fake parser.
#
# Proof:
#   * binaries exist after build-osmedia.sh
#   * file(1) says arm64 Mach-O
#   * nm shows osmedia_backend_ffmpeg AND avcodec_ / avformat_
#   * default headless BACKEND is ffmpeg; derived pixel is FRAME
#   * --no-init PPM: same pixel is not FRAME
#   * --missing PPM: same pixel is not FRAME
# Anti-vacuity: FRAME != 0; FRAME != DESK; osmedia.c calls avcodec_send_packet.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "MEDIA0: FAIL — $1" >&2; exit 1; }
setup_error() { echo "MEDIA0: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=66

for tool in clang dart python3 file nm ffmpeg pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH (source env.sh)"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-media0.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

BUILD="$CORE_DIR/scripts/build-osmedia.sh"
HEADLESS="$CORE_DIR/build/osmedia-headless"
FFI="$CORE_DIR/build/osmedia-ffi"
CLIP="$CORE_DIR/build/osmedia-clip.mp4"
DERIVE="$SCRIPT_DIR/derive.py"
HDR="$CORE_DIR/plat/media/osmedia.h"
SRC="$CORE_DIR/plat/media/osmedia.c"
DART="$CORE_DIR/plat/media/osmedia.dart"

ck; [[ -f "$BUILD" ]] || fail "no build-osmedia.sh"
ck; [[ -f "$HDR" ]] || fail "no osmedia.h"
ck; [[ -f "$SRC" ]] || fail "no osmedia.c"
ck; [[ -f "$DERIVE" ]] || fail "no derive.py"
ck; [[ -f "$DART" ]] || fail "no osmedia.dart"

FRAME=0x00C04088
DESK=0x00184060
W=64
H=64
PX=16
PY=16

ck; [[ $FRAME -ne 0 ]] || fail "FRAME is zero"
ck; [[ $FRAME -ne $DESK ]] || fail "FRAME equals DESK"
ck; [[ $((W * H)) -gt 0 ]] || fail "frame area is zero"
ck; [[ $PX -lt $W ]] || fail "PX out of range"
ck; [[ $PY -lt $H ]] || fail "PY out of range"

ck; grep -q 'OSMEDIA_FRAME = 0x00C04088' "$HDR" || fail "osmedia.h FRAME moved without derive.py"
ck; grep -q 'OSMEDIA_DESK = 0x00184060' "$HDR" || fail "osmedia.h DESK moved without derive.py"
ck; grep -q 'OSMEDIA_W = 64' "$HDR" || fail "osmedia.h W moved without derive.py"
ck; grep -q 'OSMEDIA_PX = 16' "$HDR" || fail "osmedia.h PX moved without derive.py"

# A header-only stub, or a .c that only names osmedia_backend_ffmpeg
# and fills a rect, is a FAIL.
ck; grep -q 'avformat_open_input' "$SRC" || fail "osmedia.c does not call avformat_open_input"
ck; grep -q 'avcodec_send_packet' "$SRC" || fail "osmedia.c does not call avcodec_send_packet"
ck; grep -q 'avcodec_receive_frame' "$SRC" || fail "osmedia.c does not call avcodec_receive_frame"
ck; grep -q 'libavcodec/avcodec.h' "$SRC" || fail "osmedia.c has no libavcodec include"
ck; grep -q 'libavformat/avformat.h' "$SRC" || fail "osmedia.c has no libavformat include"
ck; grep -q 'libavutil/avutil.h' "$SRC" || fail "osmedia.c has no libavutil include"

# Sibling DCDart file must name the same integers (c-modules.md §4).
ck; grep -q '@extern' "$DART" || fail "osmedia.dart has no @extern"
ck; grep -q 'osmedia_ffi_open' "$DART" || fail "osmedia.dart does not @extern open"
ck; grep -q 'osmedia_ffi_decode_frame' "$DART" || fail "osmedia.dart does not @extern decode"
ck; grep -q 'osmedia_ffi_pixel' "$DART" || fail "osmedia.dart does not @extern pixel"
ck; grep -q 'u64(16)' "$DART" || fail "osmedia.dart PX is not 16"

# Not in kernel.elf this slice.
if [[ -f "$CORE_DIR/kernel/kmain.dart" ]]; then
  if grep -q 'osmedia' "$CORE_DIR/kernel/kmain.dart"; then
    fail "osmedia leaked into kmain.dart — not this slice"
  fi
fi

echo "=== BUILD (platform clang + official FFmpeg) ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$BUILD' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-osmedia.sh exited $BUILD_STATUS"
ck; [[ -x "$HEADLESS" ]] || fail "no osmedia-headless"
ck; [[ -x "$FFI" ]] || fail "no osmedia-ffi"
ck; [[ -f "$CLIP" ]] || fail "no planted osmedia-clip.mp4"

capture_sh FILE_OUT FILE_STATUS -- "file '$HEADLESS'"
echo "$FILE_OUT"
ck; [[ $FILE_STATUS -eq 0 ]] || fail "file(1) failed"
ck; echo "$FILE_OUT" | grep -q 'Mach-O' || fail "headless is not Mach-O (do not use none-elf)"
if echo "$FILE_OUT" | grep -qi 'ELF'; then
  fail "headless is ELF — wrong toolchain"
fi
ck; echo "$FILE_OUT" | grep -q 'arm64' || fail "headless is not arm64"

capture_sh NM_OUT NM_STATUS -- "nm '$HEADLESS'"
ck; [[ $NM_STATUS -eq 0 ]] || fail "nm failed"
ck; echo "$NM_OUT" | grep -q 'osmedia_backend_ffmpeg' \
  || fail "osmedia_backend_ffmpeg not in the binary"
# Real FFmpeg, not a comment and not a stub that only exports the name.
ck; printf '%s\n' "$NM_OUT" | grep -E 'avcodec_' >/dev/null \
  || fail "no avcodec_ symbol — stub that only names osmedia_backend_ffmpeg"
ck; printf '%s\n' "$NM_OUT" | grep -E 'avformat_' >/dev/null \
  || fail "no avformat_ symbol — stub that only names osmedia_backend_ffmpeg"

echo "=== HEADLESS planted clip (FFmpeg) ==="
unset OSMEDIA_NO_FFMPEG
capture_sh PAGE_OUT PAGE_STATUS -- "'$HEADLESS' -i '$CLIP' -o '$WORKDIR/frame.ppm'"
echo "$PAGE_OUT"
ck; [[ $PAGE_STATUS -eq 0 ]] || fail "headless frame exited $PAGE_STATUS"
ck; echo "$PAGE_OUT" | grep -q 'BACKEND ffmpeg' \
  || fail "default path is not ffmpeg (got: $PAGE_OUT)"
ck; echo "$PAGE_OUT" | grep -q 'VERSION none' && fail "default VERSION is none"
ck; echo "$PAGE_OUT" | grep -E 'VERSION [0-9]' >/dev/null \
  || fail "no FFmpeg VERSION line"
ck; [[ -f "$WORKDIR/frame.ppm" ]] || fail "no frame.ppm"

capture_sh DR_OUT DR_STATUS -- "python3 '$DERIVE' '$WORKDIR/frame.ppm' frame"
echo "$DR_OUT"
ck; [[ $DR_STATUS -eq 0 ]] || fail "derive frame failed: $DR_OUT"
ck; echo "$DR_OUT" | grep -q 'FRAME_OK' || fail "no FRAME_OK"

echo "=== HEADLESS --no-init (negative) ==="
capture_sh NONE_OUT NONE_STATUS -- "'$HEADLESS' --no-init -i '$CLIP' -o '$WORKDIR/none.ppm'"
echo "$NONE_OUT"
ck; [[ $NONE_STATUS -eq 0 ]] || fail "headless --no-init exited $NONE_STATUS"
ck; echo "$NONE_OUT" | grep -q 'BACKEND none' \
  || fail "--no-init did not select none (got: $NONE_OUT)"
if echo "$NONE_OUT" | grep -q 'BACKEND ffmpeg'; then
  fail "--no-init still says ffmpeg"
fi

capture_sh DN_OUT DN_STATUS -- "python3 '$DERIVE' '$WORKDIR/none.ppm' none"
echo "$DN_OUT"
ck; [[ $DN_STATUS -eq 0 ]] || fail "derive none failed: $DN_OUT"
ck; echo "$DN_OUT" | grep -q 'NONE_OK' || fail "no NONE_OK"

echo "=== HEADLESS --missing (negative) ==="
capture_sh MISS_OUT MISS_STATUS -- "'$HEADLESS' --missing -o '$WORKDIR/miss.ppm'"
echo "$MISS_OUT"
ck; [[ $MISS_STATUS -eq 0 ]] || fail "headless --missing exited $MISS_STATUS"
ck; echo "$MISS_OUT" | grep -q 'BACKEND none' \
  || fail "--missing did not select none (got: $MISS_OUT)"

capture_sh DM_OUT DM_STATUS -- "python3 '$DERIVE' '$WORKDIR/miss.ppm' none"
echo "$DM_OUT"
ck; [[ $DM_STATUS -eq 0 ]] || fail "derive missing failed: $DM_OUT"
ck; echo "$DM_OUT" | grep -q 'NONE_OK' || fail "no NONE_OK on missing file"

capture_sh DIFF_OUT DIFF_STATUS -- "python3 -c \"
import pathlib
a=pathlib.Path('$WORKDIR/frame.ppm').read_bytes()
b=pathlib.Path('$WORKDIR/none.ppm').read_bytes()
raise SystemExit(0 if a!=b else 1)
\""
ck; [[ $DIFF_STATUS -eq 0 ]] || fail "frame and no-init PPMs are identical"

# FFmpeg symbols must survive the no-init run — they were linked, not imagined.
capture_sh NM2_OUT NM2_STATUS -- "nm '$HEADLESS'"
ck; [[ $NM2_STATUS -eq 0 ]] || fail "nm after no-init failed"
ck; printf '%s\n' "$NM2_OUT" | grep -E 'avcodec_' >/dev/null \
  || fail "avcodec_ symbols gone after no-init path"
ck; printf '%s\n' "$NM2_OUT" | grep -E 'avformat_' >/dev/null \
  || fail "avformat_ symbols gone after no-init path"

echo "=== DCDART FFI planted clip ==="
capture_sh FF_OUT FF_STATUS -- "'$FFI' -i '$CLIP' -o '$WORKDIR/ffi.ppm'"
echo "$FF_OUT"
ck; [[ $FF_STATUS -eq 0 ]] || fail "osmedia-ffi exited $FF_STATUS"
ck; echo "$FF_OUT" | grep -q 'BACKEND ffmpeg' \
  || fail "ffi default path is not ffmpeg (got: $FF_OUT)"
ck; [[ -f "$WORKDIR/ffi.ppm" ]] || fail "no ffi.ppm"
capture_sh FDR_OUT FDR_STATUS -- "python3 '$DERIVE' '$WORKDIR/ffi.ppm' frame"
echo "$FDR_OUT"
ck; [[ $FDR_STATUS -eq 0 ]] || fail "derive ffi frame failed: $FDR_OUT"
ck; echo "$FDR_OUT" | grep -q 'FRAME_OK' || fail "no FFI FRAME_OK"

echo "=== DCDART FFI --no-init (negative) ==="
capture_sh FN_OUT FN_STATUS -- "'$FFI' --no-init -i '$CLIP' -o '$WORKDIR/ffi-none.ppm'"
echo "$FN_OUT"
ck; [[ $FN_STATUS -eq 0 ]] || fail "osmedia-ffi --no-init exited $FN_STATUS"
ck; echo "$FN_OUT" | grep -q 'BACKEND none' \
  || fail "ffi --no-init did not select none (got: $FN_OUT)"
capture_sh FDN_OUT FDN_STATUS -- "python3 '$DERIVE' '$WORKDIR/ffi-none.ppm' none"
echo "$FDN_OUT"
ck; [[ $FDN_STATUS -eq 0 ]] || fail "derive ffi none failed: $FDN_OUT"
ck; echo "$FDN_OUT" | grep -q 'NONE_OK' || fail "no FFI NONE_OK"

capture_sh FNM_OUT FNM_STATUS -- "nm '$FFI'"
ck; [[ $FNM_STATUS -eq 0 ]] || fail "nm osmedia-ffi failed"
ck; echo "$FNM_OUT" | grep -q 'osmediaFfiFrame' || fail "osmediaFfiFrame not in ffi binary"

require_assertions "$ASSERTIONS_REQUIRED"
echo "MEDIA0: PASS — FFmpeg linked; planted pixel is FRAME; --no-init/--missing are negatives ($ASSERTIONS checks)"
