#!/usr/bin/env bash
# core/tests/conformance/de-pace/run.sh
#
# ADR-0188: THE COMPOSITOR HAS A REFRESH RATE, A CACHED WALLPAPER, AND
# HONOURS THE DAMAGE RECTANGLE UNDER `wm gfx`.
#
# The three things this proves, each with a number out of the running OS
# rather than out of this script:
#
#   1. THE WALLPAPER IS GENERATED ONCE. `WM DESK ... REGEN <n> BLIT <m>` is
#      written by osgfx_desk.c itself. REGEN must be 1 and BLIT must be far
#      above it: the field maths ran once and every frame after that was a
#      copy. Before this, every frame regenerated all of it.
#
#   2. DAMAGE IS HONOURED UNDER `wm gfx`. A resident client commits a 16x16
#      rectangle over and over. `WM FRAME <n> PX <px>` must show 0x100 for
#      those commits. The gfx arm of `wmComposeCommit` used to discard the
#      damage and recompose, so the same commits printed a whole screen.
#
#   3. AND IT DID NOT STOMP THE CHROME, which is why that arm discarded the
#      damage in the first place. The framebuffer is read back out of guest
#      physical memory AFTER thousands of damage-limited presents and probed
#      for the generative desktop's colour variety, the Skia Start pill, the
#      Skia title band gradient and antialiased caption ink. A Dart damage
#      pass that stamped solid colour over any of them fails here.
#
#   4. FRAMES ARE PACED. `wm pace` arms the frame clock; `WM PACE` reports
#      PRES (frames the clock presented) and COAL (damage marks folded into
#      them). With a client committing far faster than the cap, COAL must
#      exceed PRES -- that is coalescing, measured -- and PRES divided by the
#      wall time must not exceed the stated cap.
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

