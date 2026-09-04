#!/usr/bin/env bash
# Boot 1280×720 on user-local QEMU 9.2 + virgl Venus.
# fb arms SET_SCANOUT first; Venus reuses the same control queue.
# llvmpipe is functional proof only — host has no /dev/dri.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
ART="${ARTIFACTS_DIR:-/opt/cursor/artifacts}"
mkdir -p "$ART"
PREFIX="${OSCORTEX_QEMU_VENUS_PREFIX:-/tmp/oscortex-qemu-venus}"
if [[ ! -x "$PREFIX/bin/qemu-system-x86_64" ]]; then
  PREFIX="${OSCORTEX_QEMU_VENUS_PREFIX:-$REPO_DIR/.qemu-venus}"
fi
QEMU="$PREFIX/bin/qemu-system-x86_64"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
unset LD_PRELOAD
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

fail() { echo "prove-venus-r27: FAIL — $*" >&2; exit 1; }
say() { echo "prove-venus-r27: $*" >&2; }

[[ -x "$QEMU" ]] || fail "no venus qemu at $QEMU"
"$QEMU" -device virtio-gpu-gl-pci,help 2>&1 | grep -q 'venus' \
  || fail "qemu has no venus= property"

KERNEL="${KERNEL_ELF:-$CORE_DIR/build/kernel.elf}"
[[ -f "$KERNEL" ]] || fail "missing $KERNEL"
DISK_SRC="${DISK_IMG:-$CORE_DIR/build/disk.img}"
[[ -f "$DISK_SRC" ]] || fail "missing $DISK_SRC"

RUN="$CORE_DIR/build/prove-venus-r27"
mkdir -p "$RUN"
cp "$DISK_SRC" "$RUN/disk.img"
: >"$RUN/serial.txt"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
QMP=$(python3 "$PICKER")
echo "$QMP" >"$RUN/qmp.port"

# Host has no /dev/dri. egl-headless needs a render node and dies.
# GTK+llvmpipe is the functional Venus path.
DISPLAY_ARGS=(-display gtk,gl=on)
if [[ "${OSCORTEX_VENUS_HEADLESS:-0}" == "1" ]]; then
  DISPLAY_ARGS=(-display gtk,gl=on)
fi

set +e
timeout 180 "$QEMU" \
  -name oscortex-prove-venus-r27 \
  -kernel "$KERNEL" \
  -m 512M -cpu qemu64 \
  -vga none \
  -device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M,xres=1280,yres=720 \
  -drive "file=$RUN/disk.img,format=raw,if=ide,index=0,media=disk" \
  "${DISPLAY_ARGS[@]}" \
  -serial "file:$RUN/serial.txt" \
  -qmp "tcp:127.0.0.1:${QMP},server,nowait" \
  -no-reboot \
  >"$RUN/qemu.log" 2>&1 &
QPID=$!
set -e
echo "$QPID" >"$RUN/qemu.pid"
say "pid=$QPID qmp=$QMP qemu=$QEMU"

deadline=$((SECONDS + 90))
booted=0
while (( SECONDS < deadline )); do
  if grep -q 'M1 END' "$RUN/serial.txt" 2>/dev/null; then
    booted=1
    break
  fi
  if ! kill -0 "$QPID" 2>/dev/null; then
    say "qemu exited early"
    tail -40 "$RUN/qemu.log" >&2 || true
    break
  fi
  sleep 1
done
if [[ "$booted" != 1 ]]; then
  tail -40 "$RUN/serial.txt" >&2 || true
  tail -40 "$RUN/qemu.log" >&2 || true
  kill "$QPID" 2>/dev/null || true
  fail "did not reach M1 END"
fi

PNG="$ART/oscortex-round27-virtio-scanout.png"
ART_PNG="$PNG" python3 - "$QMP" <<'PY'
import json, os, socket, sys, time
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=5)
f = s.makefile("rw", encoding="utf-8")
json.loads(f.readline())
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
json.loads(f.readline())
def key(name):
    f.write(json.dumps({"execute": "send-key",
        "arguments": {"keys": [{"type": "qcode", "data": name}]}}) + "\n")
    f.flush()
    while True:
        obj = json.loads(f.readline())
        if "return" in obj or "error" in obj:
            break
