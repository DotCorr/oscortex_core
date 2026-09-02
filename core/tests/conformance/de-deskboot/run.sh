#!/usr/bin/env bash
# core/tests/conformance/de-deskboot/run.sh
#
# ADR-0197 — boot is wallpaper + split glass dock. FILES and SET open
# from dock hits, not from sit-in spawn.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
DESK_C="$CORE_DIR/user/frame/desk.c"
SET_C="$CORE_DIR/user/frame/set.c"
SITIN="$CORE_DIR/scripts/sit-in.sh"
SITVIEW="$CORE_DIR/scripts/sit-in-view.sh"
ADR="$CORE_DIR/docs/decisions/0197-osxui-glass-and-boot-to-desk.md"
SITFAT="$CORE_DIR/tests/conformance/de-sitfat"

fail() { echo "DE-DESKBOOT: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-DESKBOOT: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

export OSGFX_SKIA=1
export OSGFX_CRT=0
export OSMEDIA_FFMPEG=0

ASSERTIONS_REQUIRED=34

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-deskboot.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"

ck; [[ -f "$ADR" ]] || fail "ADR-0197 missing"
ck; grep -q 'osxui_app_island' "$DESK_C" || fail "desk.c has no glass island"
ck; grep -q 'DESK FROST' "$DESK_C" || fail "desk.c has no frost vary probe"
ck; grep -q 'osgfx_glass_frost' "$CORE_DIR/plat/osgfx/osgfx_desk.c" \
  || fail "no wallpaper frost sampler"
ck; grep -q 'WM_PAINT_GLASS' "$CORE_DIR/user/frame/osframe.h" \
  || fail "no WM_PAINT_GLASS"
ck; grep -q 'SYS_SPAWN' "$DESK_C" || fail "desk.c cannot spawn"
ck; ! grep -q 'proc spawn FILES.ELF' "$SITIN" \
  || fail "sit-in.sh still auto-spawns FILES"
ck; ! grep -q 'proc spawn FILES.ELF' "$SITVIEW" \
  || fail "sit-in-view.sh still auto-spawns FILES"
ck; ! grep -q 'proc spawn SET.ELF' "$SITVIEW" \
  || fail "sit-in-view.sh still auto-spawns SET"
ck; grep -q 'osxui_glass' "$CORE_DIR/plat/osxui/osxui.h" \
  || fail "osxui.h has no glass API"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
echo "STRUCTURAL: pass"

echo
echo "=== BUILD ==="
if [[ "${SITIN_SKIP_BUILD:-}" == 1 && -f "$CORE_DIR/build/kernel.elf" ]]; then
  echo "skipping build-kernel (SITIN_SKIP_BUILD=1)"
else
  capture_sh BK_OUT BK_ST -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
  echo "$BK_OUT"
  ck; [[ $BK_ST -eq 0 ]] || fail "build-kernel exited $BK_ST"
fi
KERNEL_ELF="$CORE_DIR/build/kernel.elf"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
capture_sh BD_OUT BD_ST -- "bash '$SITFAT/build-disk.sh' '$WORKDIR/fat' 2>&1"
echo "$BD_OUT"
ck; [[ $BD_ST -eq 0 ]] || fail "build-disk exited $BD_ST"

echo
echo "=== RUNTIME ==="
PORT=$(python3 "$PICKER")
SER="$WORKDIR/serial.txt"
PNG="$WORKDIR/frame.png"
: >"$SER"

qemu-system-x86_64 \
  -name oscortex-de-deskboot \
  -machine q35,accel=tcg -cpu qemu64 -m 256 \
  -kernel "$KERNEL_ELF" \
  -drive "file=$WORKDIR/fat/disk.img,format=raw,if=ide,index=0,media=disk" \
  -device virtio-tablet-pci \
  -display none -serial "file:$SER" \
  -qmp "tcp:127.0.0.1:${PORT},server,nowait" \
  -no-reboot \
  >"$WORKDIR/qemu.log" 2>&1 &
QPID=$!
cleanup_q() {
  kill "$QPID" 2>/dev/null || true
  wait "$QPID" 2>/dev/null || true
  cleanup
}
trap cleanup_q EXIT

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1200"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm de'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'vtab'),ret,wait:800"
KEYS="$KEYS,$(typekeys 'proc spawn DESK.ELF'),ret,wait:3000"

FB="$WORKDIR/fb.raw"
capture_sh DR_OUT DR_ST -- "python3 '$DRIVER' --port '$PORT' --serial '$SER' --wait-for 'M1 END\n' --keys '$KEYS' --settle-for 'DESK READY' --settle-timeout 90 --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' --fb-out '$FB' --png '$PNG' --no-quit 2>&1"
echo "$DR_OUT"
ck; [[ $DR_ST -eq 0 ]] || { tail -80 "$SER" >&2; fail "comp-drive exited $DR_ST"; }

ck; grep -q 'DESK READY' "$SER" || fail "no DESK READY"
ck; grep -q 'DESK DOCK' "$SER" || fail "no DESK DOCK"
ck; ! grep -q 'FILES READY' "$SER" || fail "FILES on boot"
ck; ! grep -q 'SET READY' "$SER" || fail "SET on boot"

ck; python3 - "$PORT" "$SER" <<'PY' || fail "dock hits did not launch FILES and SET"
import json, socket, sys, time

port = int(sys.argv[1])
ser = sys.argv[2]

def read():
    return open(ser, "r", encoding="latin-1", errors="replace").read()

class Q:
    def __init__(self):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.s.settimeout(8)
        self.f = self.s.makefile("rw", encoding="utf-8")
        json.loads(self.f.readline())
        self.cmd("qmp_capabilities")

    def cmd(self, name, **kw):
        msg = {"execute": name}
        if kw:
            msg["arguments"] = kw
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            m = json.loads(line)
            if "event" in m:
                continue
            if "error" in m:
                raise SystemExit("QMP %s" % m["error"])
            return

q = Q()
GW, GH = 800, 600

def wait_new(tok, marked, timeout=12):
    deadline = time.time() + timeout
    while time.time() < deadline:
        now = read()
        if tok in now[len(marked):]:
            return True
        time.sleep(0.05)
    return False

def abs_xy(x, y):
    return x * 32767 // max(1, GW - 1), y * 32767 // max(1, GH - 1)

def place(x, y):
    ax, ay = abs_xy(x, y)
    for _ in range(8):
        n = read().count("MOUSE ABS")
        q.cmd("input-send-event", events=[
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}}])
        t = time.time() + 1.2
        while time.time() < t:
            if read().count("MOUSE ABS") > n:
                return
            time.sleep(0.04)

