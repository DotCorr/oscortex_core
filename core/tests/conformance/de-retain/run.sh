#!/usr/bin/env bash
# core/tests/conformance/de-retain/run.sh
#
# ADR-0190 / GAP-0333: A WINDOW'S BODY SURVIVES TIME.
#
# THE DEFECT THIS EXISTS FOR, and it shipped past a green suite:
#
#   `isr_common` calls `osgfx_guest_tick` on the instruction after
#   `isrDispatch`, on every interrupt. That tick returns immediately while
#   `m->gen == last_gen`, so what decides whether the session paints is who
#   last moved `gen` — and the only thing that moves it is `wmGfxKick`. When
#   the tick originally painted the WHOLE scanout, and nothing in that path
#   read a client's shared memory. The chrome cache now has the stronger hot
#   path: its scanout blit cuts rectangular holes for both live client bodies.
#   `wmSessionRestore` remains the uncached fallback.
#
#   So a kick that was not part of a compose — and `wmPointerTick` made one on
#   EVERY pointer packet — handed the screen to Skia and left every mapped
#   client's body painted over with wallpaper. It did not come back, because
#   the compositor does not poll clients and a client that has committed once
#   has nothing more to say. On the live door at 1280x720 one pointer walk
#   emptied both windows and they stayed empty.
#
# WHY THE EXISTING SUITE COULD NOT SEE IT. Every compositor harness in this
# repo probes the FIRST frame, and the two that run for any length of time
# (de-pace, de-session) drive a client that COMMITS IN A LOOP — so its window
# is re-blitted hundreds of times a second and its body cannot be observed to
# rot. This harness is the other shape on purpose: two clients that commit
# ONCE and then only yield, which is what every real application does between
# one redraw and the next.
#
# WHAT IS ASSERTED, and it is deliberately the strictest form available: the
# two clients' interior blocks are read out of guest physical memory with
# `pmemsave` at T0 and after every stage, and compared BYTE FOR BYTE. Not
# "still roughly there". Identical, after two minutes of elapsed time, forty
# pointer packets, forty cached chrome blits and an armed frame clock.
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

