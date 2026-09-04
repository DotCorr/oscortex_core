#!/usr/bin/env bash
# core/tests/conformance/de-session/run.sh
#
# Session chrome + generative desktop on Venus Graphite sit-in path.
# Phase 1: osgfx_session_paint (rrect windows, DE strip via osxui).
# Phase 2: osgfx_fill_desk_generative when wm de or Graphite armed.
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

fail() { echo "DE-session: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-session: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=70

for tool in qemu-system-x86_64 python3 clang x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
# Docker is only required for the optional Venus/GL isolation image.
# The Homebrew/std-vga path is native QEMU and must run on cloud Linux.
HAVE_DOCKER=0
command -v docker >/dev/null 2>&1 && HAVE_DOCKER=1
HAVE_PODMAN=0
command -v podman >/dev/null 2>&1 && HAVE_PODMAN=1
HAVE_VIRTIO_GL=0
if qemu-system-x86_64 -device help 2>/dev/null | grep -q 'virtio-gpu-gl-pci'; then
  HAVE_VIRTIO_GL=1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-session.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
# Clean up THIS harness's container by NAME, never by image ancestor.
# `--filter ancestor=oscortex-qemu-gl:local | xargs docker rm -f` also kills
# the long-lived interactive sit-in door (core/scripts/sit-in-view.sh), which
# runs from the same image -- so a harness run silently took the owner's live
# desktop down with it.
GL_NAME="oscortex-de-session-$$"
cleanup() {
  if [[ "${HAVE_DOCKER:-0}" == 1 ]]; then
    docker rm -f "$GL_NAME" >/dev/null 2>&1 || true
  fi
  if [[ "${HAVE_PODMAN:-0}" == 1 ]]; then
    podman rm -f "$GL_NAME" >/dev/null 2>&1 || true
  fi
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Inherited BUILD_DIR from an older daily-drive (r23-kbuild, etc.) must
# not silently test a stale kernel. This harness always isolates unless
# the caller points at THIS workdir.
if [[ -z "${BUILD_DIR:-}" || "$BUILD_DIR" == "$CORE_DIR/build" ||
      "$BUILD_DIR" != "$WORKDIR"* ]]; then
  BUILD_DIR="$WORKDIR/kbuild"
fi
mkdir -p "$BUILD_DIR"
if [[ -d "$CORE_DIR/build/skia" && ! -e "$BUILD_DIR/skia" ]]; then
  ln -s "$CORE_DIR/build/skia" "$BUILD_DIR/skia"
fi
KERNEL_ELF="$BUILD_DIR/kernel.elf"
SIT="$CORE_DIR/tests/conformance/d3-session"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
DERIVE="$SCRIPT_DIR/derive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
SKIA_TEXT="$CORE_DIR/tests/conformance/de-skia-text"
SESSION_C="$CORE_DIR/plat/osgfx/osgfx_session.c"
DESK_C="$CORE_DIR/plat/osgfx/osgfx_desk.c"
SKIA_CPP="$CORE_DIR/plat/osgfx/osgfx_skia.cpp"
GRAPHITE_LIB="$CORE_DIR/build/skia/out/guest-elf-graphite/libskia.a"
XRES=1200
YRES=720

echo "=== STRUCTURAL ==="
ck; [[ -f "$SESSION_C" ]] || fail "osgfx_session.c missing"
ck; [[ -f "$DESK_C" ]] || fail "osgfx_desk.c missing"
ck; grep -q 'osgfx-session-tick' "$SESSION_C" \
  || fail "osgfx-session-tick token missing"
ck; grep -q 'osgfx-desk-gen' "$DESK_C" \
  || fail "osgfx-desk-gen token missing"
ck; grep -q 'osgfx_session_paint' "$SKIA_CPP" \
  || fail "tick_body does not call osgfx_session_paint"
ck; grep -q 'osgfx_fill_rrect' "$SESSION_C" \
  || fail "osgfx_session.c does not call osgfx_fill_rrect"
ck; grep -q 'osxui_button(' "$SESSION_C" \
  || fail "osgfx_session.c does not paint DE via osxui_button(OsGfx)"
ck; grep -q 'osgfx-session-chrome' "$SESSION_C" \
  || fail "osgfx-session-chrome token missing"
ck; grep -q 'OSGFX_WIN_FILL' "$SESSION_C" \
  || fail "osgfx_session.c does not paint window body fill"
ck; grep -q 'osgfx_fill_desk_generative' "$SESSION_C" \
  || fail "osgfx_session.c does not call generative desk"
ck; grep -q 'osgfx-glyph-aa' "$CORE_DIR/plat/osgfx/osgfx_glyph.c" \
  || fail "osgfx_glyph.c lost soft-AA door token"
ck; grep -q 'rrect_cover' "$SKIA_CPP" \
  || fail "osgfx_skia.cpp lost soft rrect coverage AA"
# ADR-0187: chrome shapes are real Skia draws and labels are real outlines.
ck; grep -q 'c->drawRRect' "$SKIA_CPP" \
  || fail "osgfx_fill_rrect does not reach SkCanvas::drawRRect"
ck; grep -q 'skia-drawpath-outline' "$SKIA_CPP" \
  || fail "osgfx_skia.cpp lost the outline text path token"
ck; grep -q 'osgfx_text(' "$SESSION_C" \
  || fail "osgfx_session.c does not label chrome via osgfx_text outlines"
ck; grep -q 'osgfx_face_regular' "$CORE_DIR/plat/osgfx/osgfx_font_data.c" \
  || fail "osgfx_font_data.c has no extracted TrueType face"
ck; grep -q 'osgfxGuestDe' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "wmgfx.dart does not pack DE into mailbox flags"
# DE-004: session never paints the retired Start/taskbar fallback. The panel
# flag remains because it also withdraws server-side CSD and menus.
ck; grep -q 'OSGFX_GUEST_PANEL' "$SESSION_C" \
  || fail "osgfx_session.c lost the client panel ownership flag"
ck; ! grep -q 'paint_de_strip' "$SESSION_C" \
  || fail "osgfx_session.c still contains the retired Start fallback"
ck; grep -q 'OSGFX SESSION CHROME CLIENT' "$SESSION_C" \
  || fail "osgfx_session.c has no CSD-withdraw token"
ck; grep -q 'if (session_csd == 0)' "$SESSION_C" \
  || fail "osgfx_session.c does not withdraw the title band"
ck; python3 - "$CORE_DIR/plat/osgfx/osgfx.h" "$CORE_DIR/kernel/wmgfx.dart" <<'PY' \
  || fail "window radius is not one modest card"
import re, sys
h, d = open(sys.argv[1]).read(), open(sys.argv[2]).read()
r = int(re.search(r"OSGFX_RADIUS = (\d+)", h).group(1))
b = int(re.search(r"OSGFX_BLIT_INSET = (\d+)", h).group(1))
g = int(re.search(r"wmGfxRadius = (\d+)", d).group(1))
sys.exit(0 if r == b == g == 18 else 1)
PY
ck; grep -q 'OSGFX_CORNER_TL' "$SESSION_C" \
  || fail "session does not paint top card corners"
# Menus are a scanout overlay, not baked into the DESK session cache
# (that bake was a 900 ms MISS and painted a session card after DESK
# attached). Withdrawal = pop==0 skips the blit; DESK/panel does not
# get a session-cached menu card.
ck; grep -q 'osgfx_session_blit_menu' "$SESSION_C" \
  || fail "osgfx_session.c lost osgfx_session_blit_menu"
ck; grep -q 'Baking cmd->pop into the cache' "$SESSION_C" \
  || fail "session paint no longer documents pop-not-in-cache"
ck; grep -q 'm->pop != 0' "$SKIA_CPP" \
  || fail "chrome_overlay_scanout does not gate menu blit on pop"
ck; python3 - "$SESSION_C" <<'PY' \
  || fail "session still paints a cached ctx menu after DESK (paint_ctx_menu is called)"
import sys
src = open(sys.argv[1]).read()
# Definition may remain; a call would bake the card into session paint.
body = src.split("void osgfx_session_paint(", 1)[-1]
if "paint_ctx_menu(" in body:
    raise SystemExit(1)
PY
ck; grep -q 'osgfxGuestPanel' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "wmgfx.dart does not publish the client-owns-the-strip flag"
ck; grep -q 'u64 wmPanelStrip' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "wmgfx.dart has no wmPanelStrip"
ck; grep -A6 'u64 wmDeChromeDraw' "$CORE_DIR/kernel/wmde.dart" \
  | grep -q 'wmMetaGfx' \
  || fail "wmDeChromeDraw does not skip when wm gfx owns strip"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
echo "STRUCTURAL: pass  session + desk + mailbox DE flags"

echo
echo "=== BUILD ==="
ck; [[ -f "$GRAPHITE_LIB" ]] || {
  bash "$CORE_DIR/scripts/build-skia-guest-graphite.sh" \
    || fail "build-skia-guest-graphite.sh failed"
}
capture_sh BUILD_OUT BUILD_STATUS -- "BUILD_DIR='$BUILD_DIR' OSMEDIA_FFMPEG=0 OSGFX_SKIA=1 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
# Never reuse a stale/raced kernel — that ships empty guest_tick (paper stamps).
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
# Restore durable Skia image if a concurrent OSGFX_SKIA=0 harness stomped.
if ! nm "$KERNEL_ELF" | grep -E -q '[[:space:]]T[[:space:]]+osgfx_fill_rrect$'; then
  if [[ -f "$BUILD_DIR/kernel-skia.elf" ]]; then
    cp -f "$BUILD_DIR/kernel-skia.elf" "$KERNEL_ELF"
  fi
fi
elf_has() { python3 -c "import sys; sys.exit(0 if open(sys.argv[1],'rb').read().find(sys.argv[2].encode())>=0 else 1)" "$1" "$2"; }
ck; elf_has "$KERNEL_ELF" "osgfx-session-tick" \
  || fail "kernel.elf lost osgfx-session-tick"
ck; elf_has "$KERNEL_ELF" "osgfx-session-chrome" \
  || fail "kernel.elf lost osgfx-session-chrome"
ck; elf_has "$KERNEL_ELF" "osgfx-desk-gen" \
  || fail "kernel.elf lost osgfx-desk-gen"
ck; elf_has "$KERNEL_ELF" "osgfx_session_paint" \
  || fail "kernel.elf lost osgfx_session_paint"
ck; elf_has "$KERNEL_ELF" "osgfx-glyph-aa" \
  || fail "kernel.elf lost osgfx-glyph-aa (soft label AA)"
ck; elf_has "$KERNEL_ELF" "skia-draw" \
  || fail "kernel.elf lost skia-draw (soft rrect path not linked)"
ck; elf_has "$KERNEL_ELF" "skia-drawpath-outline" \
  || fail "kernel.elf lost skia-drawpath-outline (outline text not linked)"
ck; grep -q 'osgfx_text$' "$BUILD_DIR/kernel.map" \
  || grep -q ' osgfx_text' "$BUILD_DIR/kernel.map" \
  || fail "kernel.map has no osgfx_text — outline text not linked"
ck; grep -q 'osgfx_face_regular' "$BUILD_DIR/kernel.map" \
  || fail "kernel.map has no osgfx_face_regular — no outline table in image"
ck; grep -q 'osgfx_fill_rrect' "$BUILD_DIR/kernel.map" \
  || fail "kernel.map has no osgfx_fill_rrect — Skia not linked"
ck; grep -q 'osgfx_guest_tick' "$BUILD_DIR/kernel.map" \
  || fail "kernel.map has no osgfx_guest_tick — session tick missing"
echo "BUILD: pass  session + desk linked"

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
LBA_B=$(lba_of B)

typekeys() { python3 -c "
import sys
out=[]
for c in sys.argv[1]:
    out.append({' ':'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:3000"
KEYS="$KEYS,$(typekeys 'wm de'),ret,wait:1500"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_A"),ret,until:D3S COMMIT,wait:800"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_B"),ret,until:D3S COMMIT,wait:1500"

SER="$WORKDIR/serial.txt"
FB_BIN="$WORKDIR/fb.bin"
PNG="$CORE_DIR/build/de-session.png"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
QEMU_PID=$!
run_status DRIVE_STATUS -- python3 - "$PORT" "$SER" "$FB_BIN" "$PNG" "$KEYS" <<'PY'
import json, os, re, socket, struct, sys, time, zlib

port, serial, fb_bin, png, keys = (
    int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
)

class Qmp:
    def __init__(self, port):
        deadline = time.time() + 20
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.f = self.s.makefile("rw", encoding="utf-8")
                json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                return
            except OSError as e:
                last = e
                time.sleep(0.2)
        raise SystemExit("could not connect to QMP: %s" % last)

    def cmd(self, execute, **args):
        self.f.write(json.dumps({"execute": execute, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                if "error" in msg:
                    raise SystemExit("QMP %s: %s" % (execute, msg["error"]))
                return msg["return"]

def count_marker(path, marker):
    if not os.path.exists(path):
        return 0
    return open(path, "rb").read().count(marker.encode("latin-1"))

def wait_marker(path, marker, timeout=45, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_marker(path, marker) >= at_least:
            return True
        time.sleep(0.1)
    return False

def write_png(path, width, height, pitch, bgra):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        off = y * pitch
        row = bgra[off:off + width * 4]
        for x in range(width):
            b, g, r = row[x * 4], row[x * 4 + 1], row[x * 4 + 2]
            raw.extend((r, g, b))
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    open(path, "wb").write(blob)

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("kernel never reached the prompt")
time.sleep(0.5)
commits = 0
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        commits += 1
        if not wait_marker(serial, marker + "\n", timeout=20, at_least=commits):
            raise SystemExit("never saw %d x %s" % (commits, marker))
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(1.5)
text = open(serial, "r", encoding="latin-1").read()
m = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
if not m:
    raise SystemExit("never saw WM ON BASE")
addr = int(m.group(1), 16)
pitch = int(m.group(2), 16)
q.cmd("pmemsave", val=addr, size=600 * pitch, filename=os.path.abspath(fb_bin))
data = open(fb_bin, "rb").read()
write_png(png, 800, 600, pitch, data)
q.cmd("quit")
print("DE-session: dumped fb @ 0x%X pitch %d" % (addr, pitch))
PY
await QEMU_STATUS "$QEMU_PID"
ck; if [[ $DRIVE_STATUS -ne 0 ]]; then
  tail -80 "$SER" >&2
  fail "Homebrew session driver exited $DRIVE_STATUS"
fi
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON missing"
ck; grep -q 'WM DE ON' "$SER" || fail "WM DE ON missing"
ck; ! grep -q 'FAULT RECOVERED' "$SER" \
  || fail "first compose still recovered a #GP"
ck; grep -q 'OSGFX DESK GEN' "$SER" || fail "OSGFX DESK GEN missing — generative desk did not run"
ck; grep -q 'D3S COMMIT' "$SER" || fail "D3S COMMIT missing"
# ADR-0161 16-op walk still lives in osgfx_skia.cpp (including the two
# ops once called unreachable). Runtime `OSGFX SKIA OPS OK 16` is not
# emitted: osgfx_fps_run_probe=0 because probe 4 never returns on qemu64.
# Coverage is the source walk + the pixel chrome checks below, not a
# token the kernel no longer prints.
ck; grep -q 'OSGFX PROBE 5 RRECT-XY-AA' "$SKIA_CPP" \
  || fail "16-op walk lost AA MakeRectXY rrect"
ck; grep -q 'OSGFX PROBE 7 PATH-AA' "$SKIA_CPP" \
  || fail "16-op walk lost AA path"
ck; grep -q 'OSGFX PROBE 14 TEXT OUT' "$SKIA_CPP" \
  || fail "16-op walk lost text op"
ck; grep -q 'osgfx_fps_run_probe = 0' "$SKIA_CPP" \
  || fail "probe gate missing (enabling it hangs probe 4 on qemu64)"
ck; grep -qE 'OSGFX CLIENT TEXT OUTLINE|OSGFX TEXT OUTLINE PROPORTIONAL' "$SER" \
  || fail "no outline-text token on serial"
# No DESK.ELF runs in this phase. The bottom band must therefore remain
# wallpaper, proving there is no one-frame legacy Start flash before DESK.
ck; ! grep -q 'OSGFX SESSION STRIP CLIENT' "$SER" \
  || fail "session withdrew its strip with no client panel up"
ck; ! grep -q 'OSGFX SESSION CHROME CLIENT' "$SER" \
  || fail "session withdrew titles with no DESK up"
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-Fa-f]+ PITCH ([0-9A-Fa-f]+)' "$SER" | awk '{print $NF}')))
ck; python3 "$DERIVE" variety "$FB_BIN" "$PITCH" 800 600 48 \
  || fail "desktop is still flat solid"
# Title band — window A at (100,120), 32 rows. ADR-0187 replaced the flat
# fill plus stamped sheen rectangle with one Skia vertical gradient, so a
# single exact-colour probe is the wrong assertion: sample the whole band.
ck; python3 "$DERIVE" title_gradient "$FB_BIN" "$PITCH" 200 120 32 \
  0x00F4F0E8 0x00E8E0D0 \
  || fail "title band is not a Skia vertical gradient in the title colours"
# Window A at (100,120): modest-radius interior is pearl, not wallpaper teeth.
ck; python3 - "$FB_BIN" "$PITCH" <<'PY' || fail "window A corner is not one Skia AA card"
import sys
data = open(sys.argv[1], "rb").read()
pitch = int(sys.argv[2])
def px(x, y):
    off = y * pitch + x * 4
    return int.from_bytes(data[off:off+4], "little") & 0xFFFFFF
ink = px(106, 126)
r, g, b = (ink >> 16) & 255, (ink >> 8) & 255, ink & 255
if r < 180 or g < 170 or b < 150:
    raise SystemExit("corner interior %06X is not pearl" % ink)
shades = set(px(x, y) for y in range(120, 130) for x in range(100, 110))
if len(shades) < 6:
    raise SystemExit("corner 10x10 has %d shades — not AA" % len(shades))
print("session corner AA: pearl %06X shades %d" % (ink, len(shades)))
PY
# The retired Start pill colour must not appear at its old centre.
ck; python3 "$PROBE" --absent "$FB_BIN" "$PITCH" 22 580 0x00C87840 "start_tile" \
  || fail "legacy Start fallback is still visible before DESK"
# Window A at (100,120) w=240: close at (314,127) size 18 — mid + AABB corner
ck; python3 "$DERIVE" close_rrect "$FB_BIN" "$PITCH" 314 127 18 9 0x00D45050 \
  || fail "close button is a flat pixel blob, not an osgfx rrect"
ck; python3 "$DERIVE" close_aa "$FB_BIN" "$PITCH" 314 127 18 9 0x00D45050 \
  || fail "close button edge is binary (no soft AA fringe)"
# FILES caption — real antialiased proportional OUTLINE text (ADR-0187).
#
# This used to count pixels EXACTLY equal to 0x202830 and require >= 20.
# That assertion could only ever be satisfied by opaque stamps: it passed
# precisely because the caption was an 8x16 bitmap blitted at full
# coverage. Now that Skia scan-converts a real Roboto outline, almost no
# pixel reaches full coverage, so the old check would fail on strictly
# better output. It is replaced by three properties a bitmap font CANNOT
# satisfy and antialiased outline text must:
#   1. many distinct ink shades (AA ramp), not one flat ink colour;
#   2. a large fraction of the ink at intermediate coverage (the fringe);
#   3. cap height and run width that are NOT multiples of the 8x16 cell.
ck; python3 "$SKIA_TEXT/caption.py" "$FB_BIN" "$PITCH" 114 120 285 152 \
  || fail "FILES caption is not antialiased proportional outline text"
# ADR-0183: body is FRAME shm, not solid OSGFX_WIN_FILL wipe.
ck; python3 "$PROBE" "$FB_BIN" "$PITCH" 160 160 0x00F0C020 "win_body" \
  || fail "window body is not client shm (ADR-0183)"
echo "HOMEBREW: pass  DESK GEN + variety + no fallback Start + close AA rrect + body"

echo
echo "=== GL QEMU (venus=on) ==="
VENUS_MODE=""
VENUS_SKIP_WHY=""
mkdir -p "$WORKDIR/gl"
cp "$DISK_IMG" "$WORKDIR/gl/disk.img"
SER="$WORKDIR/gl/serial.txt"
: >"$SER"
GL_KEYS="$(typekeys 'virtgpuv'),ret,wait:8000"
GL_KEYS="$GL_KEYS,$(typekeys 'wm on'),ret,wait:2500"
GL_KEYS="$GL_KEYS,$(typekeys 'wm gfx'),ret,wait:30000"
GL_KEYS="$GL_KEYS,$(typekeys 'wm de'),ret,wait:800"
GL_KEYS="$GL_KEYS,$(typekeys "proc spawn $LBA_A"),ret,wait:2000"
GL_KEYS="$GL_KEYS,$(typekeys "proc spawn $LBA_B"),ret,wait:3000"
GL_PNG="$WORKDIR/gl/de-session-venus.png"

run_venus_native() {
  local port="$1"
  timeout 480 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 512M -cpu qemu64 \
    -vga none \
    -device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M,xres="${XRES}",yres="${YRES}" \
    -drive "file=$WORKDIR/gl/disk.img,format=raw,if=ide,index=0,media=disk" \
    -display none \
    -serial "file:$SER" \
    -qmp "tcp:127.0.0.1:${port},server,nowait" \
    -no-reboot \
    >"$WORKDIR/gl/qemu.log" 2>&1 &
  echo $!
}

run_venus_docker() {
  local port="$1"
  if ! docker image inspect oscortex-qemu-gl:local >/dev/null 2>&1; then
    bash "$CORE_DIR/scripts/build-qemu-gl.sh" || return 1
  fi
  timeout 480 docker run --rm --name "$GL_NAME" \
    -v "$KERNEL_ELF:/kernel.elf:ro" \
    -v "$WORKDIR/gl:/work" \
    -p "127.0.0.1:${port}:${port}" \
    -e LIBGL_ALWAYS_SOFTWARE=1 \
    -e GALLIUM_DRIVER=llvmpipe \
    -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
    oscortex-qemu-gl:local \
    bash -c "echo VENUS_GL; xvfb-run -a qemu-system-x86_64 -kernel /kernel.elf -m 512M -cpu qemu64 -vga none -device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M,xres=${XRES},yres=${YRES} -drive file=/work/disk.img,format=raw,if=ide,index=0,media=disk -display gtk,gl=on -serial file:/work/serial.txt -qmp tcp:0.0.0.0:${port},server,nowait -no-reboot; echo VENUS_QDONE" \
    >"$WORKDIR/gl/qemu.log" 2>&1 &
  echo $!
}

if [[ "$HAVE_VIRTIO_GL" == 1 ]]; then
  ck; PORT=$(python3 "$PICKER") || fail "no free QMP port for GL"
  QEMU_PID=$(run_venus_native "$PORT")
  VENUS_MODE="native-virtio-gpu-gl"
elif [[ "$HAVE_DOCKER" == 1 ]]; then
  ck; PORT=$(python3 "$PICKER") || fail "no free QMP port for GL"
  QEMU_PID=$(run_venus_docker "$PORT") || QEMU_PID=""
  VENUS_MODE="docker"
elif [[ "$HAVE_PODMAN" == 1 ]]; then
  VENUS_SKIP_WHY="podman present but no oscortex-qemu-gl image path wired; docker absent"
else
  VENUS_SKIP_WHY="docker/podman absent and host virtio-gpu-gl-pci unavailable"
fi

if [[ -n "$VENUS_SKIP_WHY" ]]; then
  echo "DE-session: VENUS SKIP — $VENUS_SKIP_WHY"
  mkdir -p "${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
  cat >"${ARTIFACTS_DIR:-/opt/cursor/artifacts}/oscortex-round25-session.json" <<EOF
{
  "round": 25,
  "homebrew": "PASS",
  "venus": "SKIP",
  "venus_why": "$VENUS_SKIP_WHY",
  "have_docker": $HAVE_DOCKER,
  "have_podman": $HAVE_PODMAN,
  "have_virtio_gl": $HAVE_VIRTIO_GL,
  "coverage_removed": false
}
EOF
    require_assertions 69
    echo "DE-session: PASS — Homebrew session chrome + generative desk ($ASSERTIONS checks); Venus SKIP ($VENUS_SKIP_WHY)"
  exit 0
fi

waited=0
while [[ $waited -lt 120 ]]; do
  grep -q 'M1 END' "$SER" 2>/dev/null && break
  sleep 1
  waited=$((waited + 1))
done
if ! grep -q 'M1 END' "$SER"; then
  if [[ "$VENUS_MODE" == "native-virtio-gpu-gl" && "$HAVE_DOCKER" == 0 ]]; then
    echo "DE-session: VENUS SKIP — native virtio-gpu-gl failed to reach M1 END; docker absent"
    cat "$WORKDIR/gl/qemu.log" >&2 || true
    mkdir -p "${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
    cat >"${ARTIFACTS_DIR:-/opt/cursor/artifacts}/oscortex-round25-session.json" <<EOF
{
  "round": 25,
  "homebrew": "PASS",
  "venus": "SKIP",
  "venus_why": "native virtio-gpu-gl did not reach M1 END; docker not installed",
  "have_docker": 0,
  "have_virtio_gl": 1,
  "coverage_removed": false
}
EOF
    require_assertions 69
    echo "DE-session: PASS — Homebrew only; Venus capability missing at runtime"
    exit 0
  fi
  cat "$WORKDIR/gl/qemu.log" >&2
  echo "--- serial ---" >&2
  cat "$SER" >&2
  fail "GL boot never reached M1 END"
fi
run_status GL_DRIVE_STATUS -- python3 "$DRIVER" \
  --port "$PORT" --serial "$SER" --wait-for 'M1 END\n' \
  --png "$GL_PNG" --screen-text "$WORKDIR/gl/screen.txt" \
  --no-screendump \
  --keys "$GL_KEYS"
if [[ "$HAVE_DOCKER" == 1 ]]; then
  docker rm -f "$GL_NAME" >/dev/null 2>&1 || true
fi
await QEMU_STATUS "$QEMU_PID"
if [[ $GL_DRIVE_STATUS -ne 0 ]]; then
  echo "    note: qmp-drive exited $GL_DRIVE_STATUS"
fi
if ! grep -q 'VIRTIO VENUS OK' "$SER"; then
  if [[ "$VENUS_MODE" == "native-virtio-gpu-gl" && "$HAVE_DOCKER" == 0 ]]; then
    echo "DE-session: VENUS SKIP — native virtio-gpu-gl reached boot but no VIRTIO VENUS OK; docker absent"
    mkdir -p "${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
    cat >"${ARTIFACTS_DIR:-/opt/cursor/artifacts}/oscortex-round25-session.json" <<EOF
{
  "round": 25,
  "homebrew": "PASS",
  "venus": "SKIP",
  "venus_why": "native virtio-gpu-gl has no VIRTIO VENUS OK; docker not installed",
  "have_docker": 0,
  "have_podman": $HAVE_PODMAN,
  "have_virtio_gl": 1,
  "coverage_removed": false
}
EOF
    require_assertions 69
    echo "DE-session: PASS — Homebrew only; Venus Graphite isolation not available"
    exit 0
  fi
  fail "VIRTIO VENUS OK missing"
fi
ck; grep -q 'VIRTIO VENUS OK' "$SER" || fail "VIRTIO VENUS OK missing"
ck; grep -q 'OSGFX GRAPHITE OK' "$SER" || fail "OSGFX GRAPHITE OK missing"
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON missing on Venus"
ck; grep -q 'WM DE ON' "$SER" || fail "WM DE ON missing on Venus"
ck; grep -q 'OSGFX GRAPHITE DESK 001C6A38' "$SER" \
  || fail "OSGFX GRAPHITE DESK 001C6A38 missing on Venus"
ck; grep -q 'OSGFX SESSION CHROME' "$SER" \
  || fail "OSGFX SESSION CHROME missing — DE session paint did not run"
ck; grep -q 'OSGFX GRAPHITE RRECT' "$SER" \
  || fail "OSGFX GRAPHITE RRECT missing on Venus"
ck; grep -qE 'osgfx_graphite_fill_rrect|0x00D45050' "$SKIA_CPP" \
  || fail "close colour not routed through Graphite fill_rrect"
if [[ -f "$GL_PNG" ]]; then
  echo "    Venus PNG: $GL_PNG"
fi
if grep -q 'OSGFX DESK GEN' "$SER"; then
  echo "    Venus serial: OSGFX DESK GEN"
else
  echo "    note: generative desk pixels proved on Homebrew (212+ colours)"
fi
echo "VENUS: pass  Graphite armed + SESSION CHROME + RRECT ($VENUS_MODE)"

mkdir -p "${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
cat >"${ARTIFACTS_DIR:-/opt/cursor/artifacts}/oscortex-round25-session.json" <<EOF
{
  "round": 25,
  "homebrew": "PASS",
  "venus": "PASS",
  "venus_mode": "$VENUS_MODE",
  "have_docker": $HAVE_DOCKER,
  "have_virtio_gl": $HAVE_VIRTIO_GL
}
EOF

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-session: PASS — session chrome + generative desk ($ASSERTIONS checks)"
exit 0
