#!/usr/bin/env bash
# core/tests/conformance/plat-clone/run.sh
#
# ADR-0130: a named platform ELF may clone a sibling on its page
# tables. TAP/FILES stay 64 KiB / 2 MiB. Same binary planted as
# PLAT.ELF and ASK.ELF — only the name honours syscall 28.
# The child writes the derived CHILD line. First PROC KILL FREED
# is 0 (survivor still walks the tables); the last equals ASK.
#
# Not glibc. Not CEF OnPaint. Syscall 11 stays fdwait. No help line.
# drawRRect owns osgfx_skia. de-browse floor stays 87.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "PLAT-CLONE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "PLAT-CLONE: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run.
ASSERTIONS_REQUIRED=43

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-plat-clone.XXXXXX")" \
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
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "BUILD: build-kernel.sh exited $BUILD_STATUS (osgfx/media may be mid-edit)"
fi
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
ck; x86_64-elf-nm "$KERNEL_ELF" | grep -q ' T procSysClone$' \
  || fail "kernel.elf has no procSysClone — this door is not linked"

echo
echo "=== STRUCTURAL ==="
HEAP_MAX=$(dartconst heapMaxInc heap.dart)
HEAP_PLAT_MAX=$(dartconst heapPlatMaxInc heap.dart)
ELF_MAX=$(dartconst elfImageMax elf.dart)
VM_PROG_END=$(dartconst vmProgEnd vm.dart)
CLONE_NO=$(dartconst procSysCloneNo proc.dart)
SPAWN_NO=$(dartconst procSysSpawnNo proc.dart)
MMAP_NO=$(dartconst heapSysMmapNo heap.dart)
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$HEAP_PLAT_MAX" -eq 229318656 ]] \
  || fail "heapPlatMaxInc moved — platform window is RO+RX LOAD span (ADR-0168)"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$VM_PROG_END" -eq 270532608 ]] \
  || fail "vmProgEnd moved — app load window must stay 2 MiB"
ck; [[ "$CLONE_NO" -eq 28 ]] \
  || fail "procSysCloneNo is $CLONE_NO, expected 28"
ck; [[ "$SPAWN_NO" -eq 26 ]] \
  || fail "spawn moved off 26"
ck; [[ "$MMAP_NO" -eq 27 ]] \
  || fail "mmap moved off 27"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; grep -E '^\| 28 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q clone \
  || fail "syscall 28 is not clone in the registry"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$CORE_DIR/tests/conformance/de-browse/run.sh" \
  || fail "de-browse floor moved — do not raise it on this door"
ck; grep -q 'procSysCloneNo' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart has no procSysCloneNo"
ck; grep -A20 'u64 procSpaceShared' "$CORE_DIR/kernel/proc.dart" | grep -q 'procSlotPml4' \
  || fail "procSpaceShared does not compare PML4 — first exit would free the survivor"
ck; grep -A8 'u64 procSpaceFree' "$CORE_DIR/kernel/proc.dart" | grep -q 'procSpaceShared' \
  || fail "procSpaceFree does not consult procSpaceShared"
ck; grep -q 'procSysCloneNo' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart never dispatches clone"
ck; grep -q 'ADR-0130' "$CORE_DIR/docs/decisions/0130-clone-is-the-platform-thread-door.md" \
  || fail "ADR-0130 file is missing"
ck; grep -q '0129 is Graphite' "$CORE_DIR/docs/decisions/0130-clone-is-the-platform-thread-door.md" \
  || fail "ADR-0130 stole 0129"
ck; ! grep -q 'proc clone' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a clone help string"
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
echo "STRUCTURAL: pass  clone=28 on PLAT.ELF only; TAP/FILES 64K/2MiB; fdwait=11; help 2511"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/plat-clone.img"
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
# vmPlatPdCount is how many 2MiB page-directory entries [vmPlatBase, vmPlatEnd)
# needs, not an independent number. It was typed as 95 in the teardown check
# below, which stopped being true when ADR-0168 grew the plat window to the
# RO+RX LOAD span of the measured official libcef and vm.dart went to 111.
# Derive it, and assert the constant agrees with its own window, so this and
# plat-map/plat-huge cannot drift apart again.
VM_PLAT_BASE=$(dartconst vmPlatBase vm.dart)
VM_PLAT_END=$(dartconst vmPlatEnd vm.dart)
VM_BIG=$(dartconst vmBigBytes vm.dart)
VM_PLAT_PD=$(dartconst vmPlatPdCount vm.dart)
ck; [[ -n "$VM_PLAT_BASE" && -n "$VM_PLAT_END" && -n "$VM_BIG" && "$VM_BIG" -gt 0 ]] \
  || fail "could not read the plat window out of vm.dart"
