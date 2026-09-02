#!/usr/bin/env bash
# core/tests/conformance/g10-virgl/run.sh
#
# G10 — The device executes GPU work, including alpha.
# docs/design/gpu.md §5/G10, ADR-0098.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# `virtgpug` negotiates VIRTIO_GPU_F_VIRGL, CTX_CREATE, SUBMIT_3D
# (virgl CLEAR navy, CLEAR 50% red, BLIT), TRANSFER_FROM_HOST_3D,
# SET_SCANOUT. The pixel in backing is written by the *device*.
#
# Homebrew QEMU 11.0.0 on this arm64 Mac has no virtio-gpu-gl-pci
# (cocoa-only bottle, no virglrenderer). Positive boot uses Docker
# image oscortex-qemu-gl:local — Debian sid qemu-system-x86 11.1.0
# + qemu-system-modules-opengl + libvirglrenderer1 + Xvfb + llvmpipe.
# Built by scripts/build-qemu-gl.sh.
#
# `bash -c "xvfb-run …"` execs xvfb-run as PID 1 and QEMU never
# starts; the wrapper must be `echo; xvfb-run` so bash stays.
# gtk+gl QEMU often closes QMP on quit; serial is the proof.
#
# Alpha: the GPU CLEAR of 50% red is A=0x80 (0x80FF0000). Host
# glBlitFramebuffer copies, so blit may not src-over; a device
# clear with alpha still proves the GPU wrote the translucent
# channel. Src-over of 50% red over navy is also accepted if
# a later virglrenderer blends. Neither dword is stored in
# virtgpu3d.dart.
#
# Negative: -vga std and virtio-gpu-pci print VIRTIO 3D NONE.
# Anti-vacuity: virtgpuc (G5) and virtgpuz (no submit) must not
# print VIRTIO 3D OK.
#
# G0–G9 contracts are not rewritten. No help, no last .bss, no
# syscall. No Mac Metal. Sit-in is the OS.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "G10-virgl: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G10-virgl: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=50

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf docker; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$CORE_DIR/build/g10-virgl-run"
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
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

# Not G3–G9 modes, not 800×600, not 1280×800, not 1024×768.
XRES=1056
YRES=752

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="
ck; [[ -f "$CORE_DIR/kernel/virtgpu3d.dart" ]] || fail "virtgpu3d.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "virtgpu3d.dart is not a part of kmain.dart"
ck; grep -q "^part 'virtgpu3d.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'virtgpu3d.dart'"
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
ck; grep -q 'void virtgpu3dInit()' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "virtgpu3dInit is missing"
ck; grep -q 'void shellVirtgpu3d(' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "shellVirtgpu3d is missing"
ck; grep -q 'void shellVirtgpu3dNo(' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "shellVirtgpu3dNo is missing — that is the no-submit negative"
ck; grep -q 'virtgpu3dTypeCtxNew' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "no CTX_CREATE type"
ck; grep -q 'virtgpu3dTypeSubmit' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "no SUBMIT_3D type"
ck; grep -q 'virtgpu3dTypeXferFrom' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "no TRANSFER_FROM_HOST_3D type"
ck; grep -q 'virtgpu3dCcmdClear' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "no virgl CLEAR opcode"
ck; grep -q 'virtgpu3dCcmdBlit' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "no virgl BLIT opcode"
ck; grep -q 'shellVirtgpu3d' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpug"
ck; grep -q 'void shellVirtgpuCap(' "$CORE_DIR/kernel/virtgpu.dart" \
  || fail "G9 shellVirtgpuCap was removed — do not rewrite G9"
ck; [[ -f "$CORE_DIR/docs/decisions/0098-virtio-gpu-3d-executes-alpha.md" ]] \
  || fail "ADR-0098 is missing"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "virtgpu3d.dart declares @bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
ck; ! grep -q 'virtgpu3d\|virtgpug\|VIRGL0\|g10-virgl' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G10 added a syscall"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
ck; ! grep -qE '0xFF8C2030|0xff8c2030|0x8C2030|0x80FF0000|0x80ff0000' \
      "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "result dword is stored in virtgpu3d.dart — that is a CPU paint"
ck; ! grep -q '0x00101018' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "G5 desktop constant appears in virtgpu3d.dart"
ck; python3 - "$CORE_DIR/kernel/virtgpu3d.dart" <<'PY' || fail "virtgpu3dInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpu3dInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpu3dInit missing", file=sys.stderr); sys.exit(1)
if m.group(1).strip():
    print("virtgpu3dInit is not empty", file=sys.stderr); sys.exit(1)
PY
ck; ! grep -q "$XRES" "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "derived xres $XRES appears in virtgpu3d.dart"
ck; grep -q '3D GPU → CPU raster → 2D mailbox' "$CORE_DIR/docs/design/gpu.md" \
  || fail "gpu.md is missing the paint fallback sentence"
ck; [[ -f "$CORE_DIR/scripts/build-qemu-gl.sh" ]] \
  || fail "scripts/build-qemu-gl.sh is missing — that is how this Mac gets 3D QEMU"
capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  virtgpug/z; CTX/SUBMIT/XFER; no help, no .bss; G9 remains"

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
echo "=== BOOT host -vga std (no 3D device) ==="
drive_host "$WORKDIR/std" "std-vga" "v,i,r,t,g,p,u,g,ret,wait:8000" -vga std

echo
echo "=== BOOT host virtio-gpu-pci (2D mailbox only) ==="
drive_host "$WORKDIR/twod" "virtio-gpu-pci" "v,i,r,t,g,p,u,g,ret,wait:15000" \
  -vga none -device virtio-gpu-pci

echo
echo "=== BOOT host G5 virtgpuc (2D flush must not be 3D OK) ==="
drive_host "$WORKDIR/g5" "virtgpuc" "v,i,r,t,g,p,u,c,ret,wait:20000" \
  -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}"

echo
echo "=== CRITERION host negatives ==="
ck; python3 - "$WORKDIR/std/serial.txt" <<'PY' || fail "std-vga negative failed"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "VIRTIO 3D NONE" not in s:
    fails.append("std-vga did not print VIRTIO 3D NONE")
if "VIRTIO 3D OK" in s:
    fails.append("std-vga printed VIRTIO 3D OK")
if "VIRTIO PAINT 3D" in s:
    fails.append("std-vga printed PAINT 3D")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints VIRTIO 3D NONE, no 3D OK"

ck; python3 - "$WORKDIR/twod/serial.txt" <<'PY' || fail "2D virtio-gpu-pci negative failed"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "VIRTIO 3D NONE" not in s:
    fails.append("2D device did not print VIRTIO 3D NONE")
if "VIRTIO 3D OK" in s:
    fails.append("2D device printed VIRTIO 3D OK — that would be a labelled mailbox")
if "VIRTIO PAINT 3D" in s:
    fails.append("2D device printed PAINT 3D")
if "VIRTIO PAINT 2D" not in s:
    fails.append("2D device did not print VIRTIO PAINT 2D")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtio-gpu-pci (no VIRGL) is PAINT 2D, not 3D OK"

ck; python3 - "$WORKDIR/g5/serial.txt" <<'PY' || fail "G5 anti-vacuity failed"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
if "VIRTIO 3D OK" in s:
    print("virtgpuc printed VIRTIO 3D OK — G5 flush is not 3D", file=sys.stderr)
    sys.exit(1)
