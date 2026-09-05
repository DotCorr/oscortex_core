#!/usr/bin/env bash
# DE-vwin — a planted decoded frame is committed through a wmsurface
# (ADR-0135). docs/design/de-media.md, GAP-0316 leftover after ADR-0131.
#
# de-vblit already plants FRAME at (16, 400). This harness requires those
# RGB bytes on a client shm window body, not only the raw Bochs tile.
#
# Binary:
#   * OSMEDIA_NO_WIN=1: PLAY attaches, PIX/BLIT land, window body is not FRAME
#   * win kernel: go PLAY.ELF + play plants FRAME at (WIN_X+PX, WIN_Y+PY)
#   * raw tile at (32, 416) still FRAME (de-vblit unmoved)
#   * missing CLIP.MP4 is not FRAME on the window
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

fail() { echo "DE-vwin: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-vwin: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=77

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-nm ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH (source env.sh)"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-vwin.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
HDR="$CORE_DIR/plat/media/osmedia.h"
SRC="$CORE_DIR/plat/media/osmedia.c"
GUEST="$CORE_DIR/plat/media/osmedia_guest.c"
KMEDIA="$CORE_DIR/kernel/kmedia.dart"
WMDE="$CORE_DIR/kernel/wmde.dart"
PLAY_C="$CORE_DIR/user/frame/play.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"
PROG_LD="$CORE_DIR/tests/conformance/frame2/prog.ld"
DERIVE="$SCRIPT_DIR/derive.py"
MAKEIMG="$SCRIPT_DIR/make-image.py"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$MAKEIMG" ]] || setup_error "make-image.py not found"
[[ -f "$DERIVE" ]] || setup_error "derive.py not found"
[[ -f "$PLAY_C" ]] || setup_error "play.c not found"
[[ -f "$FRAME_H" ]] || setup_error "osframe.h not found"
[[ -f "$PROG_LD" ]] || setup_error "frame2/prog.ld not found"

# SKIA=0 avoids the in-flight Venus osgfx_vk.c compile. osxui_hex_fb
# is weak in osgfx_glyph.c. Not Graphite video.
export OSGFX_SKIA="${OSGFX_SKIA:-0}"

echo "=== HEADER ==="
capture_sh HDR_OUT HDR_STATUS -- "python3 '$DERIVE' '$HDR' header"
echo "$HDR_OUT"
ck; [[ $HDR_STATUS -eq 0 ]] || fail "derive header failed: $HDR_OUT"
ck; echo "$HDR_OUT" | grep -q 'HEADER_OK' || fail "no HEADER_OK"
ck; grep -q 'mediaWinX = 200' "$KMEDIA" || fail "kmedia.dart WIN_X drifted from osmedia.h"
ck; grep -q 'mediaWinY = 80' "$KMEDIA" || fail "kmedia.dart WIN_Y drifted from osmedia.h"
ck; grep -q '#define WIN_X 200UL' "$PLAY_C" || fail "play.c WIN_X drifted"
ck; grep -q '#define WIN_Y 80UL' "$PLAY_C" || fail "play.c WIN_Y drifted"

echo
echo "=== PLAY.ELF ==="
CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror
  -I"$CORE_DIR/user/frame"
)
clang "${CFLAGS[@]}" "$PLAY_C" -o "$WORKDIR/play.o" \
  || fail "clang could not compile play.c"
x86_64-elf-ld -T "$PROG_LD" -z max-page-size=0x1000 --build-id=none \
  -o "$WORKDIR/play.elf" "$WORKDIR/play.o" \
  || fail "ld could not link PLAY.ELF"
ck; [[ -s "$WORKDIR/play.elf" ]] || fail "PLAY.ELF is empty"
ck; ! grep -qE '^#define SYS_' "$PLAY_C" || fail "play.c copies SYS_* by hand"
ck; grep -q '#include "osframe.h"' "$PLAY_C" || fail "play.c does not include osframe.h"
ck; ! grep -q 'oslibc.h' "$PLAY_C" || fail "play.c includes oslibc.h"
ck; ! grep -qE 'fdwait|SYS_FDWAIT' "$PLAY_C" || fail "play.c names fdwait"
ck; ! grep -qiE 'guest OS' "$PLAY_C" || fail "play.c says guest OS"
ck; grep -q 'SYS_WMSURFACE' "$PLAY_C" || fail "play.c does not call wmsurface"
ck; grep -q 'SYS_SHMCREATE' "$PLAY_C" || fail "play.c does not shmcreate"
echo "PLAY.ELF: pass  $(wc -c < "$WORKDIR/play.elf") bytes against osframe.h"

