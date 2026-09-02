#!/usr/bin/env bash
# core/tests/conformance/d3-resident/run.sh
#
# D3 — A process outlives the shell command that started it.
# display-protocol.md §6, ADR-0053.
#
# Binary: spawn a spinner; type `ticks` while it is still live; its per-slot
# preempt counter, which `proc sched` already prints, is strictly greater
# after that command than before.
#
# Negative control: spawn a program that exits immediately; `ticks` still
# works; the preempt counter does not advance.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "D3-resident: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D3-resident: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run. A drop below it is the failure.
ASSERTIONS_REQUIRED=17

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d3.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== PROGRAMS ==="
ck; bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" || fail "the test programs could not be built"
PROG_S="$WORKDIR/progS.elf"
PROG_E="$WORKDIR/progE.elf"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROG_S" "$PROG_E" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_S=$(lba_of S)
LBA_E=$(lba_of E)
echo "IMAGE: pass  spinner at 0x$LBA_S, exit-at-once at 0x$LBA_E"

echo
echo "=== STRUCTURAL ==="
dartconst() {
  awk -F'= *' -v n="$1" '$0 ~ ("^const int " n " =") { gsub(/;.*/,"",$2); print $2; exit }' \
    "$CORE_DIR/kernel/$2"
}
RESIDENT_WORD=$(dartconst procHeadResident proc.dart)
ck; [[ "$RESIDENT_WORD" == "14" ]] || fail "procHeadResident is ${RESIDENT_WORD:-missing}, expected 14"
ck; grep -q '^\.global resume_user$' "$CORE_DIR/boot/isr.S" \
  || fail "isr.S has no resume_user — D3 re-enters ring 3 from a saved frame"
ck; grep -q 'proc_idle_gate()' "$CORE_DIR/kernel/shell.dart" \
  || fail "shellMain does not call proc_idle_gate — the idle walk would be inlined"
ck; grep -q 'shellProcSpawnArgs' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch proc spawn"
ck; grep -q 'procHeadResident' "$CORE_DIR/kernel/shell.dart" \
  || fail "shellTicks does not look at procHeadResident before remasking IRQ0"
echo "STRUCTURAL: pass  header word 14 is resident, resume_user exists, the idle loop and ticks honour it"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o && bash scripts/verify-freestanding.sh build/kdata.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
EXTERN_COUNT=$(sed -n 's/.*(\([0-9]*\) declared extern(s).*/\1/p' <<<"$VERIFY_OUT" | head -1)
# ADR-0104 (the OS calls osgfx), ADR-0113/ADR-0133 (osxui paints through
# osgfx), ADR-0136 (panel hex is an osgfx glyph), ADR-0172 (Venus encodes
# retained SPIR-V) and ADR-0181 (the generative desk) gave the OS platform C
# modules to call. Their entry points are `external` too, so the RAW count
# moves every time the OS calls one more of its own modules -- which is not
# what any milestone's extern pin below is about.
#
# Subtracted BY PATTERN rather than by a typed list, because a typed list is a
# second place to forget: `osgfx_*` and `osxui_*` are, by ADR-0104, C module
# entry points. Read out of dcc's own manifest, which is the authority on what
# kmain.o declares, the same file the D3 block above reads. The pin they are
# subtracted from still says exactly what it always said -- THIS milestone
# added no new assembly primitive -- and each module entry point is asserted
# NOT to be defined in assembly, which is the property the pin exists to
# protect and which a bumped total would not state.
EXTERN_MANIFEST="$CORE_DIR/build/kmain.o.externs"
ck; [[ -f "$EXTERN_MANIFEST" ]] || fail "dcc wrote no $EXTERN_MANIFEST — the extern census below has nothing authoritative to read"
PLAT_EXTERNS=$(grep -E '^(osgfx|osxui)_[A-Za-z0-9_]+$' "$EXTERN_MANIFEST" | sort -u)
PLAT_PRESENT=$(wc -w <<<"$PLAT_EXTERNS" | tr -d ' ')
ck; [[ "$PLAT_PRESENT" -ge 7 ]] \
  || fail "kmain.o declares only $PLAT_PRESENT osgfx_/osxui_ entry points, expected at least the seven of ADR-0104/0113/0136/0172/0181 — the OS stopped calling its own C modules"
for sym in $PLAT_EXTERNS; do
  ck; ! grep -qE "^[.]glob(a)?l[[:space:]]+$sym\b" "$CORE_DIR/boot/isr.S" "$CORE_DIR/boot/boot.S" "$CORE_DIR/boot/portio.S" \
    || fail "$sym is defined in assembly — it is a platform C module entry point (ADR-0104), and an assembly definition of it would mean the module seam had been replaced by a stub"
done
EXTERN_COUNT=$(( EXTERN_COUNT - PLAT_PRESENT ))
# ADR-0148's TLS door is the one genuinely NEW assembly primitive since these
# numbers were pinned: `setfs` has to land in the FS_BASE MSR, and wrmsr has no
# DCDart spelling. Subtracted by name, and asserted to BE assembly.
ck; grep -qE "^[.]glob(a)?l[[:space:]]+msr_write\b" "$CORE_DIR/boot/isr.S" \
  || fail "msr_write is not defined in isr.S — ADR-0148's FS_BASE door was supposed to be one wrmsr stub in assembly"
