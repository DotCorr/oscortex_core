#!/usr/bin/env bash
# core/tests/conformance/apps1/run.sh
#
# Application system: named FRAME apps on a FAT volume, launched by
# 8.3 name through `proc spawn`, not by raw LBA.
#
# `run NAME` has argv; `proc spawn <lba>` has heap and residency.
# This harness is the seam: `proc spawn APP1.ELF` does procCreate +
# elfLoadFile (FAT) and stays READY. No new syscall, no help line
# (GAP-0304 / m3-shell golden), no last .bss theft.
#
# Binary: APPS.TXT lists two 8.3 ELFs; `cat` shows both names;
# `proc spawn app1.elf` and `proc spawn app2.elf` each print ELF FILE
# <name>, sbrk succeeds, and PROC SPAWN. Negative: a missing name is
# FS ERR 10, not a load.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "APPS1: FAIL — $1" >&2; exit 1; }
setup_error() { echo "APPS1: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run. A drop below it is the failure.
ASSERTIONS_REQUIRED=43

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-apps1.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
MOUNTPOINT="$WORKDIR/mnt"
ATTACHED=""
cleanup() {
  [[ -n "$ATTACHED" ]] && hdiutil detach "$ATTACHED" -force >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'shellProcSpawnName' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart has no shellProcSpawnName — spawn is still LBA-only"
ck; grep -q 'shellProcSpawnArgs' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch proc spawn"
ck; grep -A20 'void shellProcSpawnArgs' "$CORE_DIR/kernel/proc.dart" \
  | grep -q 'procFieldEnd' \
  || fail "shellProcSpawnArgs no longer tokenizes a second word"
ck; grep -A30 'void shellProcSpawnArgs' "$CORE_DIR/kernel/proc.dart" \
  | grep -q 'shellProcSpawnName' \
  || fail "shellProcSpawnArgs does not hand a non-hex word to spawn-by-name"
# spawn is already dispatched from shell.dart; it must not grow help.
ck; ! grep -q 'proc spawn' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a proc spawn help string — leave it out of help"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — help moved"
ck; ! grep -q 'proc spawn' "$CORE_DIR/tests/conformance/m3-shell/expected.txt" \
  || fail "m3-shell expected.txt grew a proc spawn help line"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — stolen last place"
# The spawn-by-name path is new functions, not a new @bss block.
ck; ! grep -n 'shellProcSpawnName' -A40 "$CORE_DIR/kernel/proc.dart" \
  | grep -q '@bss' \
  || fail "spawn-by-name donated .bss"
ck; ! grep -E '^[0-9]+ +spawn' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "a syscall was allocated for spawn — reuse elfLoadFile"
MASK_SITES=$(grep -c 'procSessionTimerOff();' "$CORE_DIR/kernel/proc.dart")
ck; [[ "$MASK_SITES" -eq 8 ]] \
  || fail "procSessionTimerOff sites moved to $MASK_SITES (expected 8)"
echo "STRUCTURAL: pass  spawn-by-name, help 2511, last .bss wmeventStore, no new syscall"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/apps1.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/app1.elf" "$WORKDIR/app2.elf" \
  || fail "make-image.py could not write the volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
echo "IMAGE: pass  fsck_msdos accepts the volume"

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
  ck; [[ $ATTACH_STATUS -eq 0 ]] \
    || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount the image"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  ck; [[ -f "$MOUNTPOINT/APP1.ELF" ]] || fail "mounted volume has no APP1.ELF"
  ck; [[ -f "$MOUNTPOINT/APP2.ELF" ]] || fail "mounted volume has no APP2.ELF"
  ck; [[ -f "$MOUNTPOINT/APPS.TXT" ]] || fail "mounted volume has no APPS.TXT"
  ck; cmp -s "$MOUNTPOINT/APP1.ELF" "$WORKDIR/app1.elf" \
    || fail "macOS reads APP1.ELF differently"
  ck; cmp -s "$MOUNTPOINT/APP2.ELF" "$WORKDIR/app2.elf" \
    || fail "macOS reads APP2.ELF differently"
  ck; cmp -s "$MOUNTPOINT/APPS.TXT" "$DISK_IMG.apps" \
    || fail "macOS reads APPS.TXT differently from the planted catalog"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  macOS msdos driver reads APP1.ELF, APP2.ELF, APPS.TXT"
fi

echo
echo "=== DERIVE ==="
DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG.apps" > "$DERIVED" \
  || fail "derive.py could not derive expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
ck; [[ "$(d catalog_lines)" -eq 2 ]] || fail "catalog is not two names"
ck; [[ "$(d marker_a)" != "$(d marker_b)" ]] \
  || fail "the two app markers are identical — the test is vacuous"
echo "DERIVED: $(d elf_file_a) / $(d elf_file_b)"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

echo
echo "=== BOOT A — catalog, then spawn both names ==="
# Two READY yielders print PREEMPT forever, so qmp-drive's quiet wait
# cannot succeed. This driver waits for markers and quits.
KEYS="$(typekeys 'cat apps.txt'),ret,until:APP2.ELF,wait:400"
KEYS="$KEYS,$(typekeys 'proc spawn app1.elf'),ret,until:USER WRITE APPS1 APP1 HEAP 1,wait:400"
KEYS="$KEYS,$(typekeys 'proc spawn app2.elf'),ret,until:USER WRITE APPS1 APP2 HEAP 1,wait:400"

mkdir -p "$WORKDIR/main"
SER="$WORKDIR/main/serial.txt"
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
  >"$WORKDIR/main/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 - "$port" "$SER" "$KEYS" <<'PY'
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
                hello = json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                print("APPS1: QEMU", hello.get("QMP", {}).get("version", {}))
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
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        if not wait_marker(serial, marker, timeout=20):
            raise SystemExit("never saw %s" % marker)
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(0.4)
q.cmd("quit")
PY
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/main/qemu.log" >&2
  echo "--- serial (tail) ---" >&2
  tail -80 "$SER" >&2
  fail "session driver exited $drive_status"
fi
ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
  cat "$WORKDIR/main/qemu.log" >&2
  fail "qemu exited $qemu_status"
fi
ck; [[ -s "$SER" ]] || fail "the main boot captured no serial"

echo
echo "=== BOOT B — missing name is a FAT refusal ==="
NEG_KEYS="$(typekeys 'proc spawn nosuch.elf'),ret,wait:2500"
mkdir -p "$WORKDIR/neg"
NSER="$WORKDIR/neg/serial.txt"
: >"$NSER"
ck; nport=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$NSER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$nport,server,nowait" \
  >"$WORKDIR/neg/qemu.log" 2>&1 &
nqemu_pid=$!
run_status ndrive_status -- python3 "$DRIVER" --port "$nport" --serial "$NSER" \
  --wait-for 'M1 END\n' --png "$WORKDIR/neg/shot.png" --screen-text "$WORKDIR/neg/screen.txt" \
  --keys "$NEG_KEYS"
await nqemu_status "$nqemu_pid"
ck; if [[ $ndrive_status -ne 0 ]]; then
  cat "$WORKDIR/neg/qemu.log" >&2
  echo "--- serial ---" >&2
  tail -40 "$NSER" >&2
  fail "qmp-drive.py exited $ndrive_status for the missing-name boot"
fi
ck; if [[ $nqemu_status -ne 0 && $nqemu_status -ne 124 ]]; then
  cat "$WORKDIR/neg/qemu.log" >&2
  fail "qemu exited $nqemu_status on the missing-name boot"
fi

echo
echo "=== ASSERT ==="
python3 - "$SER" "$NSER" "$DERIVED" <<'PY' || fail "the boots do not satisfy named spawn"
import re, sys

main = open(sys.argv[1], "rb").read().decode("latin-1")
neg = open(sys.argv[2], "rb").read().decode("latin-1")
derived = {}
for line in open(sys.argv[3]):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        derived[k] = v
fails = []

def need(ser, key, label):
    if derived[key] not in ser:
        fails.append("%s missing %r" % (label, derived[key]))

need(main, "cat_a", "catalog cat")
need(main, "cat_b", "catalog cat")
need(main, "fs_open_a", "spawn APP1")
need(main, "fs_open_b", "spawn APP2")
need(main, "elf_file_a", "spawn APP1")
need(main, "elf_file_b", "spawn APP2")
need(main, "marker_a", "APP1 ran")
need(main, "marker_b", "APP2 ran")
need(main, "heap_a", "APP1 heap")
need(main, "heap_b", "APP2 heap")

if derived["heap_fail_a"] in main:
    fails.append("APP1 HEAP 0 — sbrk was refused; spawn did not give a process heap")
if derived["heap_fail_b"] in main:
    fails.append("APP2 HEAP 0 — sbrk was refused")

spawns = len(re.findall(r"^PROC SPAWN ", main, re.M))
if spawns != 2:
    fails.append("PROC SPAWN lines: %d, expected 2" % spawns)

if "ELF DISK LBA" in main:
    fails.append("main boot used the LBA loader — name spawn must go through ELF FILE")

if "PROC END" in main:
    fails.append("PROC END — a spawned app exited; spawn is supposed to stay")

need(neg, "missing", "missing-name boot")
if derived["elf_file_a"] in neg or derived["elf_file_b"] in neg:
    fails.append("missing-name boot still loaded an ELF")
if "PROC SPAWN" in neg:
    fails.append("missing-name boot printed PROC SPAWN")
if "usage:" in neg.lower() and "no such name" not in neg:
    fails.append("missing name fell through to usage instead of FAT lookup")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- main serial (tail) ----", file=sys.stderr)
    print("\n".join(main.splitlines()[-80:]), file=sys.stderr)
    print("---- neg serial (tail) ----", file=sys.stderr)
    print("\n".join(neg.splitlines()[-40:]), file=sys.stderr)
    sys.exit(1)

print("    (cat APPS.TXT, two ELF FILE names, two HEAP 1, two PROC SPAWN, FS ERR 10)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "APPS1: PASS — APPS.TXT listed APP1.ELF and APP2.ELF; proc spawn by 8.3 name loaded both from FAT (ELF FILE, not LBA), each sbrk'd, both stayed resident; a missing name is FS ERR 10; help unchanged (2511), no new syscall, last .bss still wmeventStore"
exit 0