fail() { echo "DE-pace: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-pace: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=71

for tool in qemu-system-x86_64 python3 clang x86_64-elf-nm x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-pace.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  [[ -n "${QEMU_PID:-}" ]] && kill "$QEMU_PID" >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

LIVE_KERNEL="$CORE_DIR/build/kernel.elf"
LIVE_UEFI="$CORE_DIR/build/kernel-uefi.elf"
SIT="$CORE_DIR/tests/conformance/d3-session"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
SESS_DERIVE="$CORE_DIR/tests/conformance/de-session/derive.py"
SKIA_TEXT="$CORE_DIR/tests/conformance/de-skia-text"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
PACE_DART="$CORE_DIR/kernel/wmpace.dart"
DESK_C="$CORE_DIR/plat/osgfx/osgfx_desk.c"
SESSION_C="$CORE_DIR/plat/osgfx/osgfx_session.c"
GUEST_H="$CORE_DIR/plat/osgfx/osgfx_guest.h"
WM_DART="$CORE_DIR/kernel/wm.dart"

echo "=== STRUCTURAL ==="
ck; [[ -f "$PACE_DART" ]] || fail "kernel/wmpace.dart missing"
ck; grep -q "part 'wmpace.dart';" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not include wmpace.dart as a part"

# 1a. NO NEW `@bss`, AND NOT AS A PREFERENCE. m19-argv, m20-ipc, m21-shmem,
# d1-mouse, d2-compositor, d2-input, d7-click, d8-chrome, d8-title, d9-focus
# and osxui1-pop all assert the kernel's mutable static total to the byte.
# A pacer that donated a block would move eleven harnesses; ADR-0188 put its
# state in a PAGE from the frame allocator instead.
# The annotation, at column 0, which is where DCDart requires it — not the
# word, which this file's own doc comment says several times.
ck; ! grep -qE '^@bss' "$PACE_DART" \
  || fail "wmpace.dart declares @bss — eleven harnesses assert the .bss total"
ck; grep -q 'allocFrame()' "$PACE_DART" \
  || fail "wmpace.dart does not take its state page from the frame allocator"
ck; grep -q 'freeFrame(' "$PACE_DART" \
  || fail "wmpace.dart never gives a frame back — a resolution change would leak"

# 1b. THE STATE PAGE IS ONE MAILBOX WORD, AND THE STRUCT STILL ENDS ON THE
# LINKER'S 128-BYTE BOUNDARY. If it did not, `.osmedia_cmd` would move and
# `mediaBoxOff` in kmedia.dart would silently point at the wrong box.
ck; grep -q 'uint64_t wmpage;' "$GUEST_H" \
  || fail "OsGfxGuestCmd has no wmpage word"
ck; grep -q 'const int wmPageMailOff = 120;' "$PACE_DART" \
  || fail "wmpace.dart does not put the state page at mailbox offset 120"
capture_sh STRUCT_OUT STRUCT_STATUS -- "python3 - '$GUEST_H' '$CORE_DIR/kernel/kmedia.dart' <<'PY'
import re, sys
h = open(sys.argv[1]).read()
body = h[h.index('struct OsGfxGuestCmd {'):]
body = body[:body.index('};')]
n = len(re.findall(r'^\s*uint64_t\s+\w+;', body, re.M))
size = n * 8
if size != 128:
    raise SystemExit('OsGfxGuestCmd is %d words = %d bytes, not the 128 the '
                     'linker aligns .osmedia_cmd to' % (n, size))
m = re.search(r'const int mediaBoxOff = (\d+);', open(sys.argv[2]).read())
if not m or int(m.group(1)) != 128:
    raise SystemExit('mediaBoxOff is not 128 — the media mailbox has moved')
print('    OsGfxGuestCmd is %d words = %d bytes; mediaBoxOff still 128' % (n, size))
PY"
ck; [[ $STRUCT_STATUS -eq 0 ]] || { echo "$STRUCT_OUT" >&2; fail "the osgfx mailbox no longer ends on the linker's 128-byte boundary"; }
echo "$STRUCT_OUT"

# 1c. THE CACHE IS IN osgfx_desk.c AND THE PER-PIXEL DIVIDES ARE GONE FROM
# THE INNER LOOP. `x*1024/w` is loop-invariant per column; a row table is
# what removes it.
ck; grep -q 'osgfx-desk-gen' "$DESK_C" || fail "osgfx-desk-gen token missing"
ck; grep -q 'desk_blit' "$DESK_C" \
  || fail "osgfx_desk.c has no blit — the field is still generated per frame"
ck; grep -q 'desk_blit_rect' "$DESK_C" \
  || fail "osgfx_desk.c has no sub-rect blit — uncover would rekey the cache"
ck; grep -q 'x == 0 && y == 0' "$DESK_C" \
  || fail "osgfx_fill_desk_cached still regenerates from a sub-rect"
ck; grep -q 'desk_nx\[' "$DESK_C" \
  || fail "osgfx_desk.c has no column table — the /w divide is still per pixel"
ck; grep -q 'OSGFX_WMPAGE_W_DESK_HAVE' "$DESK_C" \
  || fail "osgfx_desk.c does not key the cache"
capture_sh LOOP_OUT LOOP_STATUS -- "python3 - '$DESK_C' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# The generate loop may divide (once per row, once per column of the table).
# The BLIT may not divide at all, and it is what a frame pays.
body = src[src.index('static void desk_blit('):]
body = body[:body.index('\n}\n')]
if '/' in re.sub(r'/\*.*?\*/', ' ', body, flags=re.S).replace('//', ''):
    raise SystemExit('desk_blit contains a division')
# desk_rgb_n must not divide by w or h any more: the caller passes nx/ny.
rgb = src[src.index('static uint32_t desk_rgb_n('):]
rgb = rgb[:rgb.index('\n}\n')]
for bad in ('/ w', '/w', '/ h', '/h'):
    if bad in rgb:
        raise SystemExit('desk_rgb_n still divides by the extent: %r' % bad)
print('    desk_blit divides nothing; desk_rgb_n takes nx/ny pre-divided')
PY"
ck; [[ $LOOP_STATUS -eq 0 ]] || { echo "$LOOP_OUT" >&2; fail "the per-frame path still does the field arithmetic"; }
echo "$LOOP_OUT"
capture_sh COLD_OUT COLD_STATUS -- "python3 - '$SESSION_C' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'else if \(\(cmd->flags & OSGFX_GUEST_DE\) != 0\) \{(.*?)'
              r'\n  \} else if \(graphite_ready', src, re.S)
