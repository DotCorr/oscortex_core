#!/usr/bin/env bash
# core/tests/conformance/d3-session/run.sh
#
# D3 + compositor: spawn two resident clients, the prompt comes back, and
# the windows are still live. Not d2-compositor: those clients exit and
# GAP-0306 reaps the surfaces. These stay READY and yield, so the region
# (and the window) outlive `proc spawn`.
#
# Binary: after `wm on` and two `proc spawn`s, a later `wm` still reports
# a live window, both clients printed COMMIT, and the serial has no REAP.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "D3-session: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D3-session: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run. A drop below it is the failure.
ASSERTIONS_REQUIRED=20

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d3s.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
SITIN="$CORE_DIR/scripts/sit-in.sh"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== PROGRAMS ==="
ck; bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" \
  || fail "the resident clients could not be built"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/progA.elf" "$WORKDIR/progB.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_A=$(lba_of A)
LBA_B=$(lba_of B)
ck; [[ -n "$LBA_A" && -n "$LBA_B" ]] || fail "could not read slot LBAs"
ck; [[ "$LBA_A" != "$LBA_B" ]] || fail "both clients have the same header LBA"
echo "IMAGE: pass  window A at 0x$LBA_A, window B at 0x$LBA_B"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'SYS_YIELD' "$SCRIPT_DIR/client.c" \
  || fail "client.c has no SYS_YIELD"
ck; grep -q 'SYS_SHMCREATE' "$SCRIPT_DIR/client.c" \
  || fail "client.c has no SYS_SHMCREATE"
ck; grep -q 'SYS_WMSURFACE' "$SCRIPT_DIR/client.c" \
  || fail "client.c has no SYS_WMSURFACE"
ck; grep -q 'for (;;)' "$SCRIPT_DIR/client.c" \
  || fail "client.c has no forever loop"
ck; grep -q 'shellProcSpawnArgs' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch proc spawn"
# THE DOOR PLANTS RESIDENT CLIENTS -- not necessarily D3's two toys.
#
# This asked sit-in.sh to name the string 'd3-session', which it did when D3
# landed and the door had nothing else to show. The door has since outgrown
# them: its disk is built by de-sitfat/build-disk.sh and plants FILES, SET,
# PING, STUDIO, DESK, BROWSE, PLAY, TAP and APP1. Asking for a literal path
# was asking the door not to grow, and the property D3 owns is that the LIVE
# door runs more than one resident client that owns a surface -- which is now
# more true than it was, not less. Assert the property, counted, with a floor
# of two, and require the door to spawn by 8.3 name rather than coop.
SITFAT_DISK="$CORE_DIR/tests/conformance/de-sitfat/build-disk.sh"
ck; [[ -f "$SITFAT_DISK" ]] \
  || fail "sit-in.sh's disk builder $SITFAT_DISK is missing — the door plants nothing"
ck; grep -q 'de-sitfat' "$SITIN" \
  || fail "sit-in.sh does not use de-sitfat to build its disk — the door's client set is unknown to this harness"
DOOR_CLIENTS=$(grep -cE '^  "[A-Z0-9]+\.ELF=' "$SITFAT_DISK" || true)
ck; [[ "$DOOR_CLIENTS" -ge 2 ]] \
  || fail "the door's disk plants $DOOR_CLIENTS client ELF(s); D3 needs at least two resident clients for two windows to be independent"
ck; grep -q 'proc spawn' "$SITIN" \
  || fail "sit-in.sh does not spawn the resident clients"
if grep -E 'typekeys.*proc coop|"proc coop ' "$SITIN"; then
  fail "sit-in.sh still types proc coop — those clients exit and the windows REAP"
fi
ck; true
echo "STRUCTURAL: pass  spawnable clients, sit-in no longer coops them"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

# qmp-drive.py waits for serial to go quiet. Two READY residents print
# YIELD/PREEMPT forever, so that wait cannot succeed. This driver does
# not wait for quiet; it waits for COMMIT markers and then quits.
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_A"),ret,until:USER WRITE D3S COMMIT,wait:400"
KEYS="$KEYS,$(typekeys 'wm'),ret,wait:600"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_B"),ret,until:USER WRITE D3S COMMIT,wait:400"

