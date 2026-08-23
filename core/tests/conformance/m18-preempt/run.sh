#!/usr/bin/env bash
# core/tests/conformance/m18-preempt/run.sh
#
# Mechanical check of ROADMAP.md's M18 exit criterion: THIS KERNEL CAN RUN A
# PROGRAM THAT NEVER YIELDS WITHOUT HANGING THE MACHINE.
#
# ===========================================================================
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ===========================================================================
# M11 ran two programs at CPL 3 in two address spaces with per-process FPU
# state, switched by a `yield` SYSCALL. Every switch in that milestone was one
# the running program asked for, and `docs/known-gaps.md` GAP-0085 said so:
# a process that never calls `yield` or `exit` cannot be stopped, and `user
# hold` spins forever with the machine held.
#
# The two programs on this harness's disk cannot ask for anything:
#
#   * progC MAKES NO SYSTEM CALLS AT ALL. `build-progs.sh` disassembles the
#     linked executable and requires the count of `int $0x80` to be EXACTLY
#     ZERO. Its whole body is `xorl %r15d,%r15d; 1: incq %r15; jmp 1b`.
#   * progD makes four kinds of syscall and `yield` is not one of them; the
#     same script requires that the immediate 3 never reaches RAX in either
#     program.
#
# So every context switch this harness observes is one the kernel performed
# against the program's will, from a timer interrupt, and the kernel counts
# those in a word (`procHeadPreempts`) that is NOT the one it counts yields in.
#
# ===========================================================================
# WHY THERE IS NO BYTE-EXACT GOLDEN HERE, AND WHAT REPLACES IT
# ===========================================================================
# M0 through M17 assert whole serial captures byte for byte. That is not
# available to a preemptive scheduler: which instruction a timer interrupt
# lands on is a property of the host, so the exact interleaving of two spinning
# programs is not reproducible and a golden over it would be a flake generator.
#
# What is asserted instead is arithmetic, and each one is falsifiable:
#
#   1. QUANTA == the budget typed at the shell, EXACTLY. The scheduler ends a
#      session at a stated number of quantum expiries, so the boot is
#      TICK-COUNT-DRIVEN and not wall-clock-driven. M1 solved the same problem
#      the same way.
#   2. SWITCHES == YIELDS + SURVIVING EXITS + PREEMPTS, over the whole session.
#      This is M11's identity with the term M18 added. `m11-proc/run.sh`
#      asserts the same equation, where the new term is zero.
#   3. YIELDS == 0 for both processes, and PREEMPTS > 0 for both, from the
#      kernel's own per-slot counters.
#   4. progD's XMM0 and XMM7 hold its own pattern in all four lanes AFTER three
#      involuntary switches, and its exit status is derived from its own ELF.
#   5. progC's saved R15 -- read out of the kernel's process table in guest
#      physical memory, at an address the kernel printed -- is large, and its
#      saved RIP is inside progC's own R+X segment with CS at ring 3.
#   6. THE NEGATIVE CONTROL: the same two programs under `proc coop` hang the
#      machine exactly as GAP-0085 describes. No exit, no budget, no end, and
#      QEMU's own registers show the CPU parked in progC at CPL 3.
#
# The M1 golden IS still asserted byte for byte, as a prefix, on both boots.
#
# Usage:  bash run.sh
# Exit:   0 = M18 pass, 1 = fail, 2 = setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M18-preempt: FAIL — $1" >&2
  exit 1
}
setup_error() {
  echo "M18-preempt: FAIL — $1" >&2
  exit 2
}

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

DERIVE="$SCRIPT_DIR/derive.py"
BUILD_PROGS="$SCRIPT_DIR/build-progs.sh"
MAKE_IMAGE="$SCRIPT_DIR/make-image.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
for f in "$DERIVE" "$BUILD_PROGS" "$MAKE_IMAGE" "$DRIVER" "$M1_EXPECTED"; do
  [[ -f "$f" ]] || setup_error "$f not found"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m18.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

dartconst() {
  awk -F'= *' -v n="$1" '$0 ~ ("^const int " n " =") { gsub(/;.*/,"",$2); print $2; exit }' \
    "$CORE_DIR/kernel/$2"
}

# ---------------------------------------------------------------------------
# Step 1 — build the kernel.
# ---------------------------------------------------------------------------
BUILD_LOG="$WORKDIR/build.log"
bash "$CORE_DIR/scripts/build-kernel.sh" >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
cat "$BUILD_LOG"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS (log above)"
KERNEL_ELF="$CORE_DIR/build/kernel.elf"
[[ -f "$KERNEL_ELF" ]] || fail "build-kernel.sh reported success but $KERNEL_ELF was not produced"

# ---------------------------------------------------------------------------
# Step 2 — build the two programs and the disk they live on.
# ---------------------------------------------------------------------------
bash "$BUILD_PROGS" "$WORKDIR" || fail "the test programs could not be built (see above)"
PROG_C="$WORKDIR/progC.elf"
PROG_D="$WORKDIR/progD.elf"

DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
python3 "$MAKE_IMAGE" "$DISK_IMG" "$PROG_C" "$PROG_D" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_C=$(lba_of C)
LBA_D=$(lba_of D)
IMG_BYTES=$(wc -c <"$DISK_IMG" | tr -d ' ')
echo "IMAGE: pass  $IMG_BYTES bytes = $(( IMG_BYTES / 512 )) sectors, 2 program slots (C at 0x$LBA_C, D at 0x$LBA_D), generated and re-read from disk"

# ---------------------------------------------------------------------------
# Step 3 — structural checks.
# ---------------------------------------------------------------------------

