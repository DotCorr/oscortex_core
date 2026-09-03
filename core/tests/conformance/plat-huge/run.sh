#!/usr/bin/env bash
# core/tests/conformance/plat-huge/run.sh
#
# ADR-0155: a named platform ELF may mmap a 189 MiB window — the
# full CEF .text plant (ADR-0123 measured 189095087 bytes; window
# is 189 << 20). PMM / boot.S identity raised together to 256 MiB.
# Same binary as PLAT.ELF and ASK.ELF — only the name honours
# syscall 27. Every page is touched; write() walks live tables;
# teardown frees 111 plat tables + 48384 frames above ASK.
#
# Anti-vacuity: old 128 MiB PMM / 112 MiB window fails the floor.
# Not glibc. Not CEF OnPaint. Not the rest of DT_NEEDED. Syscall 11
# stays fdwait. No help line. Graphite / MakeVulkan / Venus fenced.
# de-browse floor stays 87. TAP/FILES stay 64 KiB / 2 MiB.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "PLAT-HUGE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "PLAT-HUGE: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor: shrinking the window or skipping FREED/XOR fails this.
ASSERTIONS_REQUIRED=50

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-plat-huge.XXXXXX")" \
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
VM_PLAT_BASE=$(dartconst vmPlatBase vm.dart)
VM_PLAT_BYTES=$(dartconst vmPlatBytes vm.dart)
VM_PLAT_PD=$(dartconst vmPlatPdCount vm.dart)
VM_USER_END=$(dartconst vmUserEnd vm.dart)
VM_PLAT_END=$(dartconst vmPlatEnd vm.dart)
VM_MAP=$(dartconst vmMapBytes vm.dart)
MMAP_NO=$(dartconst heapSysMmapNo heap.dart)
PMM_MAX=$(dartconst pmmMaxFrames pmm.dart)
PMM_MIB=$(dartconst pmmBoundMib pmm.dart)
MAP_PAGES=$(awk -F', *' '/^\.set MAP_2MIB_PAGES/{print $2; exit}' "$CORE_DIR/boot/boot.S")
# 189 MiB plant; floor fails below that size / under the old 128 MiB PMM.
WANT_BYTES=198180864
OLD_PMM=32768
OLD_WIN=117440512
ck; [[ "$HEAP_MAX" -eq 2097152 ]] \
  || fail "heapMaxInc moved — TAP/FILES must stay at the 2 MiB cap"
ck; [[ "$ELF_MAX" -eq 65536 ]] \
  || fail "elfImageMax moved — TAP/FILES stay 64 KiB"
ck; [[ "$VM_PROG_END" -eq 270532608 ]] \
  || fail "vmProgEnd moved — app load window must stay 2 MiB"
ck; [[ "$VM_PLAT_BASE" -eq 274726912 ]] \
  || fail "vmPlatBase moved — mmap VA is derived from this"
ck; [[ "$HEAP_PLAT_MAX" -eq 229318656 ]] \
  || fail "heapPlatMaxInc is $HEAP_PLAT_MAX, expected 229318656 (RO+RX LOAD span)"
ck; [[ "$VM_PLAT_BYTES" -eq 229318656 ]] \
  || fail "vmPlatBytes is $VM_PLAT_BYTES, expected 229318656"
ck; [[ "$HEAP_PLAT_MAX" -ge "$WANT_BYTES" ]] \
  || fail "platform window below the 189 MiB plant floor"
ck; [[ "$HEAP_PLAT_MAX" -gt "$OLD_WIN" ]] \
  || fail "platform window still 112 MiB — ADR-0155 did not raise it"
# DERIVED from the window itself, not typed. plat-map pinned 95 and plat-huge
# pinned 111 for the SAME constant; vm.dart says 111 (ADR-0168 grew the plat
# window to the RO+RX LOAD span of the measured official libcef), so one of the
# two harnesses was simply out of date and the pair could not both be right.
# vmPlatPdCount is not an independent fact: it is how many 2MiB page-directory
# entries [vmPlatBase, vmPlatEnd) needs. Assert THAT, and the two harnesses
# cannot disagree again.
VM_PLAT_END=$(dartconst vmPlatEnd vm.dart)
VM_BIG=$(dartconst vmBigBytes vm.dart)
ck; [[ -n "$VM_PLAT_END" && -n "$VM_BIG" && "$VM_BIG" -gt 0 ]] \
  || fail "could not read vmPlatEnd/vmBigBytes out of vm.dart"
