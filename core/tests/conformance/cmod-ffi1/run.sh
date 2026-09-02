#!/usr/bin/env bash
# CMOD-FFI1 — DCDart @bare calls osgfx_* (C module), writes a PPM.
# docs/design/dcdart-c-ffi.md, ADR-0081.
#
# dcc --mode bare --target host. Not a Cocoa app. Not preview.html.
#
# Proof:
#   * osgfx_ffi.o is Mach-O; nm has U osgfx_ffi_fill_rrect
#   * osgfx-ffi nm has osgfxFfiPaint and osgfx_fill_rrect
#   * PPM AABB corner is desktop (rrect), title interior is TITLE
# Anti-vacuity: TITLE != DESK; RADIUS != 0.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "CMOD-FFI1: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CMOD-FFI1: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=20

for tool in clang dart python3 file nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH (source env.sh)"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-cmod-ffi1.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

BUILD="$CORE_DIR/scripts/build-preview-ui.sh"
FFI="$CORE_DIR/build/osgfx-ffi"
OBJ="$CORE_DIR/build/osgfx_ffi.o"
DERIVE="$CORE_DIR/tests/conformance/gfx0-host/derive.py"
DART="$CORE_DIR/plat/osgfx/osgfx.dart"

ck; [[ -f "$BUILD" ]] || fail "no build-preview-ui.sh"
ck; [[ -f "$DART" ]] || fail "no osgfx.dart"
ck; [[ -f "$DERIVE" ]] || fail "no derive.py"
ck; grep -q '@extern' "$DART" || fail "osgfx.dart has no @extern"
ck; grep -q 'osgfxFfiPaint' "$DART" || fail "osgfx.dart has no osgfxFfiPaint"

echo "=== BUILD (dcc --target host + clang Metal) ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$BUILD' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-preview-ui.sh exited $BUILD_STATUS"
ck; [[ -x "$FFI" ]] || fail "no osgfx-ffi"
ck; [[ -f "$OBJ" ]] || fail "no osgfx_ffi.o"

capture_sh FILE_OUT FILE_STATUS -- "file '$OBJ'"
echo "$FILE_OUT"
ck; [[ $FILE_STATUS -eq 0 ]] || fail "file(1) failed"
ck; echo "$FILE_OUT" | grep -q 'Mach-O' || fail "dcc object is not Mach-O"
if echo "$FILE_OUT" | grep -qi 'ELF'; then
  fail "dcc object is ELF — use --target host"
fi

capture_sh NM_O NM_O_STATUS -- "nm '$OBJ'"
ck; [[ $NM_O_STATUS -eq 0 ]] || fail "nm object failed"
ck; echo "$NM_O" | grep -q 'osgfx_ffi_fill_rrect' || fail "object has no osgfx_ffi_fill_rrect"
ck; echo "$NM_O" | grep -q 'osgfxFfiPaint' || fail "object has no osgfxFfiPaint"

capture_sh NM_B NM_B_STATUS -- "nm '$FFI'"
ck; [[ $NM_B_STATUS -eq 0 ]] || fail "nm binary failed"
ck; echo "$NM_B" | grep -q 'osgfx_fill_rrect' || fail "binary has no osgfx_fill_rrect (C module missing)"
ck; echo "$NM_B" | grep -q 'osgfxFfiPaint' || fail "binary has no osgfxFfiPaint (DCDart missing)"

echo "=== DCDART PAINT ==="
capture_sh RUN_OUT RUN_STATUS -- "'$FFI' -o '$WORKDIR/rrect.ppm'"
echo "$RUN_OUT"
ck; [[ $RUN_STATUS -eq 0 ]] || fail "osgfx-ffi paint exited $RUN_STATUS"
ck; [[ -f "$WORKDIR/rrect.ppm" ]] || fail "no rrect.ppm"

capture_sh DR_OUT DR_STATUS -- "python3 '$DERIVE' '$WORKDIR/rrect.ppm' rrect"
echo "$DR_OUT"
ck; [[ $DR_STATUS -eq 0 ]] || fail "derive rrect failed: $DR_OUT"
ck; echo "$DR_OUT" | grep -q 'RRECT_OK' || fail "no RRECT_OK"

require_assertions "$ASSERTIONS_REQUIRED"
echo "CMOD-FFI1: PASS — DCDart @extern called the C paint module ($ASSERTIONS checks)"