# 3a. THE QUANTUM AND THE POLICY ARE NAMED CONSTANTS, AND THEY ARE THE NUMBERS
#     derive.py USES.
QUANTUM=$(dartconst procQuantumTicks proc.dart)
POLICY_COOP=$(dartconst procPolicyCoop proc.dart)
POLICY_PREEMPT=$(dartconst procPolicyPreempt proc.dart)
[[ -n "$QUANTUM" ]] || fail "core/kernel/proc.dart has no \`const int procQuantumTicks\` — the quantum is a magic number somewhere instead of a named constant"
[[ "$QUANTUM" -ge 2 ]] || fail "procQuantumTicks is $QUANTUM. A quantum of 1 makes preemption a coin flip inside m11-proc's microsecond-long slices, and its 4096-byte golden would flake; see proc.dart's note on why it is 8."
[[ "$POLICY_COOP" == "0" && "$POLICY_PREEMPT" == "1" ]] \
  || fail "procPolicyCoop/procPolicyPreempt are $POLICY_COOP/$POLICY_PREEMPT, expected 0/1"
echo "STRUCTURAL: pass  the quantum is a named constant, procQuantumTicks = $QUANTUM PIT ticks (100 Hz -> $(( QUANTUM * 10 )) ms of ring-3 time)"

# 3b. EVERY SLOT WORD IN THE KERNEL IS A DIFFERENT WORD.
#
# THIS CHECK EXISTS BECAUSE M18's FIRST BUILD FAILED IT. `procSlotPreempts` was
# written as word 16, which is M12's `heapSlotBase`. Nothing crashed: the kernel
# booted, preempted correctly, and printed `N 10003001` for a preemption count
# -- the process's heap break, read back as a scheduler statistic. proc.dart's
# own comment says "slot words 0..31 are metadata" and does not say which of
# them are spoken for, and two files were assigning them independently.
python3 - "$CORE_DIR/kernel" <<'PY' || fail "two subsystems are using the same process-table slot word"
import os, re, sys
root = sys.argv[1]
seen = {}
fails = []
for fn in sorted(os.listdir(root)):
    if not fn.endswith(".dart"):
        continue
    src = open(os.path.join(root, fn)).read()
    for m in re.finditer(r"^const int (\w*Slot\w+) = (\d+);", src, re.M):
        name, val = m.group(1), int(m.group(2))
        # Only the ones that INDEX a slot word. `procSlotBytes`, `procSlotWords`
        # and `procSlotShift` are sizes, not indices, and are excluded by name.
        if name in ("procSlotBytes", "procSlotWords", "procSlotShift"):
            continue
        if val in seen and seen[val][0] != name:
            fails.append("slot word %d is both %s (%s) and %s (%s)"
                         % (val, seen[val][0], seen[val][1], name, fn))
        seen.setdefault(val, (name, fn))
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d distinct slot-word indices across the kernel: %s)"
      % (len(seen), ", ".join("%d=%s" % (v, seen[v][0]) for v in sorted(seen))))
PY
echo "STRUCTURAL: pass  no two subsystems index the same process-table slot word"

# 3b2. `procTick` TESTS THE INTERRUPTED PRIVILEGE LEVEL, AND THIS CHECK IS
#      SOURCE-LEVEL BECAUSE NO BOOT CAN CATCH ITS ABSENCE.
#
# THIS CHECK EXISTS BECAUSE A MUTATION SURVIVED. Deleting the ring-3 test --
# letting `procTick` preempt a tick that interrupted RING 0 -- changed NOTHING
# observable: every one of this harness's assertions still passed. The reason is
# the same measurement that makes the design defensible in the first place
# (ADR-0022 §3): every gate in this IDT is an INTERRUPT gate, so IF is clear for
# the whole of every kernel entry from ring 3, and a tick essentially never
# arrives at CPL 0 with a process live. `procHeadKernTicks` reads 1 on a real
# boot -- one tick, in `enter_user`'s three-instruction window before its `cli`.
#
# So the check that the decision is still in the source is the only check
# available, and it is worth having precisely because the behavioural evidence
# is absent. GAP-0143 says so out loud rather than leaving the impression that
# the boot proves it.
CS_TEST=$(grep -c 'userFrame(frame, u64(userFrameCs)) & u64(3)) < u64(3)' "$CORE_DIR/kernel/proc.dart")
[[ "$CS_TEST" -eq 1 ]] || fail "proc.dart tests the interrupted CS's privilege bits at $CS_TEST site(s) in procTick, expected exactly 1. Removing that test lets a tick that interrupted RING 0 switch processes — which would switch stacks out from under the kernel — and NO BOOT IN THIS HARNESS CAN SEE IT, because a tick almost never lands at CPL 0 with a process live (procHeadKernTicks reads 1). See GAP-0143."
echo "STRUCTURAL: pass  procTick tests the interrupted CS's privilege bits before it preempts anything — asserted from the source, because no boot can catch its absence"