fail() { echo "DE-retain: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-retain: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=38

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-retain.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    [[ -f "$WORKDIR/serial.txt" ]] &&
      cp "$WORKDIR/serial.txt" "$CORE_DIR/build/de-retain-last-serial.txt" || true
    [[ -f "$WORKDIR/report.json" ]] &&
      cp "$WORKDIR/report.json" "$CORE_DIR/build/de-retain-last-report.json" || true
  fi
  [[ -n "${QEMU_PID:-}" ]] && kill "$QEMU_PID" >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
SIT="$CORE_DIR/tests/conformance/d3-session"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
WM_DART="$CORE_DIR/kernel/wm.dart"
PACE_DART="$CORE_DIR/kernel/wmpace.dart"
GFX_DART="$CORE_DIR/kernel/wmgfx.dart"
ISR_S="$CORE_DIR/boot/isr.S"
CHROME_C="$CORE_DIR/plat/osgfx/osgfx_chrome.c"

echo "=== STRUCTURAL ==="
# 1a. THE RESTORE IS ON THE TRAMPOLINE, ON THE INSTRUCTION AFTER THE TICK.
# One frame later is not good enough and neither is "some later compose": the
# two halves are one present, and between them the screen is wrong.
ck; grep -q 'call osgfx_guest_tick' "$ISR_S" \
  || fail "isr.S no longer calls the session tick — this harness is about what follows it"
ck; grep -q 'call wmSessionRestore' "$ISR_S" \
  || fail "isr.S does not call wmSessionRestore — a session present is not followed by the client re-blit"
capture_sh ORDER_OUT ORDER_STATUS -- "python3 - '$ISR_S' <<'PY'
import sys
src = open(sys.argv[1]).read()
i = src.index('call osgfx_guest_tick')
j = src.index('call wmSessionRestore')
if j < i:
    raise SystemExit('wmSessionRestore is called BEFORE osgfx_guest_tick — it '
                     'would put back pixels the tick is about to paint over')
between = src[i:j].split('call osgfx_guest_tick', 1)[1]
other = [ln.strip() for ln in between.splitlines()
         if ln.strip().startswith('call ')]
if other:
    raise SystemExit('something else is called between the session tick and '
                     'the restore: %r' % other)
print('    isr_common: osgfx_guest_tick then wmSessionRestore, nothing between')
PY"
ck; [[ $ORDER_STATUS -eq 0 ]] || { echo "$ORDER_OUT" >&2; fail "the restore is not on the instruction after the tick"; }
echo "$ORDER_OUT"

# 1b. THE RESTORE IS THE CLIENT BLIT, AND IT IS DART ONLY. Skia must not run
# in an interrupt (ADR-0172), so a restore that reached the session tick would
# be a corrupted allocator rather than a repaired window.
ck; grep -q 'void wmSessionRestore()' "$PACE_DART" \
  || fail "wmpace.dart has no wmSessionRestore"
capture_sh REST_OUT REST_STATUS -- "python3 - '$PACE_DART' <<'PY'
import sys
src = open(sys.argv[1]).read()
body = src[src.index('void wmSessionRestore()'):]
body = body[:body.index('\n}\n')]
for bad in ('osgfx_guest_tick', 'osgfx_', 'wmCompose('):
    if bad in body:
        raise SystemExit('wmSessionRestore reaches %r — Skia must not run in '
                         'an interrupt (ADR-0172)' % bad)
if 'wmDrawWindow' not in body:
    raise SystemExit('wmSessionRestore does not blit any client')
if 'wmMetaBusy' not in body:
    raise SystemExit('wmSessionRestore has no re-entrancy guard; two painters '
                     'in one framebuffer is a torn frame')
if 'wmGfxChromeStamp' in body:
    raise SystemExit('wmSessionRestore stamps the chrome signature — ADR-0188 '
                     'makes wmCompose the one place entitled to claim the '
                     'chrome on the screen is current')
if 'wmReap' not in body:
    raise SystemExit('wmSessionRestore reads frame vectors without reaping '
                     'dead regions first')
print('    wmSessionRestore: Dart-only client blit, busy-guarded, reaps first')
PY"
ck; [[ $REST_STATUS -eq 0 ]] || { echo "$REST_OUT" >&2; fail "wmSessionRestore is not what ADR-0190 says it is"; }
echo "$REST_OUT"

# 1c. THE DEBT IS RECORDED WHERE THE GENERATION IS MOVED, because that is the
# only thing that makes the tick paint. And it is cleared by wmCompose, which
# does the same blit itself in the same frame.
ck; grep -q 'wmSessionOwe();' "$GFX_DART" \
  || fail "wmGfxKick does not record that a session present is coming"
ck; grep -q 'wmSessionOwedClear();' "$WM_DART" \
  || fail "wmCompose does not settle the debt its own blit already paid"

# 1d. THE POINTER NEVER KICKS. Sprite restore+place plus dirty old+new
# cursor bounds. A kick from IRQ12 was a full session tick on every
# packet — the R18 2.3 fps cost-bound. Chrome-stale geom still composes
# in task context (drag/max), not from the pointer IRQ.
capture_sh PTR_OUT PTR_STATUS -- "python3 - '$WM_DART' <<'PY'
import sys
src = open(sys.argv[1]).read()
body = src[src.index('void wmPointerTick()'):]
body = body[:body.index('\n}\n')]
if 'wmGfxKick();' in body:
    raise SystemExit('wmPointerTick still kicks — every packet is a '
                     'session tick (Round 19 dirty-region gate)')
if 'wmDamageRect(ox, oy' not in body:
    raise SystemExit('wmPointerTick does not dirty old cursor bounds')
if 'wmLatNotePresent' not in body:
    raise SystemExit('wmPointerTick does not same-tick note LAT')
print('    wmPointerTick is sprite-only: no kick, old+new cursor damage')
PY"
ck; [[ $PTR_STATUS -eq 0 ]] || { echo "$PTR_OUT" >&2; fail "the pointer still kicks the session for a move that changes nothing"; }
echo "$PTR_OUT"
ck; grep -q 'osgfx_pointer_raster' "$CORE_DIR/plat/osgfx/osgfx.h" \
  || fail "pointer sprite is not a Skia ABI"
ck; grep -q 'wmPtrW' "$PACE_DART" \
  || fail "save-under is not sized to the Skia sprite"

# 1e. NO NEW `@bss`. Eleven harnesses assert the kernel's mutable static total
# to the byte; ADR-0188 put the pacer's state in a page from the frame
# allocator and this ADR's four words go in the same page.
ck; ! grep -qE '^@bss' "$PACE_DART" \
  || fail "wmpace.dart declares @bss — eleven harnesses assert the .bss total"
ck; grep -q 'const int wmPageWSessionOwed' "$PACE_DART" \
  || fail "the session debt is not a state-page word"

# 1f. THE CACHED PATH DOES NOT CREATE DEBT IN THE FIRST PLACE. It copies the
# chrome frame around DISJOINT live client-body spans (and the dock/pop
# holes). Unioning win0+win1 into one cut punched the wallpaper between
# FILES and SET and left stale FILES pixels in SET's hole.
capture_sh HOLE_OUT HOLE_STATUS -- "python3 - '$CHROME_C' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'static void chrome_blit\(.*?\) \{(.*?)^\}', src, re.M | re.S)
if not m:
    raise SystemExit('chrome_blit is gone')
body = m.group(1)
for geom in ('win0', 'win1'):
    if 'chrome_body_span(%s' % geom not in body:
        raise SystemExit('chrome_blit does not cut a body hole for %s' % geom)
if 'chrome_copy_span' not in body:
    raise SystemExit('chrome_blit no longer copies row spans around its holes')
if 'chrome_span_hit' not in body:
    raise SystemExit('chrome_blit no longer keeps disjoint body holes')
if 'OSGFX_GUEST_PANEL' not in body:
    raise SystemExit('chrome_blit dropped the dock-strip hole')
print('    chrome_blit copies around disjoint client-body, dock, and pop holes')
PY"
ck; [[ $HOLE_STATUS -eq 0 ]] || { echo "$HOLE_OUT" >&2; fail "cached chrome presents can overwrite a client body"; }
echo "$HOLE_OUT"
echo "STRUCTURAL: pass  restore fallback on trampoline, cached blit preserves both body holes"

echo
echo "=== BUILD (isolated BUILD_DIR) ==="
LIVE_KERNEL="$CORE_DIR/build/kernel.elf"
LIVE_UEFI="$CORE_DIR/build/kernel-uefi.elf"
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
echo "$BUILD_OUT" | tail -3
ck; [[ $BUILD_STATUS -eq 0 ]] || { echo "$BUILD_OUT" >&2; fail "build-kernel.sh exited $BUILD_STATUS"; }
KERNEL_ELF="$BUILD_DIR/kernel.elf"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no isolated kernel.elf after a successful build"
if [[ -n "$LIVE_SHA" ]]; then
  ck; [[ "$(sha256sum "$LIVE_KERNEL" | awk '{print $1}')" == "$LIVE_SHA" ]] \
    || fail "live kernel.elf changed across isolated de-retain"
fi
if [[ -n "$LIVE_UEFI_SHA" ]]; then
  ck; [[ "$(sha256sum "$LIVE_UEFI" | awk '{print $1}')" == "$LIVE_UEFI_SHA" ]] \
    || fail "live kernel-uefi.elf changed across isolated de-retain"
fi
ck; grep -q 'wmSessionRestore' "$BUILD_DIR/kernel.map" \
  || fail "kernel.map has no wmSessionRestore — the trampoline would call a symbol that is not there"
# The counters below are read out of guest physical memory rather than off the
# serial line, because two resident clients ping-pong through procTick and the
# shell never runs again — so no command can ask for the report after the
# second spawn. `osgfx_guest_cmd` is where the state page's address lives.
MAILBOX=$(x86_64-elf-nm "$KERNEL_ELF" | awk '$3 == "osgfx_guest_cmd" { print $1 }')
ck; [[ -n "$MAILBOX" ]] \
  || fail "kernel.elf has no osgfx_guest_cmd symbol — the state page has no mailbox to live in"
echo "BUILD: pass  wmSessionRestore linked into kernel.elf, mailbox at 0x$MAILBOX"

echo
echo "=== PROGRAMS ==="
ck; bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" \
  || fail "de-retain clients failed to build"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SIT/make-image.py" "$DISK_IMG" \
  "$WORKDIR/progA.elf" "$WORKDIR/progB.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py failed"
LBA_A=$(python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['A']['header_lba'])" "$LAYOUT_JSON")
LBA_B=$(python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['B']['header_lba'])" "$LAYOUT_JSON")
ck; [[ -n "$LBA_A" && -n "$LBA_B" && "$LBA_A" != "$LBA_B" ]] \
  || fail "could not read two distinct slot LBAs"

echo
echo "=== BOOT ==="
SER="$WORKDIR/serial.txt"
FBDIR="$WORKDIR/fb"
PNG="$CORE_DIR/build/de-retain.png"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
timeout 900 qemu-system-x86_64 \
  -name oscortex-de-retain \
  -kernel "$KERNEL_ELF" \
  -m 128M -cpu qemu64 -vga std \
  -device virtio-tablet-pci \
  -serial "file:$SER" -display none -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
QEMU_PID=$!

run_status DRIVE_STATUS -- python3 "$SCRIPT_DIR/drive.py" \
  "$PORT" "$SER" "$FBDIR" "$PNG" "$LBA_A" "$LBA_B" "$MAILBOX" \
  "$WORKDIR/report.json"
ck; if [[ $DRIVE_STATUS -ne 0 ]]; then
  tail -40 "$SER" >&2
  fail "de-retain driver exited $DRIVE_STATUS"
fi
await QEMU_STATUS "$QEMU_PID"

jget() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$WORKDIR/report.json" "$1"; }

ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON missing"
ck; grep -q 'WM DE ON' "$SER" || fail "WM DE ON missing"
ck; grep -q 'OSGFX DESK GEN' "$SER" || fail "OSGFX DESK GEN missing"
ck; [[ "$(grep -c '^USER WRITE D3S COMMIT$' "$SER")" -eq 2 ]] \
  || fail "expected exactly two client commits, got $(grep -c '^USER WRITE D3S COMMIT$' "$SER")"
# NOTHING DIED. A reaped window has no body to lose and would satisfy the
# comparison below for the least interesting reason.
# Count reaps from the idle serial snapshot (drive.py, before QMP quit).
# `file:` serial is block-buffered: a last-tick WM REAP can appear in $SER
# only after qemu dies, which is not "a client's region died during the run".
REAPS_IDLE=$(jget reaps)
echo "    reaps at idle snapshot: $REAPS_IDLE"
ck; [[ "$REAPS_IDLE" -eq 0 ]] \
  || { grep -m2 '^WM REAP ' "$SER" >&2; fail "a client's region died during the run"; }
# A reap with SHM DROP / PROC END in the snapshot is a real death; the
# post-quit line alone is not.

# ---- THE MEASUREMENT -----------------------------------------------------
TOTAL=$(jget total_secs)
PACED=$(jget paced)
RESTORES=$(jget restores)
RESTORE_PX=$(jget restore_px)
RESTORE_SKIP=$(jget restore_skip)
OWED_END=$(jget owed_at_end)
BLIT0=$(jget desk_blits_t0)
BLIT=$(jget desk_blits)
CHROME0=$(jget chrome_blits_t0)
CHROME=$(jget chrome_blits)
MOUSE=$(jget mouse_packets)
MENUS=$(jget wall_menus)
echo "    ${TOTAL}s of elapsed time, $MOUSE pointer packets, $MENUS popovers"
echo "    session presents after T0: desk BLIT $BLIT0 -> $BLIT"
echo "    cached chrome presents after T0: BLIT $CHROME0 -> $CHROME"
echo "    restores $RESTORES, pixels $RESTORE_PX, deferred $RESTORE_SKIP, owed at end $OWED_END"

# The interval has to be long enough to be the interval from the bug report.
# The door was an empty card inside two minutes, and a harness that checks the
# first frame is exactly why this shipped.
ck; python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 120.0 else 1)" "$TOTAL" \
  || fail "the run covered only ${TOTAL}s — GAP-0333 took about two minutes to show on the door"

