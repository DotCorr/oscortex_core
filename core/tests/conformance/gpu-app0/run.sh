#!/usr/bin/env bash
# core/tests/conformance/gpu-app0/run.sh
#
# G12 — explicit app GPU (osgpu.h). docs/design/gpu.md, ADR-0114.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# Two uses: UI / osgfx / wm never include osgpu.h. Games call
# osgpu_create / osgpu_submit / osgpu_readback. Hidden `osgpug`
# hits G10 virgl (CLEAR + TRANSFER_FROM_HOST_3D). The printed
# OSGPU PIX is device-written (alpha or colour ≠ CPU blit).
#
# Positive boot uses Docker oscortex-qemu-gl:local (same as G10).
# Negative: no 3D device → OSGPU NONE; wm gfx still ON.
# Anti-vacuity: virtgpuc (G5) must not print OSGPU OK.
# No syscall. 11 stays fdwait. No help line.
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

fail() { echo "gpu-app0: FAIL — $1" >&2; exit 1; }
setup_error() { echo "gpu-app0: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run (61 checks executed).
ASSERTIONS_REQUIRED=61

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-ld docker clang nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$CORE_DIR/build/gpu-app0-run"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR" || setup_error "could not create $WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  docker ps -aq --filter ancestor=oscortex-qemu-gl:local 2>/dev/null | xargs docker rm -f >/dev/null 2>&1 || true
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
HDR="$CORE_DIR/user/gpu/osgpu.h"
SRC="$CORE_DIR/user/gpu/osgpu.c"
APP="$CORE_DIR/user/gpu/gpuapp.c"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

# Not G10 1056×752, not G11 1136×816, not 800×600.
XRES=1008
YRES=720

echo "=== BUILD ==="
# OSGFX_SKIA=0: G12 is osgpu + G10 virgl, not guest Skia. The Skia
# CRT is a sibling file this rung must not rewrite.
capture_sh BUILD_OUT BUILD_STATUS -- "OSGFX_SKIA=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="
ck; [[ -f "$CORE_DIR/docs/decisions/0114-osgpu-is-the-explicit-app-gpu.md" ]] \
  || fail "ADR-0114 is missing"
ck; [[ -f "$HDR" ]] || fail "osgpu.h is missing"
ck; [[ -f "$SRC" ]] || fail "osgpu.c is missing"
ck; [[ -f "$APP" ]] || fail "gpuapp.c is missing"
ck; grep -q 'osgpu_create' "$HDR" || fail "osgpu.h has no osgpu_create"
ck; grep -q 'osgpu_submit' "$HDR" || fail "osgpu.h has no osgpu_submit"
ck; grep -q 'osgpu_readback' "$HDR" || fail "osgpu.h has no osgpu_readback"
ck; grep -q 'OSGPU_KIND_CLEAR' "$HDR" || fail "osgpu.h has no CLEAR kind"
ck; grep -q 'OSGPU_KIND_TRIANGLE' "$HDR" || fail "osgpu.h has no TRIANGLE kind"
ck; grep -q '#include "osgpu.h"' "$APP" || fail "gpuapp.c does not include osgpu.h"
ck; ! grep -q '#include.*"osgfx.h"' "$APP" || fail "gpuapp.c includes osgfx.h — UI is implicit"
ck; ! grep -q 'osgpu.h\|osgpu_' "$CORE_DIR/kernel/wm.dart" \
  || fail "wm.dart calls osgpu — UI must not pick"
ck; ! grep -q 'osgpu.h\|osgpu_' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "wmgfx.dart calls osgpu — implicit path must not"
ck; ! grep -q 'osgpu.h\|osgpu_' "$CORE_DIR/plat/osgfx/osgfx_sw.c" \
  || fail "osgfx_sw.c includes osgpu — do not rewrite the Skia agent file"
ck; ! grep -q 'osgpu.h\|osgpu_' "$CORE_DIR/plat/osxui/osxui.c" \
  || fail "osxui.c calls osgpu — widgets are implicit"
ck; grep -q 'shellOsgpu' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch osgpug"
ck; grep -q 'void shellOsgpu(' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "shellOsgpu is missing"
ck; grep -q 'void virtgpu3dGoApp(' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "virtgpu3dGoApp is missing — osgpug must call G10"
ck; grep -q 'virtgpu3dCcmdClear' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "G10 CLEAR opcode was removed"
ck; grep -q 'void shellVirtgpu3d(' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "shellVirtgpu3d was removed — do not rewrite G10"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "virtgpu3d.dart declares @bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
ck; ! grep -q 'osgpu\|osgpug\|gpu-app0\|SYS_OSGPU' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G12 added a syscall — prefer the hidden command"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
# This used to be an allow-list of file NAMES for the last part, which every
# newly added part broke on sight without anything having actually moved
# (ADR-0145's virtnet.dart, then virtab.dart, are the ones that broke it). The
# property it was proxying for is that NOTHING lands in .bss after
# wmevent.dart's block: every harness that measures "from my block to the end
# of .bss" depends on it. Assert that property directly, from the source side,
# so it holds for any part list.
LAST_BSS_PART=$(grep -E "^part '" "$CORE_DIR/kernel/kmain.dart" \
  | sed -E "s/^part '(.*)';/\\1/" \
  | while read -r p; do grep -q '^@bss' "$CORE_DIR/kernel/$p" && echo "$p"; done \
  | tail -1)
ck; [[ "$LAST_BSS_PART" == "wmevent.dart" ]] \
  || fail "the last part that declares @bss is ${LAST_BSS_PART:-none}, expected wmevent.dart — a part after it now owns mutable static storage, so wmeventStore is no longer the last block in .bss and every harness that measures to the end of .bss has silently moved"
ck; python3 - "$CORE_DIR/kernel/virtgpu3d.dart" <<'PY' || fail "virtgpu3dInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpu3dInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpu3dInit missing", file=sys.stderr); sys.exit(1)
if m.group(1).strip():
    print("virtgpu3dInit is not empty", file=sys.stderr); sys.exit(1)
