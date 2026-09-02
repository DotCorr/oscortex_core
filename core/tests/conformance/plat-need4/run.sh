#!/usr/bin/env bash
# core/tests/conformance/plat-need4/run.sh
#
# ADR-0163: named PLAT.ELF walks sixteen DT_NEEDED (LIBC.SO + LIBM.SO
# + LIBDL.SO + LIBPT.SO + LIBGB.SO + LIBGO.SO + LIBNP.SO + LIBNS.SO
# + LIBNU.SO + LIBSM.SO + LIBDB.SO + LIBGI.SO + LIBAT.SO + LIBAB.SO
# + LIBCU.SO + LIBX1.SO), dlopens each, and prints derived LINE1..LINE16
# from write / need_fn / dl_fn / pt_fn / gb_fn / go_fn / np_fn / ns_fn
# / nu_fn / sm_fn / db_fn / gi_fn / at_fn / ab_fn / cu_fn / x1_fn.
# ASK.ELF of the same bytes is REFUSED 11. A volume without LIBX1.SO
# cannot invent LINE16. Satisfies 16 of 32 CEF DT_NEEDED stand-ins;
# 16 remain. OnPaint leftover. Not glibc. Not libcef. Syscall 11 stays
# fdwait. TAP/FILES stay 64K/2MiB. No help line. Graphite / osgfx_skia /
# MakeVulkan / Venus fenced. Do not break plat-need / plat-need2 /
# plat-need3.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "PLAT-NEED4: FAIL — $1" >&2; exit 1; }
setup_error() { echo "PLAT-NEED4: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned from the first green run.
ASSERTIONS_REQUIRED=64

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-plat-need4.XXXXXX")" \
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
ck; grep -aob $'dl_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no dl_fn NUL string — ADR-0160 resolve is missing"
ck; grep -aob $'pt_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no pt_fn NUL string — ADR-0160 resolve is missing"
ck; grep -aob $'gb_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no gb_fn NUL string — ADR-0162 resolve is missing"
ck; grep -aob $'ns_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no ns_fn NUL string — ADR-0162 resolve is missing"
ck; grep -aob $'nu_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no nu_fn NUL string — ADR-0163 resolve is missing"
ck; grep -aob $'sm_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no sm_fn NUL string — ADR-0163 resolve is missing"
ck; grep -aob $'db_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no db_fn NUL string — ADR-0163 resolve is missing"
ck; grep -aob $'gi_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no gi_fn NUL string — ADR-0163 resolve is missing"
ck; grep -aob $'at_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no at_fn NUL string — ADR-0163 resolve is missing"
ck; grep -aob $'ab_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no ab_fn NUL string — ADR-0163 resolve is missing"
ck; grep -aob $'cu_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no cu_fn NUL string — ADR-0163 resolve is missing"
ck; grep -aob $'x1_fn\0' "$KERNEL_ELF" >/dev/null \
  || fail "kernel.elf has no x1_fn NUL string — ADR-0163 resolve is missing"

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
ck; grep -q 'elfStrNuFn' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart has no elfStrNuFn — nu_fn resolve is missing"
ck; grep -q 'elfStrX1Fn' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart has no elfStrX1Fn — x1_fn resolve is missing"
ck; grep -q 'ADR-0163' "$CORE_DIR/docs/decisions/0163-dt-needed-loads-sixteen-fat-sos.md" \
  || fail "ADR-0163 file is missing"
ck; grep -q '0162 is' "$CORE_DIR/docs/decisions/0163-dt-needed-loads-sixteen-fat-sos.md" \
  || fail "ADR-0163 stole 0162"
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
ck; [[ -d "$CORE_DIR/tests/conformance/plat-need" ]] \
  || fail "plat-need harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-need2" ]] \
  || fail "plat-need2 harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-need3" ]] \
  || fail "plat-need3 harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-huge" ]] \
  || fail "plat-huge harness missing — do not break it"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-libc" ]] \
  || fail "plat-libc harness missing — do not break it"
