#!/usr/bin/env bash
# core/tests/conformance/g11-osgfx-gl/run.sh
#
# G11 — osgfx session chrome reaches VIRGL scanout.
# docs/design/gpu.md §5/G11, ADR-0107.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# The compose buffer `osgfx_sw` / `osgfx_guest_tick` already paints
# (`wm gfx`, ADR-0104) is uploaded to a VIRGL 3D resource
# (TRANSFER_TO_HOST_3D) and SET_SCANOUT. Rounded-chrome samples
# (AABB desktop, title interior) come back through
# TRANSFER_FROM_HOST_3D. That is not G10's CLEAR and not a G5
# 2D mailbox.
#
# Positive boot uses Docker oscortex-qemu-gl:local (same as G10).
# Homebrew QEMU has no virtio-gpu-gl-pci.
#
# Negative: -vga std and virtio-gpu-pci print VIRTIO 3D NONE.
# Anti-vacuity: virtgpuc (G5) must not print OSGFX 3D.
# G10 CLEAR contract is not rewritten.
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

fail() { echo "G11-osgfx-gl: FAIL — $1" >&2; exit 1; }
setup_error() { echo "G11-osgfx-gl: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=45

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf docker clang; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$CORE_DIR/build/g11-osgfx-gl-run"
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
SIT="$CORE_DIR/tests/conformance/d3-session"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

# Not G10's 1056×752, not 800×600, not 1280×800, not 1024×768.
XRES=1136
YRES=816

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="
ck; [[ -f "$CORE_DIR/docs/decisions/0107-osgfx-chrome-reaches-virgl-scanout.md" ]] \
  || fail "ADR-0107 is missing"
ck; grep -q 'DE chrome is compositor policy' \
      "$CORE_DIR/docs/decisions/0106-de-chrome-is-compositor-policy.md" \
  || fail "ADR-0106 is no longer DE chrome — do not steal that number"
ck; grep -q 'virtgpu3dTypeXferTo' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "no TRANSFER_TO_HOST_3D type"
ck; grep -q '0x0205' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "TRANSFER_TO_HOST_3D 0x0205 is missing"
ck; grep -q 'virtgpu3dTypeXferFrom' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "G10 TRANSFER_FROM_HOST_3D was removed"
ck; grep -q 'virtgpu3dCcmdClear' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "G10 CLEAR opcode was removed"
ck; grep -q 'void shellVirtgpu3d()' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "shellVirtgpu3d was removed — do not rewrite G10"
ck; grep -q 'void shellVirtgpu3dNo(' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "shellVirtgpu3dNo was removed"
ck; grep -q 'void shellVirtgpu3dOsgfx(' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "shellVirtgpu3dOsgfx is missing"
ck; grep -q 'virtgpu3dStrCmdOsgfx' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "virtgpuk command string is missing"
ck; grep -q 'shellVirtgpu3dOsgfx' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch virtgpuk"
ck; grep -q 'osgfx_fill_rrect' "$CORE_DIR/plat/osgfx/osgfx_sw.c" \
  || fail "osgfx_sw.c lost osgfx_fill_rrect"
ck; ! grep -q '@bss' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "virtgpu3d.dart declares @bss"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
ck; ! grep -q 'virtgpuk\|g11-osgfx\|OSGFX 3D' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "G11 added a syscall"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
ck; ! grep -qE '0x80FF0000|0x80ff0000' "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "G10 result dword stored in virtgpu3d.dart"
ck; ! grep -q "$XRES" "$CORE_DIR/kernel/virtgpu3d.dart" \
  || fail "derived xres $XRES appears in virtgpu3d.dart"
ck; python3 - "$CORE_DIR/kernel/virtgpu3d.dart" <<'PY' || fail "virtgpu3dInit is not a no-op"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"void virtgpu3dInit\(\) \{(.*?)\n\}", src, re.S)
if not m:
    print("virtgpu3dInit missing", file=sys.stderr); sys.exit(1)
if m.group(1).strip():
    print("virtgpu3dInit is not empty", file=sys.stderr); sys.exit(1)
PY
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
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  virtgpuk; TO_HOST_3D; G10 CLEAR remains; no help, no .bss"

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
drive_host "$WORKDIR/std" "std-vga" \
  "f,b,ret,wait:800,$(typekeys 'wm gfx'),ret,wait:400,v,i,r,t,g,p,u,k,ret,wait:8000" \
  -vga std

echo
echo "=== BOOT host virtio-gpu-pci (2D mailbox only) ==="
drive_host "$WORKDIR/twod" "virtio-gpu-pci" \
  "v,i,r,t,g,p,u,k,ret,wait:15000" \
  -vga none -device virtio-gpu-pci