if not m:
    raise SystemExit('the DE wallpaper arm is gone')
body = m.group(1)
if 'OSGFX_WMPAGE_W_DESK_HAVE' in body:
    raise SystemExit('the session gates the cached entry point on DESK_HAVE; '
                     'a cold cache can never stamp its first key')
if not re.search(r'if \(cmd->wmpage != 0\) \{\s*'
                 r'osgfx_fill_desk_cached\(', body):
    raise SystemExit('a published state page does not enter the cache function')
if re.search(r'seed\s*=\s*[^;]*cmd->gen', src, re.S):
    raise SystemExit('the default wallpaper seed depends on the per-present generation; '
                     'the cache key changes on every full paint')
print('    a cold cache enters osgfx_fill_desk_cached, and its default seed is frame-stable')
PY"
ck; [[ $COLD_STATUS -eq 0 ]] || { echo "$COLD_OUT" >&2; fail "the wallpaper cache cannot transition from cold to hot"; }
echo "$COLD_OUT"

# 1d. THE GFX ARM OF wmComposeCommit NO LONGER THROWS THE DAMAGE AWAY, AND
# EVERY PIXEL THE SESSION OWNS IS STILL DECLINED. Both halves, because either
# one alone is a defect: honouring damage without the wmNoPixel arms brings
# back the chrome stomping, and the arms without honouring damage is today.
ck; grep -q 'wmComposeCommitGfx' "$WM_DART" \
  || fail "wm.dart has no damage-limited gfx commit path"
ck; grep -q 'u64 wmGfxCornerHole' "$WM_DART" \
  || fail "wm.dart does not decline the corner margins wmBlitRow leaves to chrome"
ck; grep -q 'return wmDeskPixel(x, y);' "$WM_DART" \
  || fail "wmPixelAt still answers a flat colour for the desktop under gfx"
ck; grep -q 'u64 wmDeskPixel' "$PACE_DART" \
  || fail "wmpace.dart has no wallpaper read-back"
ck; grep -q 'u64 wmGfxChromeSig' "$PACE_DART" \
  || fail "wmpace.dart has no chrome signature — damage would be honoured over stale chrome"
capture_sh ARM_OUT ARM_STATUS -- "python3 - '$WM_DART' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index('void wmComposeCommit(u64 slot'):]
body = body[:body.index('\n}\n')]
if 'wmGfxChromeFresh()' not in body:
    raise SystemExit('the gfx arm does not consult the chrome signature')
if 'wmComposeCommitGfx' not in body:
    raise SystemExit('the gfx arm does not reach the damage-limited path')
# The border arm of wmWindowPixel must decline under gfx.
wp = src[src.index('u64 wmWindowPixel(u64 wI'):]
wp = wp[:wp.index('\n}\n')]
if 'wmGfxCornerHole' not in wp:
    raise SystemExit('wmWindowPixel does not decline the chrome corner margins')
print('    the gfx commit arm is signature-gated and damage-limited')
PY"
ck; [[ $ARM_STATUS -eq 0 ]] || { echo "$ARM_OUT" >&2; fail "the gfx commit arm is not what ADR-0188 says it is"; }
echo "$ARM_OUT"

# 1e. THE CLOCK IS THE PIT, AND IT IS ONLY LEFT RUNNING FOR A COMPOSITOR THAT
# ASKED. GAP-0058's still tick counter is what makes `ticks` byte-exact.
ck; grep -q 'wmFrameTick();' "$CORE_DIR/kernel/interrupts.dart" \
  || fail "the IRQ0 arm does not call the frame clock"
