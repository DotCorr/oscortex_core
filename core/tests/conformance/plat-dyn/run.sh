#!/usr/bin/env bash
# core/tests/conformance/plat-dyn/run.sh
#
# ADR-0126: a named platform ELF may carry PT_INTERP pointing at our
# LD.SO on the FAT. The interp maps the dyn ELF (kernel maps both,
# enters the interp) and jumps to e_entry. Derived write comes from
# the dyn program. ASK.ELF is the same bytes and is still REFUSED 11.
# No LD.SO on the volume is REFUSED 11, not a silent static run.
#
# Not glibc. Not libc.so.6. Not CEF OnPaint. Syscall 11 stays fdwait.
# TAP/FILES stay 64K/2MiB. de-browse floor stays 87.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "PLAT-DYN: FAIL — $1" >&2; exit 1; }
setup_error() { echo "PLAT-DYN: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run.
ASSERTIONS_REQUIRED=40

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-plat-dyn.XXXXXX")" \
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
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
VM_PROG_END=$(dartconst vmProgEnd vm.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 231718912 ]] \
  || fail "heapPlatMaxInc moved — platform window is RO+RX LOAD span (ADR-0168)"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$VM_PROG_END" -eq 270532608 ]] \
  || fail "vmProgEnd moved — app load window must stay 2 MiB"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$CORE_DIR/tests/conformance/de-browse/run.sh" \
  || fail "de-browse floor moved — do not raise it on this door"
ck; grep -q 'elfInterpPermit' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart has no elfInterpPermit"
ck; grep -q 'elfHonorInterp' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart has no elfHonorInterp"
ck; grep -q 'elfErrDynamic' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart no longer names elfErrDynamic"
ck; grep -q 'PT_DYNAMIC' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart lost the PT_DYNAMIC refusal"
ck; ! grep -q 'proc interp' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew an interp help string"
ck; ! grep -q 'osgfx_skia' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart touched osgfx_skia"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
echo "STRUCTURAL: pass  interp door on PLAT.ELF only; TAP/FILES 64K/2MiB; fdwait=11; help 2511"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_FULL="$WORKDIR/plat-dyn.img"
DISK_BARE="$WORKDIR/plat-dyn-bare.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_FULL" "$WORKDIR/plat.elf" "$WORKDIR/ld.so" \
  || fail "make-image.py could not write the full volume"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_BARE" "$WORKDIR/plat.elf" \
  || fail "make-image.py could not write the no-interp volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_FULL"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the full image"; }
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$DISK_BARE"
ck; [[ $FSCK2_STATUS -eq 0 ]] || { echo "$FSCK2_OUT" >&2; fail "fsck_msdos rejected the bare image"; }

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

boot_keys() {
  local disk="$1" keys="$2" tag="$3"
  mkdir -p "$WORKDIR/$tag"
  local ser="$WORKDIR/$tag/serial.txt"
  : >"$ser"
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
    >"$WORKDIR/$tag/qemu.log" 2>&1 &
  qemu_pid=$!
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
                print("PLAT-DYN: QEMU", hello.get("QMP", {}).get("version", {}))
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
time.sleep(0.5)
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
    cat "$WORKDIR/$tag/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -80 "$ser" >&2
    fail "$tag session driver exited $drive_status"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$WORKDIR/$tag/qemu.log" >&2
    fail "$tag qemu exited $qemu_status"
  fi
  ck; [[ -s "$ser" ]] || fail "$tag captured no serial"
}

echo
echo "=== BOOT — PLAT.ELF then ASK.ELF (LD.SO present) ==="
KEYS="$(typekeys 'proc spawn plat.elf'),ret,until:DYN LINE,until:PROC KILL,wait:400"
KEYS="$KEYS,$(typekeys 'proc spawn ask.elf'),ret,until:REFUSED 11,until:PROC KILL,wait:400"
boot_keys "$DISK_FULL" "$KEYS" "full"

echo
echo "=== BOOT — PLAT.ELF without LD.SO ==="
KEYS2="$(typekeys 'proc spawn plat.elf'),ret,until:REFUSED 11,until:PROC KILL,wait:400"
boot_keys "$DISK_BARE" "$KEYS2" "bare"

echo
echo "=== ASSERT ==="
python3 - "$WORKDIR/full/serial.txt" "$WORKDIR/bare/serial.txt" "$DERIVED" <<'PY' || fail "the boots do not satisfy the interp door"
import sys

full = open(sys.argv[1], "rb").read().decode("latin-1")
bare = open(sys.argv[2], "rb").read().decode("latin-1")
derived = {}
for line in open(sys.argv[3]):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        derived[k] = v
fails = []

def need(ser, token, label):
    if token not in ser:
        fails.append("%s missing %r" % (label, token))

def refuse(ser, label):
    if "ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not link" not in ser:
        fails.append("%s did not print ELF REFUSED 11" % label)

need(full, "ELF FILE PLAT    .ELF", "full plat load")
need(full, "ELF INTERP LD      .SO", "full interp open")
need(full, "ELF FILE LD      .SO", "full interp file")
need(full, derived["interp_map"], "full interp ran")
need(full, derived["dyn_start"], "full dyn ran")
need(full, derived["dyn_line"], "full derived write")
need(full, "ELF FILE ASK     .ELF", "full ask load")
refuse(full, "ASK.ELF")
need(full, "PROC PLAT 00 WIN 000000000DCFC000", "plat flag")

if full.count("INTERP MAP") != 1:
    fails.append("INTERP MAP count %d, expected 1 (only PLAT.ELF)" % full.count("INTERP MAP"))
if full.count("DYN LINE") != 1:
    fails.append("DYN LINE count %d, expected 1 (only PLAT.ELF)" % full.count("DYN LINE"))
if "PROC PLAT 01" in full:
    fails.append("ASK.ELF was given a platform flag")
if "ELF DISK LBA" in full:
    fails.append("full boot used the LBA loader")

# ASK spawn is after the first PROC KILL
parts = full.split("PROC KILL", 1)
if len(parts) < 2:
    fails.append("full boot had no PROC KILL")
else:
    after_ask = parts[1]
    if "DYN LINE" in after_ask:
        fails.append("ASK.ELF ran the dyn program")
    if "INTERP MAP" in after_ask:
        fails.append("ASK.ELF entered the interp")

need(bare, "ELF FILE PLAT    .ELF", "bare plat load")
refuse(bare, "bare PLAT.ELF")
if "INTERP MAP" in bare:
    fails.append("bare boot entered the interp with no LD.SO")
if "DYN START" in bare or "DYN LINE" in bare:
    fails.append("bare boot ran the dyn program — silent static run")
if "ELF INTERP" in bare and "REFUSED" not in bare:
    fails.append("bare boot honoured a missing interp")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- full serial (tail) ----", file=sys.stderr)
    print("\n".join(full.splitlines()[-80:]), file=sys.stderr)
    print("---- bare serial (tail) ----", file=sys.stderr)
    print("\n".join(bare.splitlines()[-40:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF + LD.SO: INTERP MAP then derived DYN LINE; ASK.ELF same bytes REFUSED 11; no LD.SO REFUSED 11, not a static run)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "PLAT-DYN: PASS — named PLAT.ELF PT_INTERP → LD.SO mapped the dyn and jumped to e_entry; derived write from the dyn; ASK.ELF still REFUSED 11; missing LD.SO is 11 not a static run; TAP/FILES 64K/2MiB; leftovers libc / 189 MiB .text"
exit 0