def click_until(x, y, token, tries=8):
    for _ in range(tries):
        marked = read()
        place(x, y)
        time.sleep(0.12)
        q.cmd("input-send-event", events=[
            {"type": "btn", "data": {"button": "left", "down": True}}])
        if wait_new(token, marked, timeout=1.8):
            q.cmd("input-send-event", events=[
                {"type": "btn", "data": {"button": "left", "down": False}}])
            return True
        q.cmd("input-send-event", events=[
            {"type": "btn", "data": {"button": "left", "down": False}}])
        time.sleep(0.25)
    return False

place(8, 8)
time.sleep(0.2)
# Settings first (right-island icon 0), then Files (icon 1), while
# the desk is still empty so a client body cannot steal the press.
if not click_until(552, 572, "DESK LAUNCH SET.ELF"):
    tail = [ln for ln in read().splitlines()
            if "DESK" in ln or "SET" in ln or "MOUSE" in ln]
    raise SystemExit("Settings icon did not launch last=%s" % tail[-10:])
deadline = time.time() + 12
while time.time() < deadline:
    if "SET READY" in read() or "SET CSD" in read():
        break
    time.sleep(0.1)
else:
    raise SystemExit("SET did not ready")
if not click_until(592, 572, "DESK LAUNCH FILES.ELF"):
    tail = [ln for ln in read().splitlines()
            if "DESK" in ln or "FILES" in ln or "MOUSE" in ln]
    raise SystemExit("Files icon did not launch last=%s" % tail[-10:])
deadline = time.time() + 12
while time.time() < deadline:
    if "FILES READY" in read() or "FILES CSD" in read():
        break
    time.sleep(0.1)
else:
    raise SystemExit("FILES did not ready")
print("dock launches ok")
PY

ck; grep -q 'DESK LAUNCH FILES.ELF' "$SER" || fail "no DESK LAUNCH FILES"
ck; grep -q 'FILES CSD' "$SER" || fail "FILES did not open glass CSD"
ck; grep -q 'DESK LAUNCH SET.ELF' "$SER" || fail "no DESK LAUNCH SET"
ck; grep -q 'SET CSD' "$SER" || fail "SET did not open glass CSD"
ck; grep -q 'Appearance' "$SET_C" \
  || fail "SET has no Appearance pane"
ck; grep -q 'Devices' "$SET_C" \
  || fail "SET has no Devices pane"
ck; grep -q 'CTL_ON 0x004080E0' "$SET_C" \
  || fail "SET accent is not the glass blue (still orange?)"
ck; ! grep -q 'CTL_ON 0x00E07020' "$SET_C" \
  || fail "SET still uses orange CTL_ON"
ck; grep -q 'lab_app' "$SET_C" || fail "SET has no Appearance label"
ck; ! grep -q 'OSGFX OOM' "$SER" || fail "Skia bump exhausted"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-DESKBOOT: PASS ($ASSERTIONS_REQUIRED checks) — empty desk, dock launches FILES and SET"
exit 0
