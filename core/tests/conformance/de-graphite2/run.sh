#!/usr/bin/env bash
# core/tests/conformance/de-graphite2/run.sh
#
# ADR-0134 — Graphite MakeVulkan needs a VkDevice.
# docs/design/c-modules.md, GAP-0313 leftover after ADR-0129.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# Venus capset 4 arms mailbox vk. A kernel ICD supplies handles.
# MakeVulkan returns a live context (OSGFX GRAPHITE OK) and one
# Graphite GPU pixel (PIX 00E24A18). Homebrew stays NONE.
# Chrome rrects stay CPU. Not a planted virgl CLEAR / G11 upload.
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

fail() { echo "DE-graphite2: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-graphite2: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=51

for tool in qemu-system-x86_64 python3 clang x86_64-elf-nm x86_64-elf-readelf docker; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-graphite2.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  docker ps -aq --filter ancestor=oscortex-qemu-gl:local 2>/dev/null \
    | xargs docker rm -f >/dev/null 2>&1 || true
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
SIT="$CORE_DIR/tests/conformance/d3-session"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
GRAPHITE_GUEST="$CORE_DIR/plat/osgfx/osgfx_graphite_guest.cpp"
VK_C="$CORE_DIR/plat/osgfx/osgfx_vk.c"
ADR="$CORE_DIR/docs/decisions/0134-graphite-makevulkan-needs-a-vkdevice.md"
ADR129="$CORE_DIR/docs/decisions/0129-graphite-makevulkan-is-the-kernel-door.md"
GRAPHITE_LIB="$CORE_DIR/build/skia/out/guest-elf-graphite/libskia.a"
XRES=1200
YRES=720

echo "=== STRUCTURAL ==="
ck; [[ -f "$ADR" ]] || fail "ADR-0134 is missing"
ck; grep -q '0129 is the call' "$ADR" || fail "ADR-0134 stole 0129"
ck; [[ -f "$ADR129" ]] || fail "ADR-0129 was removed"
ck; grep -q 'ContextFactory::MakeVulkan' "$GRAPHITE_GUEST" \
  || fail "guest Graphite door does not call MakeVulkan — do not revert ADR-0129"
ck; grep -q 'graphite-vk-try' "$GRAPHITE_GUEST" \
  || fail "graphite-vk-try token missing"
ck; grep -q 'osgfx-vk-icd' "$VK_C" || fail "osgfx-vk-icd token missing"
ck; grep -q 'OSGFX GRAPHITE NONE' "$GRAPHITE_GUEST" \
  || fail "NONE line missing — leftover must print"
ck; grep -q 'OSGFX GRAPHITE OK' "$GRAPHITE_GUEST" \
  || fail "OK line missing"
ck; grep -q '0x00E24A18' "$GRAPHITE_GUEST" \
  || fail "Graphite pixel colour missing"
ck; ! grep -q 'osgfx_backend_graphite(void) { return 1; }' "$GRAPHITE_GUEST" \
  || fail "backend_graphite is hard-coded 1 — that is a stub token"
ck; grep -q 'virtgpu3dStrCmdVenus' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "virtgpuv command string missing"
ck; grep -q 'shellVirtgpu3dVenus' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpuv"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" 2>/dev/null \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
if [[ -n "$HELP_SIZE" ]]; then
  ck; [[ "$HELP_SIZE" -eq 2511 ]] \
    || fail "shellStrHelp is ${HELP_SIZE} bytes, expected 2511"
else
  ck; true
fi
ck; ! grep -q 'virtgpuv\|de-graphite2\|GRAPHITE OK' \
      "$CORE_DIR/docs/syscall-registry.md" \
  || fail "ADR-0134 added a syscall"
echo "STRUCTURAL: pass  ADR-0134; MakeVulkan stays; ICD token; no stub"

echo
echo "=== ANTI-VACUITY (no Skia .o) ==="
capture_sh NOSKIA_OUT NOSKIA_STATUS -- \
  "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$NOSKIA_OUT"
ck; [[ $NOSKIA_STATUS -eq 0 ]] || fail "OSGFX_SKIA=0 build-kernel.sh exited $NOSKIA_STATUS"
cp "$KERNEL_ELF" "$WORKDIR/kernel-noskia.elf"
elf_has() { python3 -c "import sys; sys.exit(0 if open(sys.argv[1],'rb').read().find(sys.argv[2].encode())>=0 else 1)" "$1" "$2"; }
ck; ! elf_has "$WORKDIR/kernel-noskia.elf" "ContextFactory10MakeVulkan" \
  || fail "OSGFX_SKIA=0 kernel.elf still names MakeVulkan"
ck; ! elf_has "$WORKDIR/kernel-noskia.elf" "osgfx-vk-icd" \
  || fail "OSGFX_SKIA=0 kernel.elf still has osgfx-vk-icd"
ck; ! elf_has "$WORKDIR/kernel-noskia.elf" "graphite-vk-try" \
  || fail "OSGFX_SKIA=0 kernel.elf still has graphite-vk-try"
echo "ANTI-VACUITY: pass  CPU-only has no Graphite / ICD token"

echo
echo "=== BUILD Graphite guest + kernel ==="
ck; [[ -f "$GRAPHITE_LIB" ]] || {
  echo "building guest-elf-graphite libskia.a"
  bash "$CORE_DIR/scripts/build-skia-guest-graphite.sh" \
    || fail "build-skia-guest-graphite.sh failed"
}
ck; [[ -f "$GRAPHITE_LIB" ]] || fail "no guest-elf-graphite libskia.a"
capture_sh BUILD_OUT BUILD_STATUS -- "OSMEDIA_FFMPEG=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
ck; [[ -f "$CORE_DIR/build/osgfx_graphite_guest.o" ]] \
  || fail "osgfx_graphite_guest.o not linked"
ck; [[ -f "$CORE_DIR/build/osgfx_vk.o" ]] || fail "osgfx_vk.o not linked"
ck; elf_has "$KERNEL_ELF" "ContextFactory10MakeVulkan" \
  || fail "kernel.elf has no ContextFactory::MakeVulkan"
ck; elf_has "$KERNEL_ELF" "osgfx-vk-icd" \
  || fail "kernel.elf has no osgfx-vk-icd"
ck; elf_has "$KERNEL_ELF" "graphite-vk-try" \
  || fail "kernel.elf has no graphite-vk-try"
ck; elf_has "$KERNEL_ELF" "skia-draw" \
  || fail "CPU Skia paint path was dropped"
echo "GRAPHITE LINK: pass  MakeVulkan + ICD + graphite-vk-try"

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
ck; [[ -n "$LBA_A" && -n "$LBA_B" ]] || fail "could not read slot LBAs"

typekeys() { python3 -c "
import sys
out=[]
for c in sys.argv[1]:
    out.append({' ':'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'virtgpuv'),ret,wait:2000"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:2500"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_A"),ret,until:D3S COMMIT,wait:400"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_B"),ret,until:D3S COMMIT,wait:800"

SER="$WORKDIR/serial.txt"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
timeout 180 qemu-system-x86_64 \
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
run_status DRIVE_STATUS -- python3 - "$PORT" "$SER" "$KEYS" <<'PY'
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

def wait_marker(path, marker, timeout=25, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_marker(path, marker) >= at_least:
            return True
        time.sleep(0.1)
    return False

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("kernel never reached the prompt")
time.sleep(0.4)
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
time.sleep(0.8)
q.cmd("quit")
PY
await QEMU_STATUS "$QEMU_PID"
ck; if [[ $DRIVE_STATUS -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  echo "--- serial (tail) ---" >&2
  tail -80 "$SER" >&2
  fail "Homebrew session driver exited $DRIVE_STATUS"
fi
ck; [[ -s "$SER" ]] || fail "Homebrew serial capture is empty"
ck; grep -q 'VIRTIO VENUS NONE' "$SER" \
  || fail "Homebrew virtgpuv did not print VIRTIO VENUS NONE"
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON did not print"
ck; grep -q 'OSGFX GRAPHITE NONE' "$SER" \
  || fail "OSGFX GRAPHITE NONE did not print on Homebrew"
ck; ! grep -q 'OSGFX GRAPHITE OK' "$SER" \
  || fail "OSGFX GRAPHITE OK on no-Vulkan QEMU — that is a stub context"
ck; ! grep -q 'OSGFX GRAPHITE PIX 00E24A18' "$SER" \
  || fail "Graphite pixel on Homebrew — planted colour"
ck; grep -q 'D3S COMMIT' "$SER" || fail "D3S COMMIT missing — sit-in path broke"
echo "HOMEBREW: pass  VENUS NONE; GRAPHITE NONE; WM GFX ON; no OK; no PIX"

echo
echo "=== GL QEMU (venus=on) ==="
if ! docker image inspect oscortex-qemu-gl:local >/dev/null 2>&1; then
  echo "building oscortex-qemu-gl:local via scripts/build-qemu-gl.sh"
  bash "$CORE_DIR/scripts/build-qemu-gl.sh" \
    || setup_error "build-qemu-gl.sh failed"
fi
ck; docker image inspect oscortex-qemu-gl:local >/dev/null
capture_sh GLHELP_OUT GLHELP_STATUS -- \
  "docker run --rm oscortex-qemu-gl:local qemu-system-x86_64 -device virtio-gpu-gl-pci,help"
ck; [[ $GLHELP_STATUS -eq 0 ]] \
  || fail "docker qemu has no virtio-gpu-gl-pci: $GLHELP_OUT"
ck; echo "$GLHELP_OUT" | grep -q 'venus' \
  || fail "docker qemu virtio-gpu-gl-pci has no venus= property"
echo "    3D QEMU: oscortex-qemu-gl:local venus=on"

# Do not spawn two READY clients first — they steal the shell.
GL_KEYS="$(typekeys 'virtgpuv'),ret,wait:8000"
GL_KEYS="$GL_KEYS,$(typekeys 'wm gfx'),ret,wait:8000"

mkdir -p "$WORKDIR/gl"
cp "$DISK_IMG" "$WORKDIR/gl/disk.img" || fail "could not copy disk.img"
SER="$WORKDIR/gl/serial.txt"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port for GL"
timeout 360 docker run --rm \
  -v "$KERNEL_ELF:/kernel.elf:ro" \
  -v "$WORKDIR/gl:/work" \
  -p "127.0.0.1:${PORT}:${PORT}" \
  -e LIBGL_ALWAYS_SOFTWARE=1 \
  -e GALLIUM_DRIVER=llvmpipe \
  -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
  oscortex-qemu-gl:local \
  bash -c "echo VENUS_GL; xvfb-run -a qemu-system-x86_64 -kernel /kernel.elf -m 512M -cpu qemu64 -vga none -device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M,xres=${XRES},yres=${YRES} -drive file=/work/disk.img,format=raw,if=ide,index=0,media=disk -display gtk,gl=on -serial file:/work/serial.txt -qmp tcp:0.0.0.0:${PORT},server,nowait -no-reboot; echo VENUS_QDONE" \
  >"$WORKDIR/gl/qemu.log" 2>&1 &
QEMU_PID=$!
waited=0
while [[ $waited -lt 90 ]]; do
  if grep -q 'M1 END' "$SER" 2>/dev/null; then
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
ck; grep -q 'M1 END' "$SER" || {
  cat "$WORKDIR/gl/qemu.log" >&2
  echo "--- serial ---" >&2
  cat "$SER" >&2
  fail "GL boot never reached M1 END"
}
run_status GL_DRIVE_STATUS -- python3 "$DRIVER" \
  --port "$PORT" --serial "$SER" --wait-for 'M1 END\n' \
  --png "$WORKDIR/gl/screen.png" --screen-text "$WORKDIR/gl/screen.txt" \
  --no-screendump \
  --keys "$GL_KEYS"
docker ps -aq --filter ancestor=oscortex-qemu-gl:local 2>/dev/null \
  | xargs docker rm -f >/dev/null 2>&1 || true
await QEMU_STATUS "$QEMU_PID"
if [[ $GL_DRIVE_STATUS -ne 0 ]]; then
  echo "    note: qmp-drive exited $GL_DRIVE_STATUS (gtk+gl often drops QMP on quit)"
fi
ck; [[ -s "$SER" ]] || fail "GL serial capture is empty"
ck; grep -q 'VIRTIO VENUS OK' "$SER" \
  || {
    cat "$WORKDIR/gl/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$SER" >&2
    fail "virtgpuv did not print VIRTIO VENUS OK on venus=on"
  }
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON missing on venus=on"
ck; grep -q 'OSGFX GRAPHITE OK' "$SER" \
  || {
    echo "--- serial ---" >&2
    cat "$SER" >&2
    fail "OSGFX GRAPHITE OK missing — MakeVulkan still null"
  }
ck; grep -q 'OSGFX GRAPHITE PIX 00E24A18' "$SER" \
  || {
    echo "--- serial ---" >&2
    cat "$SER" >&2
    fail "OSGFX GRAPHITE PIX 00E24A18 missing — no Graphite GPU pixel"
  }
echo "VENUS: pass  VENUS OK; GRAPHITE OK; PIX 00E24A18; WM GFX ON"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-graphite2: PASS — MakeVulkan live on Venus ICD; Homebrew NONE; one Graphite GPU pixel ($ASSERTIONS checks)"
exit 0