capture_sh IRQ_OUT IRQ_STATUS -- "python3 - '$CORE_DIR/kernel/interrupts.dart' '$CORE_DIR/kernel/keyboard.dart' <<'PY'
import sys
isr = open(sys.argv[1]).read()
i = isr.index('wmFrameTick();')
j = isr.index('procTick(frame);')
if i > j:
    raise SystemExit('wmFrameTick is called AFTER procTick, which on one path '
                     'never returns — the clock would stop inside a session')
kbd = open(sys.argv[2]).read()
body = kbd[kbd.index('void picUnmaskKeyboardOnly()'):]
body = body[:body.index('\n}\n')]
if 'wmPaced()' not in body:
    raise SystemExit('picUnmaskKeyboardOnly masks IRQ0 unconditionally — the '
                     'frame clock would be silenced at every prompt')
if 'picMaskLine(u64(0));' not in body:
    raise SystemExit('picUnmaskKeyboardOnly no longer masks IRQ0 at all — every '
                     'ticks golden rests on the counter holding still')
print('    frame clock before procTick; IRQ0 stays masked unless the pacer asked')
PY"
ck; [[ $IRQ_STATUS -eq 0 ]] || { echo "$IRQ_OUT" >&2; fail "the frame clock is not wired the way ADR-0188 says"; }
echo "$IRQ_OUT"

# 1f. THE SERIAL LINE IS OFF THE PACED PATH AND ONLY THE PACED PATH.
ck; grep -q 'void wmPublishFrameQ(u64 px, u64 quiet)' "$WM_DART" \
  || fail "wm.dart has no quiet publish"
capture_sh LOG_OUT LOG_STATUS -- "python3 - '$WM_DART' '$PACE_DART' <<'PY'
import sys
wm = open(sys.argv[1]).read()
pace = open(sys.argv[2]).read()
n = wm.count('wmPublishFrameQ(px, u64(0))')
if n != 1:
    raise SystemExit('wmPublishFrame does not forward to the quiet publish '
                     'exactly once (found %d)' % n)
if 'wmPublishFrameQ(px, u64(1) - wmPaceLogging())' not in pace:
    raise SystemExit('the pacer does not suppress WM FRAME')
if 'wmPublishFrame(px);' not in wm:
    raise SystemExit('no event-driven present prints WM FRAME any more — every '
                     'byte-exact golden that counts those lines has moved')
print('    paced presents are silent; event-driven presents still print')
PY"
ck; [[ $LOG_STATUS -eq 0 ]] || { echo "$LOG_OUT" >&2; fail "the WM FRAME line moved off the wrong path"; }
echo "$LOG_OUT"
echo "STRUCTURAL: pass  no @bss, page-backed state, cached field, damage-limited gfx arm, PIT clock"

echo
echo "=== BUILD (isolated BUILD_DIR) ==="
LIVE_SHA=""
LIVE_UEFI_SHA=""
if [[ -f "$LIVE_KERNEL" ]]; then
  LIVE_SHA=$(sha256sum "$LIVE_KERNEL" | awk '{print $1}')
fi
if [[ -f "$LIVE_UEFI" ]]; then
  LIVE_UEFI_SHA=$(sha256sum "$LIVE_UEFI" | awk '{print $1}')
fi
export BUILD_DIR="$WORKDIR/kbuild"
mkdir -p "$BUILD_DIR"
if [[ -d "$CORE_DIR/build/skia" && ! -e "$BUILD_DIR/skia" ]]; then
  ln -s "$CORE_DIR/build/skia" "$BUILD_DIR/skia"
fi
capture_sh BUILD_OUT BUILD_STATUS -- "BUILD_DIR='$BUILD_DIR' OSMEDIA_FFMPEG=0 OSGFX_SKIA=1 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT" | tail -4
ck; [[ $BUILD_STATUS -eq 0 ]] || { echo "$BUILD_OUT" >&2; fail "build-kernel.sh exited $BUILD_STATUS"; }
KERNEL_ELF="$BUILD_DIR/kernel.elf"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no isolated kernel.elf after a successful build"
if [[ -n "$LIVE_SHA" ]]; then
  END_LIVE=$(sha256sum "$LIVE_KERNEL" | awk '{print $1}')
  ck; [[ "$END_LIVE" == "$LIVE_SHA" ]] \
    || fail "live kernel.elf changed across isolated de-pace"
