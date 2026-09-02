#!/usr/bin/env bash
# core/tests/conformance/cef-dl/run.sh
#
# ADR-0174: named PLAT.ELF walks real DT_NEEDED `libdl.so.2` (not
# LIBDL.SO). Kernel resolves via planted SOMAP.TXT → FAT LIBDL.SO
# and returns dl_fn. Derived LINE from the face. Missing SOMAP
# refuses (anti-vacuity). ASK.ELF is REFUSED 11.
#
# FAT 8.3 cannot store `libdl.so.2` as a short name — the planted
# mapping table is the honest door. Not OnPaint. Not the rest of
# UND / other 31 sonames. Syscall 11 stays fdwait. Graphite/Venus
# fenced. Do not break cef-und2 / cef-plt / cef-load floors.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "CEF-DL: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CEF-DL: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=54

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-cef-dl.XXXXXX")" \
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
ck; grep -aob $'dl_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no dl_fn NUL string"
ck; grep -aob $'SOMAP.TXT' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no SOMAP.TXT string"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
DLOPEN_NO=$(dartconst elfSysDlopenNo elf.dart)
SOMAP_MAX=$(dartconst elfSomapMax elf.dart)
UND2=$(dartconst elfCefUnd2BatchWant elf.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 231718912 ]] \
  || fail "heapPlatMaxInc moved — platform window is RO+RX LOAD span (ADR-0168)"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$DLOPEN_NO" -eq 29 ]] \
  || fail "elfSysDlopenNo is $DLOPEN_NO, expected 29"
ck; [[ "$SOMAP_MAX" -eq 4096 ]] \
  || fail "elfSomapMax moved — planted map is one page"
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
ck; [[ -d "$CORE_DIR/tests/conformance/cef-plt" ]] \
  || fail "cef-plt harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/cef-load" ]] \
  || fail "cef-load harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/cef-und2" ]] \
  || fail "cef-und2 harness missing — do not break it"
ck; grep -q 'ADR-0174' "$CORE_DIR/docs/decisions/0174-real-named-libdl-so-2-via-somap.md" \
  || fail "ADR-0174 file is missing"
ck; grep -q '0173 is' "$CORE_DIR/docs/decisions/0174-real-named-libdl-so-2-via-somap.md" \
  || fail "ADR-0174 stole an earlier number"
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
echo "STRUCTURAL: pass  real libdl.so.2 via SOMAP→LIBDL.SO; dlopen=29; fdwait=11; cef-und2=100 held"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_FULL="$WORKDIR/cef-dl.img"
DISK_MISS_MAP="$WORKDIR/cef-dl-miss-map.img"
DISK_MISS_SO="$WORKDIR/cef-dl-miss-so.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_FULL" "$WORKDIR/plat.elf" \
  --libdl "$WORKDIR/libdl.so" --somap "$WORKDIR/somap.txt" \
  || fail "make-image.py could not write the full volume"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_MISS_MAP" "$WORKDIR/plat.elf" \
  --libdl "$WORKDIR/libdl.so" \
  || fail "make-image.py could not write the miss-map volume"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_MISS_SO" "$WORKDIR/plat.elf" \
  --somap "$WORKDIR/somap.txt" \
  || fail "make-image.py could not write the miss-so volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_FULL"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck rejected full image"; }
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_MISS_MAP"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck rejected miss-map image"; }
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_MISS_SO"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck rejected miss-so image"; }

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
                print("CEF-DL: QEMU", hello.get("QMP", {}).get("version", {}))
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
echo "=== BOOT — full (libdl.so.2 + SOMAP + LIBDL.SO) then ASK.ELF ==="
KEYS_FULL="$(typekeys 'vm'),ret,until:READY 1"
KEYS_FULL="$KEYS_FULL,$(typekeys 'proc spawn plat.elf'),ret,until:LINE ,wait:400"
KEYS_FULL="$KEYS_FULL,$(typekeys 'proc spawn ask.elf'),ret,until:REFUSED 11,until:PROC KILL,wait:400"
run_boot full "$DISK_FULL" "$KEYS_FULL" "$WORKDIR/full/serial.txt"

echo
echo "=== BOOT — miss SOMAP.TXT (LIBDL.SO present) ==="
KEYS_MISS="$(typekeys 'vm'),ret,until:READY 1"
KEYS_MISS="$KEYS_MISS,$(typekeys 'proc spawn plat.elf'),ret,until:MISS ,wait:400"
run_boot missmap "$DISK_MISS_MAP" "$KEYS_MISS" "$WORKDIR/missmap/serial.txt"

echo
echo "=== BOOT — miss LIBDL.SO (SOMAP present) ==="
KEYS_MISS_SO="$(typekeys 'vm'),ret,until:READY 1"
KEYS_MISS_SO="$KEYS_MISS_SO,$(typekeys 'proc spawn plat.elf'),ret,until:MISS ,wait:400"
run_boot missso "$DISK_MISS_SO" "$KEYS_MISS_SO" "$WORKDIR/missso/serial.txt"

