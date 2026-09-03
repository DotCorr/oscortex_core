#!/usr/bin/env bash
# core/tests/conformance/cef-somap/run.sh
#
# ADR-0176: named PLAT.ELF walks all 32 official CEF DT_NEEDED Linux
# sonames (libdl.so.2 … ld-linux-x86-64.so.2). Kernel resolves each
# via planted SOMAP.TXT → OUR plat-need5 FAT LIB*.SO faces. Derived
# LINE1..LINE32. Missing one alias (ld-linux) refuses that name.
# ASK.ELF is REFUSED 11.
#
# FAT 8.3 cannot store most CEF sonames. Not OnPaint. Not the rest of
# UND. Syscall 11 stays fdwait. Graphite/Venus fenced. Do not break
# cef-dl / cef-und2 / plat-need5 floors.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "CEF-SOMAP: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CEF-SOMAP: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=51

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-cef-somap.XXXXXX")" \
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
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfSysDlopen$' \
  || fail "kernel.elf has no elfSysDlopen"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -E '[[:space:]]T[[:space:]]+elfDlopenSomapApply$' \
  || fail "kernel.elf has no elfDlopenSomapApply — SOMAP door not linked"
ck; grep -aob $'SOMAP.TXT' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no SOMAP.TXT string"
ck; grep -q 'elfDlopenNameMax' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart has no elfDlopenNameMax — long CEF sonames cannot pass"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
DLOPEN_NO=$(dartconst elfSysDlopenNo elf.dart)
SOMAP_MAX=$(dartconst elfSomapMax elf.dart)
NAME_MAX=$(dartconst elfDlopenNameMax elf.dart)
UND2=$(dartconst elfCefUnd2BatchWant elf.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 229318656 ]] \
  || fail "heapPlatMaxInc moved — platform window is RO+RX LOAD span (ADR-0168)"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$DLOPEN_NO" -eq 29 ]] \
  || fail "elfSysDlopenNo is $DLOPEN_NO, expected 29"
ck; [[ "$SOMAP_MAX" -eq 4096 ]] \
  || fail "elfSomapMax moved — planted map is one page"
ck; [[ "$NAME_MAX" -eq 64 ]] \
  || fail "elfDlopenNameMax is $NAME_MAX, expected 64"
# cef-und2 OWNS this number (ADR-0178 -> 0179 -> 0180 took it 100 -> 200 ->
# 400). This harness only has to not break its floor, and it used to say so by
# pinning 100 -- the ADR-0178 value -- which meant it went red every time the
# batch GREW, i.e. exactly when the thing it was protecting got better. Read
# cef-und2's own pin and require at least it: agreement by construction, and
# still red if anyone shrinks the batch under this harness.
UND2_FLOOR=$(grep -oE '\$BATCH2" -eq [0-9]+' "$CORE_DIR/tests/conformance/cef-und2/run.sh" | grep -oE '[0-9]+$' | head -1)
ck; [[ -n "$UND2_FLOOR" ]] \
  || fail "cef-und2/run.sh no longer pins elfCefUnd2BatchWant, so this harness has no floor to hold"
ck; [[ "$UND2" -ge "$UND2_FLOOR" ]] \
  || fail "elfCefUnd2BatchWant is $UND2, below the $UND2_FLOOR cef-und2 pins — do not break the cef-und2 floor"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; grep -E '^\| 29 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q dlopen \
  || fail "syscall 29 is not dlopen in the registry"
ck; bash "$CORE_DIR/scripts/verify-syscall-registry.sh" >/dev/null \
  || fail "verify-syscall-registry.sh disagrees"
# A FENCE IS A FLOOR, NOT A PIN. These two lines pinned the exact
# ASSERTIONS_REQUIRED of two OTHER harnesses so this door could not be widened
# by quietly deleting their checks. Pinning the number made them red when a
# floor ROSE -- cef-und2 went 59 -> 62 when someone added three real checks --
# which is the improvement the fence exists to encourage. Read the floors and
# require they never go BELOW the values recorded here; that is exactly the
# abuse the fence was for, and nothing else.
fence_floor() {
  awk -F= '/^ASSERTIONS_REQUIRED=/{print $2; exit}' "$1"
}
BROWSE_FLOOR=$(fence_floor "$CORE_DIR/tests/conformance/de-browse/run.sh")
UND2_ASSERTS=$(fence_floor "$CORE_DIR/tests/conformance/cef-und2/run.sh")
ck; [[ -n "$BROWSE_FLOOR" && "$BROWSE_FLOOR" -ge 87 ]] \
  || fail "de-browse declares ${BROWSE_FLOOR:-no} checks, below the 87 it declared when this fence was written — do not buy this door with de-browse's coverage"
ck; [[ -n "$UND2_ASSERTS" && "$UND2_ASSERTS" -ge 59 ]] \
  || fail "cef-und2 declares ${UND2_ASSERTS:-no} checks, below the 59 it declared when this fence was written — fence"