PY
ck; ! grep -qE '0x80FF0000|0x80ff0000|0xFF8C2030|0xff8c2030' \
      "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "result dword is stored in virtgpu3d.dart — that is a CPU paint"
ck; ! grep -q "$XRES" "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "derived xres $XRES appears in virtgpu3d.dart"
ck; grep -q 'GPU is used two ways' \
      "$CORE_DIR/../.cursor/skills/plug-the-os/SKILL.md" \
  || fail "plug-the-os is missing the two-level GPU rule"
ck; grep -q 'Two uses. Do not mix them' "$CORE_DIR/docs/design/gpu.md" \
  || fail "gpu.md is missing the two-level rule"
ck; grep -q 'Games call osgpu' "$CORE_DIR/docs/design/gpu.md" \
  || fail "gpu.md does not say games call osgpu"
capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"

echo
echo "=== C ABI ==="
CFLAGS=(
  -c
  -target x86_64-unknown-none-elf
  -ffreestanding
  -nostdlib
  -fno-pic
  -fno-pie
  -mno-red-zone
  -fno-stack-protector
  -fno-asynchronous-unwind-tables
  -fno-builtin
  -O2
  -Wall
  -Wextra
  -Werror
  -I"$CORE_DIR/user/gpu"
)
ck; clang "${CFLAGS[@]}" "$SRC" -o "$WORKDIR/osgpu.o" \
  || fail "osgpu.c did not compile for the kernel triple"
ck; clang "${CFLAGS[@]}" "$APP" -o "$WORKDIR/gpuapp.o" \
  || fail "gpuapp.c did not compile for the kernel triple"
ck; x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$WORKDIR/gpuapp.elf" "$WORKDIR/gpuapp.o" "$WORKDIR/osgpu.o" \
  || fail "could not link GPUAPP.ELF"
ck; [[ -s "$WORKDIR/gpuapp.elf" ]] || fail "GPUAPP.ELF is empty"
ck; nm "$WORKDIR/osgpu.o" | grep -q 'osgpu_create' \
  || fail "osgpu.o has no osgpu_create"
ck; nm "$WORKDIR/osgpu.o" | grep -q 'osgpu_submit' \
  || fail "osgpu.o has no osgpu_submit"
ck; nm "$WORKDIR/osgpu.o" | grep -q 'osgpu_readback' \
  || fail "osgpu.o has no osgpu_readback"
ck; ! grep -q '#define SYS_OSGPU\|#define SYS_.*[^0-9]11' "$APP" "$SRC" "$HDR" \
  || fail "osgpu invented a syscall number"
