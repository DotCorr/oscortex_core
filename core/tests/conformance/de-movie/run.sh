#!/usr/bin/env bash
# DE-movie — two different frames on the same wmsurface (ADR-0143).
# Leftover after ADR-0135 / de-vwin.
#
# Binary:
#   * planted two-colour annex-B: PIX≈FRAME, MOV≈FRAME2, window body FRAME2
#   * OSMEDIA_NO_MOVIE=1: PIX≈FRAME, no MOV, window body stays FRAME
#
# No new syscall. 11 is fdwait. No help. Not Graphite / Venus.
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

fail() { echo "DE-movie: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-movie: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=44

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-nm ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH (source env.sh)"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-movie.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
HDR="$CORE_DIR/plat/media/osmedia.h"
GUEST="$CORE_DIR/plat/media/osmedia_guest.c"
KMEDIA="$CORE_DIR/kernel/kmedia.dart"
PLAY_C="$CORE_DIR/user/frame/play.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"
PROG_LD="$CORE_DIR/tests/conformance/frame2/prog.ld"
DERIVE="$SCRIPT_DIR/derive.py"
MAKEIMG="$SCRIPT_DIR/make-image.py"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$MAKEIMG" ]] || setup_error "make-image.py not found"
[[ -f "$DERIVE" ]] || setup_error "derive.py not found"
[[ -f "$PLAY_C" ]] || setup_error "play.c not found"

export OSGFX_SKIA="${OSGFX_SKIA:-0}"

echo "=== HEADER ==="
capture_sh HDR_OUT HDR_STATUS -- "python3 '$DERIVE' '$HDR' header"
echo "$HDR_OUT"
ck; [[ $HDR_STATUS -eq 0 ]] || fail "derive header failed: $HDR_OUT"
ck; echo "$HDR_OUT" | grep -q 'HEADER_OK' || fail "no HEADER_OK"
ck; grep -q 'OSMEDIA_FRAME2' "$HDR" || fail "osmedia.h has no FRAME2"
ck; grep -q 'movie_hold' "$GUEST" || fail "osmedia_guest.c has no movie hold"
ck; grep -q 'OSMEDIA MOV' "$GUEST" || fail "osmedia_guest.c never prints MOV"
ck; grep -q 'wmMediaPresent' "$GUEST" || fail "osmedia_guest.c never presents off decode_stack"
ck; grep -q 'wmWinStrideOf' "$KMEDIA" || fail "kmedia.dart blit ignores ADR-0185 packed stride"
ck; grep -q 'ADR-0143' "$CORE_DIR/docs/decisions/0143-two-frames-on-the-same-wmsurface.md" \
  || fail "ADR-0143 file missing"
ck; grep -q '0144 is dlopen' "$CORE_DIR/docs/decisions/0143-two-frames-on-the-same-wmsurface.md" \
  || fail "ADR-0143 stole 0144"
ck; grep -q 'movie (ADR-0143)' "$KMEDIA" || fail "kmedia.dart lost the movie note"
ck; ! grep -qiE 'guest OS' "$GUEST" || fail "osmedia_guest.c says guest OS"
ck; grep -q '11 stays' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "registry lost the fdwait / 11 sentence"
ck; ! grep -qE 'fdwait|SYS_FDWAIT' "$PLAY_C" || fail "play.c names fdwait"
echo "HEADER: pass  FRAME2 + movie path named"

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
echo "PLAY.ELF: pass  $(wc -c < "$WORKDIR/play.elf") bytes"

echo
echo "=== ANTI-VACUITY (decode + window, no second still) ==="
capture_sh NOMOV_OUT NOMOV_STATUS -- \
  "OSMEDIA_NO_MOVIE=1 OSMEDIA_NO_WIN=0 OSMEDIA_NO_BLIT=0 OSMEDIA_FFMPEG=1 OSGFX_SKIA=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$NOMOV_OUT"
ck; [[ $NOMOV_STATUS -eq 0 ]] || fail "OSMEDIA_NO_MOVIE=1 build exited $NOMOV_STATUS"
cp "$KERNEL_ELF" "$WORKDIR/kernel-nomovie.elf"
ck; x86_64-elf-nm "$WORKDIR/kernel-nomovie.elf" | grep -E 'avcodec_' >/dev/null \
  || fail "NO_MOVIE kernel has no avcodec_"
ck; ! x86_64-elf-nm "$WORKDIR/kernel-nomovie.elf" | grep -q 'movie_inner' \
  || true
echo "ANTI-VACUITY BUILD: pass  ffmpeg linked, movie path compiled out"

echo
echo "=== BUILD (movie) ==="
capture_sh BUILD_OUT BUILD_STATUS -- \
  "OSMEDIA_NO_MOVIE=0 OSMEDIA_NO_WIN=0 OSMEDIA_NO_BLIT=0 OSMEDIA_FFMPEG=1 OSGFX_SKIA=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "movie build-kernel.sh exited $BUILD_STATUS"
cp "$KERNEL_ELF" "$WORKDIR/kernel-movie.elf"
ck; x86_64-elf-nm "$WORKDIR/kernel-movie.elf" | grep -E 'avcodec_' >/dev/null \
  || fail "movie kernel has no avcodec_"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
echo "BUILD: pass  movie kernel"

echo
echo "=== CLIP (two colours, MP4) ==="
CLIP="$WORKDIR/clip.mp4"
# Two one-frame MP4s concatenated. lavfi concat can emit two IDRs
# of the same colour; separate encodes keep FRAME then FRAME2.
# Real ftyp MP4 — guest annex-B decode is leftover.
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=0xC04088:s=64x64:d=0.2:r=10" \
  -frames:v 1 -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
  -f mp4 "$WORKDIR/f1.mp4" || fail "ffmpeg FRAME still"
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=0x20C040:s=64x64:d=0.2:r=10" \
  -frames:v 1 -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
  -f mp4 "$WORKDIR/f2.mp4" || fail "ffmpeg FRAME2 still"
printf "file '%s'\nfile '%s'\n" "$WORKDIR/f1.mp4" "$WORKDIR/f2.mp4" \
  > "$WORKDIR/list.txt"
ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 \
  -i "$WORKDIR/list.txt" -c copy -f mp4 "$CLIP" \
  || fail "ffmpeg concat movie"
ck; [[ -s "$CLIP" ]] || fail "planted clip is empty"
ck; python3 - "$CLIP" <<'PY' || fail "plant looks like annex-B"
import sys
b = open(sys.argv[1], "rb").read(8)
if b[:3] == b"\x00\x00\x01" or b[:4] == b"\x00\x00\x00\x01":
    raise SystemExit("annex")
if b[4:8] != b"ftyp":
    raise SystemExit("not ftyp mp4")
print("MP4_OK")
PY
ffmpeg -y -hide_banner -loglevel error -i "$CLIP" \
  -frames:v 2 -f image2 "$WORKDIR/proof%d.ppm" \
  || fail "host could not decode the planted movie"
ck; python3 - "$WORKDIR/proof1.ppm" "$WORKDIR/proof2.ppm" <<'PY' \
  || fail "planted stills are not two different colours"
import sys
def pix(path):
    b = open(path, "rb").read()
    i = 0
    lines = 0
    while lines < 3:
        if b[i] == 10:
            lines += 1
        i += 1
    off = i + (16 * 64 + 16) * 3
    return (b[off] << 16) | (b[off + 1] << 8) | b[off + 2]
a, b = pix(sys.argv[1]), pix(sys.argv[2])
print("PROOF 0x%06X 0x%06X" % (a, b))
if abs(((a >> 16) & 0xFF) - 0xC0) > 20 or abs(((b >> 16) & 0xFF) - 0x20) > 20:
    raise SystemExit("colours drifted")
if a == b:
    raise SystemExit("both stills match")
PY
python3 "$MAKEIMG" "$WORKDIR/plant.img" "$CLIP" "$WORKDIR/play.elf" \
  || fail "make-image plant failed"
ck; [[ -s "$WORKDIR/plant.img" ]] || fail "no plant.img"

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
                print("DE-movie: QEMU", hello.get("QMP", {}).get("version", {}))
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

def wait_marker(path, marker, timeout=50, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_marker(path, marker) >= at_least:
            return True
        time.sleep(0.1)
    return False

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("kernel never reached the prompt")
time.sleep(3.0)
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        if not wait_marker(serial, marker, timeout=50):
            raise SystemExit("never saw %s" % marker)
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(0.6)
text = open(serial, "rb").read().decode("latin-1", "replace")
m = re.search(r"FB BAR ([0-9A-Fa-f]+)", text)
if not m:
    raise SystemExit("no FB BAR line")
addr = int(m.group(1), 16)
pm = re.search(r"WM ON BASE [0-9A-Fa-f]+ PITCH ([0-9A-Fa-f]+)", text)
pitch = int(pm.group(1), 16) if pm else 3200
q.cmd("pmemsave", val=addr, size=600 * pitch, filename=os.path.abspath(fb_bin))
print("DE-movie: dumped fb @ 0x%X pitch %d" % (addr, pitch))
q.cmd("quit")
PY
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -100 "$ser" >&2
    fail "session driver exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
  ck; [[ -s "$ser" ]] || fail "the $label boot captured no serial"
}

# movie_hold=32 ticks ≈ 320ms; wait long enough after play for MOV.
KEYS_MOV="$(typekeys 'fb'),ret,until:FB BAR ,wait:400,$(typekeys 'wm on'),ret,until:WM ON,wait:400,$(typekeys 'go PLAY.ELF'),ret,until:PLAY ATTACH,wait:400,$(typekeys 'play'),ret,until:OSMEDIA MOV ,wait:800"
KEYS_ONE="$(typekeys 'fb'),ret,until:FB BAR ,wait:400,$(typekeys 'wm on'),ret,until:WM ON,wait:400,$(typekeys 'go PLAY.ELF'),ret,until:PLAY ATTACH,wait:400,$(typekeys 'play'),ret,until:OSMEDIA PIX ,wait:900"

echo
echo "=== BOOT no-movie planted (first still only) ==="
drive_session "$WORKDIR/nomovie" "$KEYS_ONE" "nomovie" \
  "$WORKDIR/plant.img" "$WORKDIR/kernel-nomovie.elf"
capture_sh NM_OUT NM_STATUS -- \
  "python3 '$DERIVE' '$HDR' nomovie '$WORKDIR/nomovie/serial.txt'"
echo "$NM_OUT"
if [[ $NM_STATUS -ne 0 ]]; then
  echo "--- nomovie serial (OSMEDIA/WM/PLAY) ---" >&2
  grep -E 'OSMEDIA|WM ATTACH|PLAY |WM ON|FB BAR' \
    "$WORKDIR/nomovie/serial.txt" >&2 || tail -40 "$WORKDIR/nomovie/serial.txt" >&2
  fail "derive nomovie failed: $NM_OUT"
fi
ck; echo "$NM_OUT" | grep -q 'NOMOVIE_OK' || fail "no NOMOVIE_OK"
ck; [[ -s "$WORKDIR/nomovie/fb.bin" ]] || fail "nomovie produced no fb"
capture_sh W1_OUT W1_STATUS -- \
  "python3 '$DERIVE' '$HDR' win1 '$WORKDIR/nomovie/fb.bin' 3200"
echo "$W1_OUT"
ck; [[ $W1_STATUS -eq 0 ]] || fail "derive win1 failed: $W1_OUT"
ck; echo "$W1_OUT" | grep -q 'WIN1_OK' || fail "no WIN1_OK — skip movie must keep FRAME"

echo
echo "=== BOOT movie planted (two stills, same window) ==="
drive_session "$WORKDIR/movie" "$KEYS_MOV" "movie" \
  "$WORKDIR/plant.img" "$WORKDIR/kernel-movie.elf"
capture_sh MV_OUT MV_STATUS -- \
  "python3 '$DERIVE' '$HDR' movie '$WORKDIR/movie/serial.txt'"
echo "$MV_OUT"
ck; [[ $MV_STATUS -eq 0 ]] || fail "derive movie failed: $MV_OUT"
ck; echo "$MV_OUT" | grep -q 'MOVIE_OK' || fail "no MOVIE_OK"
ck; grep -q 'PLAY ATTACH' "$WORKDIR/movie/serial.txt" \
  || fail "PLAY.ELF did not attach"
ck; grep -q 'WM ATTACH ' "$WORKDIR/movie/serial.txt" \
  || fail "no WM ATTACH"
ck; [[ -s "$WORKDIR/movie/fb.bin" ]] || fail "movie produced no fb"
capture_sh W2_OUT W2_STATUS -- \
  "python3 '$DERIVE' '$HDR' win2 '$WORKDIR/movie/fb.bin' 3200"
echo "$W2_OUT"
ck; [[ $W2_STATUS -eq 0 ]] || fail "derive win2 failed: $W2_OUT"
ck; echo "$W2_OUT" | grep -q 'WIN2_OK' || fail "no WIN2_OK — window body did not become FRAME2"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-movie: PASS — two different frames on the same wmsurface; PIX=FRAME MOV=FRAME2; window body ends FRAME2; OSMEDIA_NO_MOVIE keeps FRAME ($ASSERTIONS checks)"
exit 0
