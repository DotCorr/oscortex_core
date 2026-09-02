#!/usr/bin/env bash
# BROWSER0 — Chromium Content as a platform module (Android WebView shape).
# docs/design/c-modules.md, ADR-0083.
#
# Platform clang++. Not an app ELF. Not Flutter. Not preview.html.
# Not osgfx Metal rewritten as "Chrome".
#
# Proof:
#   * binaries exist after build-oschrome.sh
#   * file(1) says arm64 Mach-O
#   * nm shows oschrome_backend_chromium AND a real CEF/Content symbol
#     (cef_ / CefInitialize) — the backend name alone is not enough
#   * default headless BACKEND is chromium; derived pixel is PAGE
#   * --no-init PPM: same pixel is not PAGE (negative)
# Anti-vacuity: PAGE != 0; PAGE != DESK; oschrome.mm calls CefInitialize.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "BROWSER0: FAIL — $1" >&2; exit 1; }
setup_error() { echo "BROWSER0: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=41

for tool in clang++ python3 file nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-browser0.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

BUILD="$CORE_DIR/scripts/build-oschrome.sh"
FETCH="$CORE_DIR/scripts/fetch-cef.sh"
HEADLESS="$CORE_DIR/build/oschrome-headless"
APP_BIN="$CORE_DIR/build/oschrome-headless.app/Contents/MacOS/oschrome-headless"
DERIVE="$SCRIPT_DIR/derive.py"
HDR="$CORE_DIR/plat/chrome/oschrome.h"
MM="$CORE_DIR/plat/chrome/oschrome.mm"
FW="$CORE_DIR/build/oschrome-headless.app/Contents/Frameworks/Chromium Embedded Framework.framework"

ck; [[ -f "$BUILD" ]] || fail "no build-oschrome.sh"
ck; [[ -f "$FETCH" ]] || fail "no fetch-cef.sh"
ck; [[ -f "$HDR" ]] || fail "no oschrome.h"
ck; [[ -f "$DERIVE" ]] || fail "no derive.py"
ck; [[ -f "$MM" ]] || fail "no oschrome.mm"

PAGE=0x00C03890
DESK=0x00184060
W=128
H=128
PX=32
PY=32

ck; [[ $PAGE -ne 0 ]] || fail "PAGE is zero"
ck; [[ $PAGE -ne $DESK ]] || fail "PAGE equals DESK"
ck; [[ $((W * H)) -gt 0 ]] || fail "view area is zero"
ck; [[ $PX -lt $W ]] || fail "PX out of range"
ck; [[ $PY -lt $H ]] || fail "PY out of range"

ck; grep -q 'OSCHROME_PAGE = 0x00C03890' "$HDR" || fail "oschrome.h PAGE moved without derive.py"
ck; grep -q 'OSCHROME_DESK = 0x00184060' "$HDR" || fail "oschrome.h DESK moved without derive.py"
ck; grep -q 'OSCHROME_W = 128' "$HDR" || fail "oschrome.h W moved without derive.py"

# A header-only stub, or a .mm that only names oschrome_backend_chromium
# and fills a rect, is a FAIL.
ck; grep -q 'CefInitialize' "$MM" || fail "oschrome.mm does not call CefInitialize"
ck; grep -q 'OnPaint' "$MM" || fail "oschrome.mm has no OnPaint"
ck; grep -q 'include/cef_' "$MM" || fail "oschrome.mm has no CEF include"
ck; grep -q 'SetAsWindowless' "$MM" || fail "oschrome.mm is not windowless Content"

echo "=== BUILD (platform clang++ + official CEF) ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$BUILD' --headless 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-oschrome.sh exited $BUILD_STATUS"
ck; [[ -x "$HEADLESS" ]] || fail "no oschrome-headless"
ck; [[ -x "$APP_BIN" ]] || fail "no oschrome-headless.app Mach-O"
ck; [[ -d "$FW" ]] || fail "no Chromium Embedded Framework.framework — CEF was not linked"

capture_sh FILE_OUT FILE_STATUS -- "file '$APP_BIN'"
echo "$FILE_OUT"
ck; [[ $FILE_STATUS -eq 0 ]] || fail "file(1) failed"
ck; echo "$FILE_OUT" | grep -q 'Mach-O' || fail "headless is not Mach-O (do not use none-elf)"
if echo "$FILE_OUT" | grep -qi 'ELF'; then
  fail "headless is ELF — wrong toolchain"
fi
ck; echo "$FILE_OUT" | grep -q 'arm64' || fail "headless is not arm64"

capture_sh NM_OUT NM_STATUS -- "nm '$APP_BIN'"
ck; [[ $NM_STATUS -eq 0 ]] || fail "nm failed"
ck; echo "$NM_OUT" | grep -q 'oschrome_backend_chromium' \
  || fail "oschrome_backend_chromium not in the binary"
# Real CEF / Content, not a comment and not a stub that only exports the name.
# grep without -q: -q closes the pipe on the first cef_ hit and
# pipefail then looks like a missing symbol (Broken pipe).
ck; printf '%s\n' "$NM_OUT" | grep -E 'cef_|CefInitialize|cef_initialize' >/dev/null \
  || fail "no cef_/CefInitialize symbol — stub that only names oschrome_backend_chromium"

# The framework itself is Chromium, not a renamed dylib.
capture_sh FWNM_OUT FWNM_STATUS -- "nm -gU '$FW/Chromium Embedded Framework' 2>/dev/null | head -n 20"
if [[ $FWNM_STATUS -ne 0 ]]; then
  capture_sh FWNM_OUT FWNM_STATUS -- "nm '$FW/Chromium Embedded Framework'"
fi
ck; [[ $FWNM_STATUS -eq 0 ]] || fail "nm on CEF framework failed"
ck; printf '%s\n' "$FWNM_OUT" | grep -E 'cef_|content' >/dev/null \
  || fail "framework has no cef_/content symbol"

echo "=== HEADLESS data: URL (Chromium) ==="
unset OSCHROME_NO_CHROMIUM
capture_sh PAGE_OUT PAGE_STATUS -- "'$APP_BIN' -o '$WORKDIR/page.ppm'"
echo "$PAGE_OUT"
ck; [[ $PAGE_STATUS -eq 0 ]] || fail "headless page exited $PAGE_STATUS"
ck; echo "$PAGE_OUT" | grep -q 'BACKEND chromium' \
  || fail "default path is not chromium (got: $PAGE_OUT)"
ck; [[ -f "$WORKDIR/page.ppm" ]] || fail "no page.ppm"

capture_sh DR_OUT DR_STATUS -- "python3 '$DERIVE' '$WORKDIR/page.ppm' page"
echo "$DR_OUT"
ck; [[ $DR_STATUS -eq 0 ]] || fail "derive page failed: $DR_OUT"
ck; echo "$DR_OUT" | grep -q 'PAGE_OK' || fail "no PAGE_OK"

echo "=== HEADLESS --no-init (negative) ==="
capture_sh NONE_OUT NONE_STATUS -- "'$APP_BIN' --no-init -o '$WORKDIR/none.ppm'"
echo "$NONE_OUT"
ck; [[ $NONE_STATUS -eq 0 ]] || fail "headless --no-init exited $NONE_STATUS"
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

# CEF symbols must survive the no-init run — they were linked, not imagined.
capture_sh NM2_OUT NM2_STATUS -- "nm '$APP_BIN'"
ck; [[ $NM2_STATUS -eq 0 ]] || fail "nm after no-init failed"
ck; printf '%s\n' "$NM2_OUT" | grep -E 'cef_|CefInitialize|cef_initialize' >/dev/null \
  || fail "CEF symbols gone after no-init path"

require_assertions "$ASSERTIONS_REQUIRED"
echo "BROWSER0: PASS — CEF/Content linked; data: pixel is PAGE; --no-init is a negative ($ASSERTIONS checks)"