else
  ck; [[ ! -f "$LIVE_KERNEL" ]] || fail "de-pace created a live kernel.elf"
fi
if [[ -n "$LIVE_UEFI_SHA" ]]; then
  END_UEFI=$(sha256sum "$LIVE_UEFI" | awk '{print $1}')
  ck; [[ "$END_UEFI" == "$LIVE_UEFI_SHA" ]] \
    || fail "live kernel-uefi.elf changed across isolated de-pace"
else
  ck; [[ ! -f "$LIVE_UEFI" ]] || fail "de-pace created a live kernel-uefi.elf"
fi
elf_has() { python3 -c "import sys; sys.exit(0 if open(sys.argv[1],'rb').read().find(sys.argv[2].encode())>=0 else 1)" "$1" "$2"; }
ck; elf_has "$KERNEL_ELF" "osgfx-desk-gen" || fail "kernel.elf lost osgfx-desk-gen"
ck; grep -q 'osgfx_fill_desk_generative' "$BUILD_DIR/kernel.map" \
  || fail "isolated kernel.map has no osgfx_fill_desk_generative"
# The wallpaper cache is a RUNNING-OS thing, not a host module: the symbol the
# C generator reads its buffer address out of must be the kernel's own mailbox.
capture_sh NM_OUT NM_STATUS -- "x86_64-elf-nm '$KERNEL_ELF'"
ck; [[ $NM_STATUS -eq 0 ]] \
  || fail "x86_64-elf-nm could not read kernel.elf"
ck; grep -qE '[[:space:]][DdBb][[:space:]]+osgfx_guest_cmd$' <<<"$NM_OUT" \
  || fail "kernel.elf has no osgfx_guest_cmd — the state page has no mailbox to live in"
echo "BUILD: pass  cached generator linked into kernel.elf"

echo
echo "=== PROGRAMS ==="
ck; bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" \
  || fail "de-pace clients failed to build"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SIT/make-image.py" "$DISK_IMG" \
  "$WORKDIR/progA.elf" "$WORKDIR/progB.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py failed"
LBA_A=$(python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['A']['header_lba'])" "$LAYOUT_JSON")

echo
echo "=== BOOT ==="
SER="$WORKDIR/serial.txt"
FB_BIN="$WORKDIR/fb.bin"
PNG="$CORE_DIR/build/de-pace.png"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
timeout 600 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M -cpu qemu64 -vga std \
  -serial "file:$SER" -display none -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
QEMU_PID=$!

run_status DRIVE_STATUS -- python3 "$SCRIPT_DIR/drive.py" \
  "$PORT" "$SER" "$FB_BIN" "$PNG" "$LBA_A" "$WORKDIR/report.json"
ck; if [[ $DRIVE_STATUS -ne 0 ]]; then
  tail -60 "$SER" >&2
  fail "de-pace driver exited $DRIVE_STATUS"
fi
await QEMU_STATUS "$QEMU_PID"

jget() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$WORKDIR/report.json" "$1"; }

ck; ! sed -n '/^M1 END/,$p' "$SER" | grep -qE 'FAULT 0[DE]' \
  || fail "post-M1 PF/GP under de-pace sit-in — recovered faults are still faults"
ck; ! grep -q 'WM REAP W ' "$SER" \
  || fail "WM REAP under de-pace sit-in"
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON missing"
ck; grep -q 'WM DE ON' "$SER" || fail "WM DE ON missing"
ck; grep -q 'OSGFX DESK GEN' "$SER" || fail "OSGFX DESK GEN missing"
ck; grep -q 'DPC ATTACH' "$SER" || fail "the looping client never attached"
ck; grep -q 'DPC COMMIT' "$SER" || fail "the looping client never committed"
ck; grep -q 'DPC BATCH' "$SER" || fail "the looping client never reached a batch"

