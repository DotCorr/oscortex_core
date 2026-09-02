#!/usr/bin/env bash
# core/tests/conformance/de-desk/run.sh
#
# ADR-0183 / ADR-0197 — DESK.ELF is the desk shell; boot is wallpaper +
# split glass dock; FILES opens from a dock hit.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# Structural: ADR-0183/0197, desk.c uses osxui glass islands + spawn,
# sit-in does not require FILES on boot.
# Runtime: DESK READY + DESK DOCK; no FILES until dock click; CSD/rename
# / contextual still hold after FILES launches.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
DESK_C="$CORE_DIR/user/frame/desk.c"
ADR="$CORE_DIR/docs/decisions/0183-desk-shell-is-a-frame-app.md"
SESS="$CORE_DIR/plat/osgfx/osgfx_session.c"
WM="$CORE_DIR/kernel/wm.dart"
SHM="$CORE_DIR/kernel/shm.dart"
SITFAT="$CORE_DIR/tests/conformance/de-sitfat"

fail() {
  if [[ -n "${SER:-}" && -f "$SER" ]]; then
    cp "$SER" "$CORE_DIR/build/de-desk-last-serial.txt" 2>/dev/null || true
  fi
  echo "DE-DESK: FAIL — $1" >&2
  exit 1
}
setup_error() { echo "DE-DESK: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

# THE STRIP IS SKIA NOW, SO THE KERNEL MUST HAVE SKIA IN IT (ADR-0192).
#
# This harness used to run OSGFX_SKIA=0 and still see an orange Start pill,
# because DESK.ELF wrote that pill into its own shm by hand: a solid span walk,
# square corners, an 8x16 bitmap caption. There is nothing left in DESK.ELF
# that can draw a pill -- it asks the OS, through `wmOpPaint` -- so on a kernel
# with no rasteriser the strip is a bare gradient-less band, which is the same
# thing every other surface in that link is. Asserting an antialiased pill and
# a proportional advance means asserting them against the image that has a
# rasteriser, and that is what OSGFX_SKIA=1 is.
export OSGFX_SKIA=1
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=119

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-desk.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"

ck; [[ -f "$ADR" ]] || fail "ADR-0183 missing"
ck; [[ -f "$DESK_C" ]] || fail "desk.c missing"
ck; [[ -f "$SESS" ]] || fail "osgfx_session.c missing"
ck; [[ -f "$WM" ]] || fail "wm.dart missing"

echo "=== STRUCTURAL ==="
ck; grep -q 'DESK.ELF' "$ADR" || fail "ADR does not name DESK.ELF"
# ADR-0192: the strip's captions are outlines and its geometry is asked for.
# `osxui_label_fb` is the 8x16 bitmap cell the taskbar used to be captioned
# with; code that still called it could still stamp one.
ck; grep -vE '^[[:space:]]*(\*|/\*|//)' "$DESK_C" | grep -q 'osxui_label_fb' \
  && fail "desk.c still calls osxui_label_fb — the taskbar is a bitmap cell"
ck; grep -q 'osxui_app.h' "$DESK_C" || fail "desk.c does not use the osxui app SDK"
ck; grep -q 'osxui_app_screen' "$DESK_C" \
  || fail "desk.c does not ask the compositor for the screen rect"
ck; grep -qE 'osxui_app_label_box|osxui_app_clock|osxui_app_text' "$DESK_C" \
  || fail "desk.c does not caption through the app text API"
ck; grep -q 'osxui_app_island' "$DESK_C" \
  || fail "desk.c does not paint glass islands"
ck; grep -q 'paint_icon_glyph' "$DESK_C" \
  || fail "desk.c still uses coloured squares for dock icons"
ck; grep -q 'DESK FROST' "$DESK_C" \
  || fail "desk.c has no frost vary line"
ck; grep -q 'osgfx_glass_frost' "$CORE_DIR/plat/osgfx/osgfx.h" \
  || fail "osgfx.h has no glass frost ABI"
ck; grep -q 'wmPaintGlass' "$CORE_DIR/kernel/wmext.dart" \
  || fail "wmext has no glass paint kind"
ck; grep -q 'osxui_app_icon_btn' "$DESK_C" \
  || fail "desk.c does not paint dock icon buttons"
ck; grep -q 'SYS_SPAWN' "$DESK_C" \
  || fail "desk.c cannot launch from the dock"
ck; grep -vE '^[[:space:]]*(\*|/\*|//)' "$DESK_C" \
  | grep -qE '(^|[^0-9A-Za-z_])(794|549|800|600)([^0-9]|$)' \
  && fail "desk.c still has an 800x600 constant in its code"
# The compositor's fallback strip has to be withdrawable, or there are two.
ck; grep -q 'OSGFX_GUEST_PANEL' "$SESS" \
  || fail "osgfx_session.c does not check the client-owns-the-strip flag"
ck; grep -q 'osgfxGuestPanel' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "wmgfx.dart does not publish the client-owns-the-strip flag"
ck; grep -q 'u64 wmPanelStrip' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "wmgfx.dart has no wmPanelStrip"
ck; grep -q 'DESK READY' "$DESK_C" || fail "desk.c no DESK READY"
ck; grep -q 'ADR-0183' "$WM" || fail "wm.dart missing ADR-0183"
ck; grep -q 'osgfx_guest_tick' "$WM" || fail "wmCompose lost tick"
ck; grep -q 'wmDrawWindow' "$WM" || fail "wmCompose lost blit"
# Body fill must not paint OSGFX_WIN_FILL over the window interior.
ck; ! grep -n 'osgfx_fill_rrect(g, x, y, w, h, r, fill)' "$SESS" \
  || fail "session still fills full window body with fill colour"
ck; grep -q 'never fill the client body' "$SESS" \
  || fail "session missing ADR-0183 body comment"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; grep -q 'osgfx_pointer_raster' "$CORE_DIR/plat/osgfx/osgfx.h" \
  || fail "no Skia pointer ABI"
ck; grep -q 'CLIENT_POINTER' "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "osgfx_skia.cpp has no pointer path"
ck; grep -q 'wmPointerBlit' "$CORE_DIR/kernel/wm.dart" \
  || fail "wm does not blit a Skia sprite"
ck; grep -q 'wmContextShow' "$CORE_DIR/kernel/wmpop.dart" \
  || fail "no contextual right-click"
ck; grep -q 'final u64 geomHit = wmDeGeomHit' "$CORE_DIR/kernel/wmpop.dart" \
  || fail "CSD title context clicks still fall through as wallpaper"
ck; grep -q 'WM_SCREEN_NAME' "$CORE_DIR/user/frame/osframe.h" \
  || fail "no screen name op for desk pills"
ck; [[ -f "$CORE_DIR/docs/decisions/0194-skia-pointer-and-contextual-menus.md" ]] \
  || fail "ADR-0194 missing"
ck; [[ -f "$CORE_DIR/docs/decisions/0195-csd-titles-and-desk-menus.md" ]] \
  || fail "ADR-0195 missing"
ck; [[ -f "$CORE_DIR/docs/decisions/0196-one-skia-aa-card-and-proved-rename.md" ]] \
  || fail "ADR-0196 missing"
ck; grep -q 'OSGFX SESSION CHROME CLIENT' "$SESS" \
  || fail "session has no CSD-withdraw token"
ck; grep -q 'if (session_csd == 0)' "$SESS" \
  || fail "session still paints the title band with DESK up"
ck; grep -q 'cmd->pop != 0 && panel == 0' "$SESS" \
  || fail "session still paints menus with DESK up"
ck; grep -q 'WMEVENT_TYPE_CONTEXT' "$CORE_DIR/user/frame/osframe.h" \
  || fail "no context press type for file-row menus"
ck; grep -q 'WM_SCREEN_POP' "$CORE_DIR/user/frame/osframe.h" \
  || fail "no SCREEN_POP for DESK menus"
ck; grep -q 'osxui_app_csd' "$CORE_DIR/user/frame/files.c" \
  || fail "FILES does not paint CSD titles"
ck; grep -q 'files_stride \* files_cap_h' "$CORE_DIR/user/frame/files.c" \
  || fail "FILES does not size native backing from target dimensions"
ck; grep -q 'SYS_SHMGROW' "$CORE_DIR/user/frame/files.c" \
  || fail "FILES does not grow backing for native maximize"
ck; grep -q 'WM_OP_BACKING' "$CORE_DIR/user/frame/files.c" \
  || fail "FILES does not publish its grown native stride"
ck; grep -q 'void wmBackingOp' "$CORE_DIR/kernel/wmext.dart" \
  || fail "WM does not validate native backing updates"
ck; ! grep -q 'WM_SURFACE_VIEWPORT' "$CORE_DIR/user/frame/files.c" \
  || fail "FILES still requests raster viewport scaling"
ck; grep -q 'u64 shmVaFind' "$SHM" \
  || fail "SHM still strands large native surfaces in fixed 128-page slots"
ck; python3 - "$SHM" <<'PY' \
  || fail "SHM native-surface bound is unsafe or too small"
import re, sys
s = open(sys.argv[1]).read()
n = int(re.search(r"const int shmMaxPages = (\d+);", s).group(1))
sys.exit(0 if 424 <= n <= 510 else 1)
PY
ck; grep -q 'wmPointerPending' "$WM" \
  || fail "pointer packets arriving during composition are still discarded"
ck; grep -q 'wmeventEnqueue(panel, x, y)' "$WM" \
  || fail "fallback chrome does not dispatch unmatched client dock clicks"
ck; grep -q 'u64 wmPanelWindow' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "dock dispatch confuses panel ownership with a window slot"
ck; grep -q 'if (wmIsPanel(hit) > u64(0))' "$WM" \
  || fail "dock presses still raise or drag the DESK panel"
ck; grep -q 'def button(x, y, btn, down):' "$0" \
  || fail "QMP button transitions do not carry absolute tablet coordinates"
ck; grep -q 'osxui_app_csd' "$CORE_DIR/user/frame/set.c" \
  || fail "SET does not paint CSD titles"
ck; grep -q 'osxui_app_csd' "$CORE_DIR/user/frame/tap.c" \
  || fail "TAP does not paint CSD titles"
ck; grep -q 'osxui_app_csd' "$CORE_DIR/user/frame/browse.c" \
  || fail "BROWSE does not paint CSD titles"
ck; grep -q 'osxui_app_csd' "$CORE_DIR/user/frame/studio.c" \
  || fail "STUDIO does not paint CSD titles"
ck; grep -q 'osxui_app_csd' "$CORE_DIR/tests/conformance/de-chrome/ping.c" \
  || fail "PING does not paint CSD titles"
ck; grep -q 'void wmOverlayRestore' "$WM" \
  || fail "wm has no overlay restore — hide still leaves leftover pixels"
ck; python3 - "$CORE_DIR/plat/osgfx/osgfx.h" "$CORE_DIR/kernel/wmgfx.dart" <<'PY' \
  || fail "window radius is not one modest card (OSGFX_RADIUS / BLIT_INSET / wmGfxRadius)"
import re, sys
h, d = open(sys.argv[1]).read(), open(sys.argv[2]).read()
r = int(re.search(r"OSGFX_RADIUS = (\d+)", h).group(1))
b = int(re.search(r"OSGFX_BLIT_INSET = (\d+)", h).group(1))
g = int(re.search(r"wmGfxRadius = (\d+)", d).group(1))
sys.exit(0 if r == b == g == 18 else 1)
PY
ck; grep -q 'yy < wy + OSGFX_RADIUS' "$CORE_DIR/plat/osgfx/osgfx_chrome.c" \
  || fail "chrome_body_span does not keep top corners for the AA card"
ck; grep -q 'osxui_app_pop' "$DESK_C" \
  || fail "DESK does not poll the popover"
ck; grep -q 'FILES MENU' "$CORE_DIR/user/frame/files.c" \
  || fail "FILES has no row menu"
ck; grep -q 'wmIsOverlay' "$WM" \
  || fail "wm has no overlay rule for DESK menus"
ck; grep -q 'u64 wmWinOverlay' "$WM" \
  || fail "wmHit does not skip the DESK overlay"
ck; python3 - "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" <<'PY' || fail "canvas reset is still after the bump rewind"
import sys
t=open(sys.argv[1]).read()
a=t.find("(void)osgfx_graphite_try();")
gencheck=t.find("if (m->gen == last_gen)", a)
drop=t.find("drop_skia_before_rewind()", a)
h=t.find("static void drop_skia_before_rewind")
he=t.find("\n}", h)
body=t[h:he] if h>=0 and he>h else ""
ri=body.find("g_one.owned.reset()")
cj=body.find("client_g.owned.reset()")
hj=body.find("osgfx_heap_frame_begin()")
# Idle ticks return on gen before any rewind; a paint drops both canvases first.
sys.exit(0 if a>=0 and a<gencheck<drop and 0<=ri<hj and 0<=cj<hj else 1)
PY
ck; grep -q 'client_arg.kind != CLIENT_POINTER' \
     "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "heap reclaim must not run on the pointer blit"
ck; grep -q 'osgfx_heap_ready() > 0' \
     "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "client reclaim must wait for the Graphite watermark"
ck; grep -qF '384u * 1024u' \
     "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "client paint does not reclaim the bump when it is tight"
echo "STRUCTURAL: pass"

echo
echo "=== BUILD DESK.ELF ==="
capture_sh BP_OUT BP_ST -- "bash '$SCRIPT_DIR/build-progs.sh' '$WORKDIR/desk' 2>&1"
echo "$BP_OUT"
ck; [[ $BP_ST -eq 0 ]] || fail "build-progs exited $BP_ST"
ck; [[ -f "$WORKDIR/desk/desk.elf" ]] || fail "no desk.elf"

echo
echo "=== BUILD KERNEL + FAT ==="
if [[ "${SITIN_SKIP_BUILD:-}" == 1 && -f "$CORE_DIR/build/kernel.elf" ]]; then
  echo "skipping build-kernel (SITIN_SKIP_BUILD=1)"
else
  capture_sh BK_OUT BK_ST -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
  echo "$BK_OUT"
  ck; [[ $BK_ST -eq 0 ]] || fail "build-kernel exited $BK_ST"
fi
KERNEL_ELF="$CORE_DIR/build/kernel.elf"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
capture_sh BD_OUT BD_ST -- "bash '$SITFAT/build-disk.sh' '$WORKDIR/fat' 2>&1"
echo "$BD_OUT"
ck; [[ $BD_ST -eq 0 ]] || fail "build-disk exited $BD_ST"
ck; [[ -f "$WORKDIR/fat/disk.img" ]] || fail "no disk.img"
ck; grep -q 'DESK.ELF' "$WORKDIR/fat/layout.json" || fail "DESK.ELF not planted"

echo
echo "=== RUNTIME ==="
PORT=$(python3 "$PICKER")
SER="$WORKDIR/serial.txt"
PNG="$WORKDIR/frame.png"
: >"$SER"

qemu-system-x86_64 \
  -name oscortex-de-desk \
  -machine q35,accel=tcg -cpu qemu64 -m 256 \
  -kernel "$KERNEL_ELF" \
  -drive "file=$WORKDIR/fat/disk.img,format=raw,if=ide,index=0,media=disk" \
  -device virtio-tablet-pci \
  -display none -serial "file:$SER" \
  -qmp "tcp:127.0.0.1:${PORT},server,nowait" \
  -no-reboot \
  >"$WORKDIR/qemu.log" 2>&1 &
QPID=$!
cleanup_q() {
  kill "$QPID" 2>/dev/null || true
  wait "$QPID" 2>/dev/null || true
  cleanup
}
trap cleanup_q EXIT

# typekeys helper — qmp-drive letter tokens, not 'type:x'
typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1200"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm de'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'vtab'),ret,wait:800"
# Cold boot is wallpaper + dock (ADR-0197). FILES opens from a dock hit.
KEYS="$KEYS,$(typekeys 'proc spawn DESK.ELF'),ret,wait:3000"
KEYS="$KEYS,$(typekeys 'wm draw'),ret,wait:1000"
KEYS2="$(typekeys 'wm draw'),ret,wait:800"

FB="$WORKDIR/fb.raw"
FB2="$WORKDIR/fb2.raw"
PNG2="$WORKDIR/frame2.png"
capture_sh DR_OUT DR_ST -- "python3 '$DRIVER' --port '$PORT' --serial '$SER' --wait-for 'M1 END\n' --keys '$KEYS' --settle-for 'DESK READY' --settle-timeout 90 --keys2 '$KEYS2' --fb-out2 '$FB2' --png2 '$PNG2' --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' --fb-out '$FB' --png '$PNG' --no-quit 2>&1"
echo "$DR_OUT"
ck; [[ $DR_ST -eq 0 ]] || {
  echo "--- serial tail ---" >&2
  tail -120 "$SER" >&2
  fail "comp-drive exited $DR_ST"
}
ck; [[ -s "$PNG" ]] || fail "no png"

ck; grep -q 'DESK BOOT' "$SER" || fail "no DESK BOOT"
# Prefer READY; accept ATT OK so we still see how far paint got.
if grep -q 'DESK READY' "$SER"; then
  echo "DESK reached READY"
elif grep -q 'DESK ATT OK' "$SER"; then
  echo "DESK attached (paint may have hung)" >&2
  grep -E 'DESK |WM REFUSE|WM ATTACH' "$SER" | tail -20 >&2
  fail "DESK did not reach READY"
elif grep -q 'DESK SHM FAIL' "$SER"; then
  fail "DESK shmcreate failed"
elif grep -q 'DESK ATT FAIL' "$SER"; then
  fail "DESK attach failed"
else
  fail "DESK never started"
fi

ck; grep -q 'DESK STRIP' "$SER" || fail "no DESK STRIP"
ck; grep -q 'DESK DOCK' "$SER" || fail "no DESK DOCK"
ck; grep -q 'DESK FROST' "$SER" || fail "no DESK FROST line"
ck; grep -q 'DESK FROST .* VARY' "$SER" || fail "island frost is still one flat colour"
ck; grep -q 'DESK ISLE' "$SER" || fail "desk did not report island pixels"
ck; grep -q 'WM GFX ON' "$SER" || fail "no WM GFX ON"
ck; grep -q 'DESK READY' "$SER" || fail "no DESK READY"
ck; ! grep -q 'FILES READY' "$SER" \
  || fail "FILES was on the desk at boot — dock is empty until a click"

# ---------------------------------------------------------------------------
# RESOLUTION AWARENESS (GAP-0329). `fb` above is 800x600, so what DESK must
# have worked out is 0x320 x 0x258 and a strip at y = 600 - 48 = 0x228, flush
# left and the full width. The point is not the numbers: it is that they came
# out of WM_OP_SCREEN and not out of desk.c, which is why the ghost bar was
# floating in the middle of a 1280x720 desktop.
# ---------------------------------------------------------------------------
ck; grep -q 'DESK SCREEN 0320 H 0258' "$SER" \
  || { grep -E 'DESK SCREEN' "$SER" >&2; fail "DESK did not read 800x600"; }
ck; grep -q 'DESK ATT OK X 0000 Y 0228 W 0320 H 0030' "$SER" \
  || { grep -E 'DESK ATT' "$SER" >&2; fail "strip is not a full-width bottom bar"; }

# ---------------------------------------------------------------------------
# ONE TASKBAR. `OSGFX SESSION STRIP CLIENT` is the compositor saying it has
# WITHDRAWN its own strip because a client committed pixels over the whole
# strip rect. Without it the session paints a second bar under DESK's, which
# is exactly the defect in tigervnc-live-now.png.
# ---------------------------------------------------------------------------
ck; grep -q 'OSGFX SESSION STRIP CLIENT' "$SER" \
  || { grep -E 'DESK |OSGFX ' "$SER" | tail -30 >&2; \
       fail "session still owns the strip — two taskbars"; }
ck; ! grep -q 'FAULT RECOVERED' "$SER" \
  || fail "first compose still recovered a #GP — recovered is not the product"
ck; grep -q 'OSGFX CLIENT SHAPE SKIA' "$SER" \
  || fail "no client shape reached the Skia rrect path"

# ---------------------------------------------------------------------------
# osxui_button_fb, RETESTED RATHER THAN ASSUMED (ADR-0192 §5). desk.c's header
# recorded it as hanging in-ELF. Both tokens must appear -- ENTER without
# RETURN is the hang -- and the pixel read-back says whether it painted.
# ---------------------------------------------------------------------------
ck; grep -q 'DESK BTNFB ENTER' "$SER" || fail "osxui_button_fb never called"
ck; grep -q 'DESK BTNFB RETURN' "$SER" \
  || fail "osxui_button_fb HUNG — entered and did not return"
ck; grep -q 'DESK BTNFB PIXELS' "$SER" \
  || { grep -E 'DESK BTNFB' "$SER" >&2; \
       fail "osxui_button_fb returned but painted nothing"; }

# Boot desk: frosted left island, wallpaper in the gap, no FILES card.
# Prefer the first dump at DESK READY (fb2 is a later wm draw and can race
# a chrome present that has not yet re-blitted the panel).
ck; [[ -s "$FB" ]] || fail "no fb dump"
GLASS_FB="$FB"
ck; python3 - "$GLASS_FB" <<'PY' || fail "boot desk is not glass islands on wallpaper"
import sys
data = open(sys.argv[1], "rb").read()
pitch = 3200
def px(x, y):
    off = y * pitch + x * 4
    return int.from_bytes(data[off:off+4], "little") & 0xFFFFFF
# Left island: frosted (wallpaper bleed + tint) and NOT one flat colour.
samples = [px(80, 568), px(100, 580), px(180, 576), px(200, 568)]
for ink in samples:
    r, g, b = (ink >> 16) & 255, (ink >> 8) & 255, ink & 255
    if ink == 0xC87840:
        raise SystemExit("left island is still copper Start")
    if r + g + b < 200:
        raise SystemExit("left island %06X is not frosted glass" % ink)
if len(set(samples)) < 2:
    raise SystemExit("island pixels are one flat colour — no backdrop blur %s"
                     % ["%06X" % s for s in samples])
ink = samples[0]
# Gap between islands — wallpaper, not a full-width strip.
gap = px(400, 572)
if gap in samples:
    raise SystemExit("gap matches island — dock is still a bar")
# FILES window slot is empty (wallpaper / desk, not pearl CSD).
win = px(54, 46)
wr, wg, wb = (win >> 16) & 255, (win >> 8) & 255, win & 255
if wr >= 180 and wg >= 170 and wb >= 150 and win != gap:
    if wr > 200 and wg > 190:
        raise SystemExit("FILES CSD already on boot at (54,46)=%06X" % win)
print("boot desk: frost %s gap %06X empty-win %06X" % (
    "/".join("%06X" % s for s in samples), gap, win))
PY

echo "RUNTIME: pass  DESK READY; frosted glass dock; empty desk"

# Absolute tablet. Relative PS/2 loses the burst while a menu paints.
# Skia pointer is noted on the first tablet packet, not at DESK READY.
ck; grep -q 'VTAB OK' "$SER" || fail "vtab did not arm the tablet"
ck; python3 - "$PORT" "$SER" <<'PY' || fail "contextual / Start click stage failed"
import json, socket, sys, time

port = int(sys.argv[1])
ser = sys.argv[2]
cx = cy = 0

def read():
    return open(ser, "r", encoding="latin-1", errors="replace").read()

class Q:
    def __init__(self):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.s.settimeout(8)
        self.f = self.s.makefile("rw", encoding="utf-8")
        json.loads(self.f.readline())
        self.cmd("qmp_capabilities")

    def cmd(self, name, **kw):
        msg = {"execute": name}
        if kw:
            msg["arguments"] = kw
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            m = json.loads(line)
            if "event" in m:
                continue
            if "error" in m:
                raise SystemExit("QMP %s" % m["error"])
            return

q = Q()
GW, GH = 800, 600

def wait_new(tok, marked, timeout=12):
    deadline = time.time() + timeout
    while time.time() < deadline:
        now = read()
        if tok in now[len(marked):]:
            return True
        time.sleep(0.05)
    return False

def abs_xy(x, y):
    return x * 32767 // max(1, GW - 1), y * 32767 // max(1, GH - 1)

def place(x, y):
    ax, ay = abs_xy(x, y)
    for _ in range(8):
        n = read().count("MOUSE ABS")
        q.cmd("input-send-event", events=[
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}}])
        t = time.time() + 1.2
        while time.time() < t:
            if read().count("MOUSE ABS") > n:
                return
            time.sleep(0.04)