WANT_PLAT_PD=$(( (VM_PLAT_END - VM_PLAT_BASE + VM_BIG - 1) / VM_BIG ))
ck; [[ "$VM_PLAT_PD" -eq "$WANT_PLAT_PD" ]] \
  || fail "vmPlatPdCount is $VM_PLAT_PD but [vmPlatBase, vmPlatEnd) needs $WANT_PLAT_PD page-directory entries of $VM_BIG bytes"
echo "plat_pd=$VM_PLAT_PD" >> "$DERIVED"
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
# Sync on `vm` first. Keys typed during m2Enter (after M1 END, before
# IRQ1 is live) land as NotReady. `READY 1` is the console being up.
KEYS="$(typekeys 'vm'),ret,until:READY 1"
KEYS="$KEYS,$(typekeys 'proc spawn plat.elf'),ret,until:CHILD LINE,wait:400"
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
                print("PLAT-CLONE: QEMU", hello.get("QMP", {}).get("version", {}))
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
python3 - "$SER" "$DERIVED" <<'PY' || fail "the boot does not satisfy the clone door"
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
need("PARENT ", "parent reported a slot")
need(derived["msg_child"], "child write() from shared pages")
need(derived["child_line"], "derived child xor")
need(derived["cap_plat"], "plat cap line")
need(derived["asked_bad"], "ask clone refused")
need(derived["clone_err"], "ask PROC CLONE ERR")
need(derived["cap_app"], "ask old cap line")
need("PLAT START", "program ran")
need("BAD 0000000000000000", "program reported no faults")

if "PROC PLAT 01" in ser or "PROC PLAT 00 WIN 0000000000200000" in ser:
    fails.append("ASK.ELF was given a platform flag")
if ser.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1 (only PLAT.ELF)" % ser.count("PROC PLAT "))
if ser.count("PROC CLONE ") < 2:
    fails.append("PROC CLONE lines: %d, expected at least 2" % ser.count("PROC CLONE "))
if ser.count("CHILD LINE") != 1:
    fails.append("CHILD LINE count: %d, expected 1 (only the plat child)" % ser.count("CHILD LINE"))
if "ELF DISK LBA" in ser:
    fails.append("boot used the LBA loader")

pml4s = re.findall(
    r"PROC NEW SLOT 00 ID [0-9A-Fa-f]+ PML4 ([0-9A-Fa-f]+)", ser)
clones = re.findall(
    r"PROC CLONE 01 FN [0-9A-Fa-f]+ SP [0-9A-Fa-f]+ PML4 ([0-9A-Fa-f]+)", ser)
if not pml4s:
    fails.append("no PROC NEW SLOT 00 PML4 for PLAT.ELF")
elif not clones:
    fails.append("no PROC CLONE 01 with a PML4 — child did not share")
elif pml4s[0] != clones[0]:
    fails.append("clone PML4 %s != parent PML4 %s — not CLONE_VM"
                 % (clones[0], pml4s[0]))

kills = re.findall(r"PROC KILL SLOT ([0-9A-Fa-f]+) FREED ([0-9A-Fa-f]+)", ser)
if len(kills) < 3:
    fails.append("PROC KILL FREED lines: %d, expected 3 (plat parent, plat child, ask)"
                 % len(kills))
else:
    plat_parent = int(kills[0][1], 16)
    plat_child = int(kills[1][1], 16)
    ask_freed = int(kills[2][1], 16)
    if plat_parent != 0:
        fails.append("first FREED %d, expected 0 (survivor still walks the tables)"
                     % plat_parent)
    # PLAT installs vmPlatPdCount platform PD tables ASK does not. Shared
    # teardown means the last plat free is ASK's frames plus those, not 2x.
    plat_pd = int(derived["plat_pd"])
    if plat_child - ask_freed != plat_pd:
        fails.append("plat last FREED %d - ASK FREED %d = %d, expected %d "
                     "(vmPlatPdCount). Double-free or a copied address space "
                     "fails this delta."
                     % (plat_child, ask_freed, plat_child - ask_freed, plat_pd))
    if ask_freed < 4:
        fails.append("ASK FREED %d is too small to be the ELF tables" % ask_freed)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-100:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF clone slot 1 on parent PML4 + derived CHILD; "
      "first FREED 0; last FREED is ASK+%d plat tables; ASK.ELF same bytes "
      "refused)" % plat_pd)
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "PLAT-CLONE: PASS — named PLAT.ELF cloned a sibling on its page tables (syscall 28); child wrote the derived line; first FREED 0, last is ASK+$VM_PLAT_PD plat tables; ASK.ELF is the same bytes and is refused; TAP/FILES stay 64K/2MiB; leftovers futex / TLS / dlopen / 189MiB"
exit 0