echo "STRUCTURAL: pass  osgpu.h create/submit/readback; hidden osgpug; no syscall; UI does not call"

typekeys() { python3 -c "
import sys
out=[]
for c in sys.argv[1]:
    out.append({' ':'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_host() {
  local outdir="$1" label="$2" keys="$3"
  shift 3
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 240 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    "$@" \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for 'M1 END\n' \
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt" \
    --monitor-command 'info pci' --monitor-capture "$outdir/info-pci.txt" \
    --keys "$keys"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
}

echo
echo "=== BOOT host -vga std (no 3D device; UI implicit still works) ==="
drive_host "$WORKDIR/std" "std-vga" \
  "$(typekeys 'wm gfx'),ret,wait:400,$(typekeys 'osgpug'),ret,wait:8000" \
  -vga std

echo
echo "=== BOOT host virtio-gpu-pci (2D mailbox only) ==="
drive_host "$WORKDIR/twod" "virtio-gpu-pci" \
  "$(typekeys 'osgpug'),ret,wait:15000" \
  -vga none -device virtio-gpu-pci

echo
echo "=== BOOT host G5 virtgpuc (2D flush must not be OSGPU OK) ==="
drive_host "$WORKDIR/g5" "virtgpuc" \
  "v,i,r,t,g,p,u,c,ret,wait:20000" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== CRITERION host negatives ==="
ck; python3 - "$WORKDIR/std/serial.txt" <<'PY' || fail "std-vga negative failed"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "OSGPU NONE" not in s:
    fails.append("std-vga did not print OSGPU NONE")
if "OSGPU OK" in s:
    fails.append("std-vga printed OSGPU OK")
if "OSGPU PIX " in s:
    fails.append("std-vga printed OSGPU PIX")
if "WM GFX ON" not in s:
    fails.append("std-vga did not print WM GFX ON — implicit UI path broke")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std is OSGPU NONE; wm gfx still ON"

ck; python3 - "$WORKDIR/twod/serial.txt" <<'PY' || fail "2D virtio-gpu-pci negative failed"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "OSGPU NONE" not in s:
    fails.append("2D device did not print OSGPU NONE")
if "OSGPU OK" in s:
    fails.append("2D device printed OSGPU OK — that would be a labelled mailbox")
if "OSGPU PIX " in s:
    fails.append("2D device printed OSGPU PIX")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtio-gpu-pci (no VIRGL) is OSGPU NONE"

ck; python3 - "$WORKDIR/g5/serial.txt" <<'PY' || fail "G5 anti-vacuity failed"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
if "OSGPU OK" in s:
    print("virtgpuc printed OSGPU OK — G5 flush is not explicit GPU", file=sys.stderr)
    sys.exit(1)
if "OSGPU PIX " in s:
    print("virtgpuc printed OSGPU PIX", file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtgpuc (G5) does not print OSGPU OK"

echo
echo "=== GL QEMU (virglrenderer) ==="
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
echo "    3D QEMU: oscortex-qemu-gl:local (Debian qemu 11.1 + virglrenderer)"

echo
echo "=== BOOT GL osgpug (explicit submit + readback) ==="
mkdir -p "$WORKDIR/gl"
SER="$WORKDIR/gl/serial.txt"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 300 docker run --rm \
  -v "$KERNEL_ELF:/kernel.elf:ro" \
  -v "$WORKDIR/gl:/work" \
  -p "127.0.0.1:${PORT}:${PORT}" \
  -e LIBGL_ALWAYS_SOFTWARE=1 \
  -e GALLIUM_DRIVER=llvmpipe \
  oscortex-qemu-gl:local \
  bash -c "echo VIRGL0_GL; xvfb-run -a qemu-system-x86_64 -kernel /kernel.elf -m 128M -cpu qemu64 -vga none -device virtio-gpu-gl-pci,xres=${XRES},yres=${YRES} -display gtk,gl=on -serial file:/work/serial.txt -qmp tcp:0.0.0.0:${PORT},server,nowait -no-reboot; echo VIRGL0_QDONE" \
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
run_status DRIVE_STATUS -- python3 "$DRIVER" \
  --port "$PORT" --serial "$SER" --wait-for 'M1 END\n' \
  --png "$WORKDIR/gl/screen.png" --screen-text "$WORKDIR/gl/screen.txt" \
  --monitor-command 'info pci' --monitor-capture "$WORKDIR/gl/info-pci.txt" \
  --no-screendump \
  --keys "$(typekeys 'osgpug'),ret,wait:45000"
docker ps -aq --filter ancestor=oscortex-qemu-gl:local 2>/dev/null \
  | xargs docker rm -f >/dev/null 2>&1 || true
await QEMU_STATUS "$QEMU_PID"
if [[ $DRIVE_STATUS -ne 0 ]]; then
  echo "    note: qmp-drive exited $DRIVE_STATUS (gtk+gl often drops QMP on quit)"
  grep -q 'OSGPU OK' "$SER" || {
    cat "$WORKDIR/gl/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$SER" >&2
    fail "qmp-drive exited $DRIVE_STATUS and serial has no OSGPU OK"
  }
fi
ck; [[ -s "$SER" ]] || fail "GL serial is empty"

echo
echo "=== CRITERION explicit GPU pixel ==="
ck; python3 - "$WORKDIR/gl/serial.txt" <<'PY' || fail "GL osgpug did not prove a GPU pixel"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "OSGPU NONE" in serial:
    fails.append("GL boot printed OSGPU NONE")
if "OSGPU OK" not in serial:
    fails.append("GL boot did not print OSGPU OK")
if "VIRTIO 3D OK" not in serial:
    fails.append("GL boot did not print VIRTIO 3D OK — osgpug must hit G10 virgl")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("GL boot printed VIRTIO QTIMEOUT")
pixs = [ln for ln in serial.splitlines() if ln.startswith("OSGPU PIX ")]
if len(pixs) < 1:
    fails.append("expected OSGPU PIX, found %r" % pixs)
    pixel = None
else:
    m = re.match(r"^OSGPU PIX ([0-9A-F]{8})$", pixs[-1])
    if not m:
        fails.append("unparseable PIX: %r" % pixs[-1])
        pixel = None
    else:
        pixel = int(m.group(1), 16)

navy = (0x18 / 255.0, 0x40 / 255.0, 0x60 / 255.0, 1.0)
sr, sg, sb, sa = 1.0, 0.0, 0.0, 0.5
dr, dg, db, da = navy
or_ = sr * sa + dr * (1.0 - sa)
og = sg * sa + dg * (1.0 - sa)
ob = sb * sa + db * (1.0 - sa)
oa = sa + da * (1.0 - sa)
exp_r, exp_g, exp_b, exp_a = [int(round(x * 255)) for x in (or_, og, ob, oa)]
clr_r, clr_g, clr_b, clr_a = 255, 0, 0, 128

def channels(p):
    return ((p >> 16) & 255, (p >> 8) & 255, p & 255, (p >> 24) & 255)

def near(got, exp, slop=3):
    return abs(got - exp) <= slop

if pixel is not None:
    r, g, b, a = channels(pixel)
    if pixel == 0xFF184060 or pixel == 0x00184060:
        fails.append("PIX is navy 0x%08X — CLEAR dest only, 3D did not write alpha" % pixel)
    if pixel == 0x00101018:
        fails.append("PIX is the G5 desktop constant")
    if pixel == 0:
        fails.append("PIX is 0 — backing was never written by the device")
    blend_ok = near(r, exp_r) and near(g, exp_g) and near(b, exp_b) and (near(a, exp_a) or a == 0)
    clear_ok = near(r, clr_r) and near(g, clr_g) and near(b, clr_b) and near(a, clr_a)
    if not blend_ok and not clear_ok:
        fails.append("PIX 0x%08X R=%d G=%d B=%d A=%d; want GPU 50%% red A=128 or src-over R=%d G=%d B=%d A=%d"
                     % (pixel, r, g, b, a, exp_r, exp_g, exp_b, exp_a))

if fails:
    print(serial[-2000:], file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    GL  OSGPU OK  PIX 0x%08X  (device, not a CPU blit)" % pixel)
PY
echo "ASSERT: pass  osgpug on virtio-gpu-gl-pci; derived pixel is GPU-written"

require_assertions "$ASSERTIONS_REQUIRED"
echo "gpu-app0: PASS — osgpu.h create/submit/readback; osgpug hits G10 virgl; OSGPU PIX is device alpha; no 3D → NONE and wm gfx still ON"
exit 0
