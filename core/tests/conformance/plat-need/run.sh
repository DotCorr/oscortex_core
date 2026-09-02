#!/usr/bin/env bash
# core/tests/conformance/plat-need/run.sh
#
# ADR-0157: named PLAT.ELF walks two DT_NEEDED (LIBC.SO + LIBM.SO),
# dlopens each, and prints derived LINE1 / LINE2 from write and
# need_fn. ASK.ELF of the same bytes is REFUSED 11. A volume without
# LIBM.SO cannot invent LINE2. Satisfies 2 of 32 CEF DT_NEEDED
# stand-ins; 30 remain. OnPaint leftover. Not glibc. Not libcef.
# Syscall 11 stays fdwait. TAP/FILES stay 64K/2MiB. No help line.
# Graphite / osgfx_skia / MakeVulkan / Venus fenced.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "PLAT-NEED: FAIL — $1" >&2; exit 1; }
setup_error() { echo "PLAT-NEED: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run.
ASSERTIONS_REQUIRED=49

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-plat-need.XXXXXX")" \
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
# Lean kernel: this door is ELF/FAT DT_NEEDED, not Graphite or FFmpeg.
capture_sh BUILD_OUT BUILD_STATUS -- \
  "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 OSGFX_CRT=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "BUILD: build-kernel.sh exited $BUILD_STATUS (osgfx/media may be mid-edit)"
fi
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfSysDlopen$' \
  || fail "kernel.elf has no elfSysDlopen — this door is not linked"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfDlopenMakeExec$' \
  || fail "kernel.elf has no elfDlopenMakeExec — call would stay NX"
ck; grep -aob $'need_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no need_fn NUL string — ADR-0157 resolve is missing"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
VM_PROG_END=$(dartconst vmProgEnd vm.dart)
DLOPEN_NO=$(dartconst elfSysDlopenNo elf.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 231718912 ]] \
  || fail "heapPlatMaxInc moved — platform window is RO+RX LOAD span (ADR-0168)"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$VM_PROG_END" -eq 270532608 ]] \
  || fail "vmProgEnd moved — app load window must stay 2 MiB"
ck; [[ "$DLOPEN_NO" -eq 29 ]] \
  || fail "elfSysDlopenNo is $DLOPEN_NO, expected 29"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; grep -E '^\| 29 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q dlopen \
  || fail "syscall 29 is not dlopen in the registry"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" >/dev/null \
  || fail "verify-syscall-registry.sh disagrees"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$CORE_DIR/tests/conformance/de-browse/run.sh" \
  || fail "de-browse floor moved — do not raise it on this door"
ck; grep -q 'elfStrNeedFn' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart has no elfStrNeedFn — need_fn resolve is missing"
ck; grep -q 'ADR-0157' "$CORE_DIR/docs/decisions/0157-dt-needed-loads-two-fat-sos.md" \
  || fail "ADR-0157 file is missing"
ck; grep -q '0156 is `shmshrink`' "$CORE_DIR/docs/decisions/0157-dt-needed-loads-two-fat-sos.md" \
  || fail "ADR-0157 stole 0156"
ck; ! grep -q 'proc need\|DT_NEEDED' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a need help string"
ck; ! grep -q 'osgfx_skia' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart touched osgfx_skia — drawRRect owns that"
ck; ! grep -q 'MakeVulkan\|Venus' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart touched MakeVulkan/Venus — fenced"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
# Prior doors must stay linked.
ck; [[ -d "$CORE_DIR/tests/conformance/plat-huge" ]] \
  || fail "plat-huge harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-libc" ]] \
  || fail "plat-libc harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-dl" ]] \
  || fail "plat-dl harness missing — do not break it"
echo "STRUCTURAL: pass  DT_NEEDED×2 via dlopen=29; TAP/FILES 64K/2MiB; fdwait=11; help 2511; 2/32 satisfied"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_FULL="$WORKDIR/plat-need.img"
DISK_ONE="$WORKDIR/plat-need-one.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_FULL" "$WORKDIR/plat.elf" \
  "$WORKDIR/libc.so" "$WORKDIR/libm.so" \
  || fail "make-image.py could not write the full volume"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_ONE" "$WORKDIR/plat.elf" \
  "$WORKDIR/libc.so" \
  || fail "make-image.py could not write the one-lib volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_FULL"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck rejected full image"; }
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_ONE"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck rejected one-lib image"; }

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

run_boot() {
  local label="$1" disk="$2" keys="$3" ser="$4"
  mkdir -p "$(dirname "$ser")"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$disk,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$WORKDIR/$label/qemu.log" 2>&1 &
  local qemu_pid=$!
  run_status drive_status -- python3 - "$port" "$ser" "$keys" <<'PY'
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
                print("PLAT-NEED: QEMU", hello.get("QMP", {}).get("version", {}))
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
    cat "$WORKDIR/$label/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -80 "$ser" >&2
    fail "$label session driver exited $drive_status"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$WORKDIR/$label/qemu.log" >&2
    fail "$label qemu exited $qemu_status"
  fi
  ck; [[ -s "$ser" ]] || fail "$label captured no serial"
}