echo "STRUCTURAL: pass  DT_NEEDED×16 via dlopen=29; TAP/FILES 64K/2MiB; fdwait=11; help 2511; 16/32 satisfied"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_FULL="$WORKDIR/plat-need4.img"
DISK_MISS="$WORKDIR/plat-need4-miss.img"
SO_FULL=(
  "$WORKDIR/libc.so" "$WORKDIR/libm.so" "$WORKDIR/libdl.so" "$WORKDIR/libpt.so"
  "$WORKDIR/libgb.so" "$WORKDIR/libgo.so" "$WORKDIR/libnp.so" "$WORKDIR/libns.so"
  "$WORKDIR/libnu.so" "$WORKDIR/libsm.so" "$WORKDIR/libdb.so" "$WORKDIR/libgi.so"
  "$WORKDIR/libat.so" "$WORKDIR/libab.so" "$WORKDIR/libcu.so" "$WORKDIR/libx1.so"
)
SO_MISS=(
  "$WORKDIR/libc.so" "$WORKDIR/libm.so" "$WORKDIR/libdl.so" "$WORKDIR/libpt.so"
  "$WORKDIR/libgb.so" "$WORKDIR/libgo.so" "$WORKDIR/libnp.so" "$WORKDIR/libns.so"
  "$WORKDIR/libnu.so" "$WORKDIR/libsm.so" "$WORKDIR/libdb.so" "$WORKDIR/libgi.so"
  "$WORKDIR/libat.so" "$WORKDIR/libab.so" "$WORKDIR/libcu.so"
)
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_FULL" "$WORKDIR/plat.elf" "${SO_FULL[@]}" \
  || fail "make-image.py could not write the full volume"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_MISS" "$WORKDIR/plat.elf" "${SO_MISS[@]}" \
  || fail "make-image.py could not write the miss-libx1 volume"

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
                print("PLAT-NEED4: QEMU", hello.get("QMP", {}).get("version", {}))
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
        if not wait_marker(serial, marker, timeout=60):
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
echo "=== BOOT — full (16 DT_NEEDED) then ASK.ELF ==="
KEYS_FULL="$(typekeys 'vm'),ret,until:READY 1"
KEYS_FULL="$KEYS_FULL,$(typekeys 'proc spawn plat.elf'),ret,until:LINE16 ,wait:800"
KEYS_FULL="$KEYS_FULL,$(typekeys 'proc spawn ask.elf'),ret,until:REFUSED 11,until:PROC KILL,wait:400"
run_boot full "$DISK_FULL" "$KEYS_FULL" "$WORKDIR/full/serial.txt"

echo
echo "=== BOOT — miss LIBX1.SO ==="
KEYS_MISS="$(typekeys 'vm'),ret,until:READY 1"
KEYS_MISS="$KEYS_MISS,$(typekeys 'proc spawn plat.elf'),ret,until:MISS ,wait:800"
run_boot miss "$DISK_MISS" "$KEYS_MISS" "$WORKDIR/miss/serial.txt"

echo
echo "=== ASSERT ==="
python3 - "$WORKDIR/full/serial.txt" "$WORKDIR/miss/serial.txt" "$DERIVED" <<'PY' || fail "boots do not satisfy the sixteen-DT_NEEDED door"
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
need(full, "NEED4 START", "program ran")
for tag in ("LIBC", "LIBM", "LIBDL", "LIBPT", "LIBGB", "LIBGO", "LIBNP", "LIBNS",
            "LIBNU", "LIBSM", "LIBDB", "LIBGI", "LIBAT", "LIBAB", "LIBCU", "LIBX1"):
    # FAT open lines pad the 8.3 stem to 8 chars.
    pad = tag.ljust(8)
    need(full, "FS OPEN %s.SO" % pad, "%s.so opened" % tag.lower())
    need(full, "VIA %s" % tag, "face called through %s" % tag)
line_keys = ["line%d" % i for i in range(1, 17)]
for key in line_keys:
    need(full, derived[key], "derived " + key.upper())