def button(x, y, btn, down):
    ax, ay = abs_xy(x, y)
    q.cmd("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
        {"type": "btn", "data": {"button": btn, "down": down}}])

def press(x, y, btn, token):
    marked = read()
    place(x, y)
    time.sleep(0.12)
    button(x, y, btn, True)
    if not wait_new(token, marked):
        tail = [ln for ln in read().splitlines()
                if "MOUSE" in ln or "WM CTX" in ln or "WM WALL" in ln
                or "WM DE" in ln or "FILES" in ln]
        raise SystemExit("no %s after click @ (%d,%d) last=%s"
                         % (token, x, y, tail[-8:]))
    time.sleep(0.08)
    button(x, y, btn, False)
    time.sleep(0.35)

# Wake the tablet before the first classified click.
place(8, 8)
time.sleep(0.2)

# Empty desk first — no FILES/SET card to steal a wallpaper right-click.
press(400, 300, "right", "WM WALL MENU")
place(16, 20)
time.sleep(0.1)
button(16, 20, "left", True)
time.sleep(0.08)
button(16, 20, "left", False)
time.sleep(0.5)

# Dock Files icon (right island, second icon) launches FILES.ELF.
files_ok = False
for _ in range(8):
    marked = read()
    place(592, 572)
    time.sleep(0.12)
    button(592, 572, "left", True)
    if wait_new("DESK LAUNCH FILES.ELF", marked, timeout=1.5) or wait_new(
            "FILES READY", marked, timeout=1.5):
        files_ok = True
        button(592, 572, "left", False)
        break
    button(592, 572, "left", False)
    time.sleep(0.25)
