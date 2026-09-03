#!/usr/bin/env bash
# core/tests/conformance/de-chrome-cache/run.sh
#
# ADR-0191: the DE chrome is rasterised when its inputs change and blitted
# otherwise, and the taskbar gradient -- 88% of a rasterisation -- is cached
# separately so that a rasterisation is cheap too.
#
# THIS HARNESS EXISTS TO CATCH THE FAILURE THE SPEED-UP HIDES. A chrome cache
# that never invalidates is fast, produces a picture that passes every pixel
# probe de-session owns, and is wrong. So the boot below brackets the serve and
# the invalidation separately:
#
#   * twelve `wm draw` full composes must move BLIT by twelve and REGEN by
#     ZERO -- the cache serves, and this is also the CONTROL that makes the
#     next three assertions mean anything;
#   * opening a popover, closing it, and mapping a window must each move
#     REGEN -- the cache invalidates, on three different key words;
#   * `wm fps` must show the cached tick at least 10x the uncached one -- the
#     cache is worth having;
#   * the framebuffer must still carry ADR-0187's gradient, AA fringes and
#     outline caption -- the cache is faithful.
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

fail() { echo "DE-chrome-cache: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-chrome-cache: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=57

for tool in qemu-system-x86_64 python3 clang x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-chrome-cache.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
SIT="$CORE_DIR/tests/conformance/d3-session"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
DERIVE="$CORE_DIR/tests/conformance/de-session/derive.py"
CAPTION="$CORE_DIR/tests/conformance/de-skia-text/caption.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
CHROME_C="$CORE_DIR/plat/osgfx/osgfx_chrome.c"
SESSION_C="$CORE_DIR/plat/osgfx/osgfx_session.c"
SKIA_CPP="$CORE_DIR/plat/osgfx/osgfx_skia.cpp"
PACE_DART="$CORE_DIR/kernel/wmpace.dart"
GUEST_H="$CORE_DIR/plat/osgfx/osgfx_guest.h"
GRAPHITE_LIB="$CORE_DIR/build/skia/out/guest-elf-graphite/libskia.a"

jq_num() { python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d=d[k]
print(d if d is not None else 'null')
" "$1" "$2"; }

echo "=== STRUCTURAL ==="
ck; [[ -f "$CHROME_C" ]] || fail "osgfx_chrome.c missing"
ck; grep -q 'osgfx-chrome-cache' "$CHROME_C" \
  || fail "osgfx-chrome-cache token missing"

# THE KEY COVERS THE PAINT. Derived from both sources, not asserted as a list;
# see keycover.py for why a list would be worthless here.
ck; python3 "$SCRIPT_DIR/keycover.py" "$SESSION_C" "$CHROME_C" \
  || fail "chrome_key does not fold every mailbox word the paint reads"

# THE KEY IS CLEARED BEFORE THE PAINT, NOT AFTER IT. A cache whose key is
# stamped before the pixels are written publishes a torn frame if Skia faults
# half way through a scan conversion — and this buffer is blitted to the
# VISIBLE scanout, so a torn frame is a torn screen. The ordering is derived
# from the source rather than read by eye.
ck; python3 - "$SKIA_CPP" <<'PY' || fail "osgfx_chrome_begin is not called before osgfx_session_paint in tick_body"
import re, sys
src = open(sys.argv[1]).read()
i = src.find("tick_body(void)")
if i < 0:
    raise SystemExit("no tick_body")
body = src[i:]
b = body.find("osgfx_chrome_begin(")
p = body.find("osgfx_session_paint(g, &local")
d = body.find("osgfx_chrome_done(")
if b < 0 or p < 0 or d < 0:
    raise SystemExit("tick_body does not bracket the paint (begin=%d paint=%d done=%d)"
                     % (b, p, d))
if not (b < p < d):
    raise SystemExit("order is begin=%d paint=%d done=%d; must be begin < paint < done" % (b, p, d))
print("order: osgfx_chrome_begin < osgfx_session_paint < osgfx_chrome_done")
PY
ck; grep -q 'pg\[OSGFX_WMPAGE_W_CHROME_HAVE\] = 0;' "$CHROME_C" \
  || fail "osgfx_chrome_begin does not clear the key"

# THE HIT ARM IS A BLIT AND NOTHING ELSE.
ck; grep -q 'osgfx_chrome_fresh(m) != 0' "$SKIA_CPP" \
  || fail "tick_body has no cache-hit arm"
ck; grep -q 'osgfx_chrome_present(m)' "$SKIA_CPP" \
  || fail "tick_body never presents the cached frame"

# THE BAND CACHE IS GATED ON radius == 0, and that is a correctness condition,
# not an optimisation: a cached antialiased corner blended against whatever the
# band buffer held would paste a ring of the wrong colour.
ck; grep -q 'if (radius == 0 && g->px != 0)' "$SKIA_CPP" \
  || fail "the band cache is not gated on radius == 0"

# THE MEMORY IS THE COMPOSITOR'S, out of the frame allocator, and it can be
# given back. ADR-0188 §5's division of labour.
ck; grep -q 'wmChromeBufEnsure' "$PACE_DART" \
  || fail "wmpace.dart does not allocate the chrome run"
ck; grep -q 'wmChromeBufFree' "$PACE_DART" \
  || fail "wmpace.dart has no free path for the chrome run"
ck; grep -q 'allocFrame' "$PACE_DART" \
  || fail "the chrome run does not come from the frame allocator"
ck; grep -q 'wmRunAlloc' "$PACE_DART" \
  || fail "wmpace.dart lost the shared contiguous-run helper"
# NO NEW `@bss`, and this is a hard constraint rather than tidiness: eleven
# harnesses assert the kernel's mutable static total to the byte and several by
# name as "no new @bss" (see wmpace.dart's own header). An annotation is always
# alone on its line, so `^@bss` finds a declaration and not the prose about it.
ck; [[ "$(grep -c '^@bss' "$PACE_DART")" -eq 0 ]] \
  || fail "wmpace.dart declares @bss storage; the cache must live in frames"

# SKIA DOES NOT RUN IN AN INTERRUPT (ADR-0172). Dart never calls the C cache
# filler; it sets and clears state-page words, and the fill happens on the
# session tick in process context. The check is that no .dart file names any
# `osgfx_chrome_*` entry point.
ck; ! grep -rn 'osgfx_chrome_[a-z]*(' "$CORE_DIR/kernel/" >/dev/null 2>&1 \
  || fail "a .dart file calls into osgfx_chrome.c — Skia would run in an IRQ"

# THE WORD TABLE HAS ONE C OWNER PER REGION.
ck; grep -q 'OSGFX_WMPAGE_W_CHROME_BUF' "$GUEST_H" \
  || fail "osgfx_guest.h has no chrome cache words"
ck; grep -q 'OSGFX_WMPAGE_W_BAND_BUF' "$GUEST_H" \
  || fail "osgfx_guest.h has no band cache words"
ck; python3 - "$GUEST_H" "$PACE_DART" <<'PY' || fail "the C word table and the Dart word table disagree"
import re, sys
h, d = open(sys.argv[1]).read(), open(sys.argv[2]).read()
cw = dict((m.group(1), int(m.group(2)))
          for m in re.finditer(r"#define\s+OSGFX_WMPAGE_W_([A-Z0-9_]+)\s+(\d+)", h))
dw = dict((m.group(1), int(m.group(2)))
          for m in re.finditer(r"const\s+int\s+wmPageW([A-Za-z0-9]+)\s*=\s*(\d+)", d))
def snake(camel):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", camel).upper()
dnorm = dict((snake(k), v) for k, v in dw.items())
bad = []
for k, v in cw.items():
    if k in dnorm and dnorm[k] != v:
        bad.append("%s: C=%d Dart=%d" % (k, v, dnorm[k]))
if bad:
    raise SystemExit("; ".join(bad))
shared = sorted(set(cw) & set(dnorm))
if len(shared) < 12:
    raise SystemExit("only %d words matched by name (%s); the parse is wrong"
                     % (len(shared), ", ".join(shared)))
print("word table: %d shared words agree (%s)" % (len(shared), ", ".join(shared)))
PY

# THE PER-TICK SERIAL LINES. `wmpace.dart` owns a log word and `osgfx_chrome.c`
# prints only when it is set, so the default boot pays one compare.
ck; grep -q 'OSGFX_WMPAGE_W_CHROME_LOG' "$CHROME_C" \
  || fail "osgfx_chrome.c prints unconditionally"
ck; python3 - "$SESSION_C" <<'PY' || fail "osgfx_session.c has an ungated per-tick com1_puts"
import re, sys
src = open(sys.argv[1]).read()
# EVERY `com1_puts` IN THE PAINT MUST BE LATCHED. At 0.86-1.35 ms per serial
# line, two per-window lines were 5% of ADR-0191's frame budget on their own --
# and this file is shared, so the assertion is on the PROPERTY rather than on a
# list of allowed strings. The latch idiom here is a file-static `*_noted` flag
# tested for 0 and set to 1, which makes the line once-per-boot; the two lines
# de-session and de-osgfx-panel assert both use it.
#
# Checked by looking at the 240 characters before each call for a `_noted == 0`
# test. Crude, and deliberately so: a latch further away than that is a latch a
# reader cannot see either.
bad = []
found = []
for m in re.finditer(r'com1_puts\("([^"]*)"', src):
    text = m.group(1)
    if src[:m.start()].rstrip().endswith("extern void") or "extern" in src[max(0, m.start()-40):m.start()]:
        continue
    window = src[max(0, m.start() - 240):m.start()]
    if re.search(r"_noted\s*==\s*0", window):
        found.append(text.strip())
    else:
        bad.append(text.strip())
if bad:
    raise SystemExit("unlatched com1_puts (would print per tick): %s"
                     % ", ".join(bad))
if not found:
    raise SystemExit("no com1_puts found at all; the parse is wrong")
print("session paint prints %d latched line(s): %s"
      % (len(found), ", ".join(found)))
PY
echo "STRUCTURAL: pass  key covers the paint, begin<paint<done, frames not bss"

echo
echo "=== BUILD ==="
ck; [[ -f "$GRAPHITE_LIB" ]] || {
  bash "$CORE_DIR/scripts/build-skia-guest-graphite.sh" \
    || fail "build-skia-guest-graphite.sh failed"
}
capture_sh BUILD_OUT BUILD_STATUS -- "OSMEDIA_FFMPEG=0 OSGFX_SKIA=1 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
elf_has() { python3 -c "import sys; sys.exit(0 if open(sys.argv[1],'rb').read().find(sys.argv[2].encode())>=0 else 1)" "$1" "$2"; }
ck; elf_has "$KERNEL_ELF" "osgfx-chrome-cache" \
  || fail "kernel.elf lost osgfx-chrome-cache — the cache is not linked"
ck; grep -q 'osgfx_chrome_target' "$CORE_DIR/build/kernel.map" \
  || fail "kernel.map has no osgfx_chrome_target"
ck; grep -q 'osgfx_chrome_band' "$CORE_DIR/build/kernel.map" \
  || fail "kernel.map has no osgfx_chrome_band"
# ADR-0187/0188 must still be linked: this rung is not allowed to trade their
# proofs for speed.
ck; elf_has "$KERNEL_ELF" "skia-drawpath-outline" \
  || fail "kernel.elf lost skia-drawpath-outline (ADR-0187 regressed)"
ck; elf_has "$KERNEL_ELF" "osgfx-desk-gen" \
  || fail "kernel.elf lost osgfx-desk-gen (ADR-0188 regressed)"
echo "BUILD: pass  chrome cache linked beside ADR-0187 and ADR-0188"

echo
echo "=== PROGRAMS ==="
ck; bash "$SIT/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" \
  || fail "d3-session clients failed to build"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SIT/make-image.py" "$DISK_IMG" \
  "$WORKDIR/progA.elf" "$WORKDIR/progB.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py failed"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_A=$(lba_of A)

echo
echo "=== BOOT ==="
SER="$WORKDIR/serial.txt"
FB_BIN="$WORKDIR/fb.bin"
REPORT="$WORKDIR/report.json"
PNG="$CORE_DIR/build/de-chrome-cache.png"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
timeout 600 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 256M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
QEMU_PID=$!
run_status DRIVE_STATUS -- python3 "$SCRIPT_DIR/drive.py" \
  "$PORT" "$SER" "$FB_BIN" "$PNG" "$LBA_A" "$REPORT"
await QEMU_STATUS "$QEMU_PID"
ck; if [[ $DRIVE_STATUS -ne 0 ]]; then
  tail -60 "$SER" >&2
  fail "driver exited $DRIVE_STATUS"
fi
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON missing"
ck; grep -q 'WM DE ON' "$SER" || fail "WM DE ON missing"
ck; grep -q 'OSGFX DESK GEN' "$SER" \
  || fail "OSGFX DESK GEN missing — generative desk did not run"
ck; grep -q 'OSGFX SESSION CHROME' "$SER" \
  || fail "OSGFX SESSION CHROME missing — the session paint never ran"

# The allocation, once, out of the frame allocator.
ck; grep -qE '^WM CHROME PX [0-9A-F]{8} FRM [0-9A-F]{8} AT [0-9A-F]+' "$SER" \
  || fail "no `WM CHROME PX ... FRM ... AT ...` — the run was never allocated"
ALLOC_PX=$(jq_num "$REPORT" alloc_px)
ALLOC_FRM=$(jq_num "$REPORT" alloc_frames)
ck; [[ "$ALLOC_PX" != "null" && "$ALLOC_PX" -ge 480000 ]] \
  || fail "chrome run is $ALLOC_PX px, too small for an 800x600 screen"
echo "    chrome run: $ALLOC_PX px in $ALLOC_FRM frames"

echo
echo "--- the cache SERVES ---"
R1_REGEN=$(jq_num "$REPORT" r1.regen); R1_BLIT=$(jq_num "$REPORT" r1.blit)
R2_REGEN=$(jq_num "$REPORT" r2.regen); R2_BLIT=$(jq_num "$REPORT" r2.blit)
DRAWS=$(jq_num "$REPORT" draws)
echo "    report 1: REGEN $R1_REGEN BLIT $R1_BLIT"
echo "    report 2: REGEN $R2_REGEN BLIT $R2_BLIT   after $DRAWS x \`wm draw\`"
# ZERO new rasterisations, not "few". Every input to the key is constant across
# a `wm draw`, so one rasterisation here would mean the key folds something
# per-tick and the whole cache would be a slower way of not caching.
ck; [[ "$R2_REGEN" -eq "$R1_REGEN" ]] \
  || fail "$((R2_REGEN - R1_REGEN)) chrome rasterisation(s) across $DRAWS unchanged composes; the key is not stable"
# ...and every one of those composes was actually served, so the zero above is
# not "the tick never ran".
ck; [[ $((R2_BLIT - R1_BLIT)) -ge "$DRAWS" ]] \
  || fail "BLIT moved by $((R2_BLIT - R1_BLIT)) over $DRAWS composes; the ticks did not reach the cache"

echo
echo "--- the cache INVALIDATES ---"
# Three different key words, one at a time, each followed by ONE `wm draw`.
# Report 2 is the control: it proved a `wm draw` on its own rasterises nothing,
# so a REGEN that moves here can only be the state change that preceded it.
#
# THESE ARE THE ASSERTIONS A FROZEN CACHE FAILS, and every pixel probe below
# would pass without them.
R3_REGEN=$(jq_num "$REPORT" r3.regen)
R4_REGEN=$(jq_num "$REPORT" r4.regen)
R5_REGEN=$(jq_num "$REPORT" r5.regen)
R6_REGEN=$(jq_num "$REPORT" r6.regen)
echo "    report 3: REGEN $R3_REGEN   Start pill clicked, launcher open (mailbox \`pop\`)"
echo "    report 4: REGEN $R4_REGEN   desktop clicked, launcher closed (\`pop\` back to 0)"
echo "    report 6: REGEN $R6_REGEN   window A mapped (\`win0\`, \`tone0\`, \`tone1\`)"
ck; grep -q 'WM DE START' "$SER" \
  || fail "the Start pill click never opened the launcher — the popover leg did not run"
ck; [[ "$R3_REGEN" -gt "$R2_REGEN" ]] \
  || fail "a popover opened and the chrome was NOT repainted (REGEN stuck at $R2_REGEN) — the cache is frozen"
# The popover CLOSING matters as much as it opening, and it is the harder half:
# `wmDePopHide` clears `wmMetaPop` through a damage repaint rather than a
# compose, so this only passes if the KEY noticed rather than the paint path.
ck; [[ "$R4_REGEN" -gt "$R3_REGEN" ]] \
  || fail "the popover closed and the chrome was NOT repainted (REGEN stuck at $R3_REGEN) — the key does not see \`pop\` going back to 0"
ck; [[ "$R6_REGEN" -gt "$R5_REGEN" ]] \
  || fail "a window mapped and the chrome was NOT repainted (REGEN stuck at $R5_REGEN) — the key does not see geometry"

echo
echo "--- DESK-owned strip / wallpaper cache serves under chrome ---"
# DE-004 removed the session taskbar. osgfx_chrome_band is unused under
# `wm de` (no paint_de_strip). Replacement evidence: the DESK cache that
# actually fills the bottom strip, plus chrome REGEN/BLIT above.
D1_REGEN=$(jq_num "$REPORT" r1.desk.regen); D1_BLIT=$(jq_num "$REPORT" r1.desk.blit)
D2_REGEN=$(jq_num "$REPORT" r2.desk.regen); D2_BLIT=$(jq_num "$REPORT" r2.desk.blit)
D6_REGEN=$(jq_num "$REPORT" r6.desk.regen); D6_BLIT=$(jq_num "$REPORT" r6.desk.blit)
echo "    desk report 1: REGEN $D1_REGEN BLIT $D1_BLIT"
echo "    desk report 2: REGEN $D2_REGEN BLIT $D2_BLIT   after $DRAWS x \`wm draw\`"
echo "    desk report 6: REGEN $D6_REGEN BLIT $D6_BLIT   after window map"
ck; [[ "$D1_REGEN" -ge 1 ]] || fail "the DESK wallpaper cache was never filled"
ck; [[ "$D2_REGEN" -eq "$D1_REGEN" ]] \
  || fail "DESK REGEN moved $D1_REGEN -> $D2_REGEN across unchanged composes; wallpaper was regenerated"
ck; [[ $((D2_BLIT - D1_BLIT)) -ge 1 ]] || fail "DESK BLIT did not move; the chrome path did not reuse the wallpaper cache"

echo
echo "--- the glyph runs, counted and NOT cached (GAP-0327) ---"
G6_FILL=$(jq_num "$REPORT" r6.glyph_fill)
G6_HIT=$(jq_num "$REPORT" r6.glyph_hit)
echo "    glyph runs: $G6_FILL scan conversions, $G6_HIT served from a cache"
# ADR-0191 §6 does not land a glyph cache and says why: text is 0.25 ms of a
# 4.46 ms rasterisation, measured by stubbing it. That is a claim about a
# RATIO, so the harness asserts the two counts it rests on rather than the
# prose. GLYPH must be non-zero (the runs happen) and HIT must be zero (they
# are all misses, honestly reported). The day a cache lands, HIT moves and
# this assertion is the thing that has to be edited to say so.
ck; [[ "$G6_FILL" -ge "$R6_REGEN" ]] \
  || fail "only $G6_FILL glyph runs across $R6_REGEN rasterisations; the counter is not wired to the text path"
ck; [[ "$G6_HIT" -eq 0 ]] \
  || fail "GLYPH HIT is $G6_HIT — a glyph cache landed but ADR-0191 and GAP-0327 still say none did"

echo
echo "--- the cost, out of \`wm fps\` ---"
ck; python3 - "$REPORT" <<'PY' || fail "the wm fps ladder does not show the cache paying for itself"
import json, sys
d = json.load(open(sys.argv[1]))
f = d["fps"]
need = {"D": "session tick, chrome AND band rasterised (pre-ADR-0191)",
        "B": "session tick, chrome rasterised, band cached",
        "4": "session tick, both cached",
        "C": "full compose, chrome rasterised",
        "5": "full compose, both cached"}
for k, what in need.items():
    if k not in f or f[k]["ms"] is None:
        raise SystemExit("`wm fps` never printed stage K %s (%s)" % (k, what))
raw, band, hit = f["D"]["ms"], f["B"]["ms"], f["4"]["ms"]
craw, chit = f["C"]["ms"], f["5"]["ms"]
print("    K D  %8.3f ms/iter  N %-5d  session tick, nothing cached" % (raw, f["D"]["iters"]))
print("    K B  %8.3f ms/iter  N %-5d  session tick, band cached only" % (band, f["B"]["iters"]))
print("    K 4  %8.3f ms/iter  N %-5d  session tick, chrome cached" % (hit, f["4"]["iters"]))
print("    K C  %8.3f ms/iter  N %-5d  full compose, chrome rasterised" % (craw, f["C"]["iters"]))
print("    K 5  %8.3f ms/iter  N %-5d  full compose, chrome cached" % (chit, f["5"]["iters"]))
bad = []
# 10x, well under the 55x measured, because this is a floor on a machine whose
# speed is not this harness's to assume -- not a restatement of one run.
if hit <= 0 or raw / hit < 10.0:
    bad.append("cached tick is only %.1fx the uncached one (want >= 10x)" % (raw / hit if hit else 0))
if chit <= 0 or craw / chit < 5.0:
    bad.append("cached compose is only %.1fx the rasterising one (want >= 5x)" % (craw / chit if chit else 0))
# DE-004: no session taskbar, so K B (band-only) is not the DESK strip path.
# Chrome frame cache 10x + compose 5x is the live speed claim; desk REGEN/BLIT
# is asserted from the WM DESK report above.
if bad:
    raise SystemExit("; ".join(bad))
print("    tick %.1fx, compose %.1fx (band stage %.3f ms, not asserted)"
      % (raw / hit, craw / chit, band))
PY

echo
echo "--- the picture is still ADR-0187's ---"
PITCH=$(jq_num "$REPORT" pitch)
# Everything below came out of the cache buffer via `osgfx_chrome_present`,
# never straight from Skia: the last thing the boot did before `pmemsave` was
# a `wm pace off`, and the frame under it was a blit.
ck; python3 "$DERIVE" variety "$FB_BIN" "$PITCH" 800 600 48 \
  || fail "desktop is flat — the cached frame lost the generative field"
ck; python3 "$DERIVE" title_gradient "$FB_BIN" "$PITCH" 200 120 32 \
  0x00F4F0E8 0x00E8E0D0 \
  || fail "title band is not a Skia vertical gradient through the cache"
ck; python3 "$PROBE" --absent "$FB_BIN" "$PITCH" 22 580 0x00C87840 "start_tile" \
  || fail "retired Start fallback survived through the chrome cache"
ck; python3 "$DERIVE" close_rrect "$FB_BIN" "$PITCH" 314 127 18 9 0x00D45050 \
  || fail "close button is not an rrect through the cache"
# THE AA FRINGE, THROUGH THE CACHE. A blit is exact, so this is the assertion
# that says so: a cache that quantised, dithered or lost the alpha ramp would
# still be a rounded red button and would fail here.
ck; python3 "$DERIVE" close_aa "$FB_BIN" "$PITCH" 314 127 18 9 0x00D45050 \
  || fail "close button edge lost its soft AA fringe in the cache"
ck; python3 "$CAPTION" "$FB_BIN" "$PITCH" 114 120 285 152 \
  || fail "FILES caption is not antialiased proportional outline text through the cache"
ck; python3 "$PROBE" "$FB_BIN" "$PITCH" 160 160 0x00F0C020 "win_body" \
  || fail "window body is not client shm (ADR-0183)"

# DE-004 removed the session taskbar. Until DESK attaches, the bottom band in
# the cached frame is real wallpaper rather than a legacy gradient/Start UI.
ck; python3 - "$FB_BIN" "$PITCH" <<'PY' || fail "the cached bottom band is not wallpaper"
import sys
fb = open(sys.argv[1], "rb").read()
pitch = int(sys.argv[2])
x = 400
rows = []
for y in range(556, 596, 4):
    off = y * pitch + x * 4
    rows.append(int.from_bytes(fb[off:off + 4], "little") & 0xFFFFFF)
shades = len(set(rows))
if shades < 4:
    raise SystemExit("bottom wallpaper column at x=%d has only %d shades (%s)"
                     % (x, shades, [hex(v) for v in rows]))
print("cached bottom wallpaper: %d shades" % shades)
PY
echo "PICTURE: pass  wallpaper + no Start + close AA + outline caption through the cache"

echo
echo "    PNG: $PNG"
require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-chrome-cache: PASS — chrome cached, invalidated and faithful ($ASSERTIONS checks)"
exit 0