WANT_PLAT_PD=$(( (VM_PLAT_END - VM_PLAT_BASE + VM_BIG - 1) / VM_BIG ))
ck; [[ "$VM_PLAT_PD" -eq "$WANT_PLAT_PD" ]] \
  || fail "vmPlatPdCount is $VM_PLAT_PD but [vmPlatBase, vmPlatEnd) needs $WANT_PLAT_PD page-directory entries of $VM_BIG bytes — the count and the window disagree"
ck; [[ "$VM_USER_END" -eq "$VM_PLAT_END" ]] \
  || fail "vmUserEnd is not one past the platform window"
ck; [[ "$MMAP_NO" -eq 27 ]] \
  || fail "heapSysMmapNo is $MMAP_NO, expected 27"
ck; [[ "$PMM_MAX" -eq 65536 ]] \
  || fail "pmmMaxFrames is $PMM_MAX, expected 65536 (256 MiB)"
ck; [[ "$PMM_MAX" -gt "$OLD_PMM" ]] \
  || fail "pmmMaxFrames still $OLD_PMM — old 128 MiB bound must fail the 189 check"
ck; [[ "$PMM_MIB" -eq 256 ]] \
  || fail "pmmBoundMib is $PMM_MIB, expected 256"
ck; [[ "$MAP_PAGES" -eq 128 ]] \
  || fail "MAP_2MIB_PAGES is $MAP_PAGES, expected 128"
ck; [[ "$(( MAP_PAGES * 2097152 ))" -eq "$(( PMM_MAX * 4096 ))" ]] \
  || fail "MAP_2MIB_PAGES and pmmMaxFrames disagree"
ck; [[ "$VM_MAP" -eq "$(( PMM_MAX * 4096 ))" ]] \
  || fail "vmMapBytes is not pmmMaxFrames * 4KiB"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait \
  || fail "syscall 11 is no longer fdwait"
ck; grep -E '^\| 27 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q mmap \
  || fail "syscall 27 is not mmap in the registry"
ck; grep -q 'ASSERTIONS_REQUIRED=87' "$CORE_DIR/tests/conformance/de-browse/run.sh" \
  || fail "de-browse floor moved — do not raise it on this door"
ck; grep -q 'heapSysMmapNo' "$CORE_DIR/kernel/heap.dart" \
  || fail "heap.dart has no heapSysMmapNo"
ck; grep -A25 'u64 heapMmap' "$CORE_DIR/kernel/heap.dart" | grep -q 'heapSbrk' \
  || fail "heapMmap does not call heapSbrk — pages would not be real"
ck; grep -A25 'u64 heapMmap' "$CORE_DIR/kernel/heap.dart" | grep -q 'heapIsPlat' \
  || fail "heapMmap does not test heapIsPlat — ASK.ELF could succeed"
ck; grep -q 'heapSysMmapNo' "$CORE_DIR/kernel/user.dart" \
  || fail "user.dart never dispatches mmap"
ck; grep -q 'ADR-0155' "$CORE_DIR/docs/decisions/0155-plat-mmap-holds-full-cef-text.md" \
  || fail "ADR-0155 file is missing"
ck; ! grep -q 'proc mmap' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew an mmap help string"
ck; ! grep -q 'osgfx_skia' "$CORE_DIR/kernel/heap.dart" \
  || fail "heap.dart touched osgfx_skia — drawRRect owns that"
ck; ! grep -q 'osgfx_skia' "$CORE_DIR/kernel/vm.dart" \
  || fail "vm.dart touched osgfx_skia"
ck; ! grep -q 'MakeVulkan' "$CORE_DIR/kernel/heap.dart" \
  || fail "heap.dart touched MakeVulkan"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
# Floor that fails below 189 MiB: a 112 MiB window cannot satisfy this.
ck; [[ "$HEAP_PLAT_MAX" -gt 117440512 ]] \
  || fail "platform window still ≤112 MiB — ADR-0155 did not raise it"