echo
echo "=== BOOT host G5 virtgpuc (2D flush must not be OSGFX 3D) ==="
drive_host "$WORKDIR/g5" "virtgpuc" \
  "v,i,r,t,g,p,u,c,ret,wait:20000" \
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
if "VIRTIO OSGFX 3D" in s:
    fails.append("std-vga printed OSGFX 3D")
if "WM GFX ON" not in s:
    fails.append("std-vga did not print WM GFX ON — Bochs osgfx path broke")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  -vga std prints 3D NONE, no 3D OK; wm gfx still ON"

ck; python3 - "$WORKDIR/twod/serial.txt" <<'PY' || fail "2D virtio-gpu-pci negative failed"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if "VIRTIO 3D NONE" not in s:
    fails.append("2D device did not print VIRTIO 3D NONE")
if "VIRTIO 3D OK" in s:
    fails.append("2D device printed VIRTIO 3D OK — that would be a labelled mailbox")
if "VIRTIO OSGFX 3D" in s:
    fails.append("2D device printed OSGFX 3D")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtio-gpu-pci (no VIRGL) is not OSGFX 3D"

ck; python3 - "$WORKDIR/g5/serial.txt" <<'PY' || fail "G5 anti-vacuity failed"
import sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
if "VIRTIO 3D OK" in s:
    print("virtgpuc printed VIRTIO 3D OK — G5 flush is not 3D", file=sys.stderr)
    sys.exit(1)
