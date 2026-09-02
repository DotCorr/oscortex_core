#!/usr/bin/env bash
# ADR-0187 second capture: the same session chrome de-skia-text/run.sh asserts
# at 800x600 on -vga std, but on the Venus / Graphite scanout instead. What it
# adds over run.sh is that the outline text and the AA rrects survive a path
# where Graphite is armed and the compose target is a virtio-gpu resource
# backing rather than a Bochs aperture -- OSGFX SKIA OPS OK 16, no fault.
#
# This is also the GAP-0328 door (ADR-0189). `-display gtk,gl=on` is the
# frontend that pins GET_DISPLAY_INFO to the 640x480 placeholder console no
# matter what `xres=`/`yres=` say, so it is the hostile case: if the driver's
# mode floor holds here it holds anywhere. The asserts below therefore expect
# VIRTIO SCAN to stay small (it is the device's readback, not a mode) while
# VIRTIO MODE -- what the driver sized the backing for and drove SET_SCANOUT
# at -- is 1280x720. The geometry is taken from VIRTIO MODE, never assumed.
#
# The framebuffer is read with QMP pmemsave rather than screendump, because
# the Venus screendump path is the GAP-0325 flake. pmemsave's filename is
# resolved by QEMU *inside* the container, hence --fb-qemu-dir /work: QEMU
# writes /work/<name>.bin, we read the same file on our side of the mount.
#
# Runs its own UNIQUELY NAMED container and removes only that one. It must
# never touch oscortex-interactive-door.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$HERE/../../.." && pwd)"
SIT="$CORE_DIR/tests/conformance/d3-session"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
KERNEL_ELF="$CORE_DIR/build/kernel.elf"

XRES=1200
YRES=720
W="$CORE_DIR/build/de-skia-text/shot-venus"
OUT="$W/de-chrome-venus.png"
NAME=""

# Only ever removes the container this script named. oscortex-interactive-door
# must survive; nothing here may filter by image ancestor.
RUN=""
cleanup() {
  [[ -n "$NAME" ]] && docker rm -f "$NAME" >/dev/null 2>&1
  [[ -n "$RUN" ]] && rm -rf "$RUN"
  true
}
trap cleanup EXIT
die() { echo "shot-venus: FAIL — $*" >&2; exit 1; }

[[ -f "$KERNEL_ELF" ]] || die "no kernel.elf; build first"
docker image inspect oscortex-qemu-gl:local >/dev/null 2>&1 \
  || die "oscortex-qemu-gl:local missing; run build-qemu-gl.sh"

# The container's mount source is a mktemp dir under TMPDIR, not a directory
# in the repo. Docker Desktop shares TMPDIR (/private/var/folders/...) by
# default; a repo path under /private/tmp mounts and reads fine but the
# container's qemu then parks in xvfb-run without ever writing serial, which
# is indistinguishable from "the kernel never booted". de-session's Venus
# block boots reliably from TMPDIR, so this copies that.
mkdir -p "$W"
RUN="$(mktemp -d -t oscortex-skia-shot)" || die "mktemp failed"
bash "$SIT/build-progs.sh" "$RUN" "$CORE_DIR/kernel" >/dev/null \
  || die "d3-session clients failed to build"
python3 "$SIT/make-image.py" "$RUN/disk.img" \
  "$RUN/progA.elf" "$RUN/progB.elf" --json >"$RUN/layout.json" \
  || die "make-image.py failed"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$RUN/layout.json" "$1"; }
LBA_A=$(lba_of A)
LBA_B=$(lba_of B)

