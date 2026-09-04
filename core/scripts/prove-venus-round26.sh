#!/usr/bin/env bash
# Boot 1280×720 on user-local QEMU 9.2 + virgl Venus. Prove guest tokens.
# Does not call device-name availability "acceleration."
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
# Do not inherit tmux-root libncurses; it breaks this QEMU.
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
unset LD_PRELOAD
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

fail() { echo "prove-venus: FAIL — $*" >&2; exit 1; }
say() { echo "prove-venus: $*" >&2; }

[[ -x "$QEMU" ]] || fail "no venus qemu at $QEMU (run bootstrap-qemu-venus.sh)"
"$QEMU" -device virtio-gpu-gl-pci,help 2>&1 | grep -q 'venus' \
  || fail "qemu has no venus= property"

KERNEL="${KERNEL_ELF:-$CORE_DIR/build/kernel.elf}"
[[ -f "$KERNEL" ]] || fail "missing $KERNEL"
DISK_SRC="${DISK_IMG:-$CORE_DIR/build/disk.img}"
[[ -f "$DISK_SRC" ]] || fail "missing $DISK_SRC"

RUN="$CORE_DIR/build/prove-venus-r26"
mkdir -p "$RUN"
cp "$DISK_SRC" "$RUN/disk.img"
: >"$RUN/serial.txt"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
QMP=$(python3 "$PICKER")
echo "$QMP" >"$RUN/qmp.port"

# Prefer GTK+GLX (no DRM render node). Fall back to egl-headless.
DISPLAY_ARGS=(-display egl-headless)
if "$QEMU" -display help 2>&1 | grep -q '^gtk$'; then
  DISPLAY_ARGS=(-display gtk,gl=on)
fi
if [[ "${OSCORTEX_VENUS_HEADLESS:-0}" == "1" ]]; then
  DISPLAY_ARGS=(-display egl-headless)
fi

set +e
timeout 180 "$QEMU" \
  -name oscortex-prove-venus-r26 \
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
  say "serial tail:"
  tail -40 "$RUN/serial.txt" >&2 || true
  tail -40 "$RUN/qemu.log" >&2 || true
  kill "$QPID" 2>/dev/null || true
  python3 - "$ART/oscortex-round26-gpu.json" <<PY
import json,sys
json.dump({
  "round": 26, "ok": False, "venus_property": True,
  "guest_token": None, "why": "did not reach M1 END",
  "qemu": "$QEMU",
}, open(sys.argv[1],"w"), indent=2)
open(sys.argv[1],"a").write("\n")
PY
  fail "did not reach M1 END"
fi

python3 - "$QMP" <<'PY'
import json, socket, sys, time
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
for ch in "virtgpuv":
    key(ch)
    time.sleep(0.04)
key("ret")
time.sleep(0.2)
# Enable gfx path after Venus capset.
# G5 scanout so fbState is guest RAM + SET_SCANOUT (ADR-0064 fb
# still prints FB NONE first). Then wm can compose onto Venus.
for cmd in ("fb", "virtgpuc", "wm on", "wm gfx"):
    for ch in cmd:
        key("spc" if ch == " " else ch)
        time.sleep(0.04)
    key("ret")
    time.sleep(0.45)
# Screenshot
import os
png = os.environ.get("ART_PNG", "/opt/cursor/artifacts/oscortex-round26-gpu.png")
f.write(json.dumps({"execute": "screendump",
    "arguments": {"filename": png, "format": "png"}}) + "\n")
f.flush()
while True:
    line = f.readline()
    if not line:
        break
    obj = json.loads(line)
    if "return" in obj or "error" in obj:
        print("screendump", obj)
        break
PY

sleep 3
# Second shot after gfx
python3 - "$QMP" <<'PY'
import json, socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=5)
f = s.makefile("rw", encoding="utf-8")
json.loads(f.readline())
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
json.loads(f.readline())
png = "/opt/cursor/artifacts/oscortex-round26-gpu.png"
f.write(json.dumps({"execute": "screendump",
    "arguments": {"filename": png, "format": "png"}}) + "\n")
f.flush()
while True:
    obj = json.loads(f.readline())
    if "return" in obj or "error" in obj:
        print("screendump2", obj)
        break
PY

VENUS_OK=0
VENUS_NONE=0
GRAPHITE=0
grep -q 'VIRTIO VENUS OK' "$RUN/serial.txt" && VENUS_OK=1
grep -q 'VIRTIO VENUS NONE' "$RUN/serial.txt" && VENUS_NONE=1
grep -q 'OSGFX GRAPHITE OK' "$RUN/serial.txt" && GRAPHITE=1
grep -E 'VIRTIO|VENUS|GRAPHITE|VIRGL|OSGFX GFX' "$RUN/serial.txt" | tail -40 >&2 || true

python3 - "$ART/oscortex-round26-gpu.json" <<PY
import json, os, sys
out = {
  "round": 26,
  "qemu": "$QEMU",
  "qemu_version": "9.2.0",
  "virgl_tag": "virglrenderer-1.1.0",
  "venus_property": True,
  "resolution": "1280x720",
  "virtio_venus_ok": bool($VENUS_OK),
  "virtio_venus_none": bool($VENUS_NONE),
  "osgfx_graphite_ok": bool($GRAPHITE),
  "serial": "$RUN/serial.txt",
  "png": "$ART/oscortex-round26-gpu.png",
  "png_bytes": os.path.getsize("$ART/oscortex-round26-gpu.png") if os.path.isfile("$ART/oscortex-round26-gpu.png") else 0,
  "acceleration": bool($VENUS_OK),
  "note": "device property is not acceleration; guest token required",
}
open(sys.argv[1], "w").write(json.dumps(out, indent=2) + "\n")
print("wrote", sys.argv[1])
PY

kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
if [[ "$VENUS_OK" != 1 ]]; then
  fail "guest did not print VIRTIO VENUS OK (none=$VENUS_NONE graphite=$GRAPHITE)"
fi
say "PASS VIRTIO VENUS OK graphite=$GRAPHITE"