# 3c. THE HEADER GREW BY EXACTLY SIX WORDS AND THE BLOCK BY EXACTLY 64 BYTES.
STORE_BYTES=$(dartconst procStoreBytes proc.dart)
HEAD_WORDS=$(dartconst procHeadWords proc.dart)
TABLE_OFF=$(dartconst procTableOffset proc.dart)
FX_OFF=$(dartconst procFxOffset proc.dart)
SLOT_BYTES=$(dartconst procSlotBytes proc.dart)
PROC_MAX=$(dartconst procMax proc.dart)
FX_BYTES=$(dartconst procFxBytes proc.dart)
[[ "$STORE_BYTES" == "4224" ]] || fail "procStoreBytes is $STORE_BYTES, expected 4224 — M11's 4160 plus 64 bytes for M18's eight new header words"
[[ "$HEAD_WORDS" == "16" ]] || fail "procHeadWords is $HEAD_WORDS, expected 16"
[[ $(( HEAD_WORDS * 8 )) -eq "$TABLE_OFF" ]] || fail "procHeadWords $HEAD_WORDS * 8 != procTableOffset $TABLE_OFF"
[[ $(( TABLE_OFF + PROC_MAX * SLOT_BYTES )) -eq "$FX_OFF" ]] || fail "the table does not end where the FXSAVE areas begin"
[[ $(( FX_OFF + PROC_MAX * FX_BYTES )) -eq "$STORE_BYTES" ]] || fail "the FXSAVE areas do not end where procStore does"
[[ $(( FX_OFF % 16 )) -eq 0 ]] || fail "procFxOffset $FX_OFF is not a multiple of 16 — fxsave would #GP"
BSS_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk '$4=="OBJECT" && $8=="procStore" {print $3; exit}')
[[ "$BSS_SIZE" == "$STORE_BYTES" ]] || fail "procStore is ${BSS_SIZE:-missing} bytes in kmain.o but procStoreBytes says $STORE_BYTES"
echo "STRUCTURAL: pass  procStore is $STORE_BYTES bytes: a ${TABLE_OFF}-byte header ($HEAD_WORDS words), $PROC_MAX x $SLOT_BYTES-byte slots, $PROC_MAX x $FX_BYTES-byte FXSAVE areas, and the FXSAVE base is 16-byte aligned inside it"

