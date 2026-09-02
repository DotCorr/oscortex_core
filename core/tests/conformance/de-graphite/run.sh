#!/usr/bin/env bash
# core/tests/conformance/de-graphite/run.sh
#
# ADR-0129 — Graphite MakeVulkan is linked into kernel.elf.
# Live paint stays CPU Skia until a VkDevice exists.
# docs/design/c-modules.md, GAP-0313.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# nm shows MakeVulkan / skgpu::graphite / graphite-vk-try in kernel.elf.
# OSGFX_SKIA=0 has none of those (anti-vacuity).
# wm gfx prints WM GFX ON and OSGFX GRAPHITE NONE.
# OSGFX GRAPHITE OK is forbidden on this no-VkDevice machine.
# Sit-in still comes up (D3S COMMIT). Not a planted Graphite pixel.
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

fail() { echo "DE-graphite: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-graphite: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=34

for tool in qemu-system-x86_64 python3 clang x86_64-elf-nm x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-graphite.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
SIT="$CORE_DIR/tests/conformance/d3-session"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
GRAPHITE_MM="$CORE_DIR/plat/osgfx/osgfx_graphite.mm"
GRAPHITE_GUEST="$CORE_DIR/plat/osgfx/osgfx_graphite_guest.cpp"
GRAPHITE_LIB="$CORE_DIR/build/skia/out/guest-elf-graphite/libskia.a"
ADR="$CORE_DIR/docs/decisions/0129-graphite-makevulkan-is-the-kernel-door.md"

echo "=== STRUCTURAL ==="
ck; [[ -f "$ADR" ]] || fail "ADR-0129 is missing"
ck; grep -q '0128 is mmap' "$ADR" || fail "ADR-0129 stole 0128"
ck; [[ -f "$GRAPHITE_GUEST" ]] || fail "osgfx_graphite_guest.cpp missing"
ck; grep -q 'ContextFactory::MakeVulkan' "$GRAPHITE_GUEST" \
  || fail "guest Graphite door does not call MakeVulkan"
ck; grep -q 'graphite-vk-try' "$GRAPHITE_GUEST" \
  || fail "graphite-vk-try token missing"
ck; grep -q 'OSGFX GRAPHITE NONE' "$GRAPHITE_GUEST" \
  || fail "NONE line missing — leftover must print"
ck; ! grep -q 'osgfx_backend_graphite(void) { return 1; }' "$GRAPHITE_GUEST" \
  || fail "backend_graphite is hard-coded 1 — that is a stub token"
ck; grep -q 'MakeMetal' "$GRAPHITE_MM" \
  || fail "host Graphite MakeMetal was removed"
ck; grep -q 'osgfx_graphite_try' "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "osgfx_skia.cpp does not call the Graphite door"
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
echo "STRUCTURAL: pass  MakeVulkan door; host Metal stays; no stub token"

echo
echo "=== ANTI-VACUITY (no Skia .o) ==="
capture_sh NOSKIA_OUT NOSKIA_STATUS -- "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$NOSKIA_OUT"
ck; [[ $NOSKIA_STATUS -eq 0 ]] || fail "OSGFX_SKIA=0 build-kernel.sh exited $NOSKIA_STATUS"
cp "$KERNEL_ELF" "$WORKDIR/kernel-noskia.elf"
elf_has() { python3 -c "import sys; sys.exit(0 if open(sys.argv[1],'rb').read().find(sys.argv[2].encode())>=0 else 1)" "$1" "$2"; }
ck; ! elf_has "$WORKDIR/kernel-noskia.elf" "ContextFactory10MakeVulkan" \
  || fail "OSGFX_SKIA=0 kernel.elf still names MakeVulkan"
ck; ! elf_has "$WORKDIR/kernel-noskia.elf" "skgpu8graphite14ContextFactory" \
  || fail "OSGFX_SKIA=0 kernel.elf still names Graphite"
ck; ! elf_has "$WORKDIR/kernel-noskia.elf" "graphite-vk-try" \
  || fail "OSGFX_SKIA=0 kernel.elf still has graphite-vk-try"
echo "ANTI-VACUITY: pass  CPU-only / no Skia has no Graphite token"

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

ck; elf_has "$KERNEL_ELF" "ContextFactory10MakeVulkan" \
  || fail "kernel.elf has no ContextFactory::MakeVulkan — Graphite factory not linked"
ck; elf_has "$KERNEL_ELF" "skgpu8graphite" \
  || fail "kernel.elf has no graphite symbol"
ck; elf_has "$KERNEL_ELF" "graphite-vk-try" \
  || fail "kernel.elf has no graphite-vk-try"
ck; elf_has "$KERNEL_ELF" "skia-draw" \
  || fail "CPU Skia paint path was dropped"
echo "GRAPHITE LINK: pass  MakeVulkan + graphite-vk-try in kernel.elf"

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
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:800"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_A"),ret,until:D3S COMMIT,wait:400"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_B"),ret,until:D3S COMMIT,wait:800"

SER="$WORKDIR/serial.txt"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
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
  fail "session driver exited $DRIVE_STATUS"
fi
ck; [[ -s "$SER" ]] || fail "serial capture is empty"
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON did not print"
ck; grep -q 'OSGFX GRAPHITE NONE' "$SER" \
  || fail "OSGFX GRAPHITE NONE did not print — MakeVulkan was not called"
ck; ! grep -q 'OSGFX GRAPHITE OK' "$SER" \
  || fail "OSGFX GRAPHITE OK on no-VkDevice QEMU — that is a stub context"
ck; grep -q 'D3S COMMIT' "$SER" || fail "D3S COMMIT missing — sit-in path broke"
echo "BOOT: pass  GRAPHITE NONE; WM GFX ON; D3S COMMIT; no OK"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-graphite: PASS — MakeVulkan linked; context none without VkDevice; sit-in still up ($ASSERTIONS checks)"
exit 0