echo
echo "=== ANTI-VACUITY (decode + blit, no window) ==="
capture_sh NOWIN_OUT NOWIN_STATUS -- \
  "OSMEDIA_NO_WIN=1 OSMEDIA_NO_BLIT=0 OSMEDIA_FFMPEG=1 OSGFX_SKIA=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$NOWIN_OUT"
ck; [[ $NOWIN_STATUS -eq 0 ]] || fail "OSMEDIA_NO_WIN=1 build-kernel.sh exited $NOWIN_STATUS"
cp "$KERNEL_ELF" "$WORKDIR/kernel-nowin.elf"
# No grep -q on a pipe under pipefail: early close SIGPIPEs nm (GAP-0353 flake).
ck; x86_64-elf-nm "$WORKDIR/kernel-nowin.elf" | grep -E 'avcodec_' >/dev/null \
  || fail "OSMEDIA_NO_WIN kernel has no avcodec_ — need a real decode"
ck; x86_64-elf-nm "$WORKDIR/kernel-nowin.elf" | grep 'fbBlitArgb' >/dev/null \
  || fail "OSMEDIA_NO_WIN kernel lost fbBlitArgb"
ck; x86_64-elf-nm "$WORKDIR/kernel-nowin.elf" | grep 'wmMediaFill' >/dev/null \
  || fail "OSMEDIA_NO_WIN kernel lost wmMediaFill"
echo "ANTI-VACUITY BUILD: pass  ffmpeg linked, window call compiled out"

echo
echo "=== BUILD (window) ==="
capture_sh BUILD_OUT BUILD_STATUS -- \
  "OSMEDIA_NO_WIN=0 OSMEDIA_NO_BLIT=0 OSMEDIA_FFMPEG=1 OSGFX_SKIA=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
cp "$KERNEL_ELF" "$WORKDIR/kernel.elf"