MSR_PRESENT=$(grep -cE '^msr_write$' "$EXTERN_MANIFEST" || true)
EXTERN_COUNT=$(( EXTERN_COUNT - MSR_PRESENT ))
ck; [[ "$EXTERN_COUNT" -eq 47 ]] || fail "kmain.o declares ${EXTERN_COUNT:-no} externs, expected 47 (44 plus resume_user, proc_idle_gate and kbd_drain_gate)"
echo "FREESTANDING: pass  $EXTERN_COUNT declared externs (resume_user + proc_idle_gate)"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
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
    -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$ser" \
    --wait-for 'M1 END\n' --png "$png" --screen-text "$outdir/screen.txt" \
    --keys "$keys"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
}

echo
echo "=== BOOT A — spinner stays live across ticks ==="
SPIN_KEYS="$(typekeys "proc spawn $LBA_S"),ret,wait:1500"
SPIN_KEYS="$SPIN_KEYS,$(typekeys 'proc sched'),ret,wait:600"
SPIN_KEYS="$SPIN_KEYS,$(typekeys 'ticks'),ret,wait:800"
SPIN_KEYS="$SPIN_KEYS,$(typekeys 'proc sched'),ret,wait:600"
drive_session "$WORKDIR/spin" "$SPIN_KEYS" "$WORKDIR/spin/shot.png" "spin"
SPIN_SERIAL="$WORKDIR/spin/serial.txt"

echo
echo "=== BOOT B — exit-at-once is the negative control ==="
EXIT_KEYS="$(typekeys "proc spawn $LBA_E"),ret,wait:800"
EXIT_KEYS="$EXIT_KEYS,$(typekeys 'ticks'),ret,wait:800"
EXIT_KEYS="$EXIT_KEYS,$(typekeys 'proc sched'),ret,wait:600"
drive_session "$WORKDIR/exit" "$EXIT_KEYS" "$WORKDIR/exit/shot.png" "exit"
EXIT_SERIAL="$WORKDIR/exit/serial.txt"

echo
echo "=== ASSERT ==="
python3 - "$SPIN_SERIAL" "$EXIT_SERIAL" <<'PY' || fail "the two boots do not satisfy D3's criterion"
import re, sys

spin = open(sys.argv[1], "rb").read().decode("latin-1")
ex = open(sys.argv[2], "rb").read().decode("latin-1")
fails = []

def slots(ser):
    return [(int(a, 16), int(b, 16), int(c, 16), int(d, 16))
            for a, b, c, d in re.findall(
                r"^PROC SLOT (\d\d) PREEMPTS (\w{8}) YIELDS (\w{8}) STATE (\w{2})$",
                ser, re.M)]

if "PROC SPAWN " not in spin:
    fails.append("spin boot never printed PROC SPAWN")
if "PROC SPAWN " not in ex:
    fails.append("exit boot never printed PROC SPAWN")

ticks_spin = re.findall(r"^TICKS ([0-9A-F]{16}) \+0010 LIVE$", spin, re.M)
if len(ticks_spin) != 1:
    fails.append("spin boot TICKS LIVE lines: %d, expected 1. The shell did not "
                 "answer while the spinner was live." % len(ticks_spin))

ticks_ex = re.findall(r"^TICKS ([0-9A-F]{16}) \+0010 LIVE$", ex, re.M)
if len(ticks_ex) != 1:
    fails.append("exit boot TICKS LIVE lines: %d, expected 1" % len(ticks_ex))

ss = slots(spin)
if len(ss) < 8:
    fails.append("spin boot printed %d SLOT lines, expected two full sched reports"
                 % len(ss))
else:
    before = ss[0][1]
    after = ss[4][1]
    state_after = ss[4][3]
    if after <= before:
        fails.append("slot 0 preempts was 0x%X before ticks and 0x%X after — "
                     "D3 requires the counter to advance while the shell ran"
                     % (before, after))
    if state_after not in (1, 2):
        fails.append("slot 0 state after ticks is 0x%X, expected READY(1) or "
                     "RUNNING(2) — the spinner is not still live" % state_after)
    print("    (spin: slot 0 preempts 0x%X -> 0x%X, state 0x%X)"
          % (before, after, state_after))

es = slots(ex)
if len(es) < 4:
    fails.append("exit boot printed %d SLOT lines, expected one sched report"
                 % len(es))
else:
    p0 = es[0][1]
    st0 = es[0][3]
    if p0 != 0:
        fails.append("exit-at-once slot 0 preempts is 0x%X, expected 0 — the "
                     "negative control advanced" % p0)
    if st0 not in (0, 3):
        fails.append("exit-at-once slot 0 state is 0x%X, expected FREE(0) or "
                     "EXITED(3)" % st0)
    print("    (exit: slot 0 preempts 0x%X, state 0x%X)" % (p0, st0))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo "D3-resident: PASS — a spawned spinner stayed live across \`ticks\`, its preempt counter advanced, and an exit-at-once program did not."
exit 0