# 3d. THE STORAGE SEAM IS STILL EXACTLY THREE CALL SITES.
#
# M18 added six header words and two slot words and NO new storage block. That
# is the whole point of ADR-0022 §4: scheduler state is process-table state, and
# a second `@bss` symbol would have been a second thing the seam had to know
# about. `m11-proc/run.sh` asserts the same thing; it is repeated here because
# M18 is the milestone that was tempted.
SEAM_SITES=$(grep -c '^\s*return Bss[.]addressOf(procStore)' "$CORE_DIR/kernel/proc.dart")
[[ "$SEAM_SITES" -eq 3 ]] || fail "Bss.addressOf(procStore) is returned from $SEAM_SITES functions in proc.dart, expected exactly 3"
for f in "$CORE_DIR"/kernel/*.dart; do
  [[ "$(basename "$f")" == "proc.dart" ]] && continue
  grep -qw 'procStore' "$f" && fail "$(basename "$f") references procStore"
done
echo "STRUCTURAL: pass  M18 added no storage block: the seam is still 3 call sites in one file"

# 3e. EVERY @rodata TABLE M18 ADDED IS THE SIZE ITS CALL SITE PASSES (GAP-0060).
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M18 depends on was not emitted"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
}
check_table procStrPreempt 13
check_table procStrN 3
check_table procStrBudget 19
check_table procStrPreempts 10
check_table procStrSched 18
check_table procStrQuantum 9
check_table procStrQuanta 8
check_table procStrKticks 8
check_table procStrSlice 7
check_table procStrBudgetW 8
check_table procStrYields 8
check_table procStrHead 6
check_table procStrUsage2 79
check_table procCmdSpinSp 10
check_table procCmdCoopSp 10
check_table procCmdSched 10
echo "STRUCTURAL: pass  all 16 M18 message/command tables are exactly the sizes their call sites pass"

# 3f. shellStrHelp IS UNCHANGED, SO NOT ONE EARLIER GOLDEN MOVES.
#
# GAP-0105: `shellStrHelp` is inside the byte-exact goldens of m3, m4, m5, m6
# and m14, and its size is asserted by m4, m10, m11, m12, m13 and m15. M18 adds
# THREE shell commands and documents them on a SECOND usage table
# (`procStrUsage2`) reached from `proc` with a bad argument, precisely so that
# this number does not move. That is a real cost -- `help` does not mention
# `proc spin` -- and ADR-0022 §7 records it.
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk '$8=="shellStrHelp"{print $3; exit}')
[[ "$HELP_SIZE" -eq 2147 ]] || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2147 — UNCHANGED from M14. M18 adds three commands and no help line; if that changed, five byte-exact goldens move with it."
echo "STRUCTURAL: pass  shellStrHelp is 2147 bytes, unchanged — M18 moves no earlier golden"

# 3g. THE TIMER IS UNMASKED BY A PREEMPTIVE SESSION AND MASKED AGAIN ON EVERY
#     EXIT FROM ONE.
#
# The PIT has been masked at the PIC since M2 (GAP-0058: with IRQ0 masked the
# tick counter holds still, which is what lets `ticks` print a number m3-shell's
# golden asserts). A preemptive scheduler needs the tick, so it is turned on for
# the session and off again afterwards. A path that turned it on and did not
# turn it off would leave a 100 Hz interrupt running under every later command
# in the boot -- silently, because nothing prints.
UNMASK_SITES=$(grep -c 'picUnmaskTimerAndKeyboard();' "$CORE_DIR/kernel/proc.dart")
MASK_SITES=$(grep -c 'procSessionTimerOff();' "$CORE_DIR/kernel/proc.dart")
[[ "$UNMASK_SITES" -eq 1 ]] || fail "proc.dart unmasks the timer at $UNMASK_SITES sites, expected exactly 1 (shellProcRun, guarded by the policy)"
[[ "$MASK_SITES" -eq 5 ]] || fail "proc.dart calls procSessionTimerOff() at $MASK_SITES sites, expected exactly 5: shellProcRun's normal end, its two procCreate refusals, its cross-address refusal, and procOnFault's abandoned stack. EXACTLY, not at least: a mutation that deleted one and left four would otherwise pass, and the path it deleted would leave a 100 Hz interrupt running under every later command in the boot -- silently, because nothing prints."
echo "STRUCTURAL: pass  the timer is unmasked at exactly 1 site and re-masked at $MASK_SITES, one per exit from a session"

# 3h. verify-freestanding, and the extern count.
VERIFY_OUT=$( (cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o \
                                  && bash scripts/verify-freestanding.sh build/kdata.o \
                                  && bash scripts/verify-freestanding.sh build/kernel.elf) 2>&1 )
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
[[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed (output above)"
EXTERN_COUNT=$(sed -n 's/.*(\([0-9]*\) declared extern(s).*/\1/p' <<<"$VERIFY_OUT" | head -1)
[[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — UNCHANGED from M17. M18 is a scheduler, and a scheduler that needed a new assembly primitive would be a different design: the interrupt frame `isr_common` already builds is the whole context block."
echo "FREESTANDING: pass  $EXTERN_COUNT declared externs, unchanged from M17 — M18 added no assembly"

# ---------------------------------------------------------------------------
# Step 4 — the boots.
# ---------------------------------------------------------------------------
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5"
  shift 5
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port=$(( 47000 + ($$ % 8000) + portoff ))
  timeout 300 qemu-system-x86_64 \
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
  python3 "$DRIVER" \
    --port "$port" \
    --serial "$ser" \
    --wait-for 'M1 END\n' \
    --png "$png" \
    --screen-text "$outdir/screen.txt" \
    --keys "$keys" \
    "$@"
  local drive_status=$?
  wait "$qemu_pid" 2>/dev/null
  local qemu_status=$?
  if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot (log above)"
  fi
}

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

# THE BUDGET, IN QUANTA, AND IT IS THE ONE NUMBER THIS BOOT IS TIMED BY.
#
# 0x18 = 24 quantum expiries. At eight ticks each and 100 Hz that is 1.92
# seconds of ring-3 time -- long enough for progD to be preempted three times
# and finish, and then for progC to run ALONE for a dozen more quanta with
# nothing to switch to, which is the case that proves a LONE runaway is stopped
# too. The session ends at exactly 24 whatever the host is doing.
BUDGET_HEX=18
BUDGET=$((16#$BUDGET_HEX))

SPIN_KEYS="f,r,a,m,e,s,ret,wait:800"
SPIN_KEYS="$SPIN_KEYS,$(typekeys 'proc sched'),ret,wait:600"
SPIN_KEYS="$SPIN_KEYS,$(typekeys "proc spin $LBA_C $LBA_D $BUDGET_HEX"),ret,wait:6000"
SPIN_KEYS="$SPIN_KEYS,$(typekeys 'proc sched'),ret,wait:800"
SPIN_KEYS="$SPIN_KEYS,f,r,a,m,e,s,ret,wait:800"

SHOT_PNG="$CORE_DIR/build/screenshot-preempt.png"
rm -f "$SHOT_PNG"
drive_session "$WORKDIR/spin" "$SPIN_KEYS" "$SHOT_PNG" "spin" 90 \
  --addr-from-serial 'PROC SCHED .* HEAD ([0-9A-F]{16})' \
  --monitor-command "xp/$(( STORE_BYTES / 8 ))gx {addr}" \
  --monitor-command "info registers" \
  --monitor-capture "$WORKDIR/spin/monitor.txt"

SPIN_SERIAL="$WORKDIR/spin/serial.txt"

# BOOT B — THE NEGATIVE CONTROL. The same two programs, cooperatively.
COOP_KEYS="$(typekeys "proc coop $LBA_C $LBA_D"),ret,wait:4000"
drive_session "$WORKDIR/coop" "$COOP_KEYS" "$WORKDIR/coop/screen.png" "coop" 91 \
  --monitor-command "info registers" \
  --monitor-capture "$WORKDIR/coop/monitor.txt"
COOP_SERIAL="$WORKDIR/coop/serial.txt"

# ---------------------------------------------------------------------------
# Step 5 — the assertions.
# ---------------------------------------------------------------------------

# 5a. M1's 544-byte golden is a byte-exact prefix of BOTH boots.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
for b in "$SPIN_SERIAL" "$COOP_SERIAL"; do
  head -c "$M1_BYTES" "$b" | cmp -s - "$M1_EXPECTED" \
    || fail "the first $M1_BYTES bytes of $(dirname "$b" | xargs basename) do not match m1-interrupts/expected.txt — M18 changed M0/M1 serial output. procTick() must print NOTHING with no process live, and moving the EOI must not move a byte."
done
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is a byte-exact prefix of BOTH boots"

# 5b. EVERYTHING ELSE, in one place, against the two ELF files and derive.py.
python3 - "$SPIN_SERIAL" "$WORKDIR/spin/monitor.txt" "$DERIVE" "$PROG_C" "$PROG_D" \
          "$BUDGET" "$QUANTUM" "$CORE_DIR/kernel" "$SCRIPT_DIR" <<'PY' \
  || fail "the preemptive session does not match what the two ELF files and the kernel's own constants say should have happened"
import importlib.util, os, re, sys

ser = open(sys.argv[1], "rb").read().decode("latin-1")
mon = open(sys.argv[2], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("m18_derive", sys.argv[3])
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
c_elf = D.Elf(open(sys.argv[4], "rb").read())
d_elf = D.Elf(open(sys.argv[5], "rb").read())
budget = int(sys.argv[6])
quantum = int(sys.argv[7])
kernel_dir = sys.argv[8]
script_dir = sys.argv[9]
fails = []
notes = []

# -- derive.py's copies of the kernel's constants must BE the kernel's ----
proc_src = open(os.path.join(kernel_dir, "proc.dart")).read()
def dconst(name):
    m = re.search(r"^const int %s = (\w+);" % name, proc_src, re.M)
    if not m:
        raise SystemExit("core/kernel/proc.dart has no `const int %s`" % name)
    return int(m.group(1), 0)
for pyname, dartname in (("PROC_QUANTUM_TICKS", "procQuantumTicks"),
                         ("PROC_POLICY_COOP", "procPolicyCoop"),
                         ("PROC_POLICY_PREEMPT", "procPolicyPreempt"),
                         ("SLOT_PREEMPTS", "procSlotPreempts"),
                         ("SLOT_YIELDS", "procSlotYields"),
                         ("SLOT_SAVED", "procSlotSaved"),
                         ("HEAD_PREEMPTS", "procHeadPreempts"),
                         ("HEAD_QUANTA", "procHeadQuanta"),
                         ("HEAD_POLICY", "procHeadPolicy"),
                         ("HEAD_KERNTICKS", "procHeadKernTicks"),
                         ("HEAD_BUDGET", "procHeadBudget"),
                         ("HEAD_SWITCHES", "procHeadSwitches")):
    if getattr(D, pyname) != dconst(dartname):
        fails.append("derive.py's %s is %d but proc.dart's %s is %d"
                     % (pyname, getattr(D, pyname), dartname, dconst(dartname)))

# The five CPU-pushed words of the frame, derived from user.dart's byte offsets
# rather than from derive.py's word indices, so the two say the same thing.
user_src = open(os.path.join(kernel_dir, "user.dart")).read()
for pyname, dartname in (("FRAME_RAX", "userFrameRax"), ("FRAME_RIP", "userFrameRip"),
                         ("FRAME_CS", "userFrameCs"), ("FRAME_RFLAGS", "userFrameFlags"),
                         ("FRAME_RSP", "userFrameRsp"), ("FRAME_SS", "userFrameSs")):
    m = re.search(r"^const int %s = (\d+);" % dartname, user_src, re.M)
    if not m or int(m.group(1)) != getattr(D, pyname) * 8:
        fails.append("derive.py's %s is word %d (byte %d) but user.dart's %s is byte %s"
                     % (pyname, getattr(D, pyname), getattr(D, pyname) * 8, dartname,
                        m.group(1) if m else "missing"))

# progD's own numbers, out of progD.c, so the harness is not a second place to
# change the pattern or the spin count.
prog_src = open(os.path.join(script_dir, "progD.c")).read()
m = re.search(r"#define XMM_PATTERN_D 0x([0-9A-Fa-f]+)UL", prog_src)
if not m or int(m.group(1), 16) != D.XMM_PATTERN_D:
    fails.append("progD.c's XMM_PATTERN_D and derive.py's do not agree")
m = re.search(r"#define WANT_PREEMPTS (\d+)", prog_src)
if not m or int(m.group(1)) != D.WANT_PREEMPTS:
    fails.append("progD.c's WANT_PREEMPTS and derive.py's do not agree")
want_pre = D.WANT_PREEMPTS

# -- the session block ---------------------------------------------------
block = ser[ser.index("PROC RUN LBA"):] if "PROC RUN LBA" in ser else ""
if not block:
    raise SystemExit("the spin boot never started a session")

# 1. THE SWITCHES WERE INVOLUNTARY. Not one PROC YIELD line anywhere.
yields = re.findall(r"^PROC YIELD ", block, re.M)
if yields:
    fails.append("the session printed %d `PROC YIELD` line(s). Neither program on "
                 "this disk contains the instruction that produces one." % len(yields))
preempt_lines = re.findall(r"^PROC PREEMPT (\d\d) -> (\d\d) N (\w{8})$", block, re.M)
if len(preempt_lines) < 2 * want_pre:
    fails.append("the session printed %d `PROC PREEMPT` line(s); progD alone must be "
                 "preempted %d times and progC at least as often, so at least %d were "
                 "expected. A kernel that never preempts prints none of them and hangs."
                 % (len(preempt_lines), want_pre, 2 * want_pre))
# The per-slot N on each line must count up by one, per slot, with no gaps.
seen = {}
for cur, nxt, n in preempt_lines:
    seen[cur] = seen.get(cur, 0) + 1
    if int(n, 16) != seen[cur]:
        fails.append("a PROC PREEMPT line reports N=%s for slot %s, but it is that "
                     "slot's %d%s preemption" % (n, cur, seen[cur],
                                                 "st" if seen[cur] == 1 else "th"))
    if cur == nxt:
        fails.append("a PROC PREEMPT line switches slot %s to itself" % cur)

# 2. THE SESSION ENDED ON A TICK COUNT, NOT A CLOCK.
m = re.search(r"^PROC BUDGET QUANTA (\w{8}) PREEMPTS (\w{8})$", block, re.M)
if not m:
    fails.append("the session never printed `PROC BUDGET` -- the runaway backstop did "
                 "not fire, so either preemption or the budget is not working, and "
                 "progC would still be running")
    quanta = preempts = None
else:
    quanta, preempts = int(m.group(1), 16), int(m.group(2), 16)
    if quanta != budget:
        fails.append("the session ended after %d quantum expiries but the budget typed "
                     "at the shell was %d. The stop criterion must be the tick count "
                     "and nothing else." % (quanta, budget))
    if preempts != len(preempt_lines):
        fails.append("the kernel counted %d preemptions but printed %d PROC PREEMPT "
                     "lines" % (preempts, len(preempt_lines)))
    if preempts >= quanta:
        fails.append("every one of the %d quantum expiries produced a switch. After "
                     "progD exits there is only one runnable process and the expiries "
                     "must NOT switch -- that difference is what proves a lone runaway "
                     "is stopped too." % quanta)

# 3. M11's IDENTITY, WITH M18's TERM.
m = re.search(r"^PROC END SWITCHES (\w{8}) EXITS (\w{8}) CREATED (\w{8}) LIVE (\w{8})$",
              block, re.M)
if not m:
    fails.append("the session never printed `PROC END` -- it did not return to the shell")
else:
    switches, exits = int(m.group(1), 16), int(m.group(2), 16)
    # A `PROC EXIT ... LEFT n` with n > 0 is an exit that switched to a survivor.
    survivors = len([1 for left in re.findall(r"^PROC EXIT SLOT \d\d ID \w{8} CODE \w{16} LEFT (\w{8})$",
                                              block, re.M) if int(left, 16) > 0])
    want = len(yields) + survivors + len(preempt_lines)
    if switches != want:
        fails.append("the session reports %d switches; %d yields + %d surviving exits + "
                     "%d preemptions = %d. M11's identity with M18's term in it."
                     % (switches, len(yields), survivors, len(preempt_lines), want))
    if exits != 1:
        fails.append("%d process(es) exited, expected exactly 1 (progD). progC has no "
                     "`exit` instruction in it." % exits)

# 4. progD's OWN OUTPUT, DERIVED FROM ITS OWN ELF.
want_msg = D.expected_message(d_elf)
if ("USER WRITE " + want_msg) not in block:
    fails.append("progD never wrote the bytes of its own `msg` symbol (%r)" % want_msg)
want_line = D.expected_xmm_line(want_pre)
if ("USER WRITE " + want_line) not in block:
    got = re.search(r"^USER WRITE (D XMM .*)$", block, re.M)
    fails.append("progD reported %r; %r was derived from its own XMM pattern and the "
                 "number of involuntary switches it spun for. `OK` means both XMM0 and "
                 "XMM7 came back holding all four lanes of the pattern AFTER %d "
                 "preemptions; anything else means the FPU state did not survive a "
                 "switch the program did not ask for."
                 % (got.group(1) if got else None, want_line, want_pre))
want_code = D.expected_exit_status(d_elf)
m = re.search(r"^PROC EXIT SLOT \d\d ID \w{8} CODE (\w{16}) LEFT \w{8}$", block, re.M)
if not m:
    fails.append("progD never exited")
elif int(m.group(1), 16) != want_code:
    fails.append("progD exited with 0x%016X; 0x%016X is its .rodata word plus its "
                 ".data word plus the checksum of the 64 bytes its own compiler-emitted "
                 "movups moved. A difference of 16 means the `preempts` syscall did not "
                 "return the count it was spun on; 1 or 2 means an XMM register was lost."
                 % (int(m.group(1), 16), want_code))

# 5. THE SCHEDULER'S OWN REPORT, BEFORE AND AFTER.
scheds = re.findall(r"^PROC SCHED POLICY (\w{2}) QUANTUM (\w{2}) QUANTA (\w{8}) "
                    r"PREEMPTS (\w{8}) KTICKS (\w{8}) SLICE (\w{2}) BUDGET (\w{8}) "
                    r"HEAD (\w{16})$", ser, re.M)
if len(scheds) != 2:
    fails.append("expected two `proc sched` reports, got %d" % len(scheds))
else:
    before, after = scheds
    if int(before[0], 16) != D.PROC_POLICY_PREEMPT:
        fails.append("the scheduler's policy before any session is %s, expected %d "
                     "(preemptive). `procInit` states the default rather than leaving "
                     "it as whatever zero means." % (before[0], D.PROC_POLICY_PREEMPT))
    for label, s in (("before", before), ("after", after)):
        if int(s[1], 16) != quantum:
            fails.append("`proc sched` %s reports QUANTUM %s, but procQuantumTicks is %d"
                         % (label, s[1], quantum))
    if int(before[2], 16) != 0 or int(before[3], 16) != 0:
        fails.append("the scheduler reports %s quanta and %s preemptions BEFORE any "
                     "session ran" % (before[2], before[3]))
    if quanta is not None and int(after[2], 16) != quanta:
        fails.append("`proc sched` reports %s quanta after the session but PROC BUDGET "
                     "said %d" % (after[2], quanta))
    if int(after[4], 16) != 0:
        notes.append("KTICKS after the session is 0x%s: %d tick(s) arrived with a "
                     "process live and the interrupted CS at ring 0."
                     % (after[4], int(after[4], 16)))
    head_addr = int(after[7], 16)

# 6. THE PER-SLOT COUNTERS: ZERO YIELDS, NON-ZERO PREEMPTIONS, BOTH PROCESSES.
slots = dict((int(s, 16), (int(p, 16), int(y, 16), int(st, 16)))
             for s, p, y, st in re.findall(
                 r"^PROC SLOT (\d\d) PREEMPTS (\w{8}) YIELDS (\w{8}) STATE (\w{2})$",
                 ser, re.M)[-4:])
if len(slots) != 4:
    fails.append("`proc sched` printed %d slot lines, expected 4" % len(slots))
else:
    for s, label in ((0, "progC"), (1, "progD")):
        pre, yld, _ = slots[s]
        if yld != 0:
            fails.append("slot %d (%s) reports %d yields; its executable contains no "
                         "instruction that can produce one" % (s, label, yld))
        if pre < want_pre:
            fails.append("slot %d (%s) was preempted only %d time(s); at least %d was "
                         "expected" % (s, label, pre, want_pre))
    if slots[1][0] != want_pre:
        fails.append("slot 1 (progD) reports %d preemptions; it spins until the kernel "
                     "tells it %d and then exits, so any other number means the count "
                     "it read and the count the kernel kept are different things"
                     % (slots[1][0], want_pre))
    for s in (2, 3):
        if slots[s] != (0, 0, 0):
            fails.append("slot %d was never used but reports %r" % (s, slots[s]))

# 7. progC's SAVED REGISTERS, READ OUT OF THE KERNEL'S PROCESS TABLE IN GUEST RAM.
#
# Nothing below is a number this harness chose: `head_addr` is what the kernel
# printed, the dump was taken there, and the layout is proc.dart's own offsets.
if not fails:
    qwords = D.parse_xp(mon, "xp/%dgx 0x%016X" % (D.PROC_STORE_BYTES // 8, head_addr))
    mem = D.Memory().add(head_addr, qwords)
    table = D.ProcTable(mem, head_addr)

    if table.head_word(D.HEAD_QUANTA) != quanta:
        fails.append("the process table in RAM says %d quanta; the serial log said %d"
                     % (table.head_word(D.HEAD_QUANTA), quanta))
    if table.head_word(D.HEAD_POLICY) != D.PROC_POLICY_PREEMPT:
        fails.append("the process table's policy word is %d, not preemptive"
                     % table.head_word(D.HEAD_POLICY))
    if table.head_word(D.HEAD_BUDGET) != budget:
        fails.append("the process table's budget word is %d, not %d"
                     % (table.head_word(D.HEAD_BUDGET), budget))
    for i in (14, 15):
        if table.head_word(i) != 0:
            fails.append("header word %d is 0x%X; words 14 and 15 are unused and must "
                         "stay zero so a future field lands somewhere somebody chose"
                         % (i, table.head_word(i)))

    # A million iterations is a floor, not an estimate: progC's loop is two
    # instructions and it held the CPU for whole 80 ms quanta. A kernel that
    # scheduled it once and never again would show a small number here.
    m = re.search(r"movabsq \$(0x[0-9A-Fa-f]+), %rax", open(os.path.join(script_dir, "progC.c")).read())
    if not m:
        fails.append("progC.c no longer loads a constant into RAX -- the check that the "
                     "scheduler does not overwrite a preempted program's live RAX has "
                     "nothing to compare against, and the mutation it was written for "
                     "would survive again")
        want_rax = None
    else:
        want_rax = int(m.group(1), 16)
    f, info = D.check_saved_frame(table, 0, c_elf, "progC (slot 0)", 1000000,
                                  want_rax=want_rax)
    fails.extend(f)
    notes.append("progC's saved frame: R15 = %d iterations, RIP = 0x%X (inside its own "
                 "R+X segment), CS = 0x%X (ring 3), RSP = 0x%X"
                 % (info["r15"], info["rip"], info["cs"], info["rsp"]))

    # progD's slot holds the frame from ITS last preemption, and the same three
    # things must be true of it.
    f2, info2 = D.check_saved_frame(table, 1, d_elf, "progD (slot 1)", 0)
    fails.extend(f2)

    # THE SAVED RAX IS NOT PATCHED. `procYield` overwrites the saved RAX with 1
    # so a resumed process does not come back holding the syscall number;
    # `procTick` must NOT, because that word is a live register. progD's last
    # preemption happened inside its spin loop, where RAX holds the result of
    # the `preempts` syscall -- a value below WANT_PREEMPTS, and never 1 unless
    # WANT_PREEMPTS is 2.
    rax = table.frame_word(1, D.FRAME_RAX)
    if rax >= want_pre:
        fails.append("progD's saved RAX is %d. It was preempted inside a loop that "
                     "leaves as soon as the syscall returns %d or more, so a saved RAX "
                     "at or above that means the register was written by the switch "
                     "rather than by the program." % (rax, want_pre))
    notes.append("progD's saved RAX is %d -- the live register value at the instruction "
                 "the timer landed on, not a syscall return the scheduler wrote" % rax)

    regs = D.parse_registers(mon)
    if regs.get("CR4", 0) & 0x600 != 0x600:
        fails.append("CR4 is 0x%X: OSFXSR and OSXMMEXCPT are not both set"
                     % regs.get("CR4", 0))

if fails:
    print("the preemptive session is wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
for n in notes:
    print("    " + n)
print("    (%d involuntary switches, 0 yields, %d quantum expiries = the budget, "
      "progD's XMM pattern intact across %d of them, session ended by the scheduler)"
      % (len(preempt_lines), quanta, want_pre))
PY
echo "ASSERT: pass  TWO PROGRAMS NEITHER OF WHICH CAN YIELD ran to a scheduler-chosen end: every switch involuntary, the FPU intact across them, and the session stopped on a tick count"

# 5c. THE NEGATIVE CONTROL.
python3 - "$COOP_SERIAL" "$WORKDIR/coop/monitor.txt" "$DERIVE" "$PROG_C" <<'PY' \
  || fail "the cooperative negative control did not hang the way GAP-0085 says it must"
import importlib.util, re, sys
ser = open(sys.argv[1], "rb").read().decode("latin-1")
mon = open(sys.argv[2], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("m18_derive", sys.argv[3])
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
c_elf = D.Elf(open(sys.argv[4], "rb").read())
fails = []

if "PROC START SLOT 00" not in ser:
    raise SystemExit("the cooperative boot never started a process at all")

# The session must NOT finish. Every one of these lines is something the
# preemptive boot printed and this one must not.
for pat, what in ((r"^PROC PREEMPT ", "a preemption"),
                  (r"^PROC EXIT SLOT ", "a process exiting"),
                  (r"^PROC BUDGET ", "the runaway backstop firing"),
                  (r"^PROC END ", "the session ending")):
    if re.search(pat, ser, re.M):
        fails.append("the COOPERATIVE boot printed %s. `proc coop` must not preempt: "
                     "if it does, this is not a control, and m11-proc's hold boot -- "
                     "which parks a process at its entry point and walks two live "
                     "address spaces out of guest RAM -- has nothing to park with."
                     % what)

# progD never ran: progC was scheduled first and never yields, so the second
# process starves completely. That is the whole of GAP-0085 in one line.
if "USER WRITE PROC D" in ser:
    fails.append("progD produced output under cooperative scheduling. progC is entered "
                 "first and never yields, so progD can never reach the CPU.")

# And the machine really is parked inside progC, at CPL 3.
regs = D.parse_registers(mon)
if regs.get("CPL") != 3:
    fails.append("the CPU is at CPL %s, not 3 -- nothing was running in ring 3 when "
                 "the machine was inspected" % regs.get("CPL"))
rip = regs.get("RIP", 0)
text = c_elf.loads[0]
if not (text["vaddr"] <= rip < text["vaddr"] + text["memsz"]):
    fails.append("RIP is 0x%X, outside progC's R+X segment [0x%X, 0x%X) -- the machine "
                 "is held, but not by progC"
                 % (rip, text["vaddr"], text["vaddr"] + text["memsz"]))

if fails:
    print("the negative control is wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (no preemption, no exit, no budget, no end; CPU parked at CPL 3, RIP 0x%X "
      "inside progC's own text, progD never reached the CPU at all)" % rip)
PY
echo "ASSERT: pass  NEGATIVE CONTROL — the same two programs under \`proc coop\` hang the machine exactly as GAP-0085 describes, which is what makes the preemptive boot evidence"

# 5d. THE ALLOCATOR IS BACK WHERE IT STARTED.
#
# The budget teardown runs from inside the TIMER INTERRUPT and abandons that
# interrupt frame through `user_return`. If it freed less than it allocated, or
# freed something twice, this is where it shows.
FREE_FIRST=$(awk '/^PMM MANAGED /{print $5; exit}' "$SPIN_SERIAL")
FREE_LAST=$(awk '/^PMM MANAGED /{v=$5} END{print v}' "$SPIN_SERIAL")
[[ -n "$FREE_FIRST" && "$FREE_FIRST" == "$FREE_LAST" ]] \
  || fail "the allocator had $FREE_FIRST free frames before the session and $FREE_LAST after it — a session torn down from inside a timer interrupt leaked"
ERRORS_LAST=$(awk '/^PMM ALLOCS /{v=$5} END{print v}' "$SPIN_SERIAL")
[[ "$ERRORS_LAST" == "00000000" ]] || fail "the allocator reports $ERRORS_LAST free-errors after the session"
echo "ASSERT: pass  the allocator's free count is $FREE_FIRST before and after a session torn down from inside a timer interrupt (0 free-errors)"

# 5e. THE SHELL SURVIVED. It answered two commands after the runaway was stopped.
grep -q '^PROC SCHED POLICY' <<<"$(sed -n '/PROC END SWITCHES/,$p' "$SPIN_SERIAL")" \
  || fail "the shell never answered `proc sched` after the session ended — the machine did not come back"
grep -q '^PMM MANAGED' <<<"$(sed -n '/PROC END SWITCHES/,$p' "$SPIN_SERIAL")" \
  || fail "the shell never answered \`frames\` after the session ended"
echo "ASSERT: pass  the shell answered TWO commands after a program that never yields was stopped — the machine was not hung"

# 5f. The PNG.
[[ -s "$SHOT_PNG" ]] || fail "no PNG screenshot was written to $SHOT_PNG"
head -c 8 "$SHOT_PNG" | cmp -s - <(printf '\211PNG\r\n\032\n') || fail "$SHOT_PNG is not a PNG"
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

PREEMPTS_SEEN=$(grep -c '^PROC PREEMPT ' "$SPIN_SERIAL")
echo "M18-preempt: PASS — dcc build -> assemble -> link -> clang + x86_64-elf-ld build TWO freestanding static ELF64 programs NEITHER OF WHICH CONTAINS A \`yield\`, one of which contains NO SYSTEM CALL AT ALL -> make-image.py writes two program slots onto a disk -> 8 structural checks (the quantum a named constant at $QUANTUM ticks, no two subsystems sharing a process-table slot word, procStore 4160 -> 4224 with its three regions multiplied out and the FXSAVE base still 16-byte aligned, the storage seam STILL exactly 3 call sites and no new @bss block, 16 new @rodata tables against their call sites, shellStrHelp UNCHANGED at 2147 so no earlier golden moves, the timer unmasked at exactly one site and re-masked at every exit from a session) -> verify-freestanding pass ($EXTERN_COUNT declared externs, UNCHANGED — M18 added no assembly) -> TWO real QEMU boots, M1's 544-byte golden a byte-exact prefix of both. $PREEMPTS_SEEN INVOLUNTARY CONTEXT SWITCHES and ZERO yields; a program whose entire body is \`incq %r15; jmp .-3\` sharing the CPU with a program that reports on it; progD's XMM0 and XMM7 holding all four lanes of its own signature after THREE switches it never asked for, and exiting with a status derived from its own .rodata, its own .data and the checksum of the 64 bytes its own compiler-emitted movups moved; progC's saved R15, RIP and CS read out of the kernel's process table in guest physical memory at an address the kernel printed; the session ending at EXACTLY the $BUDGET quantum expiries typed at the shell rather than after any amount of wall clock; switches == yields + surviving exits + preemptions; the allocator's free count identical before and after a teardown performed from inside a timer interrupt; the shell answering two more commands afterwards; and the SAME TWO PROGRAMS under \`proc coop\` hanging the machine at CPL 3 inside progC with progD never once reaching the CPU. Screenshot at $SHOT_PNG"
exit 0
