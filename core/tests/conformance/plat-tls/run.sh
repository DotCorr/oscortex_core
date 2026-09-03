#!/usr/bin/env bash
# core/tests/conformance/plat-tls/run.sh
#
# ADR-0148: a named platform ELF may plant IA32_FS_BASE so a
# %fs: load/store reaches a derived TLS block. TAP/FILES stay
# 64 KiB / 2 MiB. Same binary planted as PLAT.ELF and ASK.ELF —
# only the name honours syscall 33. PLAT setfs + %fs store/load
# prints derived TLS. ASK.ELF of the same bytes is BadArg.
#
# Anti-vacuity: without the MSR write, %fs:0 faults at VA 0 and
# the derived line is missing.
#
# Not glibc. Not CEF OnPaint. Not futex. Syscall 11 stays fdwait.
# No help line. drawRRect owns osgfx_skia. de-browse floor stays 87.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "PLAT-TLS: FAIL — $1" >&2; exit 1; }
setup_error() { echo "PLAT-TLS: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run.
ASSERTIONS_REQUIRED=52

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-plat-tls.XXXXXX")" \
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
# Lean kernel: this door is proc/TLS, not Graphite or FFmpeg.
capture_sh BUILD_OUT BUILD_STATUS -- \
  "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 OSGFX_CRT=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "BUILD: build-kernel.sh exited $BUILD_STATUS (osgfx/media may be mid-edit)"
fi
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+procSysSetfs$' \
  || fail "kernel.elf has no procSysSetfs — this door is not linked"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+msr_write$' \
  || fail "kernel.elf has no msr_write — FS.base cannot be planted"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
VM_PROG_END=$(dartconst vmProgEnd vm.dart)
SETFS_NO=$(dartconst procSysSetfsNo proc.dart)
FUTEX_NO=$(dartconst procSysFutexNo proc.dart)
CLONE_NO=$(dartconst procSysCloneNo proc.dart)
DLOPEN_NO=$(dartconst elfSysDlopenNo elf.dart)
MMAP_NO=$(dartconst heapSysMmapNo heap.dart)
SPAWN_NO=$(dartconst procSysSpawnNo proc.dart)
FS_WORD=$(dartconst procSlotFsBase proc.dart)
FS_MSR=$(dartconst procFsBaseMsr proc.dart)
UNLINK_NO=$(dartconst fileSysUnlinkNo file.dart)
RENAME_NO=$(dartconst fileSysRenameNo file.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 229318656 ]] \
  || fail "heapPlatMaxInc moved — platform window is RO+RX LOAD span (ADR-0168)"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$VM_PROG_END" -eq 270532608 ]] \
  || fail "vmProgEnd moved — app load window must stay 2 MiB"
ck; [[ "$SETFS_NO" -eq 33 ]] \
  || fail "procSysSetfsNo is $SETFS_NO, expected 33"
ck; [[ "$FUTEX_NO" -eq 30 ]] \
  || fail "futex moved off 30"
ck; [[ "$CLONE_NO" -eq 28 ]] \
  || fail "clone moved off 28"
ck; [[ "$DLOPEN_NO" -eq 29 ]] \
  || fail "dlopen moved off 29"
ck; [[ "$MMAP_NO" -eq 27 ]] \
  || fail "mmap moved off 27"
ck; [[ "$SPAWN_NO" -eq 26 ]] \
  || fail "spawn moved off 26"
ck; [[ "$UNLINK_NO" -eq 31 ]] \
  || fail "unlink moved off 31"
ck; [[ "$RENAME_NO" -eq 32 ]] \
  || fail "rename moved off 32"
ck; [[ "$FS_WORD" -eq 29 ]] \
  || fail "procSlotFsBase is $FS_WORD, expected 29"
ck; [[ "$FS_MSR" -eq 3221225728 ]] \
  || fail "procFsBaseMsr is $FS_MSR, expected 0xC0000100"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; grep -E '^\| 33 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q setfs \
  || fail "syscall 33 is not setfs in the registry"