mkdir -p "$WORKDIR/boot"
SER="$WORKDIR/boot/serial.txt"
PNG="$WORKDIR/boot/shot.png"
: >"$SER"
ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" \
  >"$WORKDIR/boot/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 - "$port" "$SER" "$PNG" "$KEYS" <<'PY'
import json, os, socket, sys, time

port, serial, png, keys = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

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
                print("D3-session: QEMU", hello.get("QMP", {}).get("version", {}))
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
time.sleep(0.5)
untils = 0
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        untils += 1
        if not wait_marker(serial, marker + "\n", timeout=20, at_least=untils):
            raise SystemExit("never saw %d x %s" % (untils, marker))
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(0.4)
q.cmd("screendump", filename=os.path.abspath(png), format="png")
q.cmd("quit")
print("D3-session: wrote", png)
PY
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/boot/qemu.log" >&2
  echo "--- serial (tail) ---" >&2
  tail -80 "$SER" >&2
  fail "session driver exited $drive_status"
fi
ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
  cat "$WORKDIR/boot/qemu.log" >&2
  fail "qemu exited $qemu_status"
fi

echo
echo "=== ASSERT ==="
ck; python3 - "$SER" <<'PY' || fail "the boot does not satisfy a sittable session"
import re, sys

ser = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []

def count(pat):
    return len(re.findall(pat, ser, re.M))

spawns = count(r"^PROC SPAWN ")
if spawns != 2:
    fails.append("PROC SPAWN lines: %d, expected 2" % spawns)

if "WM ON BASE " not in ser:
    fails.append("compositor never came on")

attaches = count(r"^USER WRITE D3S ATTACH$")
if attaches != 2:
    fails.append("client ATTACH lines: %d, expected 2" % attaches)

commits = count(r"^USER WRITE D3S COMMIT$")
if commits != 2:
    fails.append("client COMMIT lines: %d, expected 2 — a window that never "
                 "committed is not on the screen" % commits)

kern_attach = count(r"^WM ATTACH W ")
if kern_attach < 2:
    fails.append("kernel WM ATTACH lines: %d, expected at least 2" % kern_attach)

kern_commit = count(r"^WM COMMIT W ")
if kern_commit < 2:
    fails.append("kernel WM COMMIT lines: %d, expected at least 2" % kern_commit)

if "WM REAP W " in ser:
    fails.append("WM REAP while the clients are still resident — GAP-0306 "
                 "fired even though nobody exited")

# The `wm` typed after the first spawn is the proof the prompt came back
# while a window was live. It must report WINS 1 (A is up; B is not yet).
# A later `wm` after both are READY would starve: two runnable residents
# schedule among themselves. That is leftover, not this assertion.
states = re.findall(r"^WM STATE A ([0-9]) WINS ([0-9]) ", ser, re.M)
if not states:
    fails.append("no WM STATE line — the prompt did not run `wm` after spawn")
else:
    active, wins = states[0]
    if active != "1":
        fails.append("first WM STATE active is %s, expected 1" % active)
    if wins != "1":
        fails.append("first WM STATE wins is %s, expected 1 (window A live "
                     "after spawn returned)" % wins)
    print("    (wm after first spawn: A %s WINS %s)" % (active, wins))

if "PROC END" in ser:
    fails.append("PROC END — a resident client exited; sit-in is not coop")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-80:]), file=sys.stderr)
    sys.exit(1)

print("    (two PROC SPAWN, two client commits, no REAP, prompt ran wm)")
PY

ck; [[ -s "$SER" ]] || fail "serial capture is empty"
ck; [[ -f "$WORKDIR/boot/shot.png" ]] || fail "qmp-drive wrote no PNG"
require_assertions "$ASSERTIONS_REQUIRED"
echo "D3-session: PASS — two spawned clients attached and committed, the prompt ran \`wm\` while a window was live, and nothing REAPed."
exit 0