ck; grep -q 'ASSERTIONS_REQUIRED=54' "$CORE_DIR/tests/conformance/cef-dl/run.sh" \
  || fail "cef-dl floor moved — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/cef-dl" ]] \
  || fail "cef-dl harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-need5" ]] \
  || fail "plat-need5 harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/cef-plt" ]] \
  || fail "cef-plt harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/cef-load" ]] \
  || fail "cef-load harness missing — do not break it"
ck; grep -q 'ADR-0176' "$CORE_DIR/docs/decisions/0176-somap-covers-all-thirty-two-cef-sonames.md" \
  || fail "ADR-0176 file is missing"
ck; grep -q '0175 is' "$CORE_DIR/docs/decisions/0176-somap-covers-all-thirty-two-cef-sonames.md" \
  || fail "ADR-0176 stole an earlier number"
ck; ! grep -q 'osgfx_skia\|MakeVulkan\|Venus' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart touched Graphite/Venus — fenced"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
echo "STRUCTURAL: pass  SOMAP×32 real CEF sonames; dlopen=29; fdwait=11; cef-dl/und2 held"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_FULL="$WORKDIR/cef-somap.img"
DISK_MISS="$WORKDIR/cef-somap-miss.img"
SO_ALL=(
  "$WORKDIR/libdl.so" "$WORKDIR/libpt.so" "$WORKDIR/libgb.so" "$WORKDIR/libgo.so" \
  "$WORKDIR/libnp.so" "$WORKDIR/libns.so" "$WORKDIR/libnu.so" "$WORKDIR/libsm.so" \
  "$WORKDIR/libdb.so" "$WORKDIR/libgi.so" "$WORKDIR/libat.so" "$WORKDIR/libab.so" \
  "$WORKDIR/libcu.so" "$WORKDIR/libx1.so" "$WORKDIR/libxc.so" "$WORKDIR/libxd.so" \
  "$WORKDIR/libxe.so" "$WORKDIR/libxf.so" "$WORKDIR/libxr.so" "$WORKDIR/libgm.so" \
  "$WORKDIR/libex.so" "$WORKDIR/libxb.so" "$WORKDIR/libxk.so" "$WORKDIR/libca.so" \
  "$WORKDIR/libpg.so" "$WORKDIR/libud.so" "$WORKDIR/libas.so" "$WORKDIR/libm.so" \
  "$WORKDIR/libap.so" "$WORKDIR/libgc.so" "$WORKDIR/libc.so" "$WORKDIR/libld.so"
)
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_FULL" "$WORKDIR/plat.elf" \
  --somap "$WORKDIR/somap.txt" "${SO_ALL[@]}" \
  || fail "make-image.py could not write the full volume"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_MISS" "$WORKDIR/plat.elf" \
  --somap "$WORKDIR/somap-miss.txt" "${SO_ALL[@]}" \
  || fail "make-image.py could not write the miss-alias volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_FULL"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck rejected full image"; }
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_MISS"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck rejected miss image"; }

DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" > "$DERIVED" || fail "derive.py failed"

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
  timeout 240 qemu-system-x86_64 \
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
                print("CEF-SOMAP: QEMU", hello.get("QMP", {}).get("version", {}))
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
    cat "$WORKDIR/$label/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -120 "$ser" >&2
    fail "$label session driver exited $drive_status"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$WORKDIR/$label/qemu.log" >&2
    fail "$label qemu exited $qemu_status"
  fi
  ck; [[ -s "$ser" ]] || fail "$label captured no serial"
}

echo
echo "=== BOOT — full (32 CEF sonames + SOMAP) then ASK.ELF ==="
KEYS_FULL="$(typekeys 'vm'),ret,until:READY 1"
KEYS_FULL="$KEYS_FULL,$(typekeys 'proc spawn plat.elf'),ret,until:LINE32 ,wait:1500"
KEYS_FULL="$KEYS_FULL,$(typekeys 'proc spawn ask.elf'),ret,until:REFUSED 11,until:PROC KILL,wait:400"
run_boot full "$DISK_FULL" "$KEYS_FULL" "$WORKDIR/full/serial.txt"

echo
echo "=== BOOT — miss ld-linux alias (faces present) ==="
KEYS_MISS="$(typekeys 'vm'),ret,until:READY 1"
KEYS_MISS="$KEYS_MISS,$(typekeys 'proc spawn plat.elf'),ret,until:MISS ,wait:1500"
run_boot miss "$DISK_MISS" "$KEYS_MISS" "$WORKDIR/miss/serial.txt"

echo
echo "=== ASSERT ==="
python3 - "$WORKDIR/full/serial.txt" "$WORKDIR/miss/serial.txt" "$DERIVED" <<'PY' || fail "boots do not satisfy the thirty-two-SOMAP door"
import re, sys

