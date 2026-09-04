#!/usr/bin/env bash
# Static lockstep: requested/pending geom is not committed/visible.
# Hit-test during HOLD uses VIS; inspector ground truth is WM VIS + gen.
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WMDE="$CORE_DIR/kernel/wmde.dart"
WM="$CORE_DIR/kernel/wm.dart"
PACE="$CORE_DIR/kernel/wmpace.dart"
EXT="$CORE_DIR/kernel/wmext.dart"
GFX="$CORE_DIR/kernel/wmgfx.dart"
CHROME="$CORE_DIR/kernel/wmchrome.dart"
CHIP="$CORE_DIR/scripts/chip-scan-round23.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
ck() { "$@"; }

ck; grep -q 'const int wmPageWVis0 = 446' "$PACE" \
  || fail "committed vis words missing"
ck; grep -q 'const int wmPageWPend0 = 450' "$PACE" \
  || fail "pending geom words missing"
ck; grep -q 'const int wmPageWVisGen0 = 454' "$PACE" \
  || fail "present generation words missing"
ck; grep -q 'void wmPendArm' "$WMDE" \
  || fail "wmPendArm missing"
ck; grep -q 'void wmVisPublish' "$WMDE" \
  || fail "wmVisPublish missing"
ck; grep -q 'void wmVisMaybePublish' "$WMDE" \
  || fail "wmVisMaybePublish missing"
ck; grep -q 'u64 wmViewGeom' "$WMDE" \
  || fail "wmViewGeom missing"
ck; grep -q 'wmStrReq' "$WMDE" \
  || fail "WM REQ token missing"
ck; grep -q 'wmStrPendTok' "$WMDE" \
  || fail "WM PEND token missing"
ck; grep -q 'wmStrVis' "$WMDE" \
  || fail "WM VIS token missing"

python3 - "$WMDE" "$WM" "$PACE" "$EXT" "$GFX" "$CHROME" "$CHIP" <<'PY' || fail "txn/hit-test source-of-truth checks"
import re, sys
wmde, wm, pace, ext, gfx, chrome, chip = [open(p).read() for p in sys.argv[1:]]

def fn(src, name):
    m = re.search(r"(void|u64) %s\(" % name, src)
    if not m:
        raise SystemExit("missing %s" % name)
    rest = src[m.start():]
    nxt = re.search(r"\n(@bare\n)?(u64|void) \w+\(", rest[8:])
    return rest[: (8 + nxt.start())] if nxt else rest

view = fn(wmde, "wmViewGeom")
if "wmPendGeomOf" not in view:
    raise SystemExit("wmViewGeom does not consult pending")
if "wmVisGeom" not in view:
    raise SystemExit("HOLD path does not return committed vis")
if "wmWinSeq" not in view:
    raise SystemExit("wmViewGeom does not gate HOLD on seq==0")

close_x = fn(wmde, "wmCloseX")
btn_y = fn(wmde, "wmBtnY")
if "wmViewGeom" not in close_x:
    raise SystemExit("wmCloseX hit-test is not view/visible geom")
if "wmViewGeom" not in btn_y:
    raise SystemExit("wmBtnY hit-test is not view/visible geom")

absx = fn(ext, "wmAbsX")
absy = fn(ext, "wmAbsY")
if "wmViewGeom" not in absx or "wmViewGeom" not in absy:
    raise SystemExit("wmAbs origin is not view geom during HOLD")

title = fn(chrome, "wmTitleHit")
if "wmViewGeom" not in title:
    raise SystemExit("wmTitleHit uses requested geom during HOLD")

toggle = fn(wmde, "wmToggleMaxWindow")
if "wmPendArm" not in toggle:
    raise SystemExit("max/restore does not arm pending")
if "wmVisPublish(" in toggle:
    raise SystemExit("max/restore publishes VIS before COMMIT")

drain = fn(wmde, "wmDefDrain")
if "osgfx_chrome_prep_present" in drain:
    raise SystemExit("max drain still punches wallpaper holes")
if "wmDefFlagSeq0" in drain:
    raise SystemExit("max drain still sets Seq0 (uncommitted blit)")
if "wmVisMaybePublish" not in drain:
    raise SystemExit("drag drain does not publish committed VIS")

maybe = fn(wmde, "wmVisMaybePublish")
if "wmWinSeq" not in maybe:
    raise SystemExit("VIS publish is not gated on committed seq")

commit = fn(wm, "wmComposeCommit")
if "wmVisMaybePublish" not in commit and "wmVisMaybePublishAll" not in commit:
    raise SystemExit("compose commit does not publish VIS")

resize = fn(wm, "wmResizeStep")
if "wmPendArm" not in resize:
    raise SystemExit("resize does not HOLD pending geom")
if "wmDefEnqueue" in resize:
    raise SystemExit("resize still union-blits old∪new")

close = fn(wmde, "wmCloseWindow")
if "wmVisClear" not in close:
    raise SystemExit("close does not drop committed VIS")

kick = fn(gfx, "wmGfxKick")
if "wmViewGeom" not in kick:
    raise SystemExit("chrome mailbox still uses requested geom on HOLD")

if "WM VIS W" not in chip:
    raise SystemExit("chip-scan-round23 does not parse WM VIS")
if "false_positive" in chip or "fp_class" in chip or "fp_classes" in chip:
    raise SystemExit("chip-scan still has post-hoc FP exemptions")
if "WM ATTACH" in chip and "live_files_xywh" in chip:
    if re.search(r"ATTACH_RE.*live_files|geom_source.*ATTACH", chip):
        raise SystemExit("chip-scan still infers AABB from ATTACH")
if "geom_source" in chip and "WM VIS" not in chip:
    raise SystemExit("chip-scan geom_source is not committed VIS")
print("de-txn-geom static PASS")
PY
echo "de-txn-geom: PASS"