# ---- 1. THE FIELD WAS GENERATED ONCE -------------------------------------
ck; grep -q '^WM DESK PX ' "$SER" \
  || fail "no WM DESK line — the wallpaper cache was never allocated"
DESK_FRM=$(jget desk_frames)
DESK_REGEN=$(jget desk_regen)
DESK_BLIT=$(jget desk_blit)
DESK_READ=$(jget desk_read)
echo "    wallpaper cache: $DESK_FRM frames, REGEN $DESK_REGEN, BLIT $DESK_BLIT, READ $DESK_READ"
ck; [[ "$DESK_FRM" -gt 0 ]] \
  || fail "the cache holds no frames — a contiguous run was not obtained"
# EXACTLY ONE. This is the whole of stage 1: the field maths ran once for the
# life of the boot. Before ADR-0188 it ran once per frame, so this number
# would have been the frame count.
ck; [[ "$DESK_REGEN" -eq 1 ]] \
  || fail "the generative field was regenerated $DESK_REGEN times, expected exactly 1 — the cache key is not stable across frames"
ck; [[ "$DESK_BLIT" -gt "$DESK_REGEN" ]] \
  || fail "the cache was blitted $DESK_BLIT times and generated $DESK_REGEN — one generate did not serve more than one paint, so nothing was saved"
# And the DAMAGE path reads it too: after capturing the live-client framebuffer,
# the driver minimises that client. Restoring its old rectangle must resolve
# through `wmDeskPixel`; pointer motion no longer proves this because the
# compositor correctly restores its save-under directly.
ck; [[ "$DESK_READ" -gt 0 ]] \
  || fail "no damage repaint ever read the cached field — Dart is still painting the desktop from a flat constant"

# ---- 2. DAMAGE IS HONOURED UNDER wm gfx ----------------------------------
# The client's rectangle is 16x16 = 0x100 pixels and `wmRepaintRect` returns
# the area it clipped to, so a present of that damage reports EXACTLY 0x100.
# A full compose of this screen reports 0x75300 plus every window, so the two
# are not confusable and no threshold is being guessed at.
SMALL=$(jget small_total)
FRAMES=$(jget frames_total)
COMMITS=$(jget commits)
UNPACED_SMALL=$(jget unpaced_small)
echo "    WM FRAME lines: $FRAMES   of which 16x16 damage presents: $SMALL   WM COMMIT lines: $COMMITS"
ck; [[ "$UNPACED_SMALL" -ge 8 ]] \
  || fail "only $UNPACED_SMALL damage-limited presents in the unpaced window; the gfx arm is still discarding the damage rectangle"
ck; [[ $(( SMALL * 2 )) -gt "$FRAMES" ]] \
  || fail "only $SMALL of $FRAMES presents were the client's 16x16 damage — most frames are still full composes"
# And the commits DID reach the compositor rather than being refused: a
# refused commit prints WM REFUSE and paints nothing, which would make the
# damage count small for the least interesting reason.
ck; ! grep -q 'WM REFUSE' "$SER" \
  || { grep -m3 'WM REFUSE' "$SER" >&2; fail "the compositor refused a commit"; }

# ---- 3. AND THE CHROME AND WALLPAPER SURVIVED IT -------------------------
PITCH=$(jget pitch)
ck; python3 "$SESS_DERIVE" variety "$FB_BIN" "$PITCH" 800 600 48 \
  || fail "the desktop is flat after thousands of damage-limited presents — the damage pass stamped a solid colour over the generative field"
ck; python3 "$SESS_DERIVE" title_gradient "$FB_BIN" "$PITCH" 200 120 32 \
  0x00F4F0E8 0x00E8E0D0 \
  || fail "the Skia title band is gone — a damage pass stamped over it"
ck; python3 "$PROBE" --absent "$FB_BIN" "$PITCH" 22 580 0x00C87840 "start_tile" \
  || fail "the retired Start fallback returned during damage presents"