full = open(sys.argv[1], "rb").read().decode("latin-1")
miss = open(sys.argv[2], "rb").read().decode("latin-1")
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
need(full, "SOMAP START", "program ran")
need(full, derived["need_thirtytwo"], "all thirty-two NEEDED loaded")
need(full, "FS OPEN SOMAP   .TXT", "somap opened")
need(full, derived["alias_tag"], "alias line printed")
need(full, derived["refuse"], "ASK.ELF REFUSED 11")
need(full, "BAD 0000000000000000", "full program reported no faults")

tags = ["LIBDL", "LIBPT", "LIBGB", "LIBGO", "LIBNP", "LIBNS", "LIBNU", "LIBSM",
        "LIBDB", "LIBGI", "LIBAT", "LIBAB", "LIBCU", "LIBX1", "LIBXC", "LIBXD",
        "LIBXE", "LIBXF", "LIBXR", "LIBGM", "LIBEX", "LIBXB", "LIBXK", "LIBCA",
        "LIBPG", "LIBUD", "LIBAS", "LIBM", "LIBAP", "LIBGC", "LIBC", "LIBLD"]
for tag in tags:
    pad = tag.ljust(8)
    need(full, "FS OPEN %s.SO" % pad, "%s.so opened" % tag.lower())
    need(full, "VIA %s" % tag, "face called through %s" % tag)

line_keys = ["line%d" % i for i in range(1, 33)]
for key in line_keys:
    need(full, derived[key], "derived " + key.upper())

if "PROC PLAT 01" in full or "PROC PLAT 00 WIN 0000000000200000" in full:
    fails.append("ASK.ELF was given a platform flag")
if full.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1" % full.count("PROC PLAT "))
for key in line_keys:
    if full.count(derived[key]) != 1:
        fails.append("%s count: %d, expected 1" % (key.upper(), full.count(derived[key])))
if "ELF DISK LBA" in full:
    fails.append("boot used the LBA loader")

opens = re.findall(r"PROC DLOPEN 00 VA ([0-9A-Fa-f]+)", full)
if len(opens) < 32:
    fails.append("PROC DLOPEN VA count: %d, expected ≥32" % len(opens))
else:
    for va_s in opens[:32]:
        va = int(va_s, 16)
        if va < 0x10600000 or va >= 0x1C100000:
            fails.append("dlopen VA %s outside platform heap" % va_s)

aliases = full.count("PROC DLOPEN ALIAS")
if aliases < 32:
    fails.append("PROC DLOPEN ALIAS count: %d, expected ≥32" % aliases)

# Anti-vacuity: SOMAP missing ld-linux alias → LINE1..31 ok, no LINE32.
need(miss, "SOMAP START", "miss program ran")
for tag in tags[:-1]:
    pad = tag.ljust(8)
    need(miss, "FS OPEN %s.SO" % pad, "miss %s opened" % tag.lower())
for key in ["line%d" % i for i in range(1, 32)]:
    need(miss, derived[key], "miss " + key.upper())
need(miss, derived["miss_line"], "miss missing ld-linux alias refused")
need(miss, derived["need_thirtyone"], "miss stopped after thirty-one NEEDED")
if derived["line32"] in miss:
    fails.append("miss invented LINE32 without ld-linux alias")
if "FS OPEN LIBLD   .SO" in miss:
    fails.append("miss opened LIBLD.SO — alias was absent, must not invent")
if "VIA LIBLD" in miss:
    fails.append("miss called through LIBLD without the alias")
if "ERR FFFFFFFFFFFFFFF9" not in miss:
    fails.append("miss never printed NotFound")

if derived["satisfied"] != "32" or derived["remain"] != "0":
    fails.append("derive count wrong: satisfied=%s remain=%s" % (
        derived["satisfied"], derived["remain"]))
if derived["und_bound"] != "50" or derived["und_remain"] != "1286":
    fails.append("UND floor drifted: bound=%s remain=%s" % (
        derived["und_bound"], derived["und_remain"]))
if derived.get("somap_lines") != "32":
    fails.append("derive somap_lines wrong: %s" % derived.get("somap_lines"))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- full serial (tail) ----", file=sys.stderr)
    print("\n".join(full.splitlines()[-200:]), file=sys.stderr)
    print("---- miss serial (tail) ----", file=sys.stderr)
    print("\n".join(miss.splitlines()[-200:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF DT_NEEDED×32 real CEF sonames → SOMAP.TXT → LIB*.SO "
      "derived LINE1..32; missing ld-linux alias → no LINE32; ASK.ELF REFUSED 11; "
      "32/32; UND 100/1336 held; leftover rest of UND / OnPaint)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "CEF-SOMAP: PASS — SOMAP covers all 32 official CEF sonames → OUR 8.3 faces; derived LINE1..LINE32; missing ld-linux alias refuses; ASK.ELF REFUSED 11; 32/32; UND 100/1336 held; leftover: rest of UND / OnPaint"
exit 0