typekeys() { python3 -c "
import sys
print(','.join({' ':'spc'}.get(c, c.lower()) for c in sys.argv[1]))
" "$1"; }

SER="$RUN/serial.txt"

# Xvfb is started by hand rather than through `xvfb-run -a`. Measured: with
# another oscortex-qemu-gl container already holding a display, `xvfb-run -a`
# parks after spawning Xvfb and never execs qemu -- `ps` in the container
# shows Xvfb but no qemu-system-x86_64, serial stays empty, and stdout stays
# empty, which is indistinguishable from "the kernel never booted". Naming the
# display explicitly boots first time. `-display egl-headless` is not an
# option here: no DRM render node in the container.
#
# The retry is kept because Venus init itself is the GAP-0325 flake.
booted=0
for attempt in 1 2 3; do
  NAME="oscortex-skia-shot-$$-$attempt"
  : >"$SER"; : >"$RUN/qemu.log"
  PORT=$(python3 "$PICKER") || die "no free QMP port"
  echo "shot-venus: attempt $attempt — ${XRES}x${YRES}, port $PORT, $NAME"
  timeout 600 docker run --rm --name "$NAME" \
    -v "$KERNEL_ELF:/kernel.elf:ro" \
    -v "$RUN:/work" \
    -p "127.0.0.1:${PORT}:${PORT}" \
    -e LIBGL_ALWAYS_SOFTWARE=1 \
    -e GALLIUM_DRIVER=llvmpipe \
    -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
    oscortex-qemu-gl:local \
    bash -c "Xvfb :77 -screen 0 1600x1200x24 -nolisten tcp \
>/tmp/xvfb.log 2>&1 & sleep 4; export DISPLAY=:77; \
qemu-system-x86_64 -kernel /kernel.elf -m 512M \
-cpu qemu64 -vga none \
-device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M,xres=${XRES},yres=${YRES} \
-drive file=/work/disk.img,format=raw,if=ide,index=0,media=disk \
-display gtk,gl=on -serial file:/work/serial.txt \
-qmp tcp:0.0.0.0:${PORT},server,nowait -no-reboot" \
    >"$RUN/qemu.log" 2>&1 &
  QEMU_PID=$!
  waited=0
  while [[ $waited -lt 200 ]]; do
    grep -q 'M1 END' "$SER" 2>/dev/null && { booted=1; break; }
    sleep 2
    waited=$((waited + 2))
  done
  [[ $booted -eq 1 ]] && { echo "shot-venus: M1 END after ${waited}s"; break; }
  echo "shot-venus: attempt $attempt never reached M1 END; retrying" >&2
  docker exec "$NAME" bash -c 'ps -eo args | grep -c "[q]emu-system"' \
    2>/dev/null | sed 's/^/    qemu procs in container: /' >&2
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  wait "$QEMU_PID" 2>/dev/null
done
[[ $booted -eq 1 ]] || {
  echo "--- qemu.log ---" >&2; cat "$RUN/qemu.log" >&2
  echo "--- serial ---" >&2; cat "$SER" >&2
  die "Venus never reached M1 END in 3 attempts"
}

# Order matters and is the door's, not de-session's. `virtgpuv` arms Venus but
# leaves no scanout, so `wm on` before `virtgpuk` prints FB NONE, the
# compositor stays off, and every client is refused wmRetOff -- which is what
# de-session's Venus block quietly lives with, because it only asserts serial
# markers. `virtgpuk` publishes the GL scanout aperture; `wm on` then finds it.
K="$(typekeys 'virtgpuv'),ret,wait:6000"
K="$K,$(typekeys 'wm gfx'),ret,wait:26000"
K="$K,$(typekeys 'virtgpuk'),ret,wait:18000"
K="$K,$(typekeys 'wm on'),ret,wait:2500"
K="$K,$(typekeys 'wm de'),ret,wait:1500"
K="$K,$(typekeys "proc spawn $LBA_A"),ret,until:D3S COMMIT,wait:2000"
K="$K,$(typekeys "proc spawn $LBA_B"),ret,until:D3S COMMIT,wait:4000"

python3 "$HERE/probe-run.py" "$PORT" "$SER" "$K" \
  --fb-png "$RUN/fb.png" --size "${XRES}x${YRES}" --fb-qemu-dir /work
rc=$?
docker rm -f "$NAME" >/dev/null 2>&1 || true
wait "$QEMU_PID" 2>/dev/null

cp "$SER" "$W/serial.txt" 2>/dev/null
[[ $rc -eq 0 ]] || die "probe-run exited $rc"
[[ -s "$RUN/fb.png" ]] || die "no PNG written (serial kept at $W/serial.txt)"
cp "$RUN/fb.png" "$OUT"

grep -q 'VIRTIO VENUS OK' "$SER" || die "Venus never armed"
grep -q 'OSGFX GRAPHITE OK' "$SER" || die "Graphite never made a context"
grep -q 'OSGFX SESSION CHROME' "$SER" || die "session chrome never painted"
grep -q 'OSGFX SKIA OPS OK 16' "$SER" \
  || die "not all 16 Skia raster ops completed on the Venus path"
grep -q 'OSGFX TEXT OUTLINE PROPORTIONAL' "$SER" \
  || die "advance is a fixed cell on the Venus path"
grep -q 'OSGFX PAINT STACK OVERFLOW' "$SER" \
  && die "paint stack guard breached on the Venus path"
# `M1 FAULT 06` is the boot-time #UD control line and must be excluded; a
# real regression here is the ADR-0187 #GP, i.e. FAULT 0D / 0E.
grep -qE 'FAULT (0D|0E)' "$SER" && die "a #GP or #PF appeared"
# The clients must actually be on screen: `wm on` before `virtgpuk` leaves the
# compositor off and refuses them, which would give a windowless picture that
# still passed every serial check above.
[[ $(grep -c 'D3S COMMIT' "$SER") -ge 2 ]] \
  || die "the two demo clients never committed a frame"
grep -q 'WM REFUSE' "$SER" && die "a client was refused by the compositor"

# GAP-0328 / ADR-0189. gtk,gl=on answers GET_DISPLAY_INFO with the placeholder
# console, so VIRTIO SCAN here is the small hint and must stay a readback. The
# rung is that the DRIVER picked the mode anyway: 1280x720 = 0x500 x 0x2D0,
# floored (src 1), and the compose pitch that follows from it is 0x1400.
grep -qE '^VIRTIO MODE 00000500 000002D0 00000001$' "$SER" \
  || die "VIRTIO MODE is not a floored 1280x720: $(grep -a 'VIRTIO MODE' "$SER" | tr -d '\r')"
grep -qE '^WM ON BASE [0-9A-F]+ PITCH 00001400' "$SER" \
  || die "compose pitch is not 1280*4: $(grep -a 'WM ON BASE' "$SER" | tr -d '\r')"

grep -E 'VIRTIO SCAN|VIRTIO MODE|VIRTIO VENUS OK|OSGFX GRAPHITE OK|OSGFX SKIA OPS OK|OSGFX TEXT|OSGFX PAINT STACK HI|WM ON BASE|WM DE ON' \
  "$SER" | sort -u | sed 's/^/    /'
cp "$OUT" "$CORE_DIR/build/de-chrome-venus.png"
echo "shot-venus: PASS — $CORE_DIR/build/de-chrome-venus.png"
echo "shot-venus: note — VIRTIO SCAN above is the device's GET_DISPLAY_INFO"
echo "            hint, which gtk,gl=on pins to the placeholder console. The"
echo "            live area is VIRTIO MODE 1280x720, which the driver drove"
echo "            SET_SCANOUT at regardless (GAP-0328 closed by ADR-0189)."