if not files_ok:
    tail = [ln for ln in read().splitlines()
            if "DESK" in ln or "FILES" in ln or "MOUSE" in ln]
    raise SystemExit("dock Files icon did not launch FILES last=%s" % tail[-8:])
deadline = time.time() + 12
while time.time() < deadline:
    if "FILES READY" in read() or "FILES CSD" in read():
        break
    time.sleep(0.1)
else:
    raise SystemExit("FILES did not become READY after dock click")
time.sleep(0.4)

press(350, 55, "right", "WM CTX TITLE")
place(16, 20)
time.sleep(0.1)
button(16, 20, "left", True)
time.sleep(0.08)
button(16, 20, "left", False)
time.sleep(0.8)
got_file = False
for _ in range(6):
    marked = read()
    place(300, 180)
    time.sleep(0.12)
    button(300, 180, "right", True)
    if wait_new("WM CTX FILE", marked, timeout=1.5):
        got_file = True
        button(300, 180, "right", False)
        break
    button(300, 180, "right", False)
    time.sleep(0.25)
if not got_file:
    tail = [ln for ln in read().splitlines()
            if "MOUSE" in ln or "WM CTX" in ln or "FILES" in ln]
    raise SystemExit("no WM CTX FILE after click @ (300,180) last=%s" % tail[-8:])