# THE CLOCK WAS ARMED FOR ALL OF IT, so this is not a boot with the timer
# masked and nothing running.
ck; [[ "$PACED" -eq 1 ]] \
  || fail "the frame clock was not armed — the interval above was not a paced one"

# ---- THE BODIES ARE STILL THERE, BYTE FOR BYTE --------------------------
# THIS IS THE ASSERTION THE HARNESS EXISTS FOR and it is first on purpose:
# with the fix backed out it is what fires, and its message is the symptom the
# owner reported rather than a statement about a counter.
capture_sh BLOCK_OUT BLOCK_STATUS -- "python3 - '$WORKDIR/report.json' <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
bad = []
for s in r['stages']:
    for who, same, diff, cols in (('A', s['a_same'], s['a_diff_px'], s['a_colours']),
                                  ('B', s['b_same'], s['b_diff_px'], s['b_colours'])):
        if not same:
            bad.append('%s: client %s lost %d interior pixels after %.1fs '
                       '(%s) — now %s'
                       % (s['stage'], who, diff, s['secs_since_t0'], s['note'],
                          cols))
    print('    %-5s +%6.1fs  %-46s A %s  B %s'
          % (s['stage'], s['secs_since_t0'], s['note'],
             'intact' if s['a_same'] else 'LOST', 'intact' if s['b_same'] else 'LOST'))