ck; grep -E '^\| 30 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q futex \
  || fail "syscall 30 is not futex in the registry"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" >/dev/null \
  || fail "verify-syscall-registry.sh disagrees"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$CORE_DIR/tests/conformance/de-browse/run.sh" \
  || fail "de-browse floor moved — do not raise it on this door"
ck; grep -q 'procSysSetfsNo' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart has no procSysSetfsNo"
ck; grep -q 'procSysSetfsNo' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart never dispatches setfs"
ck; grep -q 'msr_write' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart has no msr_write"
ck; grep -q 'msr_write' "$CORE_DIR/boot/isr.S" \
  || fail "isr.S has no msr_write"
ck; grep -q 'ADR-0148' "$CORE_DIR/docs/decisions/0148-setfs-is-the-platform-tls-door.md" \
  || fail "ADR-0148 file is missing"
ck; grep -q '0147 is unlink' "$CORE_DIR/docs/decisions/0148-setfs-is-the-platform-tls-door.md" \
  || fail "ADR-0148 stole 0147"
ck; ! grep -q 'proc setfs\|setfs ' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a setfs help string"
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
echo "STRUCTURAL: pass  setfs=33 on PLAT.ELF only; TAP/FILES 64K/2MiB; fdwait=11; help 2511"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/plat-tls.img"
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
KEYS="$KEYS,$(typekeys 'proc spawn plat.elf'),ret,until:TLS ,wait:400"
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
                print("PLAT-TLS: QEMU", hello.get("QMP", {}).get("version", {}))
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
python3 - "$SER" "$DERIVED" <<'PY' || fail "the boot does not satisfy the TLS door"
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
need("PROC SETFS ", "setfs line")
need(derived["asked_ok"], "plat setfs ok")
need(derived["tls_line"], "derived TLS after %fs store/load")
need(derived["cap_plat"], "plat cap line")
need(derived["asked_bad"], "ask setfs refused")
need(derived["setfs_err"], "ask PROC SETFS ERR")
need(derived["cap_app"], "ask old cap line")
need("PLAT START", "program ran")
need("BAD 0000000000000000", "program reported no faults")

if derived["zero_mix"] in ser:
    fails.append("TLS printed the zero mix — %fs store never landed SIG")
if "PROC PLAT 01" in ser or "PROC PLAT 00 WIN 0000000000200000" in ser:
    fails.append("ASK.ELF was given a platform flag")
if ser.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1 (only PLAT.ELF)" % ser.count("PROC PLAT "))
if ser.count(derived["tls_line"]) != 1:
    fails.append("derived TLS count: %d, expected 1" % ser.count(derived["tls_line"]))
if "ELF DISK LBA" in ser:
    fails.append("boot used the LBA loader")
if "USER FAULT" in ser or "PROC FAULT" in ser:
    fails.append("a fault fired — FS.base was not live for the %fs store")

sets = re.findall(r"PROC SETFS ([0-9A-Fa-f]+) ADDR ", ser)
errs = re.findall(r"PROC SETFS ([0-9A-Fa-f]+) ERR ", ser)
if not sets:
    fails.append("no PROC SETFS ADDR — PLAT never planted FS.base")
if not errs:
    fails.append("no PROC SETFS ERR — ASK never refused")

# ADDR must appear before the derived TLS line; ERR after ASK spawn.
si = ser.find("PROC SETFS ")
tl = ser.find(derived["tls_line"])
ei = ser.find(derived["setfs_err"])
if si < 0 or tl < 0 or ei < 0:
    fails.append("ordering markers missing")
elif not (si < tl < ei):
    fails.append("order was not SETFS < TLS < ASK ERR (si=%d tl=%d ei=%d)" % (si, tl, ei))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-120:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF setfs + %fs store/load → derived TLS; ASK.ELF same bytes refused)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "PLAT-TLS: PASS — named PLAT.ELF planted IA32_FS_BASE (syscall 33); derived TLS after %fs store/load; ASK.ELF is the same bytes and is refused; TAP/FILES stay 64K/2MiB; leftovers libc / 189MiB"
exit 0