time.sleep(0.35)
if "FILES MENU" not in read():
    raise SystemExit("file-row right-click did not open FILES menu")
if read().count("WM WALL MENU") != 1:
    raise SystemExit("a non-desk right-click opened set-background")
press(316, 192, "left", "FILES OPEN")
press(300, 180, "right", "WM CTX FILE")
if "FILES MENU" not in read():
    raise SystemExit("second file-row right-click did not open FILES menu")
press(316, 216, "left", "FILES RENAME")
# Rename's files_repaint is a full CSD + row-outline batch. Start
# clicks during that paint are dropped (IF off / wmMetaBusy).
time.sleep(1.2)
started = False
for _ in range(8):
    marked = read()
    place(262, 572)
    time.sleep(0.12)
    button(262, 572, "left", True)
    if wait_new("WM DE START", marked, timeout=1.5):
        started = True
        break
    button(262, 572, "left", False)
    time.sleep(0.25)
if not started:
    raise SystemExit("no WM DE START after Start click")
button(262, 572, "left", False)
time.sleep(0.35)
# Each transition includes absolute coordinates. Button-only virtio-tablet
# reports are not guaranteed to produce a packet; wmPointerPending preserves
# a complete report that arrives during a compositor pass.
spawned = False
for _ in range(8):
    marked = read()
    place(40, 500)
    time.sleep(0.08)
    button(40, 500, "left", True)
    if wait_new("WM DE SPAWN", marked, timeout=1.2):
        spawned = True
        break
    button(40, 500, "left", False)
    time.sleep(0.2)
