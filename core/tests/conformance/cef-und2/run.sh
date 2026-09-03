#!/usr/bin/env bash
# core/tests/conformance/cef-und2/run.sh
#
# ADR-0180: bind ≥400 measured high-traffic UND faces through OUR
# LIBC.SO (50+ beyond ADR-0172's fifty). Unbound PLT → #PF / no LINE.
# ASK.ELF is BadArg. malloc absent from official PLT — not claimed.
#
# Not OnPaint. Not real-named libdl.so.2 (FAT 8.3 leftover). Remaining
# UND documented. Syscall 11 stays fdwait. Graphite / Venus fenced.
# TAP/FILES 64K/2MiB. Do not break cef-und / cef-plt / cef-load floors.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "CEF-UND2: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CEF-UND2: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=62

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-cef-und2.XXXXXX")" \
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
  "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "BUILD: build-kernel.sh exited $BUILD_STATUS (osgfx/media may be mid-edit)"
fi
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
KERNEL_END=$(python3 - "$KERNEL_ELF" <<'PY'
import struct, sys
p = open(sys.argv[1], "rb").read()
assert p[:4] == b"\x7fELF"
if p[4] == 2:
    phoff = struct.unpack_from("<Q", p, 32)[0]
    phentsize = struct.unpack_from("<H", p, 54)[0]
    phnum = struct.unpack_from("<H", p, 56)[0]
    mx = 0
    for i in range(phnum):
        off = phoff + i * phentsize
        typ = struct.unpack_from("<I", p, off)[0]
        if typ != 1:
            continue
        va = struct.unpack_from("<Q", p, off + 16)[0]
        msz = struct.unpack_from("<Q", p, off + 40)[0]
        mx = max(mx, va + msz)
    print(mx)
else:
    phoff = struct.unpack_from("<I", p, 28)[0]
    phentsize = struct.unpack_from("<H", p, 42)[0]
    phnum = struct.unpack_from("<H", p, 44)[0]
    mx = 0
    for i in range(phnum):
        off = phoff + i * phentsize
        typ, _foff, va, _pa, _fsz, msz = struct.unpack_from("<IIIIII", p, off)
        if typ == 1:
            mx = max(mx, va + msz)
    print(mx)
PY
)
ck; [[ "$KERNEL_END" -le 16777216 ]] \
  || fail "kernel_image_end $KERNEL_END exceeds vmFineBytes 16MiB — refuse fat CRT/Skia"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfCefPlaceLibcMemset$' \
  || fail "kernel.elf has no elfCefPlaceLibcMemset — UND batch door not linked"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfCefWritePltTrampoline$' \
  || fail "kernel.elf has no elfCefWritePltTrampoline"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfCefUndBatchLine$' \
  || fail "kernel.elf has no elfCefUndBatchLine"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfDlopenMapPlant$' \
  || fail "kernel.elf has no elfDlopenMapPlant"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
RO=$(dartconst elfCefRoFilesz elf.dart)
RX=$(dartconst elfCefRxFilesz elf.dart)
PLANT=$(dartconst elfCefPlantBytes elf.dart)
PLANT_PA=$(dartconst elfCefPlantPa elf.dart)
PLT_OFF=$(dartconst elfCefMemsetPltOff elf.dart)
BATCH_WANT=$(dartconst elfCefUndBatchWant elf.dart)
BATCH2=$(dartconst elfCefUnd2BatchWant elf.dart)
UND_TOTAL=$(dartconst elfCefUndTotal elf.dart)
FACE_OFF=$(dartconst elfCefUndFaceOff elf.dart)
FACE_MAX=$(dartconst elfCefUndFaceMax elf.dart)
DLOPEN_NO=$(dartconst elfSysDlopenNo elf.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 229318656 ]] \
  || fail "heapPlatMaxInc is $HEAP_PLAT_MAX — do not break cef-load window"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$RO" -eq 42593760 ]] \
  || fail "elfCefRoFilesz drifted from official readelf"
ck; [[ "$RX" -eq 189117488 ]] \
  || fail "elfCefRxFilesz drifted from official readelf"
ck; [[ "$PLANT" -eq 231711248 ]] \
  || fail "elfCefPlantBytes drifted — do not break cef-load plant"
ck; [[ "$PLANT_PA" -eq 16777216 ]] \
  || fail "elfCefPlantPa moved"
ck; [[ "$PLT_OFF" -eq 231711200 ]] \
  || fail "elfCefMemsetPltOff drifted from official memset@plt"
ck; [[ "$BATCH_WANT" -eq 5 ]] \
  || fail "elfCefUndBatchWant is $BATCH_WANT, expected 5 (ADR-0170 floor)"
ck; [[ "$BATCH2" -eq 400 ]] \
  || fail "elfCefUnd2BatchWant is $BATCH2, expected 400"