if bad:
    raise SystemExit('\n'.join(bad))
PY"
ck; [[ $BLOCK_STATUS -eq 0 ]] || { echo "$BLOCK_OUT" >&2; fail "a client body was painted over and never put back — GAP-0333"; }
echo "$BLOCK_OUT"

# AND SOMETHING HAS TO HAVE HAPPENED IN IT. A boot in which the session never
# repainted would keep every client body by doing nothing at all, and would
# pass every comparison above while proving nothing.
ck; [[ "$MOUSE" -gt 20 ]] \
  || fail "only $MOUSE pointer packets reached the compositor"
ck; [[ "$MENUS" -gt 5 ]] \
  || fail "only $MENUS popovers opened — the chrome signature barely moved, so cached body-hole preservation was barely exercised"
# Pop-only presents blit the chrome cache and do not bump DESK BLIT.
# Chrome BLIT movement is the session-present proof.
ck; [[ "$CHROME" -gt "$CHROME0" ]] \
  || fail "the chrome cache never blitted after T0 — its client-body holes were not exercised"
ck; [[ $(( CHROME - CHROME0 )) -ge $(( MENUS * 2 )) ]] \
  || fail "only $(( CHROME - CHROME0 )) cached chrome blits for $MENUS open/close cycles — both sides of each transition were not presented"
# NO DEBT LEFT STANDING. An owed restore at the end of a ninety-second quiet
# window is a screen that is wrong and has no interrupt left to fix it.
ck; [[ "$OWED_END" -eq 0 ]] \
  || fail "a session present was still owed a client re-blit after the whole idle window"

# If the uncached fallback did run, it must have restored real client pixels
# and must not have been starved by the busy guard. Zero restores is expected
# when every measured present used the cached hole-preserving blitter.
ck; python3 - "$RESTORES" "$RESTORE_PX" "$RESTORE_SKIP" <<'PY' \
  || fail "the uncached restore fallback ran without restoring client pixels"
import sys
n, px, skip = map(int, sys.argv[1:])
if n > 0 and (px < 1 or n <= skip):
    raise SystemExit(1)
PY

if [[ -f "$PNG" ]]; then
  echo "    PNG: $PNG"
fi
echo "BOOT: pass  two idle clients kept their bodies through ${TOTAL}s and $((CHROME - CHROME0)) cached chrome presents"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-retain: PASS — ADR-0190 ($ASSERTIONS checks)"
exit 0