if not spawned:
    raise SystemExit("no WM DE SPAWN after launch-row click")
if "SET CSD" not in read():
    marked = read()
    if not wait_new("SET CSD", marked, timeout=12):
        raise SystemExit("Start row 1 did not paint SET CSD")
time.sleep(0.08)
button(40, 500, "left", False)
time.sleep(0.35)
print("contextual + Start spawn tokens ok")
PY

ck; grep -qE 'WM PTR SKIA|OSGFX POINTER SKIA' "$SER" \
  || { grep -E 'WM PTR|OSGFX POINTER|POINTER' "$SER" | tail -20 >&2; \
       fail "pointer sprite was not Skia"; }
ck; grep -q 'WM WALL MENU' "$SER" \
  || fail "empty desk right-click did not open wallpaper menu"
ck; grep -q 'WM CTX TITLE' "$SER" \
  || fail "title right-click did not classify as TITLE"
ck; grep -q 'WM CTX FILE' "$SER" \
  || { grep -E 'WM CTX|MOUSE PKT' "$SER" | tail -20 >&2; \
       fail "file-row right-click did not classify as FILE"; }
ck; grep -q 'DESK LAUNCH FILES.ELF' "$SER" \
  || fail "dock did not print DESK LAUNCH FILES.ELF"
ck; grep -q 'FILES CSD' "$SER" \
  || fail "FILES did not paint CSD title chrome"