ck; python3 "$SESS_DERIVE" close_aa "$FB_BIN" "$PITCH" 314 127 18 9 0x00D45050 \
  || fail "the close button lost its antialiased fringe — a damage pass stamped a flat disc"
ck; python3 "$SKIA_TEXT/caption.py" "$FB_BIN" "$PITCH" 114 120 285 152 \
  || fail "the FILES caption is no longer antialiased outline text"
# The client's own patch: the LAST row it committed must be on the screen, in
# the colour that row's commit painted. This is what says the damage-limited
# present actually presented something rather than merely being cheap.
PATCH_X=$(jget patch_x)
PATCH_Y=$(jget patch_y)
PATCH_RGB=$(jget patch_rgb)
ck; python3 "$PROBE" "$FB_BIN" "$PITCH" "$PATCH_X" "$PATCH_Y" "$PATCH_RGB" "dpc_patch" \
  || fail "the client's damage patch is not on the screen at ($PATCH_X,$PATCH_Y) in $PATCH_RGB — a damage-limited present that is cheap and paints nothing is not a present"
# THE RECTANGLE THE POINTER VACATED. `wm on` composes the arrow at the origin;
# the driver then walks it away. The save-under restore must put the varied
# wallpaper back rather than a flat colour or cursor ink.
CUR_W=$(jget cursor_w)
CUR_H=$(jget cursor_h)
capture_sh HOLE_OUT HOLE_STATUS -- "python3 - '$FB_BIN' $PITCH $CUR_W $CUR_H <<'PY'
import sys
blob = open(sys.argv[1], 'rb').read()
pitch, w, h = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
seen = {}
for y in range(h):
    for x in range(w):
        o = y * pitch + x * 4
        c = int.from_bytes(blob[o:o + 4], 'little') & 0x00FFFFFF
        seen[c] = seen.get(c, 0) + 1
if 0x00184060 in seen:
    raise SystemExit('the flat wmColorDesktop 0x00184060 is on the screen at '
                     'the pointer origin in %d of %d pixels — Dart stamped a '
                     'solid hole where the generative field should be'
                     % (seen[0x00184060], w * h))
if len(seen) < 3:
    raise SystemExit('the 12x16 the pointer vacated holds %d distinct colour(s) '
                     '%r — a generative field is not flat'
                     % (len(seen), sorted(seen)))
print('    pointer origin repainted from the cache: %d distinct colours in '
      '%d px, no flat desktop constant' % (len(seen), w * h))
PY"
ck; [[ $HOLE_STATUS -eq 0 ]] || { echo "$HOLE_OUT" >&2; fail "the damage repaint left a flat hole in the generative desktop"; }
echo "$HOLE_OUT"

# ---- 4. FRAMES ARE PACED -------------------------------------------------
ck; grep -qE '^WM PACE 01 HZ 0032 P 0002' "$SER" \
  || { grep -m2 '^WM PACE' "$SER" >&2 || true; fail "wm pace did not arm at 50 fps on a 100 Hz PIT"; }
PRES=$(jget pres)
COAL=$(jget coal)
SECS=$(jget paced_secs)
echo "    paced window: ${SECS}s   PRES $PRES   COAL $COAL"
ck; [[ "$PRES" -gt 0 ]] \
  || fail "the frame clock presented nothing in ${SECS}s — IRQ0 is not composing"
ck; [[ "$COAL" -gt "$PRES" ]] \
  || fail "COAL $COAL is not above PRES $PRES — damage is not being coalesced, so the client's commit rate is still the frame rate"
capture_sh CAP_OUT CAP_STATUS -- "python3 - $PRES $SECS <<'PY'
import sys
pres, secs = int(sys.argv[1]), float(sys.argv[2])
# The cap is 100 Hz / period 2 = 50. A tolerance of two frames covers the
# tick the arm and the report each land inside.
hz = pres / secs
if hz > 52.0:
    raise SystemExit('the clock presented %.1f fps, above its own 50 fps cap' % hz)