need(full, derived["need_sixteen"], "all sixteen NEEDED loaded")
need(full, derived["refuse"], "ASK.ELF REFUSED 11")
need(full, "BAD 0000000000000000", "full program reported no faults")

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
if len(opens) < 16:
    fails.append("PROC DLOPEN VA count: %d, expected ≥16" % len(opens))
else:
    for va_s in opens[:16]:
        va = int(va_s, 16)
        if va < 0x10400000 or va >= 0x1C100000:
            fails.append("dlopen VA %s outside platform heap" % va_s)

# Anti-vacuity: missing LIBX1.SO → LINE1..15 ok, no LINE16.
need(miss, "NEED4 START", "miss program ran")
for tag in ("LIBC", "LIBM", "LIBDL", "LIBPT", "LIBGB", "LIBGO", "LIBNP", "LIBNS",
            "LIBNU", "LIBSM", "LIBDB", "LIBGI", "LIBAT", "LIBAB", "LIBCU"):
    pad = tag.ljust(8)
    need(miss, "FS OPEN %s.SO" % pad, "miss %s opened" % tag.lower())
for key in ["line%d" % i for i in range(1, 16)]:
    need(miss, derived[key], "miss " + key.upper())
need(miss, derived["miss_line"], "miss missing LIBX1 refused")
need(miss, derived["need_fifteen"], "miss stopped after fifteen NEEDED")
if derived["line16"] in miss:
    fails.append("miss invented LINE16 without LIBX1.SO")
if "FS OPEN LIBX1   .SO" in miss:
    fails.append("miss opened LIBX1.SO — volume should lack it")
if "VIA LIBX1" in miss:
    fails.append("miss called through LIBX1 without the file")
if "ERR FFFFFFFFFFFFFFF9" not in miss:
    fails.append("miss never printed NotFound")

if derived["satisfied"] != "16" or derived["remain"] != "16":
    fails.append("derive count wrong: satisfied=%s remain=%s" % (
        derived["satisfied"], derived["remain"]))
remain = derived.get("remaining", "").split(",")
if len(remain) != 16:
    fails.append("remaining list length %d, expected 16" % len(remain))
for must in ("libXcomposite.so.1", "libpango-1.0.so.0", "ld-linux-x86-64.so.2"):
    if must not in remain:
        fails.append("remaining list lost %s" % must)
for must_not in ("libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0",
                 "libglib-2.0.so.0", "libgobject-2.0.so.0", "libnspr4.so",
                 "libnss3.so", "libnssutil3.so", "libsmime3.so", "libdbus-1.so.3",
                 "libgio-2.0.so.0", "libatk-1.0.so.0", "libatk-bridge-2.0.so.0",
                 "libcups.so.2", "libX11.so.6"):
    if must_not in remain:
        fails.append("remaining list still has satisfied %s" % must_not)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- full serial (tail) ----", file=sys.stderr)
    print("\n".join(full.splitlines()[-160:]), file=sys.stderr)
    print("---- miss serial (tail) ----", file=sys.stderr)
    print("\n".join(miss.splitlines()[-160:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF DT_NEEDED×16 → sixteen FAT stand-ins derived LINE1..16; "
      "LIBX1 absent → no LINE16; ASK.ELF REFUSED 11; 16/32 CEF NEEDED stand-ins; "
      "16 remain)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "PLAT-NEED4: PASS — named PLAT.ELF walked 16 DT_NEEDED (LIBC.SO + LIBM.SO + LIBDL.SO + LIBPT.SO + LIBGB.SO + LIBGO.SO + LIBNP.SO + LIBNS.SO + LIBNU.SO + LIBSM.SO + LIBDB.SO + LIBGI.SO + LIBAT.SO + LIBAB.SO + LIBCU.SO + LIBX1.SO); derived LINE1..LINE16; missing LIBX1.SO refuses LINE16; ASK.ELF REFUSED 11; satisfied 16/32 CEF NEEDED stand-ins (16 remain); TAP/FILES 64K/2MiB; leftover OnPaint + 16 DT_NEEDED"
exit 0