echo
echo "=== BOOT — full (LIBC.SO + LIBM.SO) then ASK.ELF ==="
KEYS_FULL="$(typekeys 'vm'),ret,until:READY 1"
KEYS_FULL="$KEYS_FULL,$(typekeys 'proc spawn plat.elf'),ret,until:LINE2 ,wait:400"
KEYS_FULL="$KEYS_FULL,$(typekeys 'proc spawn ask.elf'),ret,until:REFUSED 11,until:PROC KILL,wait:400"
run_boot full "$DISK_FULL" "$KEYS_FULL" "$WORKDIR/full/serial.txt"

echo
echo "=== BOOT — one-lib (LIBM.SO absent) ==="
KEYS_ONE="$(typekeys 'vm'),ret,until:READY 1"
KEYS_ONE="$KEYS_ONE,$(typekeys 'proc spawn plat.elf'),ret,until:MISS ,wait:400"
run_boot one "$DISK_ONE" "$KEYS_ONE" "$WORKDIR/one/serial.txt"

echo
echo "=== ASSERT ==="
python3 - "$WORKDIR/full/serial.txt" "$WORKDIR/one/serial.txt" "$DERIVED" <<'PY' || fail "boots do not satisfy the DT_NEEDED door"
import re, sys

full = open(sys.argv[1], "rb").read().decode("latin-1")
one = open(sys.argv[2], "rb").read().decode("latin-1")
derived = {}
for line in open(sys.argv[3]):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        derived[k] = v
fails = []

def need(ser, token, label):
    if token not in ser:
        fails.append("%s missing %r" % (label, token))

need(full, "ELF FILE PLAT    .ELF", "full plat load")
need(full, "ELF FILE ASK     .ELF", "full ask load")
need(full, "PROC PLAT 00 WIN 000000000DCFC000", "plat flag")
need(full, "NEED START", "program ran")
need(full, "FS OPEN LIBC    .SO", "libc.so opened")
need(full, "FS OPEN LIBM    .SO", "libm.so opened")
need(full, "VIA LIBC", "write called through libc")
need(full, "VIA LIBM", "need_fn called through libm")
need(full, derived["line1"], "derived LINE1")
need(full, derived["line2"], "derived LINE2")
need(full, derived["need_two"], "both NEEDED loaded")
need(full, derived["refuse"], "ASK.ELF REFUSED 11")
need(full, "BAD 0000000000000000", "full program reported no faults")

if "PROC PLAT 01" in full or "PROC PLAT 00 WIN 0000000000200000" in full:
    fails.append("ASK.ELF was given a platform flag")
if full.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1" % full.count("PROC PLAT "))
if full.count(derived["line1"]) != 1:
    fails.append("LINE1 count: %d, expected 1" % full.count(derived["line1"]))
if full.count(derived["line2"]) != 1:
    fails.append("LINE2 count: %d, expected 1" % full.count(derived["line2"]))
if "ELF DISK LBA" in full:
    fails.append("boot used the LBA loader")

opens = re.findall(r"PROC DLOPEN 00 VA ([0-9A-Fa-f]+)", full)
if len(opens) < 2:
    fails.append("PROC DLOPEN VA count: %d, expected ≥2" % len(opens))
else:
    for va_s in opens[:2]:
        va = int(va_s, 16)
        if va < 0x10400000 or va >= 0x1C100000:
            fails.append("dlopen VA %s outside platform heap" % va_s)

# Anti-vacuity: missing LIBM.SO → LINE1 ok, no LINE2.
need(one, "NEED START", "one-lib program ran")
need(one, "FS OPEN LIBC    .SO", "one-lib libc opened")
need(one, derived["line1"], "one-lib LINE1")
need(one, derived["miss_line"], "one-lib missing LIBM refused")
need(one, derived["need_one"], "one-lib stopped after first NEEDED")
if derived["line2"] in one:
    fails.append("one-lib invented LINE2 without LIBM.SO")
if "FS OPEN LIBM    .SO" in one:
    fails.append("one-lib opened LIBM.SO — volume should lack it")
if "VIA LIBM" in one:
    fails.append("one-lib called through LIBM without the file")
if "ERR FFFFFFFFFFFFFFF9" not in one:
    fails.append("one-lib never printed NotFound")

if derived["satisfied"] != "2" or derived["remain"] != "30":
    fails.append("derive count wrong: satisfied=%s remain=%s" % (
        derived["satisfied"], derived["remain"]))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- full serial (tail) ----", file=sys.stderr)
    print("\n".join(full.splitlines()[-80:]), file=sys.stderr)
    print("---- one-lib serial (tail) ----", file=sys.stderr)
    print("\n".join(one.splitlines()[-80:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF DT_NEEDED×2 → LIBC.SO write LINE1 + LIBM.SO need_fn LINE2; "
      "LIBM absent → no LINE2; ASK.ELF REFUSED 11; 2/32 CEF NEEDED stand-ins)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "PLAT-NEED: PASS — named PLAT.ELF walked 2 DT_NEEDED (LIBC.SO + LIBM.SO); derived LINE1/LINE2; missing LIBM.SO refuses LINE2; ASK.ELF REFUSED 11; satisfied 2/32 CEF NEEDED stand-ins (30 remain); TAP/FILES 64K/2MiB; leftover OnPaint"
exit 0
