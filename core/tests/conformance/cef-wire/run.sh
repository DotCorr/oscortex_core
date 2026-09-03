#!/usr/bin/env bash
# core/tests/conformance/cef-wire/run.sh
#
# ADR-0167: a named platform ELF may dlopen a measured official
# linux64 libcef.so slice (CEF.SO). Map + walk 32 official
# DT_NEEDED + apply one R_X86_64_64 whose addend is the first 8
# official cef_initialize bytes. Derived PIXEL / NEED / NHASH /
# RELOC. ASK.ELF of the same bytes is BadArg. MISS.SO is NotFound.
#
# Not OnPaint. Not full 1.5 GiB libcef. Not glibc faces for the
# 1,336 UND. Syscall 11 stays fdwait. No help line. Graphite /
# MakeVulkan / Venus fenced. de-browse floor stays 87. TAP/FILES
# stay 64 KiB / 2 MiB. browse-paint stand-in floor stays.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "CEF-WIRE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CEF-WIRE: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor set after the first green run; raised if checks grow.
ASSERTIONS_REQUIRED=45

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-cef-wire.XXXXXX")" \
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
  || fail "kernel.elf has no elfDlopenMakeExec — RX LOAD would stay NX"
# The mark string is a @rodata u8 table, so it has no symbol of its own and
# `objdump -s` splits its ASCII column on 16-byte lines. Reassemble .rodata
# and search for the exact bytes elf.dart declares, which also pins the
# declaration itself to 'cef_initialize' + NUL (ADR-0167).
capture_sh MARK_OUT MARK_STATUS -- "python3 - '$CORE_DIR/kernel/elf.dart' '$CORE_DIR/build/kmain.o' <<'PY'
import re, subprocess, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> elfStrCefInit = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('elf.dart no longer declares elfStrCefInit')
want = bytes(int(h, 16) for h in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if want != b'cef_initialize\x00':
    raise SystemExit('elfStrCefInit is %r, not cef_initialize + NUL' % want)
dump = subprocess.run(['x86_64-elf-objdump', '-s', '-j', '.rodata', sys.argv[2]],
                      capture_output=True, text=True).stdout
blob = bytearray()
for line in dump.splitlines():
    g = re.match(r'^ [0-9a-f]+ ((?:[0-9a-f]{2,8} )+)', line)
    if g:
        blob += bytes.fromhex(g.group(1).replace(' ', ''))
off = blob.find(want)
if off < 0:
    raise SystemExit('kmain.o .rodata (%d bytes) does not contain the bytes' % len(blob))
print('MARK cef_initialize+NUL at .rodata offset %d of %d' % (off, len(blob)))
PY"
echo "$MARK_OUT"
ck; [[ $MARK_STATUS -eq 0 ]] \
  || fail "kmain.o has no cef_initialize mark string — ADR-0167 not linked: $MARK_OUT"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
VM_PROG_END=$(dartconst vmProgEnd vm.dart)
DLOPEN_NO=$(dartconst elfSysDlopenNo elf.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 229318656 ]] \
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
ck; grep -q 'ASSERTIONS_REQUIRED=111' "$CORE_DIR/tests/conformance/browse-paint/run.sh" \
  || fail "browse-paint floor moved — do not break the OnPaint stand-in"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-need5" ]] \
  || fail "plat-need5 harness missing — do not break 32/32 stand-ins"
ck; [[ -d "$CORE_DIR/tests/conformance/plat-huge" ]] \
  || fail "plat-huge harness missing — do not break 189 MiB"
ck; grep -q 'elfStrCefInit' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart has no elfStrCefInit"
ck; grep -q 'dynsz > u64(2048)' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart still refuses DYNAMIC >512 — official NEEDED list cannot map"
ck; grep -q 'ADR-0167' "$CORE_DIR/docs/decisions/0167-measured-libcef-slice-is-the-first-load-door.md" \
  || fail "ADR-0167 file is missing"
ck; grep -q '0166 is OnPaint stand-in' "$CORE_DIR/docs/decisions/0167-measured-libcef-slice-is-the-first-load-door.md" \
  || fail "ADR-0167 stole 0166"
ck; ! grep -q 'proc cef\|cef ' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a cef help string"
ck; ! grep -q 'osgfx_skia' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart touched osgfx_skia — drawRRect owns that"
ck; ! grep -q 'MakeVulkan' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart touched MakeVulkan"
ck; ! grep -q 'oschrome_on_paint' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c names oschrome_on_paint — that is the stand-in, not this door"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
echo "STRUCTURAL: pass  dlopen=29 CEF.SO slice; TAP/FILES 64K/2MiB; fdwait=11; help 2511; floors held"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/cef-wire.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/plat.elf" \
  "$WORKDIR/cef.so" \
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
KEYS="$KEYS,$(typekeys 'proc spawn plat.elf'),ret,until:RELOC ,wait:400"
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
                print("CEF-WIRE: QEMU", hello.get("QMP", {}).get("version", {}))
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
python3 - "$SER" "$DERIVED" <<'PY' || fail "the boot does not satisfy the cef-wire door"
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
need("PROC DLOPEN ", "dlopen line")
need("FS OPEN CEF     .SO", "cef.so opened")
need("CEF START", "program ran")
need(derived["pixel_line"], "official text pixel")
need(derived["need_line"], "32 DT_NEEDED walked")
need(derived["nhash_line"], "official NEEDED name fold")
need(derived["reloc_line"], "official-addend reloc applied")
need(derived["miss_line"], "missing MISS.SO refused")
need(derived["cap_plat"], "plat cap line")
need(derived["asked_bad"], "ask dlopen refused")
need(derived["dlopen_err"], "ask PROC DLOPEN ERR")
need(derived["cap_app"], "ask old cap line")
need("BAD 0000000000000000", "program reported no faults")

if "PROC PLAT 01" in ser or "PROC PLAT 00 WIN 0000000000200000" in ser:
    fails.append("ASK.ELF was given a platform flag")
if ser.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1 (only PLAT.ELF)" % ser.count("PROC PLAT "))
if ser.count(derived["pixel_line"]) != 1:
    fails.append("PIXEL count: %d, expected 1" % ser.count(derived["pixel_line"]))
if ser.count(derived["reloc_line"]) != 1:
    fails.append("RELOC count: %d, expected 1" % ser.count(derived["reloc_line"]))
if "ELF DISK LBA" in ser:
    fails.append("boot used the LBA loader")
# Anti-rename: stand-in OnPaint path is not this door.
if "oschrome_on_paint" in ser or "PAGE" == ser.strip():
    fails.append("serial smells like the browse-paint stand-in")

opens = re.findall(r"PROC DLOPEN 00 VA ([0-9A-Fa-f]+)", ser)
if not opens:
    fails.append("no PROC DLOPEN VA for PLAT.ELF")
else:
    va = int(opens[0], 16)
    if va < 0x10600000 or va >= 0x1C100000:
        fails.append("dlopen VA %s outside platform heap" % opens[0])
if "ERR FFFFFFFFFFFFFFF9" not in ser:
    fails.append("missing-file NotFound never printed by kernel")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-120:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF dlopen CEF.SO → map official slice → NEED 32 + PIXEL/RELOC; "
      "MISS.SO NotFound; ASK.ELF same bytes refused)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "CEF-WIRE: PASS — PLAT.ELF dlopen'd measured official CEF.SO (syscall 29); walked 32 DT_NEEDED; applied official-addend RELA; PIXEL from cef_initialize bytes; ASK refused; leftover: full libcef LOADs + glibc UND (memset@plt / libdl.so.2) + OnPaint"
exit 0