echo "STRUCTURAL: pass  mmap=27 on PLAT.ELF; RO+RX window; PMM 256 MiB; TAP/FILES 64K/2MiB; fdwait=11; help 2511"

echo
echo "=== PROGRAM ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/plat-huge.img"
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
KEYS="$(typekeys 'proc spawn plat.elf'),ret,until:CAP 000000000BD00000,until:PROC KILL,wait:400"
KEYS="$KEYS,$(typekeys 'proc spawn ask.elf'),ret,until:CAP 0000000000200000,until:PROC KILL,wait:400"

mkdir -p "$WORKDIR/main"
SER="$WORKDIR/main/serial.txt"
: >"$SER"
ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 480 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 256M \
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
                print("PLAT-HUGE: QEMU", hello.get("QMP", {}).get("version", {}))
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

def wait_marker(path, marker, timeout=240, at_least=1):
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
        if not wait_marker(serial, marker, timeout=300):
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
python3 - "$SER" "$DERIVED" <<'PY' || fail "the boot does not satisfy the huge plat mmap door"
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
need("PROC MAP 00 LEN 000000000BD00000 " + derived["map_va"], "plat mmap VA")
need(derived["map_pages"], "plat mmap page count")
need(derived["asked_ok"], "plat mmap returned plat base")
need(derived["msg_map"], "write() from mapped plat pages")
need("XOR " + derived["xor"], "derived fill xor")
need(derived["cap_plat"], "plat cap line")
need(derived["asked_bad"], "ask mmap(189 MiB) refused")
need(derived["map_err"], "ask PROC MAP ERR")
need(derived["cap_app"], "ask old cap line")
need("PLAT START", "program ran")
need("BAD 0000000000000000", "program reported no faults")

if "PROC PLAT 01" in ser or "PROC PLAT 00 WIN 0000000000200000" in ser:
    fails.append("ASK.ELF was given a platform flag")
if "PROC PLAT 00 WIN 0000000001000000" in ser:
    fails.append("WIN still prints 16 MiB — window was not raised")
if "PROC PLAT 00 WIN 0000000007000000" in ser:
    fails.append("WIN still prints 112 MiB — ADR-0155 did not raise it")
if ser.count("PROC PLAT ") != 1:
    fails.append("PROC PLAT lines: %d, expected 1 (only PLAT.ELF)" % ser.count("PROC PLAT "))
if ser.count("PROC MAP ") < 2:
    fails.append("PROC MAP lines: %d, expected at least 2" % ser.count("PROC MAP "))
if "ELF DISK LBA" in ser:
    fails.append("boot used the LBA loader")

kills = re.findall(r"PROC KILL SLOT [0-9A-Fa-f]+ FREED ([0-9A-Fa-f]+)", ser)
if len(kills) < 2:
    fails.append("PROC KILL FREED lines: %d, expected 2" % len(kills))
else:
    plat_freed = int(kills[0], 16)
    ask_freed = int(kills[1], 16)
    want_delta = int(derived["freed_delta"])
    delta = plat_freed - ask_freed
    if delta != want_delta:
        fails.append("FREED delta %d (plat %d - ask %d), expected %d "
                     "(111 plat tables + 48384 mapped pages). A no-op return "
                     "of heap base without new frames fails this check."
                     % (delta, plat_freed, ask_freed, want_delta))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    print("---- serial (tail) ----", file=sys.stderr)
    print("\n".join(ser.splitlines()[-100:]), file=sys.stderr)
    sys.exit(1)

print("    (PLAT.ELF mmap 189 MiB at 0x10600000 + heap write + xor; "
      "ASK.ELF same bytes refused; FREED delta is 111 tables + 48384 pages; "
      "leftover DT_NEEDED / OnPaint)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "PLAT-HUGE: PASS — named PLAT.ELF mmap'd 189 MiB at 0x10600000 (syscall 27); write() from those pages; teardown freed 111 tables + 48384 frames above ASK.ELF; ASK.ELF is the same bytes and is refused; TAP/FILES stay 64K/2MiB; leftovers rest of DT_NEEDED / OnPaint"
exit 0
