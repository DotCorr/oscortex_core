#!/usr/bin/env bash
# DE-media — the running OS decodes a planted H.264 frame (ADR-0116).
# docs/design/de-media.md, docs/design/c-modules.md.
#
# Host media0 is a Mac program. This harness is QEMU + kernel.elf.
#
# Binary:
#   * nm of the kernel QEMU runs shows avcodec_ or osmedia_backend_ffmpeg
#   * OSMEDIA_FFMPEG=0 kernel has no avcodec_ (anti-vacuity)
#   * planted CLIP.MP4 + hidden `play` prints OSMEDIA PIX near FRAME
#   * missing CLIP.MP4 is not FRAME
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

fail() { echo "DE-media: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-media: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=44

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-nm ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH (source env.sh)"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-media.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
HDR="$CORE_DIR/plat/media/osmedia.h"
SRC="$CORE_DIR/plat/media/osmedia.c"
GUEST="$CORE_DIR/plat/media/osmedia_guest.c"
MAKEIMG="$SCRIPT_DIR/make-image.py"
DERIVE="$SCRIPT_DIR/derive.py"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$MAKEIMG" ]] || setup_error "make-image.py not found"
[[ -f "$DERIVE" ]] || setup_error "derive.py not found"

export OSGFX_SKIA="${OSGFX_SKIA:-0}"

echo "=== ANTI-VACUITY (no FFmpeg libs) ==="
capture_sh NOFF_OUT NOFF_STATUS -- "OSMEDIA_FFMPEG=0 OSGFX_SKIA=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$NOFF_OUT"
ck; [[ $NOFF_STATUS -eq 0 ]] || fail "OSMEDIA_FFMPEG=0 build-kernel.sh exited $NOFF_STATUS"
cp "$KERNEL_ELF" "$WORKDIR/kernel-noff.elf"
NOFF_NM=$(x86_64-elf-nm "$WORKDIR/kernel-noff.elf" 2>/dev/null || true)
ck; ! echo "$NOFF_NM" | grep -E 'avcodec_' >/dev/null \
  || fail "OSMEDIA_FFMPEG=0 kernel.elf still names avcodec_"
echo "ANTI-VACUITY: pass  no avcodec_ without guest FFmpeg"

echo
echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "OSMEDIA_FFMPEG=1 OSGFX_SKIA=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
cp "$KERNEL_ELF" "$WORKDIR/kernel.elf"

NM=$(x86_64-elf-nm "$WORKDIR/kernel.elf")
ck; echo "$NM" | grep -q 'osmedia_backend_ffmpeg' \
  || echo "$NM" | grep -E 'avcodec_' >/dev/null \
  || fail "kernel.elf has neither osmedia_backend_ffmpeg nor avcodec_"
ck; echo "$NM" | grep -E 'avcodec_' >/dev/null \
  || fail "kernel.elf has no avcodec_ — stub that only names the backend"
ck; echo "$NM" | grep -q 'osmedia_guest_tick' \
  || fail "kernel.elf has no osmedia_guest_tick"
ck; echo "$NM" | grep -q 'osmedia_open_mem' \
  || fail "kernel.elf has no osmedia_open_mem"
ck; grep -q 'osmedia_guest.o\|osmedia.o' "$CORE_DIR/build/kernel.map" \
  || fail "kernel.map does not name the media objects"
echo "BUILD: pass  avcodec_ / osmedia_* in the kernel QEMU will run"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'avformat_open_input' "$SRC" || fail "osmedia.c does not call avformat_open_input"
ck; grep -q 'avcodec_send_packet' "$SRC" || fail "osmedia.c does not call avcodec_send_packet"
ck; grep -q 'avcodec_receive_frame' "$SRC" || fail "osmedia.c does not call avcodec_receive_frame"
ck; grep -q 'osmedia_open_mem' "$SRC" || fail "osmedia.c has no osmedia_open_mem"
ck; grep -q 'osmedia_decode_frame' "$GUEST" || fail "osmedia_guest.c does not call osmedia_decode_frame"
ck; grep -q 'OSMEDIA_FRAME = 0x00C04088' "$HDR" || fail "FRAME moved without derive.py"
ck; grep -q 'call osmedia_guest_tick' "$CORE_DIR/boot/isr.S" \
  || fail "isr.S does not call osmedia_guest_tick"
ck; grep -q "part 'kmedia.dart'" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part kmedia.dart"
ck; ! grep -q 'osmedia' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart names osmedia — keep the C module out of that file"
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
ck; [[ "$EV_SIZE" -eq 384 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 384"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss — DE-media stole D7's slot"
ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/kmedia.dart" \
  || fail "kmedia.dart declares @bss"
ck; ! grep -q '^@extern' "$CORE_DIR/kernel/kmedia.dart" \
  || fail "kmedia.dart added @extern — 44 stay 44"
echo "STRUCTURAL: pass  play mailbox, no syscall, no help, D7 last"

echo
echo "=== CLIP ==="
CLIP="$WORKDIR/clip.mp4"
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=0xC04088:s=64x64:d=0.2:r=10" \
  -frames:v 2 -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
  -bsf:v h264_mp4toannexb -f h264 \
  "$CLIP" || fail "ffmpeg could not plant CLIP.MP4"
ck; [[ -s "$CLIP" ]] || fail "planted clip is empty"
ck; ! python3 -c "import sys; b=open(sys.argv[1],'rb').read(8); sys.exit(0 if b==b'OSCXPRG1' else 1)" "$CLIP" \
  || fail "clip begins with OSCXPRG1 — not H.264"
python3 "$MAKEIMG" "$WORKDIR/plant.img" "$CLIP" || fail "make-image plant failed"
python3 "$MAKEIMG" "$WORKDIR/miss.img" || fail "make-image miss failed"
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
  local outdir="$1" keys="$2" label="$3" img="$4"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
    -kernel "$WORKDIR/kernel.elf" \
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
  run_status drive_status -- python3 - "$port" "$ser" "$keys" <<'PY'
import json, os, socket, sys, time

port, serial, keys = int(sys.argv[1]), sys.argv[2], sys.argv[3]

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
                print("DE-media: QEMU", hello.get("QMP", {}).get("version", {}))
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
time.sleep(0.8)
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

# Plant token is PIX, not TICK. until:OSMEDIA used to match TICK and
# quit 400ms later — FFmpeg annex-B decode on IRQ0 had not printed PIX.
# Miss must never print PIX; wait for MISS (TICK alone is not enough).
KEYS_PLANT="$(typekeys 'play'),ret,until:OSMEDIA PIX,wait:200"
KEYS_MISS="$(typekeys 'play'),ret,until:OSMEDIA MISS,wait:200"

echo
echo "=== BOOT planted CLIP.MP4 ==="
drive_session "$WORKDIR/plant" "$KEYS_PLANT" "plant" "$WORKDIR/plant.img"
echo
capture_sh DR_OUT DR_STATUS -- "python3 '$DERIVE' '$WORKDIR/plant/serial.txt' frame"
echo "$DR_OUT"
if [[ $DR_STATUS -ne 0 ]]; then
  echo "--- plant serial (OSMEDIA) ---" >&2
  grep -E 'OSMEDIA|play|FS ERR|FAT' "$WORKDIR/plant/serial.txt" >&2 || tail -40 "$WORKDIR/plant/serial.txt" >&2
  fail "derive frame failed: $DR_OUT"
fi
ck; echo "$DR_OUT" | grep -q 'FRAME_OK' || fail "no FRAME_OK"
ck; grep -q 'OSMEDIA PIX' "$WORKDIR/plant/serial.txt" \
  || fail "plant boot did not print OSMEDIA PIX"
ck; grep -q 'OSMEDIA COPY-OK' "$WORKDIR/plant/serial.txt" \
  || fail "plant boot did not copy the decoded frame"

echo
echo "=== BOOT missing CLIP.MP4 ==="
drive_session "$WORKDIR/miss" "$KEYS_MISS" "miss" "$WORKDIR/miss.img"
echo
capture_sh DM_OUT DM_STATUS -- "python3 '$DERIVE' '$WORKDIR/miss/serial.txt' none"
echo "$DM_OUT"
ck; [[ $DM_STATUS -eq 0 ]] || fail "derive miss failed: $DM_OUT"
ck; echo "$DM_OUT" | grep -q 'NONE_OK' || fail "no NONE_OK on missing file"
ck; grep -q 'OSMEDIA MISS' "$WORKDIR/miss/serial.txt" \
  || fail "miss boot did not print OSMEDIA MISS"
ck; ! grep -q 'OSMEDIA PIX' "$WORKDIR/miss/serial.txt" \
  || fail "miss boot printed OSMEDIA PIX"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-media: PASS — kernel.elf links FFmpeg; planted PIX is FRAME; missing file is not ($ASSERTIONS checks)"