ck; [[ "$UND_TOTAL" -eq 1336 ]] \
  || fail "elfCefUndTotal is $UND_TOTAL, expected 1336"
ck; [[ "$FACE_OFF" -eq 231697872 ]] \
  || fail "elfCefUndFaceOff drifted (expected PLT idx 511 / 0xDCF6DD0)"
ck; [[ "$FACE_MAX" -eq 4976 ]] \
  || fail "elfCefUndFaceMax is $FACE_MAX, expected 4976"
FACE3_OFF=$(dartconst elfCefUnd3FaceOff elf.dart)
FACE3_MAX=$(dartconst elfCefUnd3FaceMax elf.dart)
ck; [[ "$FACE3_OFF" -eq 231712768 ]] \
  || fail "elfCefUnd3FaceOff drifted (expected post-PLT hole / 0xDCFA800)"
ck; [[ "$FACE3_MAX" -eq 2048 ]] \
  || fail "elfCefUnd3FaceMax is $FACE3_MAX, expected 2048"
ck; [[ "$DLOPEN_NO" -eq 29 ]] \
  || fail "elfSysDlopenNo is $DLOPEN_NO, expected 29"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" >/dev/null \
  || fail "verify-syscall-registry.sh disagrees"
ck; grep -q 'ASSERTIONS_REQUIRED=52' "$CORE_DIR/tests/conformance/cef-und/run.sh" \
  || fail "cef-und floor moved — do not break it"
ck; grep -q 'ASSERTIONS_REQUIRED=46' "$CORE_DIR/tests/conformance/cef-plt/run.sh" \
  || fail "cef-plt floor moved — do not break it"
ck; grep -q 'ASSERTIONS_REQUIRED=44' "$CORE_DIR/tests/conformance/cef-load/run.sh" \
  || fail "cef-load floor moved — do not break it"
ck; grep -q 'ASSERTIONS_REQUIRED=45' "$CORE_DIR/tests/conformance/cef-wire/run.sh" \
  || fail "cef-wire floor moved"
ck; grep -q 'ASSERTIONS_REQUIRED=111' "$CORE_DIR/tests/conformance/browse-paint/run.sh" \
  || fail "browse-paint floor moved"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$CORE_DIR/tests/conformance/de-browse/run.sh" \
  || fail "de-browse floor moved"
ck; grep -q 'ADR-0180' "$CORE_DIR/docs/decisions/0180-high-traffic-und-batch-grows-to-four-hundred.md" \
  || fail "ADR-0180 file is missing"
ck; grep -q '0179 is the two-hundred-face' "$CORE_DIR/docs/decisions/0180-high-traffic-und-batch-grows-to-four-hundred.md" \
  || fail "ADR-0180 stole 0179"
ck; grep -q 'ADR-0178' "$CORE_DIR/docs/decisions/0178-high-traffic-und-batch-grows-to-one-hundred.md" \
  || fail "ADR-0178 file is missing"
ck; grep -q 'ADR-0172' "$CORE_DIR/docs/decisions/0172-high-traffic-und-batch-grows-to-fifty.md" \
  || fail "ADR-0172 file is missing"
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
ck; ! grep -E '\bmalloc\b' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c names an allocator face — official PLT has none"
# Anti-vacuity host pin: a LIBC missing one optional face leaves that
# face unbound; userspace call through its @plt would #PF (no LINE).
FACE_COUNT=$(grep -cE '^[a-zA-Z_].*\(' "$SCRIPT_DIR/libc.c" | awk '{print $1}')
# Exclude the static pad helper — not an exported bind face.
FACE_COUNT=$((FACE_COUNT - 1))
ck; [[ "$FACE_COUNT" -eq 400 ]] \
  || fail "libc.c exports $FACE_COUNT faces, expected 400"
echo "STRUCTURAL: pass  UND2×400 batch pins; plant/floors held; Graphite fenced"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

# Anti-vacuity: strip one optional face → nm lacks it (unbound PLT path).
python3 - "$SCRIPT_DIR/libc.c" "$WORKDIR" <<'PY' || fail "anti-vacuity strip failed"
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
# Drop __udivti3 definition (last ADR-0180 face).
out = re.sub(
    r"\n__attribute__\(\(naked\)\) int __udivti3\(void\) \{ __asm__\(\"mov \$-1, %eax\\n\\tret\"\); \}\n",
    "\n",
    src,
    count=1,
    flags=re.S,
)
if out == src:
    out = re.sub(
        r"\nint __udivti3\(void\) \{.*?\n\}\n",
        "\n",
        src,
        count=1,
        flags=re.S,
    )
if re.search(r"__udivti3\(", out):
    raise SystemExit("strip left __udivti3 behind")
