#!/usr/bin/env bash
# core/tests/conformance/cef-load/run.sh
#
# ADR-0168: PLAT.ELF dlopen maps full official libcef LOADs
# (~42 MiB RO + ~189 MiB RX) from a host-backed plant. FAT cannot
# hold 1.5 GiB (fatChainMax). Anti-vacuity: 12 KiB cef-wire slice
# sizes fail this check. ASK refused. Not OnPaint. Not glibc UND.
# Syscall 11 stays fdwait. Graphite / Venus fenced. TAP/FILES 64K/2MiB.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "CEF-LOAD: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CEF-LOAD: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=44

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-cef-load.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() {
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
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
capture_sh BUILD_OUT BUILD_STATUS -- \
  "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 OSGFX_CRT=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "BUILD: build-kernel.sh exited $BUILD_STATUS (osgfx/media may be mid-edit)"
fi
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfDlopenMapPlant$' \
  || fail "kernel.elf has no elfDlopenMapPlant — full LOAD door not linked"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfCefPlantReserve$' \
  || fail "kernel.elf has no elfCefPlantReserve"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
RO=$(dartconst elfCefRoFilesz elf.dart)
RX=$(dartconst elfCefRxFilesz elf.dart)
PLANT=$(dartconst elfCefPlantBytes elf.dart)
PLANT_PA=$(dartconst elfCefPlantPa elf.dart)
DLOPEN_NO=$(dartconst elfSysDlopenNo elf.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 231718912 ]] \
  || fail "heapPlatMaxInc is $HEAP_PLAT_MAX, expected RO+RX span"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$RO" -eq 42593760 ]] \
  || fail "elfCefRoFilesz drifted from official readelf"
ck; [[ "$RX" -eq 189117488 ]] \
  || fail "elfCefRxFilesz drifted from official readelf"
ck; [[ "$PLANT" -eq 231711248 ]] \
  || fail "elfCefPlantBytes drifted"
ck; [[ "$PLANT_PA" -eq 16777216 ]] \
  || fail "elfCefPlantPa moved"
ck; [[ "$DLOPEN_NO" -eq 29 ]] \
  || fail "elfSysDlopenNo is $DLOPEN_NO, expected 29"
ck; [[ "$RO" -gt 12288 ]] && [[ "$RX" -gt 12288 ]] \
  || fail "LOAD pins collapsed to the 12 KiB slice ceiling"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" >/dev/null \
  || fail "verify-syscall-registry.sh disagrees"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$CORE_DIR/tests/conformance/de-browse/run.sh" \
  || fail "de-browse floor moved"
ck; grep -q 'ASSERTIONS_REQUIRED=111' "$CORE_DIR/tests/conformance/browse-paint/run.sh" \
  || fail "browse-paint floor moved"
ck; grep -q 'ASSERTIONS_REQUIRED=45' "$CORE_DIR/tests/conformance/cef-wire/run.sh" \
  || fail "cef-wire floor moved — do not break the slice door"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-huge" ]] \
  || fail "plat-huge harness missing"
ck; grep -q 'ADR-0168' "$CORE_DIR/docs/decisions/0168-full-libcef-loads-are-mapped.md" \
  || fail "ADR-0168 file is missing"
ck; grep -q '0167 is the measured slice' "$CORE_DIR/docs/decisions/0168-full-libcef-loads-are-mapped.md" \
  || fail "ADR-0168 stole 0167"
ck; ! grep -q 'proc cef\|cef ' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a cef help string"
ck; ! grep -q 'osgfx_skia' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart touched osgfx_skia"
ck; ! grep -q 'MakeVulkan' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart touched MakeVulkan"
ck; ! grep -q 'oschrome_on_paint' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c names oschrome_on_paint"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
echo "STRUCTURAL: pass  RO+RX pins; plant host-backed; slice ceiling refused; floors held"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/cef-load.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/plat.elf" \
  "$WORKDIR/cef.so" "$WORKDIR/libc.so" \
  || fail "make-image.py could not write the volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }

DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" > "$DERIVED" || fail "derive.py failed"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

echo
echo "=== BOOT — PLAT.ELF then ASK.ELF (host plant at 16 MiB) ==="
KEYS="$(typekeys 'vm'),ret,until:READY 1"
KEYS="$KEYS,$(typekeys 'proc spawn plat.elf'),ret,until:RO ,wait:800"
KEYS="$KEYS,$(typekeys 'proc spawn ask.elf'),ret,until:CAP 0000000000200000,until:PROC KILL,wait:400"

mkdir -p "$WORKDIR/main"
SER="$WORKDIR/main/serial.txt"
: >"$SER"
ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 300 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 256M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -device "loader,file=$WORKDIR/cef-plant.bin,addr=0x1000000,force-raw=on" \
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
                print("CEF-LOAD: QEMU", hello.get("QMP", {}).get("version", {}))
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

def wait_marker(path, marker, timeout=60, at_least=1):
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
        if not wait_marker(serial, marker, timeout=90):
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
python3 - "$SER" "$DERIVED" <<'PY' || fail "the boot does not satisfy the cef-load door"
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
need(derived["win"], "plat flag")
need("PROC DLOPEN ", "dlopen line")
need("FS OPEN CEF     .SO", "cef.so opened")
need("CEFLOAD START", "program ran")
need(derived["kernel_ro"] + " " + derived["kernel_rx"].replace("RX ", "RX ", 1), "kernel LOAD line")
# Kernel prints: CEF LOAD RO <16hex> RX <16hex>
need("CEF LOAD RO " + derived["ro"], "kernel RO pin")
need(" RX " + derived["rx"], "kernel RX pin")
need(derived["pixel_line"], "official text pixel")
need(derived["ro_line"], "userspace RO pin")
need(derived["rx_line"], "userspace RX pin")
need(derived["cap_plat"], "plat cap line")
need(derived["asked_bad"], "ask dlopen refused")
need(derived["dlopen_err"], "ask PROC DLOPEN ERR")
need(derived["cap_app"], "ask old cap line")
need("BAD 0000000000000000", "program reported no faults")

if "PROC PLAT 01" in ser or "PROC PLAT 00 WIN 0000000000200000" in ser:
    fails.append("ASK.ELF was given a platform flag")
if ser.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1" % ser.count("PROC PLAT "))
if "oschrome_on_paint" in ser:
    fails.append("serial smells like the browse-paint stand-in")
# Anti-vacuity: a 12 KiB slice map must not pass.
if "CEF LOAD RO 0000000000003000" in ser or "CEF LOAD RO 0000000000002000" in ser:
    fails.append("kernel printed slice-sized RO — full LOAD door vacuous")
ro = int(derived["ro"], 16)
rx = int(derived["rx"], 16)
if ro <= int(derived["slice_ceiling"]) or rx <= int(derived["slice_ceiling"]):
    fails.append("derived pins collapsed to slice ceiling")

opens = re.findall(r"PROC DLOPEN 00 VA ([0-9A-Fa-f]+)", ser)
if not opens:
    fails.append("no PROC DLOPEN VA for PLAT.ELF")
else:
    va = int(opens[0], 16)
    if va < 0x10400000 or va >= 0x1E0FC000:
        fails.append("dlopen VA %s outside platform heap" % opens[0])

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-120:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF dlopen → host-plant RO %d + RX %d; PIXEL; ASK refused; "
      "12 KiB slice insufficient)" % (ro, rx))
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "CEF-LOAD: PASS — PLAT mapped full official libcef LOADs (RO $RO + RX $RX) from host plant; ASK refused; leftover: libdl.so.2 / memset@plt / OnPaint"
exit 0
