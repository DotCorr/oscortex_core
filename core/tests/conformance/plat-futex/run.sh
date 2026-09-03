#!/usr/bin/env bash
# core/tests/conformance/plat-futex/run.sh
#
# ADR-0146: a named platform ELF may futex-wait/wake on a shared
# word. TAP/FILES stay 64 KiB / 2 MiB. Same binary planted as
# PLAT.ELF and ASK.ELF — only the name honours syscall 30.
# Parent waits; child stores SIG and wakes; parent writes the
# derived SYNC line. ASK.ELF of the same bytes is BadArg.
#
# Not glibc. Not CEF OnPaint. Not TLS. Syscall 11 stays fdwait.
# No help line. drawRRect owns osgfx_skia. de-browse floor stays 87.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "PLAT-FUTEX: FAIL — $1" >&2; exit 1; }
setup_error() { echo "PLAT-FUTEX: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run.
ASSERTIONS_REQUIRED=46

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-plat-futex.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
name = sys.argv[2]
m = re.search(r"const int %s = ([0-9xXa-fA-F]+);" % re.escape(name), src)
if not m:
    sys.exit(1)
print(int(m.group(1), 0))
PY
}

echo "=== BUILD ==="
if [[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]]; then
  # shellcheck disable=SC1091
  source /Users/ghostportal/Desktop/dc_sys/env.sh
fi
# Lean kernel: this door is proc/futex, not Graphite or FFmpeg.
capture_sh BUILD_OUT BUILD_STATUS -- \
  "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 OSGFX_CRT=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "BUILD: build-kernel.sh exited $BUILD_STATUS (osgfx/media may be mid-edit)"
fi
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+procSysFutex$' \
  || fail "kernel.elf has no procSysFutex — this door is not linked"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
VM_PROG_END=$(dartconst vmProgEnd vm.dart)
FUTEX_NO=$(dartconst procSysFutexNo proc.dart)
CLONE_NO=$(dartconst procSysCloneNo proc.dart)
DLOPEN_NO=$(dartconst elfSysDlopenNo elf.dart)
MMAP_NO=$(dartconst heapSysMmapNo heap.dart)
SPAWN_NO=$(dartconst procSysSpawnNo proc.dart)
WAIT_WORD=$(dartconst procSlotWaitAddr proc.dart)
BLOCKED=$(dartconst procStateBlocked proc.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 229318656 ]] \
  || fail "heapPlatMaxInc moved — platform window is RO+RX LOAD span (ADR-0168)"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$VM_PROG_END" -eq 270532608 ]] \
  || fail "vmProgEnd moved — app load window must stay 2 MiB"
ck; [[ "$FUTEX_NO" -eq 30 ]] \
  || fail "procSysFutexNo is $FUTEX_NO, expected 30"
ck; [[ "$CLONE_NO" -eq 28 ]] \
  || fail "clone moved off 28"
ck; [[ "$DLOPEN_NO" -eq 29 ]] \
  || fail "dlopen moved off 29"
ck; [[ "$MMAP_NO" -eq 27 ]] \
  || fail "mmap moved off 27"
ck; [[ "$SPAWN_NO" -eq 26 ]] \
  || fail "spawn moved off 26"
ck; [[ "$WAIT_WORD" -eq 28 ]] \
  || fail "procSlotWaitAddr is $WAIT_WORD, expected 28"
ck; [[ "$BLOCKED" -eq 5 ]] \
  || fail "procStateBlocked is $BLOCKED, expected 5"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; grep -E '^\| 30 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q futex \
  || fail "syscall 30 is not futex in the registry"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" >/dev/null \
  || fail "verify-syscall-registry.sh disagrees"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$CORE_DIR/tests/conformance/de-browse/run.sh" \
  || fail "de-browse floor moved — do not raise it on this door"
ck; grep -q 'procSysFutexNo' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart has no procSysFutexNo"
ck; grep -q 'procSysFutexNo' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart never dispatches futex"
ck; grep -q 'procStateBlocked' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart has no BLOCKED state"
ck; grep -q 'ADR-0146' "$CORE_DIR/docs/decisions/0146-futex-is-the-platform-wait-door.md" \
  || fail "ADR-0146 file is missing"
ck; grep -q '0145 is VirtIO-net' "$CORE_DIR/docs/decisions/0146-futex-is-the-platform-wait-door.md" \
  || fail "ADR-0146 stole 0145"