# fb first: quiet SET_SCANOUT owner. Then Venus reuses the ring.
for cmd in ("fb", "virtgpuv", "wm on", "wm gfx", "wm de"):
    for ch in cmd:
        key("spc" if ch == " " else ch)
        time.sleep(0.04)
    key("ret")
    time.sleep(0.55 if cmd == "fb" else 0.35)
time.sleep(1.2)
png = os.environ.get("ART_PNG", "/opt/cursor/artifacts/oscortex-round27-virtio-scanout.png")
f.write(json.dumps({"execute": "screendump",
    "arguments": {"filename": png, "format": "png"}}) + "\n")
f.flush()
while True:
    obj = json.loads(f.readline())
    if "return" in obj or "error" in obj:
        print("screendump", obj)
        break
PY

sleep 2
VENUS_OK=0
VENUS_NONE=0
FB_VIRTIO=0
QTIMEOUT=0
GRAPHITE=0
grep -q 'VIRTIO VENUS OK' "$RUN/serial.txt" && VENUS_OK=1
grep -q 'VIRTIO VENUS NONE' "$RUN/serial.txt" && VENUS_NONE=1
grep -q 'FB VIRTIO ' "$RUN/serial.txt" && FB_VIRTIO=1
grep -q 'VIRTIO QTIMEOUT' "$RUN/serial.txt" && QTIMEOUT=1
grep -q 'OSGFX GRAPHITE OK' "$RUN/serial.txt" && GRAPHITE=1
grep -E 'FB |VIRTIO|VENUS|GRAPHITE|QTIMEOUT|WM DE|WM GFX' "$RUN/serial.txt" | tail -50 >&2 || true

python3 - "$PNG" "$ART/oscortex-round27-device-queue.json" <<PY
import json, os, struct, sys
png = sys.argv[1]
w = h = 0
if os.path.isfile(png):
    with open(png, "rb") as f:
        sig = f.read(8)
        if sig == b"\x89PNG\r\n\x1a\n":
            f.read(4)
            if f.read(4) == b"IHDR":
                w, h = struct.unpack(">II", f.read(8))
out = {
  "round": 27,
  "qemu": "$QEMU",
  "qemu_version": "9.2.0",
  "host_drm": os.path.exists("/dev/dri"),
  "renderer": "llvmpipe",
  "acceleration": False,
  "acceleration_note": "no /dev/dri; llvmpipe is functional Venus proof only",
  "queue_owner": "single virtio-gpu control queue; skip reset when DRIVER_OK; used.idx >= want",
  "fb_virtio": bool($FB_VIRTIO),
  "virtio_venus_ok": bool($VENUS_OK),
  "virtio_venus_none": bool($VENUS_NONE),
  "qtimeout": bool($QTIMEOUT),
  "osgfx_graphite_ok": bool($GRAPHITE),
  "png": png,
  "png_w": w,
  "png_h": h,
  "png_bytes": os.path.getsize(png) if os.path.isfile(png) else 0,
  "serial": "$RUN/serial.txt",
}
open(sys.argv[2], "w").write(json.dumps(out, indent=2) + "\n")
print("png", w, "x", h, "bytes", out["png_bytes"])
print("wrote", sys.argv[2])
if w != 1280 or h != 720:
    raise SystemExit("scanout png is %dx%d, want 1280x720" % (w, h))
PY

kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
if [[ "$QTIMEOUT" == 1 ]]; then
  fail "VIRTIO QTIMEOUT after fb+Venus"
fi
if [[ "$FB_VIRTIO" != 1 ]]; then
  fail "fb did not print FB VIRTIO"
fi
if [[ "$VENUS_OK" != 1 ]]; then
  fail "guest did not print VIRTIO VENUS OK (none=$VENUS_NONE)"
fi
say "PASS FB VIRTIO + VIRTIO VENUS OK + 1280 scanout + no QTIMEOUT"