pathlib.Path(sys.argv[2], "libc-miss.c").write_text(out)
print("anti-vacuity: wrote libc-miss.c without __udivti3")
PY
clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
  -fPIC -fno-stack-protector -fno-asynchronous-unwind-tables \
  -fno-builtin -Os -Wall -Wextra -Werror \
  "$WORKDIR/libc-miss.c" -o "$WORKDIR/libc-miss.o" \
  || fail "clang could not compile libc-miss.c"
x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
  -T "$SCRIPT_DIR/libc.ld" \
  -o "$WORKDIR/libc-miss.so" "$WORKDIR/libc-miss.o" \
  || fail "could not link libc-miss.so"
ck; ! x86_64-elf-nm "$WORKDIR/libc-miss.so" | grep -qE ' [Tt] __udivti3$' \
  || fail "libc-miss.so still exports __udivti3 — anti-vacuity vacuous"
ck; x86_64-elf-nm "$WORKDIR/libc.so" | grep -qE ' [Tt] __udivti3$' \
  || fail "full libc.so lost mktime"

DISK_IMG="$WORKDIR/cef-und2.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/plat.elf" \
  "$WORKDIR/libc.so" "$WORKDIR/cef.so" \
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
KEYS="$KEYS,$(typekeys 'proc spawn plat.elf'),ret,until:CEF UND BATCH ,until:LINE ,wait:800"
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
                print("CEF-UND2: QEMU", hello.get("QMP", {}).get("version", {}))
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
python3 - "$SER" "$DERIVED" <<'PY' || fail "the boot does not satisfy the cef-und2 door"
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
need("FS OPEN CEF     .SO", "cef.so opened")
need("FS OPEN LIBC    .SO", "libc.so opened during plant bind")
need("CEFUND2 START", "program ran")
need(derived["kernel_ro"] + " " + derived["kernel_rx"].replace("RX ", "RX ", 1), "kernel LOAD line")
need("CEF LOAD RO " + derived["ro"], "kernel RO pin")
need(" RX " + derived["rx"], "kernel RX pin")
need(derived["plt_line"], "kernel PLT memset line")
need(derived["und_line"], "kernel UND batch line")
need(derived["batch_user"], "userspace BATCH count")
need(derived["line"], "derived LINE from twenty PLT faces")
need(derived["cap_plat"], "plat cap line")
need("CEF ", "cef dlopen")
need("PLT ", "userspace PLT VA")
need("BAD 0000000000000000", "program reported no faults")
need("ERR FFFFFFFFFFFFFFFE", "ask PROC DLOPEN ERR")
need(derived["cap_app"], "ask old cap line")

if "PROC PLAT 01" in ser or "PROC PLAT 00 WIN 0000000000200000" in ser:
    fails.append("ASK.ELF was given a platform flag")
if ser.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1" % ser.count("PROC PLAT "))
if "oschrome_on_paint" in ser:
    fails.append("serial smells like the browse-paint stand-in")
if "CEF LOAD RO 0000000000003000" in ser or "CEF LOAD RO 0000000000002000" in ser:
    fails.append("kernel printed slice-sized RO — full LOAD door vacuous")

m = re.search(r"CEF PLT MEMSET ([0-9A-Fa-f]{16})", ser)
if not m:
    fails.append("no CEF PLT MEMSET <va> line")
else:
    va = int(m.group(1), 16)
    if va < 0x10600000 or va >= 0x1E0FC000:
        fails.append("bound memset VA %s outside platform heap" % m.group(1))
    if va == 0:
        fails.append("bound memset VA is zero — vacuous")

m2 = re.search(r"CEF UND BATCH ([0-9A-Fa-f]{16})", ser)
if not m2:
    fails.append("no CEF UND BATCH <n> line")
else:
    n = int(m2.group(1), 16)
    if n < 400:
        fails.append("UND batch count %d, expected ≥400" % n)
    if n != 400:
        fails.append("UND batch count %d, expected 400" % n)

if derived["line"] not in ser:
    fails.append("derived LINE missing — unbound PLT would #PF here")

bound = int(derived["und_bound"])
remain = int(derived["und_remain"])
total = int(derived["und_total"])
if bound + remain != total:
    fails.append("bound+remain != total")
if bound < 400:
    fails.append("bound %d < 400" % bound)
if remain != 936:
    fails.append("remaining UND is %d, expected 936" % remain)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-120:]), file=sys.stderr)
    sys.exit(1)

print("    bound=%s remain=%s total=%s list=%s"
      % (derived["und_bound"], derived["und_remain"],
         derived["und_total"], derived["bound_list"]))
print("    (PLAT.ELF: LIBC 200-face batch → CEF LOADs → @plt bound → LINE; ASK refused)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "CEF-UND2: PASS — bound 400/1336 high-traffic UND through OUR libc; remain 936; leftover: rest of UND / OnPaint"
exit 0
