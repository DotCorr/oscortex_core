#!/usr/bin/env bash
# CMOD-CHROME1 — DCDart @bare calls oschrome_* (platform WebView), writes a PPM.
# docs/design/dcdart-c-ffi.md, ADR-0095.
#
# dcc --mode bare --target host. Not a guest Chrome ELF. Not Flutter.
# Not a fake HTML parser. Links the existing CEF module (ADR-0083).
#
# Proof:
#   * oschrome_ffi.o is Mach-O; nm has U oschrome_ffi_load_url and oschromeFfiPage
#   * linked binary nm has oschrome_backend_chromium AND cef_initialize
#   * default PPM derived pixel is PAGE (0xC03890)
#   * --no-init / BACKEND none: same pixel is not PAGE
# Anti-vacuity: PAGE != 0; PAGE != DESK; oschrome.mm still calls CefInitialize.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "CMOD-CHROME1: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CMOD-CHROME1: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=51

for tool in clang dart python3 file nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH (source env.sh)"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-cmod-chrome1.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

BUILD="$CORE_DIR/scripts/build-oschrome.sh"
FFI="$CORE_DIR/build/oschrome-ffi"
APP_BIN="$CORE_DIR/build/oschrome-ffi.app/Contents/MacOS/oschrome-ffi"
OBJ="$CORE_DIR/build/oschrome_ffi.o"
HEADLESS="$CORE_DIR/build/oschrome-headless"
DERIVE="$CORE_DIR/tests/conformance/browser0/derive.py"
DART="$CORE_DIR/plat/chrome/oschrome.dart"
HDR="$CORE_DIR/plat/chrome/oschrome.h"
MM="$CORE_DIR/plat/chrome/oschrome.mm"
FFI_C="$CORE_DIR/plat/chrome/oschrome_ffi.c"
FW="$CORE_DIR/build/oschrome-ffi.app/Contents/Frameworks/Chromium Embedded Framework.framework"

ck; [[ -f "$BUILD" ]] || fail "no build-oschrome.sh"
ck; [[ -f "$DART" ]] || fail "no oschrome.dart"
ck; [[ -f "$HDR" ]] || fail "no oschrome.h"
ck; [[ -f "$MM" ]] || fail "no oschrome.mm"
ck; [[ -f "$FFI_C" ]] || fail "no oschrome_ffi.c"
ck; [[ -f "$DERIVE" ]] || fail "no derive.py"

PAGE=0x00C03890
DESK=0x00184060

ck; [[ $PAGE -ne 0 ]] || fail "PAGE is zero"
ck; [[ $PAGE -ne $DESK ]] || fail "PAGE equals DESK"
ck; grep -q 'OSCHROME_PAGE = 0x00C03890' "$HDR" || fail "oschrome.h PAGE moved without derive.py"
ck; grep -q 'u64(128)' "$DART" || fail "oschrome.dart W is not 128"
ck; grep -q 'u64(32)' "$DART" || fail "oschrome.dart PX is not 32"

ck; grep -q '@extern' "$DART" || fail "oschrome.dart has no @extern"
ck; grep -q 'oschromeFfiPage' "$DART" || fail "oschrome.dart has no oschromeFfiPage"
ck; grep -q 'oschrome_ffi_init' "$DART" || fail "oschrome.dart does not @extern init"
ck; grep -q 'oschrome_ffi_create' "$DART" || fail "oschrome.dart does not @extern create"
ck; grep -q 'oschrome_ffi_load_url' "$DART" || fail "oschrome.dart does not @extern load_url"
ck; grep -q 'oschrome_ffi_pump' "$DART" || fail "oschrome.dart does not @extern pump"
ck; grep -q 'oschrome_ffi_pixel' "$DART" || fail "oschrome.dart does not @extern pixel"
ck; grep -q 'oschrome_ffi_ppm' "$DART" || fail "oschrome.dart does not @extern ppm"
ck; grep -q 'oschrome_ffi_destroy' "$DART" || fail "oschrome.dart does not @extern destroy"
ck; grep -q 'oschrome_ffi_shutdown' "$DART" || fail "oschrome.dart does not @extern shutdown"
ck; grep -q 'oschrome_ffi_backend_chromium' "$DART" || fail "oschrome.dart does not @extern backend"

# Not a fake HTML parser in DCDart. Paint is CefInitialize / OnPaint.
if grep -q 'doctype html' "$DART"; then
  fail "oschrome.dart contains HTML — that is a fake parser, not CEF"
fi
ck; grep -q 'CefInitialize' "$MM" || fail "oschrome.mm does not call CefInitialize"
ck; grep -q 'OnPaint' "$MM" || fail "oschrome.mm has no OnPaint"
ck; grep -q 'include/cef_' "$MM" || fail "oschrome.mm has no CEF include"