NM_FILE="$WORKDIR/kernel.nm"
x86_64-elf-nm "$WORKDIR/kernel.elf" >"$NM_FILE"
ck; grep 'wmMediaFill' "$NM_FILE" >/dev/null || fail "kernel.elf has no wmMediaFill"
ck; grep 'fbBlitArgb' "$NM_FILE" >/dev/null || fail "kernel.elf has no fbBlitArgb"
ck; grep 'osmedia_readback' "$NM_FILE" >/dev/null || fail "kernel.elf has no osmedia_readback"
ck; grep -E 'avcodec_' "$NM_FILE" >/dev/null || fail "kernel.elf has no avcodec_"
echo "BUILD: pass  wmMediaFill / fbBlitArgb / avcodec_ in the kernel QEMU will run"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'wmMediaFill' "$GUEST" || fail "osmedia_guest.c does not call wmMediaFill"
ck; grep -q 'OSMEDIA_NO_WIN' "$GUEST" || fail "osmedia_guest.c has no OSMEDIA_NO_WIN skip"
ck; grep -q 'fbBlitArgb' "$GUEST" || fail "osmedia_guest.c lost fbBlitArgb — do not break de-vblit"
ck; grep -q 'void wmMediaFill' "$KMEDIA" || fail "kmedia.dart has no wmMediaFill"
ck; grep -q 'wmMediaCreate' "$KMEDIA" || fail "kmedia.dart has no wmMediaCreate"
ck; grep -q 'wmComposeCommit' "$KMEDIA" || fail "kmedia.dart does not commit the surface"
ck; grep -q 'mediaNameIsPlay' "$WMDE" || fail "wmde.dart does not kick play on PLAY.ELF"
ck; grep -q 'shellMediaPlayDefault' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch play"
ck; ! grep -E '`play`|play\(|shellMediaPlay' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry grew a play row — no new syscall"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — no help line"
EV_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="wmeventStore"{print $3+0; exit}')
EV_OFF=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="wmeventStore"{print $2; exit}')
ck; [[ "$EV_SIZE" -eq 1920 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 1920"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss — DE-vwin stole D7's slot"
ck; ! grep -qE '^@bss$|final Bss ' "$KMEDIA" \
  || fail "kmedia.dart declares @bss"
ck; ! grep -q '^@extern' "$KMEDIA" \
  || fail "kmedia.dart added @extern — 44 stay 44"
ck; ! grep -qiE 'guest OS' "$KMEDIA" || fail "kmedia.dart says guest OS"
ck; grep -q '11 stays' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry lost the fdwait / 11 sentence"
echo "STRUCTURAL: pass  window in kmedia.dart, no syscall, no help, D7 last"

echo
echo "=== CLIP ==="
CLIP="$WORKDIR/clip.mp4"
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=0xC04088:s=64x64:d=0.2:r=10" \
  -frames:v 2 -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
  -bsf:v h264_mp4toannexb -f h264 \
  "$CLIP" || fail "ffmpeg could not plant CLIP.MP4"
ck; [[ -s "$CLIP" ]] || fail "planted clip is empty"
python3 "$MAKEIMG" "$WORKDIR/plant.img" "$CLIP" "$WORKDIR/play.elf" \
  || fail "make-image plant failed"
python3 "$MAKEIMG" "$WORKDIR/miss.img" - "$WORKDIR/play.elf" \
  || fail "make-image miss failed"
ck; [[ -s "$WORKDIR/plant.img" ]] || fail "no plant.img"
ck; [[ -s "$WORKDIR/miss.img" ]] || fail "no miss.img"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" label="$3" img="$4" kern="$5"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local fb="$outdir/fb.bin"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
    -kernel "$kern" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$img,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 - "$port" "$ser" "$fb" "$keys" <<'PY'
import json, os, re, socket, sys, time

port, serial, fb_bin, keys = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

class Qmp:
    def __init__(self, port):
        deadline = time.time() + 20
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.f = self.s.makefile("rw", encoding="utf-8")
                hello = json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                print("DE-vwin: QEMU", hello.get("QMP", {}).get("version", {}))
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

def wait_marker(path, marker, timeout=40, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_marker(path, marker) >= at_least:
            return True
        time.sleep(0.1)
    return False

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("kernel never reached the prompt")
time.sleep(0.5)
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        if not wait_marker(serial, marker, timeout=40):
            raise SystemExit("never saw %s" % marker)
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(1.2)
text = open(serial, "r", encoding="latin-1").read()
m = re.search(r"FB BAR ([0-9A-Fa-f]{8})", text)
if m:
    addr = int(m.group(1), 16)
    q.cmd("pmemsave", val=addr, size=600 * 3200, filename=os.path.abspath(fb_bin))
    print("DE-vwin: dumped fb @ 0x%X" % addr)
q.cmd("quit")
PY
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -80 "$ser" >&2
    fail "session driver exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
  ck; [[ -s "$ser" ]] || fail "the $label boot captured no serial"
}

KEYS_WIN="$(typekeys 'fb'),ret,until:FB BAR ,wait:400,$(typekeys 'wm on'),ret,until:WM ON,wait:400,$(typekeys 'go PLAY.ELF'),ret,until:PLAY ATTACH,wait:400,$(typekeys 'play'),ret,until:OSMEDIA PIX,wait:900"
KEYS_MISS="$(typekeys 'fb'),ret,until:FB BAR ,wait:400,$(typekeys 'wm on'),ret,until:WM ON,wait:400,$(typekeys 'go PLAY.ELF'),ret,until:PLAY ATTACH,wait:400,$(typekeys 'play'),ret,until:OSMEDIA MISS,wait:200"

echo
echo "=== BOOT no-win planted (attach, no shm blit → pixel miss) ==="
drive_session "$WORKDIR/nowin" "$KEYS_WIN" "nowin" \
  "$WORKDIR/plant.img" "$WORKDIR/kernel-nowin.elf"
ck; grep -q 'OSMEDIA PIX' "$WORKDIR/nowin/serial.txt" \
  || fail "no-win boot did not decode (no OSMEDIA PIX)"
ck; grep -q 'OSMEDIA BLIT ' "$WORKDIR/nowin/serial.txt" \
  || fail "no-win boot lost the de-vblit tile"
ck; ! grep -q 'OSMEDIA WIN ' "$WORKDIR/nowin/serial.txt" \
  || fail "OSMEDIA_NO_WIN=1 still printed OSMEDIA WIN"
ck; [[ -s "$WORKDIR/nowin/fb.bin" ]] || fail "no-win boot produced no framebuffer dump"
capture_sh NW_OUT NW_STATUS -- \
  "python3 '$DERIVE' '$HDR' nowin '$WORKDIR/nowin/fb.bin' 3200"
echo "$NW_OUT"
ck; [[ $NW_STATUS -eq 0 ]] || fail "derive nowin failed: $NW_OUT"
ck; echo "$NW_OUT" | grep -q 'NOWIN_OK' || fail "no NOWIN_OK — skip window must miss FRAME"
capture_sh NB_OUT NB_STATUS -- \
  "python3 '$DERIVE' '$HDR' blit '$WORKDIR/nowin/fb.bin' 3200"
echo "$NB_OUT"
ck; [[ $NB_STATUS -eq 0 ]] || fail "derive nowin-blit failed: $NB_OUT"
ck; echo "$NB_OUT" | grep -q 'BLIT_OK' || fail "no-win boot lost the raw Bochs tile"

echo
echo "=== BOOT planted CLIP.MP4 + PLAY.ELF + fb + wm + play ==="
drive_session "$WORKDIR/plant" "$KEYS_WIN" "plant" \
  "$WORKDIR/plant.img" "$WORKDIR/kernel.elf"
capture_sh DR_OUT DR_STATUS -- \
  "python3 '$DERIVE' '$HDR' frame '$WORKDIR/plant/serial.txt'"
echo "$DR_OUT"
ck; [[ $DR_STATUS -eq 0 ]] || fail "derive frame failed: $DR_OUT"
ck; echo "$DR_OUT" | grep -q 'FRAME_OK' || fail "no FRAME_OK"
ck; grep -q 'PLAY ATTACH' "$WORKDIR/plant/serial.txt" \
  || fail "PLAY.ELF did not attach a wmsurface"
ck; grep -q 'WM ATTACH ' "$WORKDIR/plant/serial.txt" \
  || fail "no WM ATTACH — not a wmsurface"
ck; [[ -s "$WORKDIR/plant/fb.bin" ]] || fail "plant boot produced no framebuffer dump"
capture_sh WIN_OUT WIN_STATUS -- \
  "python3 '$DERIVE' '$HDR' win '$WORKDIR/plant/fb.bin' 3200"
echo "$WIN_OUT"
ck; [[ $WIN_STATUS -eq 0 ]] || fail "derive win failed: $WIN_OUT"
ck; echo "$WIN_OUT" | grep -q 'WIN_OK' || fail "no WIN_OK — FRAME not on the window body"
capture_sh BL_OUT BL_STATUS -- \
  "python3 '$DERIVE' '$HDR' blit '$WORKDIR/plant/fb.bin' 3200"
echo "$BL_OUT"
ck; [[ $BL_STATUS -eq 0 ]] || fail "derive blit failed: $BL_OUT"
ck; echo "$BL_OUT" | grep -q 'BLIT_OK' || fail "window commit wiped the de-vblit tile"

echo
echo "=== BOOT missing CLIP.MP4 ==="
drive_session "$WORKDIR/miss" "$KEYS_MISS" "miss" \
  "$WORKDIR/miss.img" "$WORKDIR/kernel.elf"
capture_sh DM_OUT DM_STATUS -- \
  "python3 '$DERIVE' '$HDR' none '$WORKDIR/miss/serial.txt'"
echo "$DM_OUT"
ck; [[ $DM_STATUS -eq 0 ]] || fail "derive miss failed: $DM_OUT"
ck; echo "$DM_OUT" | grep -q 'NONE_OK' || fail "no NONE_OK on missing file"
ck; [[ -s "$WORKDIR/miss/fb.bin" ]] || fail "miss boot produced no framebuffer dump"
capture_sh MN_OUT MN_STATUS -- \
  "python3 '$DERIVE' '$HDR' nowin '$WORKDIR/miss/fb.bin' 3200"
echo "$MN_OUT"
ck; [[ $MN_STATUS -eq 0 ]] || fail "derive miss-fb failed: $MN_OUT"
ck; echo "$MN_OUT" | grep -q 'NOWIN_OK' || fail "missing file still planted FRAME on the window"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-vwin: PASS — planted FRAME is a wmsurface body pixel at (216,112); skip window / missing file miss ($ASSERTIONS checks)"
