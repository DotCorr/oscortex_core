#!/usr/bin/env bash
# Preview is gone. Sit-in calls osgfx (ADR-0104, de-osgfx/).
# This file only checks the deletion the owner asked for and
# that sit-in types `wm gfx` (not OSGFX_GUEST / Mac Skia).
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "GFX3: FAIL — $1" >&2; exit 1; }
setup_error() { echo "GFX3: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=8

echo "=== PREVIEW IS GONE ==="
ck; [[ ! -f "$CORE_DIR/scripts/preview-ui.sh" ]] \
  || fail "preview-ui.sh still exists"
ck; [[ ! -f "$CORE_DIR/plat/osgfx/preview_main.m" ]] \
  || fail "preview_main.m still exists"
ck; ! find "$CORE_DIR" -name 'preview.html' | grep -q . \
  || fail "preview.html still exists"
ck; ! grep -q 'OSGFX_GUEST=1' "$CORE_DIR/scripts/sit-in.sh" \
  || fail "sit-in.sh still builds OSGFX_GUEST=1"
ck; grep -q "typekeys 'wm gfx'" "$CORE_DIR/scripts/sit-in.sh" \
  || fail "sit-in.sh does not type wm gfx"
ck; [[ -f "$CORE_DIR/plat/osgfx/osgfx_sw.c" ]] \
  || fail "osgfx_sw.c is missing — kernel must call the C ABI"
ck; [[ -f "$CORE_DIR/docs/decisions/0104-the-os-calls-osgfx.md" ]] \
  || fail "ADR-0104 is missing"
ck; [[ -f "$CORE_DIR/tests/conformance/de-osgfx/run.sh" ]] \
  || fail "de-osgfx harness is missing"

require_assertions "$ASSERTIONS_REQUIRED"
echo "GFX3: PASS — preview gone; sit-in is wm gfx / osgfx_sw ($ASSERTIONS checks)"