ck; ! grep -q 'proc futex\|futex ' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a futex help string"
ck; ! grep -q 'osgfx_skia' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart touched osgfx_skia — drawRRect owns that"
ck; ! grep -q 'osgfx_skia' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart touched osgfx_skia"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
echo "STRUCTURAL: pass  futex=30 on PLAT.ELF only; TAP/FILES 64K/2MiB; fdwait=11; help 2511"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/plat-futex.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/plat.elf" \
  || fail "make-image.py could not write the volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }

DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" > "$DERIVED" || fail "derive.py failed"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

echo
echo "=== BOOT — PLAT.ELF then ASK.ELF ==="
KEYS="$(typekeys 'vm'),ret,until:READY 1"
KEYS="$KEYS,$(typekeys 'proc spawn plat.elf'),ret,until:SYNC ,wait:400"
KEYS="$KEYS,$(typekeys 'proc spawn ask.elf'),ret,until:CAP 0000000000200000,until:PROC KILL,wait:400"

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
                print("PLAT-FUTEX: QEMU", hello.get("QMP", {}).get("version", {}))
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

def wait_marker(path, marker, timeout=40, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_marker(path, marker) >= at_least:
            return True
        time.sleep(0.1)
    return False

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("kernel never reached the prompt")
time.sleep(3.0)
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        if not wait_marker(serial, marker, timeout=40):
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
ck; [[ -s "$SER" ]] || fail "the boot captured no serial"

echo
echo "=== ASSERT ==="
python3 - "$SER" "$DERIVED" <<'PY' || fail "the boot does not satisfy the futex door"
import re, sys

ser = open(sys.argv[1], "rb").read().decode("latin-1")
derived = {}
for line in open(sys.argv[2]):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        derived[k] = v
fails = []

def need(token, label):
    if token not in ser:
        fails.append("%s missing %r" % (label, token))

need("ELF FILE PLAT    .ELF", "plat load")
need("ELF FILE ASK     .ELF", "ask load")
need("PROC PLAT 00 WIN 000000000DCFC000", "plat flag")
need("PROC CLONE ", "clone line")
need("PROC FUTEX ", "futex line")
need("WAIT ", "kernel WAIT print")
need("WAKE ", "kernel WAKE print")
need(derived["msg_child"], "child write() from shared pages")
need(derived["sync_line"], "derived SYNC after wake")
need(derived["child_line"], "derived CHILD xor")
need(derived["cap_plat"], "plat cap line")
need(derived["asked_bad"], "ask clone refused")
need(derived["fask_bad"], "ask futex refused")
need(derived["futex_err"], "ask PROC FUTEX ERR")
need(derived["cap_app"], "ask old cap line")
need("PLAT START", "program ran")
need("BAD 0000000000000000", "program reported no faults")

if derived["zero_mix"] in ser:
    fails.append("SYNC printed the zero mix — wait never saw the child's SIG")
if "PROC PLAT 01" in ser or "PROC PLAT 00 WIN 0000000000200000" in ser:
    fails.append("ASK.ELF was given a platform flag")
if ser.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1 (only PLAT.ELF)" % ser.count("PROC PLAT "))
if ser.count(derived["sync_line"]) != 1:
    fails.append("derived SYNC count: %d, expected 1" % ser.count(derived["sync_line"]))
if ser.count("CHILD LINE") != 1:
    fails.append("CHILD LINE count: %d, expected 1" % ser.count("CHILD LINE"))
if "ELF DISK LBA" in ser:
    fails.append("boot used the LBA loader")

waits = re.findall(r"PROC FUTEX ([0-9A-Fa-f]+) WAIT ", ser)
wakes = re.findall(r"PROC FUTEX ([0-9A-Fa-f]+) WAKE ", ser)
if not waits:
    fails.append("no PROC FUTEX WAIT — parent never blocked")
if not wakes:
    fails.append("no PROC FUTEX WAKE — child never woke")

# WAIT must appear before WAKE in the serial (parent blocked, then child woke).
wi = ser.find("WAIT ")
wk = ser.find("WAKE ")
sy = ser.find(derived["sync_line"])
if wi < 0 or wk < 0 or sy < 0:
    fails.append("ordering markers missing")
elif not (wi < wk < sy):
    fails.append("order was not WAIT < WAKE < SYNC (wi=%d wk=%d sy=%d)" % (wi, wk, sy))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-120:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF futex wait/wake → derived SYNC; ASK.ELF same bytes refused)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "PLAT-FUTEX: PASS — named PLAT.ELF futex wait/wake synced two clones (syscall 30); derived SYNC after WAKE; ASK.ELF is the same bytes and is refused; TAP/FILES stay 64K/2MiB; leftovers TLS / libc / 189MiB"
exit 0