ck; grep -q 'OSGFX CLIENT TEXT OUTLINE' "$SER" \
  || fail "no client outline run reached osgfx_text"
ck; grep -q 'FILES STRIP' "$SER" || fail "FILES never committed a surface"
ROW_LINE=$(grep -o 'FILES ROW OUTLINE ADV [0-9]* CELL [0-9]*' "$SER" | tail -1)
ck; [[ -n "$ROW_LINE" ]] || fail "FILES printed no row caption measurement"
ROW_ADV=$(printf '%s' "$ROW_LINE" | awk '{print $5}')
ROW_CELL=$(printf '%s' "$ROW_LINE" | awk '{print $7}')
ck; [[ "$ROW_ADV" -gt 0 ]] || fail "FILES row caption laid nothing down: $ROW_LINE"
ck; [[ "$ROW_ADV" -ne "$ROW_CELL" ]] \
  || fail "FILES row caption advance is exactly the 8x16 cell: $ROW_LINE"
echo "FILES rows: $ROW_LINE"
ck; grep -q 'FILES MENU' "$SER" \
  || fail "file-row right-click did not show FILES Open/Rename"
ck; grep -q 'FILES OPEN' "$SER" \
  || fail "FILES Open menu item did not run"
ck; grep -q 'FILES RENAME' "$SER" \
  || fail "FILES Rename menu item did not run"
ck; grep -q 'SET CSD' "$SER" \
  || fail "SET (second FRAME app) did not paint CSD title chrome"
ck; [[ "$(grep -c 'WM WALL MENU' "$SER")" -eq 1 ]] \
  || fail "a non-desk right-click opened set-background"
ck; grep -q 'WM DE START' "$SER" \
  || fail "Start click did not open launch list"
ck; grep -q 'WM DE SPAWN' "$SER" \
  || fail "Start row did not spawn by name"
ck; grep -q 'WM OVERLAY CLEAR' "$SER" \
  || fail "overlay hide did not restore the menu surface"
ck; ! grep -q 'OSGFX OOM' "$SER" \
  || fail "Skia bump exhausted after FILES rename"

echo
# The floor, which this harness printed a count against but never GATED on
# (_lib/harness.sh: that is the GAP-0168 family verbatim).
require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-DESK: PASS ($ASSERTIONS_REQUIRED checks) — glass dock, empty boot, FILES from hit"
exit 0
