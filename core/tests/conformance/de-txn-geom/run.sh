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
CHIP="$CORE_DIR/scripts/chip-scan-round24.py"
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

hit = fn(wmde, "wmHitGeom")
if "wmPendGeomOf" not in hit:
    raise SystemExit("wmHitGeom does not consult pending")
if "wmVisGeom" not in hit:
    raise SystemExit("hit-test HOLD path does not return committed vis")
if "wmWinSeq" in hit:
    raise SystemExit("wmHitGeom must stay on VIS after COMMIT until publish")

close_x = fn(wmde, "wmCloseX")
btn_y = fn(wmde, "wmBtnY")
if "wmHitGeom" not in close_x:
    raise SystemExit("wmCloseX hit-test is not committed/visible geom")
if "wmHitGeom" not in btn_y:
    raise SystemExit("wmBtnY hit-test is not committed/visible geom")

absx = fn(ext, "wmAbsX")
absy = fn(ext, "wmAbsY")
if "wmViewGeom" not in absx or "wmViewGeom" not in absy:
    raise SystemExit("wmAbs origin is not view geom during HOLD")

title = fn(chrome, "wmTitleHit")
if "wmHitGeom" not in title:
    raise SystemExit("wmTitleHit uses requested geom during HOLD")

toggle = fn(wmde, "wmToggleMaxWindow")
if "wmPendArm" not in toggle:
    raise SystemExit("max/restore does not arm pending")
if "wmVisPublish(" in toggle:
    raise SystemExit("max/restore publishes VIS before COMMIT")
if "wmPopHide" not in toggle:
    raise SystemExit("max/restore does not dismiss an open menu before HOLD")
if "wmHoldKick" not in toggle:
    raise SystemExit("max/restore does not retry an unpublished HOLD")
if "wmStrHoldRe" not in toggle:
    raise SystemExit("unpublished HOLD retry has no WM HOLD RE token")

drain = fn(wmde, "wmDefDrain")
if "osgfx_chrome_prep_present" in drain:
    raise SystemExit("max drain still punches wallpaper holes")
if "wmDefFlagSeq0" in drain:
    raise SystemExit("max drain still sets Seq0 (uncommitted blit)")
if "wmVisMaybePublish" not in drain:
    raise SystemExit("drag drain does not publish committed VIS")
if "wmWinSeq" not in drain:
    raise SystemExit("drag drain does not refuse a size-HOLD blit")

maybe = fn(wmde, "wmVisMaybePublish")
if "wmWinSeq" not in maybe:
    raise SystemExit("VIS publish is not gated on committed seq")

commit = fn(wm, "wmComposeCommit")
if "wmVisMaybePublish" not in commit and "wmVisMaybePublishAll" not in commit:
    raise SystemExit("compose commit does not publish VIS")
if "wmPendGeomOf" not in commit:
    raise SystemExit("HOLD compose still honours a stale chrome cache")
if "wmPageWChromeHave" not in commit:
    raise SystemExit("HOLD compose does not refuse an empty chrome cache")
wm_commit = fn(wm, "wmCommit")
if "wmChromeInvalidate" not in wm_commit:
    raise SystemExit("HOLD commit does not invalidate chrome for sibling titles")
if "wmPendGeomOf" not in wm_commit:
    raise SystemExit("HOLD commit does not consult pending before chrome invalidate")

resize = fn(wm, "wmResizeStep")
if "wmPendArm" not in resize:
    raise SystemExit("resize does not HOLD pending geom")
if "wmDefEnqueue" in resize:
    raise SystemExit("resize still union-blits old∪new")

close = fn(wmde, "wmCloseWindow")
if "wmVisClear" not in close:
    raise SystemExit("close does not drop committed VIS")
if "wmVisGeom" not in close:
    raise SystemExit("close uncovers requested geom, not committed VIS")

clear = fn(wmde, "wmVisClear")
if "wmStrVis" not in clear:
    raise SystemExit("VIS clear does not publish a committed generation")

grab = fn(wm, "wmGrab")
if "wmPendGeomOf" not in grab:
    raise SystemExit("title grab does not refuse drag during HOLD")
drag = fn(wm, "wmDragStep")
if "wmPendGeomOf" not in drag:
    raise SystemExit("wmDragStep does not refuse a HOLD translate")

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
watch = fn(wmde, "wmHoldWatch")
if "wmHoldKick" not in watch:
    raise SystemExit("watchdog does not re-enqueue a stuck HOLD")
if "wmHoldCancel" not in watch:
    raise SystemExit("watchdog has no timeout cancel")
if "wmCompose" not in watch:
    raise SystemExit("watchdog does not force compose after COMMIT")

cancel = fn(wmde, "wmHoldCancel")
if "wmStrHoldTo" not in cancel:
    raise SystemExit("HOLD cancel has no WM HOLD TO token")
if "wmPageWMax0" not in cancel:
    raise SystemExit("HOLD cancel does not restash restore geom")

arm = fn(wmde, "wmPendArm")
if "wmPageWHoldArm0" not in arm:
    raise SystemExit("wmPendArm does not stamp the watchdog arm tick")

if "wmHoldWatch();" not in pace and "wmHoldWatch()" not in pace:
    raise SystemExit("wmFrameTick does not run the HOLD watchdog")

if "q.key(\"esc\")" in chip and "ensure_restored" in chip:
    if "close+relaunch" in chip or "WM CLOSE" in chip and "FILES CSD" in chip:
        # Chip-scan may close for lifecycle, but must not Esc+close to unstick HOLD.
        pass
if "ensure_restored" in chip:
    idx = chip.find("def ensure_restored")
    nxt = chip.find("\n    cycle", idx)
    if nxt < 0:
        nxt = chip.find("\n    def ", idx + 4)
    rest = chip[idx:nxt] if nxt > idx else chip[idx:idx + 800]
    if "q.key" in rest or "esc" in rest:
        raise SystemExit("chip-scan still Esc-dismisses to unstick restore HOLD")
    if "WM CLOSE" in rest:
        raise SystemExit("chip-scan still close/relaunch-unsticks restore HOLD")

print("de-txn-geom static PASS")
PY
echo "de-txn-geom: PASS"