if "VIRTIO OSGFX 3D" in s:
    print("virtgpuc printed OSGFX 3D — G5 is the 2D mailbox", file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  virtgpuc (G5) does not print OSGFX 3D"

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

# virtgpuk creates the 3D scanout, kicks osgfx_guest_tick, uploads.
# Do not spawn two READY clients first — they steal the shell.
GL_KEYS="$(typekeys 'virtgpuk'),ret,wait:45000"

echo
echo "=== BOOT GL virtgpuk (osgfx upload + scanout) ==="
mkdir -p "$WORKDIR/gl"
cp "$DISK_IMG" "$WORKDIR/gl/disk.img" || fail "could not copy disk.img into the GL workdir"
SER="$WORKDIR/gl/serial.txt"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 360 docker run --rm \
  -v "$KERNEL_ELF:/kernel.elf:ro" \
  -v "$WORKDIR/gl:/work" \
  -p "127.0.0.1:${PORT}:${PORT}" \
  -e LIBGL_ALWAYS_SOFTWARE=1 \
  -e GALLIUM_DRIVER=llvmpipe \
  oscortex-qemu-gl:local \
  bash -c "echo VIRGL0_GL; xvfb-run -a qemu-system-x86_64 -kernel /kernel.elf -m 256M -cpu qemu64 -vga none -device virtio-gpu-gl-pci,xres=${XRES},yres=${YRES} -drive file=/work/disk.img,format=raw,if=ide,index=0,media=disk -display gtk,gl=on -serial file:/work/serial.txt -qmp tcp:0.0.0.0:${PORT},server,nowait -no-reboot; echo VIRGL0_QDONE" \
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
  --keys "$GL_KEYS"
docker ps -aq --filter ancestor=oscortex-qemu-gl:local 2>/dev/null \
  | xargs docker rm -f >/dev/null 2>&1 || true
await QEMU_STATUS "$QEMU_PID"
if [[ $DRIVE_STATUS -ne 0 ]]; then
  echo "    note: qmp-drive exited $DRIVE_STATUS (gtk+gl often drops QMP on quit)"
  grep -q 'VIRTIO OSGFX 3D' "$SER" || {
    cat "$WORKDIR/gl/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$SER" >&2
    fail "qmp-drive exited $DRIVE_STATUS and serial has no OSGFX 3D"
  }
fi
ck; [[ -s "$SER" ]] || fail "GL serial is empty"

echo
echo "=== CRITERION osgfx on GL scanout ==="
ck; python3 - "$WORKDIR/gl/serial.txt" "$CORE_DIR/kernel/wmchrome.dart" <<'PY' || fail "GL virtgpuk did not bind osgfx chrome"
import re, sys
serial = open(sys.argv[1], "rb").read().decode("latin-1")
# The title colour is READ from the kernel that painted it. It was typed here
# as 0xD8B060, the pre-ADR-0187 gold; this probe is about "the chrome reached
# the 3D resource", and typing the colour turned an authorised repaint into a
# claim that the GPU path broke.
m = re.search(r"^const int wmTitleColor = (0x[0-9A-Fa-f]+);",
              open(sys.argv[2]).read(), re.M)
if not m:
    raise SystemExit("wmchrome.dart has no wmTitleColor")
WM_TITLE_COLOR = int(m.group(1), 16) & 0xFFFFFF
fails = []
if "VIRTIO 3D NONE" in serial:
    fails.append("GL boot printed VIRTIO 3D NONE")
if "VIRTIO 3D OK" not in serial:
    fails.append("GL boot did not print VIRTIO 3D OK")
if "VIRTIO PAINT 3D" not in serial:
    fails.append("GL boot did not print VIRTIO PAINT 3D")
if "VIRTIO OSGFX 3D" not in serial:
    fails.append("GL boot did not print VIRTIO OSGFX 3D")
if "VIRTIO QTIMEOUT" in serial:
    fails.append("GL boot printed VIRTIO QTIMEOUT")
def last_hex(prefix):
    hits = [ln for ln in serial.splitlines() if ln.startswith(prefix)]
    if not hits:
        return None
    m = re.match(r"^" + re.escape(prefix) + r"([0-9A-F]{8})$", hits[-1])
    if not m:
        return None
    return int(m.group(1), 16)

aabb = last_hex("VIRTIO OSGFX AABB ")
title = last_hex("VIRTIO OSGFX TITLE ")
if aabb is None:
    fails.append("no parseable VIRTIO OSGFX AABB line")
if title is None:
    fails.append("no parseable VIRTIO OSGFX TITLE line")

def rgb(p):
    return p & 0x00FFFFFF

if aabb is not None:
    # ADR-0196 outset the card stroke; the AABB corner is the AA fringe
    # (measured 0x194161), not a square chrome/title/client solid.
    desk = 0x184060
    solids = (0x00344050, 0x00E8E0D0, 0x001A2430, 0x00F4F0E8)
    ar = rgb(aabb)
    if aabb == 0:
        fails.append("AABB is 0 — FROM_HOST did not restore the compose pixel")
    elif ar in solids:
        fails.append("AABB 0x%08X is solid chrome — square blit, not an AA rrect hole"
                     % aabb)
    else:
        slop = 0x18
        if any(abs(((ar >> s) & 0xFF) - ((desk >> s) & 0xFF)) > slop for s in (0, 8, 16)):
            fails.append("AABB 0x%08X is not near desktop 0x184060 — rrect corner missing or GPU did not bounce"
                         % aabb)

if title is not None:
    # ADR-0187 made the title a vertical PEARL GRADIENT, so the sampled row is
    # a ramp value above wmTitleColor, not wmTitleColor itself. Demanding
    # equality turned an authorised repaint into "the GPU path broke". What
    # still has to hold, and is strictly more than "some pixel came back", is
    # that the sample sits ON that ramp: never darker than wmTitleColor in any
    # channel, never more than a title-height's worth of lift above it, and
    # neither the desktop nor the pre-ADR-0187 gold.
    LIFT = 48
    tr, tg, tb = (rgb(title) >> 16) & 255, (rgb(title) >> 8) & 255, rgb(title) & 255
    br = (WM_TITLE_COLOR >> 16) & 255
    bg = (WM_TITLE_COLOR >> 8) & 255
    bb = WM_TITLE_COLOR & 255
    for got, base, ch in ((tr, br, "R"), (tg, bg, "G"), (tb, bb, "B")):
        if got < base:
            fails.append("TITLE 0x%08X channel %s is %d, below wmTitleColor's "
                         "%d — that is not the pearl ramp"
                         % (title, ch, got, base))
        elif got - base > LIFT:
            fails.append("TITLE 0x%08X channel %s is %d, %d above "
                         "wmTitleColor's %d — the ramp does not lift that far"
                         % (title, ch, got, got - base, base))
    if rgb(title) == 0xD8B060:
        fails.append("TITLE is the pre-ADR-0187 gold — the 3D resource has the old chrome")
    if rgb(title) == 0x184060:
        fails.append("TITLE is desktop — chrome never painted or sample missed the caption")
    if rgb(title) == 0xFFFFFF:
        fails.append("TITLE is pure white — the sample is not chrome")

if fails:
    print(serial[-2500:], file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    GL  OSGFX 3D  AABB 0x%08X  TITLE 0x%08X  (upload+FROM_HOST, not G10 CLEAR)"
      % (aabb, title))
PY
echo "ASSERT: pass  virtio-gpu-gl-pci scanout is osgfx rounded chrome; 3D OK"

require_assertions "$ASSERTIONS_REQUIRED"
echo "G11-osgfx-gl: PASS — osgfx compose uploaded to VIRGL 3D resource; AABB desktop, title interior; virtgpuc/std-vga/2D print no OSGFX 3D"
exit 0