echo "=== BUILD (dcc --target host + clang++ CEF) ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$BUILD' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-oschrome.sh exited $BUILD_STATUS"
ck; [[ -x "$FFI" ]] || fail "no oschrome-ffi"
ck; [[ -x "$APP_BIN" ]] || fail "no oschrome-ffi.app Mach-O"
ck; [[ -f "$OBJ" ]] || fail "no oschrome_ffi.o"
ck; [[ -d "$FW" ]] || fail "no Chromium Embedded Framework.framework — CEF was not linked"
ck; [[ -x "$HEADLESS" ]] || fail "oschrome-headless missing — browser0 binary was not kept"

capture_sh FILE_OUT FILE_STATUS -- "file '$OBJ'"
echo "$FILE_OUT"
ck; [[ $FILE_STATUS -eq 0 ]] || fail "file(1) failed"
ck; echo "$FILE_OUT" | grep -q 'Mach-O' || fail "dcc object is not Mach-O"
if echo "$FILE_OUT" | grep -qi 'ELF'; then
  fail "dcc object is ELF — use --target host"
fi

capture_sh NM_O NM_O_STATUS -- "nm '$OBJ'"
ck; [[ $NM_O_STATUS -eq 0 ]] || fail "nm object failed"
ck; echo "$NM_O" | grep -q 'oschrome_ffi_load_url' || fail "object has no oschrome_ffi_load_url"
ck; echo "$NM_O" | grep -q 'oschromeFfiPage' || fail "object has no oschromeFfiPage"

capture_sh NM_B NM_B_STATUS -- "nm '$APP_BIN'"
ck; [[ $NM_B_STATUS -eq 0 ]] || fail "nm binary failed"
ck; echo "$NM_B" | grep -q 'oschrome_backend_chromium' \
  || fail "oschrome_backend_chromium not in the binary"
ck; printf '%s\n' "$NM_B" | grep -E 'cef_|CefInitialize|cef_initialize' >/dev/null \
  || fail "no cef_/CefInitialize symbol — stub that only names oschrome_ffi_*"

echo "=== DCDART PAGE (Chromium) ==="
unset OSCHROME_NO_CHROMIUM
capture_sh PAGE_OUT PAGE_STATUS -- "'$APP_BIN' -o '$WORKDIR/page.ppm'"
echo "$PAGE_OUT"
ck; [[ $PAGE_STATUS -eq 0 ]] || fail "oschrome-ffi page exited $PAGE_STATUS"
ck; echo "$PAGE_OUT" | grep -q 'BACKEND chromium' \
  || fail "default path is not chromium (got: $PAGE_OUT)"
ck; [[ -f "$WORKDIR/page.ppm" ]] || fail "no page.ppm"

capture_sh DR_OUT DR_STATUS -- "python3 '$DERIVE' '$WORKDIR/page.ppm' page"
echo "$DR_OUT"
ck; [[ $DR_STATUS -eq 0 ]] || fail "derive page failed: $DR_OUT"
ck; echo "$DR_OUT" | grep -q 'PAGE_OK' || fail "no PAGE_OK"

echo "=== DCDART --no-init (negative) ==="
capture_sh NONE_OUT NONE_STATUS -- "'$APP_BIN' --no-init -o '$WORKDIR/none.ppm'"
echo "$NONE_OUT"
ck; [[ $NONE_STATUS -eq 0 ]] || fail "oschrome-ffi --no-init exited $NONE_STATUS"
ck; echo "$NONE_OUT" | grep -q 'BACKEND none' \
  || fail "--no-init did not select none (got: $NONE_OUT)"
if echo "$NONE_OUT" | grep -q 'BACKEND chromium'; then
  fail "--no-init still says chromium"
fi

capture_sh DN_OUT DN_STATUS -- "python3 '$DERIVE' '$WORKDIR/none.ppm' none"
echo "$DN_OUT"
ck; [[ $DN_STATUS -eq 0 ]] || fail "derive none failed: $DN_OUT"
ck; echo "$DN_OUT" | grep -q 'NONE_OK' || fail "no NONE_OK"

capture_sh DIFF_OUT DIFF_STATUS -- "python3 -c \"
import pathlib
a=pathlib.Path('$WORKDIR/page.ppm').read_bytes()
b=pathlib.Path('$WORKDIR/none.ppm').read_bytes()
raise SystemExit(0 if a!=b else 1)
\""
ck; [[ $DIFF_STATUS -eq 0 ]] || fail "page and no-init PPMs are identical"

capture_sh NM2_OUT NM2_STATUS -- "nm '$APP_BIN'"
ck; [[ $NM2_STATUS -eq 0 ]] || fail "nm after no-init failed"
ck; printf '%s\n' "$NM2_OUT" | grep -E 'cef_|CefInitialize|cef_initialize' >/dev/null \
  || fail "CEF symbols gone after no-init path"

require_assertions "$ASSERTIONS_REQUIRED"
echo "CMOD-CHROME1: PASS — DCDart @extern called the CEF WebView ($ASSERTIONS checks)"