if "VIRTIO 3D PIX " in s:
    print("virtgpuc printed VIRTIO 3D PIX", file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtgpuc (G5) does not print 3D OK"

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

drive_gl() {
  local outdir="$1" label="$2" keys="$3" need_ok="$4"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 300 docker run --rm \
    -v "$KERNEL_ELF:/kernel.elf:ro" \
    -v "$outdir:/work" \
    -p "127.0.0.1:${port}:${port}" \
    -e LIBGL_ALWAYS_SOFTWARE=1 \
    -e GALLIUM_DRIVER=llvmpipe \
    oscortex-qemu-gl:local \
    bash -c "echo VIRGL0_GL; xvfb-run -a qemu-system-x86_64 -kernel /kernel.elf -m 128M -cpu qemu64 -vga none -device virtio-gpu-gl-pci,xres=${XRES},yres=${YRES} -display gtk,gl=on -serial file:/work/serial.txt -qmp tcp:0.0.0.0:${port},server,nowait -no-reboot; echo VIRGL0_QDONE" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local waited=0
  while [[ $waited -lt 90 ]]; do
    if grep -q 'M1 END' "$ser" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  ck; grep -q 'M1 END' "$ser" || {
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "$label GL boot never reached M1 END"
  }
  local drive_status
  local extra=()
  if [[ "$need_ok" == "ok" ]]; then
    extra+=(--monitor-command 'xp /1wx {addr}' --addr-from-serial 'VIRTIO BACK ([0-9A-F]{8})')
  fi
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for 'M1 END\n' \
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt" \
    --monitor-command 'info pci' --monitor-capture "$outdir/info-pci.txt" \
    --no-screendump \
    "${extra[@]+"${extra[@]}"}" \
    --keys "$keys"
  # gtk+gl often drops QMP on quit; do not wait out the 300s docker timeout.
  docker ps -aq --filter ancestor=oscortex-qemu-gl:local 2>/dev/null \
    | xargs docker rm -f >/dev/null 2>&1 || true
  local qemu_status
  await qemu_status "$qemu_pid"
  if [[ $drive_status -ne 0 ]]; then
    echo "    note: qmp-drive exited $drive_status (gtk+gl often drops QMP on quit)"
    if [[ "$need_ok" == "ok" ]]; then
      grep -q 'VIRTIO 3D OK' "$ser" || {
        cat "$outdir/qemu.log" >&2
        echo "--- serial ---" >&2
        cat "$ser" >&2
        fail "qmp-drive exited $drive_status and serial has no 3D OK"
      }
    else
      grep -q 'VIRTIO 3D FEAT ' "$ser" || {
        cat "$outdir/qemu.log" >&2
        echo "--- serial ---" >&2
        cat "$ser" >&2
        fail "qmp-drive exited $drive_status and serial has no 3D FEAT"
      }
    fi
  fi
  ck; [[ -s "$ser" ]] || fail "$label GL serial is empty"
}

echo
echo "=== BOOT GL virtgpug (submit + alpha) ==="
drive_gl "$WORKDIR/gl" "virtgpug-gl" "v,i,r,t,g,p,u,g,ret,wait:45000" ok

echo
echo "=== BOOT GL virtgpuz (no submit) ==="
drive_gl "$WORKDIR/glz" "virtgpuz-gl" "v,i,r,t,g,p,u,z,ret,wait:25000" nook

echo
echo "=== CRITERION 3D + alpha ==="
ck; python3 - "$WORKDIR/glz/serial.txt" <<'PY' || fail "virtgpuz on GL printed 3D OK"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
if "VIRTIO 3D OK" in s:
    print("virtgpuz printed VIRTIO 3D OK — submit was not omitted", file=sys.stderr)
    sys.exit(1)
if "VIRTIO 3D PIX " in s:
    print("virtgpuz printed VIRTIO 3D PIX", file=sys.stderr)
    sys.exit(1)
if "VIRTIO 3D NONE" in s:
    print("virtgpuz printed 3D NONE on a GL device — VIRGL was not accepted", file=sys.stderr)
    sys.exit(1)
if "VIRTIO 3D FEAT " not in s:
    print("virtgpuz did not print 3D FEAT", file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtgpuz on virtio-gpu-gl-pci has VIRGL and no 3D OK"

ck; python3 - "$WORKDIR/gl/serial.txt" "$WORKDIR/gl/info-pci.txt" <<'PY' || fail "GL virtgpug did not prove GPU alpha"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
try:
    info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
except FileNotFoundError:
    info = ""
fails = []
if "VIRTIO 3D NONE" in serial:
    fails.append("GL boot printed VIRTIO 3D NONE")
if "VIRTIO 3D OK" not in serial:
    fails.append("GL boot did not print VIRTIO 3D OK")
if "VIRTIO PAINT 3D" not in serial:
    fails.append("GL boot did not print VIRTIO PAINT 3D")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("GL boot printed VIRTIO QTIMEOUT")
pixs = [ln for ln in serial.splitlines() if ln.startswith("VIRTIO 3D PIX ")]
if len(pixs) != 1:
    fails.append("expected one 3D PIX line, found %r" % pixs)
    pixel = None
else:
    m = re.match(r"^VIRTIO 3D PIX ([0-9A-F]{8})$", pixs[0])
    if not m:
        fails.append("unparseable PIX: %r" % pixs[0])
        pixel = None
    else:
        pixel = int(m.group(1), 16)

# GPU CLEAR 50% red is A=0x80 R=0xFF (IEEE 1,0,0,0.5). Host blit is
# often a copy, so the transferred pixel is that clear. Src-over of
# the same red over navy 0x184060 is also accepted.
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
    if pixel == 0xFFFF0000 or pixel == 0x00FF0000 or pixel == 0xFF0000FF:
        fails.append("PIX is full opaque red 0x%08X — no alpha channel" % pixel)
    if pixel == 0x00101018:
        fails.append("PIX is the G5 desktop constant")
    if pixel == 0:
        fails.append("PIX is 0 — backing was never written by the device")
    blend_ok = near(r, exp_r) and near(g, exp_g) and near(b, exp_b) and (near(a, exp_a) or a == 0)
    clear_ok = near(r, clr_r) and near(g, clr_g) and near(b, clr_b) and near(a, clr_a)
    if not blend_ok and not clear_ok:
        fails.append("PIX 0x%08X R=%d G=%d B=%d A=%d; want GPU 50%% red A=128 or src-over R=%d G=%d B=%d A=%d"
                     % (pixel, r, g, b, a, exp_r, exp_g, exp_b, exp_a))
    if a == 0xFF and not blend_ok:
        fails.append("PIX alpha is opaque and is not the src-over result")

ms = re.findall(r":\s+([0-9a-fA-F]{8})", info)
if pixel is not None and ms:
    got = int(ms[-1], 16)
    if got != pixel:
        fails.append("xp BACK dword 0x%08X != printed PIX 0x%08X" % (got, pixel))

if fails:
    print(serial[-2000:], file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
kind = "src-over" if (pixel is not None and abs(((pixel >> 16) & 255) - exp_r) <= 3 and abs((pixel & 255) - exp_b) <= 3) else "GPU-clear-50pct-red"
print("    GL  3D OK  PIX 0x%08X  %s  (device alpha, not a CPU box)" % (pixel, kind))
PY
echo "ASSERT: pass  virtio-gpu-gl-pci submit; translucent pixel is GPU-written, not a CPU box"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G10-virgl: PASS — virtio-gpu-gl-pci executed virgl CLEAR; device wrote A=0x80 (or src-over); virtgpuz/G5/std-vga print no 3D OK"