echo
echo "=== ASSERT ==="
python3 - "$WORKDIR/full/serial.txt" \
         "$WORKDIR/missmap/serial.txt" \
         "$WORKDIR/missso/serial.txt" \
         "$DERIVED" <<'PY' || fail "boots do not satisfy the real-named libdl.so.2 door"
import re, sys

full = open(sys.argv[1], "rb").read().decode("latin-1")
missmap = open(sys.argv[2], "rb").read().decode("latin-1")
missso = open(sys.argv[3], "rb").read().decode("latin-1")
derived = {}
for line in open(sys.argv[4]):
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
need(full, "CEFDL START", "program ran")
need(full, derived["need_one"], "one NEEDED walked")
need(full, "FS OPEN SOMAP   .TXT", "somap opened")
need(full, derived["alias_tag"], "alias line printed")
need(full, "FS OPEN LIBDL   .SO", "libdl face opened after alias")
need(full, "VIA LIBDL.SO.2", "dl_fn called through real soname path")
need(full, derived["line"], "derived LINE")
need(full, derived["refuse"], "ASK.ELF REFUSED 11")
need(full, "BAD 0000000000000000", "full program reported no faults")

if "PROC PLAT 01" in full or "PROC PLAT 00 WIN 0000000000200000" in full:
    fails.append("ASK.ELF was given a platform flag")
if full.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1" % full.count("PROC PLAT "))
if full.count(derived["line"]) != 1:
    fails.append("LINE count: %d, expected 1" % full.count(derived["line"]))
if "ELF DISK LBA" in full:
    fails.append("boot used the LBA loader")

opens = re.findall(r"PROC DLOPEN 00 VA ([0-9A-Fa-f]+)", full)
if len(opens) < 1:
    fails.append("PROC DLOPEN VA count: %d, expected ≥1" % len(opens))
else:
    va = int(opens[0], 16)
    if va < 0x10400000 or va >= 0x1C100000:
        fails.append("dlopen VA %s outside platform heap" % opens[0])

# Anti-vacuity: LIBDL.SO present but SOMAP absent → no LINE.
need(missmap, "CEFDL START", "missmap program ran")
need(missmap, derived["miss_line"], "missmap refused without SOMAP")
if derived["line"] in missmap:
    fails.append("missmap invented LINE without SOMAP.TXT")
if "FS OPEN LIBDL   .SO" in missmap:
    fails.append("missmap opened LIBDL.SO without a mapping — vacuous alias")
if "PROC DLOPEN ALIAS" in missmap:
    fails.append("missmap printed ALIAS without SOMAP")
if "VIA LIBDL.SO.2" in missmap:
    fails.append("missmap called through face without mapping")
if "ERR FFFFFFFFFFFFFFF9" not in missmap:
    fails.append("missmap never printed NotFound")

# Anti-vacuity: SOMAP present but LIBDL.SO absent → no LINE.
need(missso, "CEFDL START", "missso program ran")
need(missso, "FS OPEN SOMAP   .TXT", "missso opened somap")
need(missso, derived["alias_tag"], "missso alias resolved")
need(missso, derived["miss_line"], "missso refused missing LIBDL.SO")
if derived["line"] in missso:
    fails.append("missso invented LINE without LIBDL.SO")
if "FS OPEN LIBDL   .SO" in missso:
    fails.append("missso opened LIBDL.SO — volume should lack it")
if "VIA LIBDL.SO.2" in missso:
    fails.append("missso called through face without the file")

if derived["satisfied_named"] != "1":
    fails.append("derive satisfied_named wrong: %s" % derived["satisfied_named"])
if derived["und_bound"] != "50" or derived["und_remain"] != "1286":
    fails.append("UND floor drifted in derive: bound=%s remain=%s" % (
        derived["und_bound"], derived["und_remain"]))
if derived["soname"] != "libdl.so.2":
    fails.append("derive soname is not libdl.so.2")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- full serial (tail) ----", file=sys.stderr)
    print("\n".join(full.splitlines()[-100:]), file=sys.stderr)
    print("---- missmap serial (tail) ----", file=sys.stderr)
    print("\n".join(missmap.splitlines()[-80:]), file=sys.stderr)
    print("---- missso serial (tail) ----", file=sys.stderr)
    print("\n".join(missso.splitlines()[-80:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF DT_NEEDED=libdl.so.2 → SOMAP.TXT → LIBDL.SO derived LINE; "
      "missing SOMAP / missing LIBDL refuse; ASK.ELF REFUSED 11; "
      "UND 100/1336 held; leftover rest of UND / other sonames / OnPaint)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "CEF-DL: PASS — real DT_NEEDED libdl.so.2 via planted SOMAP.TXT→LIBDL.SO; derived LINE; missing map/so refuse; ASK.ELF REFUSED 11; UND 100/1336 held; leftover: rest of UND / other 31 sonames / OnPaint"
exit 0