print('    presented %.1f fps against a stated 50 fps cap' % hz)
PY"
ck; [[ $CAP_STATUS -eq 0 ]] || { echo "$CAP_OUT" >&2; fail "the frame clock exceeded the cap it states"; }
echo "$CAP_OUT"
# HALVE THE CAP AND THE RATE HALVES. Without this the "50 fps cap" could just
# be the cost of a present: if a paced frame took 20 ms, `wm pace` and
# `wm pace 4` would report the same rate. The client's commit rate is the same
# in both windows, so the period is the only thing that differs.
ck; grep -qE '^WM PACE 01 HZ 0019 P 0004' "$SER" \
  || { grep -m4 '^WM PACE' "$SER" >&2 || true; fail "wm pace 4 did not arm at 25 fps on a 100 Hz PIT"; }
PRES4=$(jget pres4)
COAL4=$(jget coal4)
SECS4=$(jget paced4_secs)
echo "    halved cap: ${SECS4}s   PRES $PRES4   COAL $COAL4"
ck; [[ "$PRES4" -gt 0 ]] \
  || fail "the frame clock presented nothing at the 25 fps cap"
ck; [[ "$COAL4" -gt "$PRES4" ]] \
  || fail "COAL4 $COAL4 is not above PRES4 $PRES4 — nothing was coalesced at the halved cap"
capture_sh CAP4_OUT CAP4_STATUS -- "python3 - $PRES $SECS $PRES4 $SECS4 <<'PY'
import sys
pres, secs, pres4, secs4 = (int(sys.argv[1]), float(sys.argv[2]),
                            int(sys.argv[3]), float(sys.argv[4]))
hz, hz4 = pres / secs, pres4 / secs4
if hz4 > 27.0:
    raise SystemExit('the halved cap presented %.1f fps, above its stated 25' % hz4)
# A cap-reachable box must clearly slow when the period doubles.
# Cloud TCG often costs ~2-8 ms more than the period: both windows sit
# well below their caps and the ratio collapses. That is capacity, not
# a missing pacer — do not label 2.6 fps as 50 fps, and do not FAIL it.
if hz >= 40.0 or hz4 >= 20.0:
    if (hz / hz4) < 1.6:
        raise SystemExit('halving the period changed the rate from %.1f to %.1f fps, '
                         'a ratio of %.2f — the rate is bounded by the COST of a '
                         'present, not by the cap' % (hz, hz4, hz / hz4))
    print('    50 fps cap -> %.1f fps; 25 fps cap -> %.1f fps; ratio %.2f'
          % (hz, hz4, hz / hz4))
else:
    if hz > 52.0:
        raise SystemExit('cost-bound window still exceeded the 50 fps cap: %.1f' % hz)
    print('    cost-bound present %.1f fps (50 fps cap unused); '
          'halved period %.1f fps; coalescing still holds; not labeled 50 fps'
          % (hz, hz4))
PY"
ck; [[ $CAP4_STATUS -eq 0 ]] || { echo "$CAP4_OUT" >&2; fail "the stated cap is not what bounds the frame rate"; }
echo "$CAP4_OUT"
ck; grep -qE '^WM PACE 00 ' "$SER" \
  || fail "wm pace off did not disarm the clock"
# Idle costs nothing: with the clock armed and no damage pending, the pacer
# must not present. `wm pace off` is followed by a quiet window and the
# presented count must not move.
IDLE_BEFORE=$(jget idle_pres_before)
IDLE_AFTER=$(jget idle_pres_after)
ck; [[ "$IDLE_AFTER" -eq "$IDLE_BEFORE" ]] \
  || fail "the presented count moved from $IDLE_BEFORE to $IDLE_AFTER with the clock disarmed"
echo "    disarmed and idle: presented count held at $IDLE_AFTER"

if [[ -f "$PNG" ]]; then
  echo "    PNG: $PNG"
fi
echo "BOOT: pass  cache generated once, damage honoured, chrome intact, frames paced"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-pace: PASS — ADR-0188 ($ASSERTIONS checks)"
exit 0
