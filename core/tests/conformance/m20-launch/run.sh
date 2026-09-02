#!/usr/bin/env bash
# core/tests/conformance/m20-launch/run.sh
#
# Mechanical check of M20's exit criterion (ADR-0034): ONE LAUNCH PATH, AND A
# PROGRAM THAT HAS BOTH ARGV AND A HEAP AT THE SAME TIME.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Before M20 this operating system had TWO ways to start a program and each was
# missing what the other had:
#
#   * `run <name> <args>` (M10/M14/M19) built a System V initial process stack
#     and entered ring 3 WITHOUT creating a process. `sbrk` is refused unless a
#     process is live — a heap's bookkeeping lives in a process slot — so a
#     program launched this way had **argv and no heap**, and `malloc` returned
#     NULL. m19-argv's own prog.c says so in its header: "NO malloc ANYWHERE".
#
#   * `proc run <lbaA> <lbaB>` (M11) created processes with address spaces and
#     heaps, and entered them with RSP at the top of an EMPTY page. Those
#     programs had **a heap and no argv**. m13-libc, the malloc harness, is
#     launched this way and names its programs by LBA.
#
# So no program could have both, which is the first thing a real C program
# needs. ADR-0034 deletes the M10 launch and routes `run` through `procCreate`,
# which now also builds the argv stack.
#
#   * THE TWO HALVES ARE TESTED THROUGH EACH OTHER, NOT SIDE BY SIDE. prog.c's
#     read buffer is `malloc`ed, and it is the buffer every byte of the file is
#     counted through. The file's NAME comes in on argv. So the counts below
#     are unobtainable unless BOTH halves worked, and a kernel with either half
#     missing cannot fake them: with no heap the program prints `WC HEAP FAIL`
#     and exits 5; with no argv it has no file to open.
#
#   * THE COUNTS ARE COMPUTED ON THE HOST from the volume this harness wrote
#     (derive.py), never read back from the machine under test.
#
#   * A NEGATIVE CONTROL FOR ARGV. WCN.ELF is a second build of the same source
#     that IGNORES argv and counts a compiled-in name. Given BETA.TXT it must
#     print ALPHA.TXT's counts and a different exit status — the control that
#     fails if argv is merely present rather than actually used. It still
#     mallocs, so it also proves the heap is not a property of one binary.
#
#   * THE LAUNCH IS PROVEN TO BE PROCESS-BACKED, STRUCTURALLY AND AT RUNTIME:
#     elf.dart no longer contains an `enter_user` call at all, and the boot
#     prints `PROC NEW`/`PROC EXIT` for a plain `run`.
#
#   * THE FRAME ALLOCATOR RETURNS EXACTLY TO BASELINE across the session, so
#     the new launch path leaks nothing.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * It does not re-assert the ABI shape of the initial stack byte by byte.
#     m19-argv reads the stack out of guest physical memory with QEMU's own
#     monitor and checks it against the System V ABI; that check is unchanged
#     and still runs. This harness asserts that the stack and the heap COEXIST.
#   * `proc run` still passes no arguments — it names programs by LBA and has
#     no argv to give. It now gets a complete but EMPTY vector (argc 0 and the
#     three terminators) rather than a bare stack pointer. GAP-0209.
#   * There is still no `envp` (GAP-0146) and no auxv beyond AT_NULL
#     (GAP-0147).
#
# Exit status: 0 on success, 1 on a failed assertion, 2 on harness/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() { echo "M20-launch: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M20-launch: FAIL — $1" >&2; exit 2; }

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m20.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PROGDIR="$WORK/progs"
mkdir -p "$PROGDIR"
DISK_IMG="$PROGDIR/disk.img"

# ---------------------------------------------------------------------------
# Step 1 — build the kernel and prove it is freestanding (CLAUDE.md rule 1).
# ---------------------------------------------------------------------------
bash "$CORE_DIR/scripts/build-kernel.sh" >"$WORK/build.log" 2>&1 \
  || { cat "$WORK/build.log" >&2; fail "build-kernel.sh failed"; }
echo "    (kernel built: $KERNEL_ELF)"

( cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kernel.elf ) \
  >"$WORK/free.log" 2>&1 || { cat "$WORK/free.log" >&2; fail "verify-freestanding.sh rejected the kernel"; }
echo "ASSERT: pass  verify-freestanding.sh accepts the kernel object"

# ---------------------------------------------------------------------------
# Step 2 — STRUCTURAL: there is ONE launch path, checked in the source.
#
# These cost no boot and they are the checks that would catch the M10 path
# growing back. `enter_user` is the instruction sequence that puts the CPU in
# ring 3; after ADR-0034 the only file that may call it is proc.dart.
# ---------------------------------------------------------------------------
ELF_ENTER=$(grep -c '^\s*enter_user(' "$CORE_DIR/kernel/elf.dart" || true)
[[ "$ELF_ENTER" -eq 0 ]] || fail "elf.dart calls enter_user() $ELF_ENTER time(s), expected 0 — the M10 launch path is back, and a program launched through it has no process slot and therefore no heap (ADR-0034)"
echo "ASSERT: pass  elf.dart contains no enter_user() call — the M10 launch path is gone"

ELF_PROCCREATE=$(grep -c 'procCreate(' "$CORE_DIR/kernel/elf.dart" || true)
[[ "$ELF_PROCCREATE" -ge 1 ]] || fail "elf.dart never calls procCreate() — \`run\` is not process-backed"
echo "ASSERT: pass  elf.dart launches through procCreate()"

ARGS_BUILD=$(grep -c 'argsBuild(' "$CORE_DIR/kernel/proc.dart" || true)
[[ "$ARGS_BUILD" -eq 1 ]] || fail "proc.dart calls argsBuild() $ARGS_BUILD time(s), expected exactly 1 (in procCreate). Two would mean the initial stack is built in two places again"
echo "ASSERT: pass  proc.dart builds the initial process stack in exactly one place"

# Every process, however it was created, gets its RSP from the built stack
# rather than from the top of the page.
grep -q 'procSet(s, u64(procSlotRsp), rsp);' "$CORE_DIR/kernel/proc.dart" \
  || fail "procCreate does not set procSlotRsp from argsBuild's result — processes would start on a bare stack again"
grep -q 'procSet(s, u64(procSlotRsp), u64(vmProgStackTop));' "$CORE_DIR/kernel/proc.dart" \
  && fail "procCreate still sets procSlotRsp to vmProgStackTop — the empty-stack entry is back"
echo "ASSERT: pass  a process's RSP comes from the built argv stack, not from vmProgStackTop"

# ---------------------------------------------------------------------------
# Step 3 — build the two programs and the volume.
# ---------------------------------------------------------------------------
bash "$SCRIPT_DIR/build-progs.sh" "$PROGDIR" >"$WORK/progs.log" 2>&1 \
  || { cat "$WORK/progs.log" >&2; fail "build-progs.sh failed"; }
echo "    (built wc.elf and wcn.elf against core/user/libc, malloc.c included)"

python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/wc.elf" "$PROGDIR/wcn.elf" --json \
  > "$WORK/layout.json" || fail "make-image.py could not write the volume"
[[ -s "$DISK_IMG" ]] || fail "make-image.py produced no image"

# THE PROGRAM ACTUALLY LINKS malloc. Without this the heap half of this harness
# could pass by never being exercised.
x86_64-elf-nm "$PROGDIR/wc.elf" | grep -qE ' [Tt] malloc$' \
  || fail "wc.elf has no \`malloc\` — the heap half of this test is not in the binary"
echo "ASSERT: pass  wc.elf links core/user/libc/malloc.c"

# ---------------------------------------------------------------------------
# Step 4 — every number this harness expects, computed on the host.
# ---------------------------------------------------------------------------
DERIVED="$WORK/derived.txt"
python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG" "$PROGDIR/wc.elf" "$PROGDIR/wcn.elf" \
  "$CORE_DIR/kernel" "$CORE_DIR/user/libc" "$SCRIPT_DIR/prog.c" > "$DERIVED" \
  || fail "derive.py could not compute the expected numbers"
d() { grep -E "^$1=" "$DERIVED" | head -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# Step 5 — the boots.
# ---------------------------------------------------------------------------
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" label="$3"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local attempt=0 port drive_status qemu_status qemu_pid
  while :; do
    attempt=$(( attempt + 1 ))
    # GAP-0150: ask the HOST for a free port rather than deriving one, and
    # retry if QEMU still loses the race. Never a hardcoded port: several of
    # these harnesses run at once.
    port=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
    : >"$ser"
    timeout 420 qemu-system-x86_64 \
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
    qemu_pid=$!
    python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --png "$outdir/shot.png" \
      --screen-text "$outdir/screen.txt" \
      --keys "$keys"
    drive_status=$?
    wait "$qemu_pid" 2>/dev/null
    qemu_status=$?
    if [[ $drive_status -ne 0 ]] && grep -q "Address already in use" "$outdir/qemu.log" \
       && [[ $attempt -lt 5 ]]; then
      echo "    (port $port was taken between the probe and the launch; retrying — attempt $attempt)"
      continue
    fi
    break
  done
  if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot"
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot"
  fi
}

# ---- Boot 1: the real build, told which file to count. ----
S1="$WORK/session"
KEYS1="f,r,a,m,e,s,ret,wait:800"
KEYS1="$KEYS1,$(typekeys "run wc.elf alpha.txt"),ret,wait:25000"
KEYS1="$KEYS1,f,r,a,m,e,s,ret,wait:1500"
drive_session "$S1" "$KEYS1" "session"
SER1="$S1/serial.txt"

# The launch is process-backed. Without these lines `run` did not create a
# process, and a program without a process slot cannot have a heap.
grep -q '^PROC NEW SLOT 00 ' "$SER1" \
  || fail "a plain \`run\` did not print \`PROC NEW\` — the launch is not process-backed, so the program has no heap"
grep -q '^PROC EXIT SLOT 00 ' "$SER1" \
  || fail "a plain \`run\` did not leave through the process exit path"
echo "ASSERT: pass  \`run wc.elf alpha.txt\` creates and tears down a PROCESS"

# THE ARGV HALF.
grep -q 'WC ARGC 2 ' "$SER1" || fail "the program did not see argc 2 (serial: $SER1)"
grep -q 'WC ARGV 0 .* wc\.elf$' "$SER1" || fail "argv[0] is not \`wc.elf\`"
grep -q 'WC ARGV 1 .* alpha\.txt$' "$SER1" || fail "argv[1] is not \`alpha.txt\`"
grep -q 'WC TERM 0 0$' "$SER1" || fail "argv[argc] and envp[0] are not both NULL"
echo "ASSERT: pass  the program read its argv: argc 2, argv[0] wc.elf, argv[1] alpha.txt, both terminators NULL"

# THE HEAP HALF.
grep -q 'WC HEAP FAIL' "$SER1" \
  && fail "malloc returned NULL — \`sbrk\` was refused, so the launch still gives argv without a heap (this is the M20 defect)"
HEAPLINE=$(grep -o 'WC HEAP PTR [0-9a-f]* BAD [0-9]* REUSE [0-9]* KERNB [0-9a-f]* BLOCKS [0-9]*' "$SER1" | head -1)
[[ -n "$HEAPLINE" ]] || fail "the program printed no \`WC HEAP\` line at all"
echo "    ($HEAPLINE)"
echo "$HEAPLINE" | grep -q ' BAD 0 ' \
  || fail "the heap buffer did not read back what was written to it: $HEAPLINE"
echo "$HEAPLINE" | grep -q ' REUSE 1 ' \
  || fail "free() + malloc() did not return the same address — the allocator is not reusing memory: $HEAPLINE"
grep -q '^PROC HEAP 00 INC ' "$SER1" \
  || fail "the kernel never serviced an \`sbrk\` for this process"
echo "ASSERT: pass  the program malloc'ed, every byte read back, and free()+malloc() reused the block"

# THE TWO HALVES THROUGH EACH OTHER: the counts came from the argv-named file,
# read through the malloc'ed buffer, and match the host's own count.
grep -q "WC $(d alpha_lines) $(d alpha_words) $(d alpha_chars) alpha\.txt$" "$SER1" \
  || fail "the counts for alpha.txt are not $(d alpha_lines)/$(d alpha_words)/$(d alpha_chars) — the file named on argv was not counted through the heap buffer"
grep -q "WC MODE 0 FILES 1 STATUS $(d alpha_status)$" "$SER1" \
  || fail "the derived exit status is not $(d alpha_status)"
grep -q "^PROC EXIT SLOT 00 ID 00000001 CODE 00000000000000$(echo "$(d alpha_status)" | tr 'a-f' 'A-F')" "$SER1" \
  || fail "the process did not exit with the status its own counts imply"
echo "ASSERT: pass  $(d alpha_lines)/$(d alpha_words)/$(d alpha_chars) for the argv-named file, counted through malloc'ed memory, exit status $(d alpha_status)"

# The frame allocator is exactly where it started.
FREE_BEFORE=$(grep -m1 -o 'FREE [0-9A-F]\{8\}' "$SER1" | head -1 | awk '{print $2}')
FREE_AFTER=$(grep -o 'FREE [0-9A-F]\{8\}' "$SER1" | tail -1 | awk '{print $2}')
[[ -n "$FREE_BEFORE" && "$FREE_BEFORE" == "$FREE_AFTER" ]] \
  || fail "the free-frame count moved across the session: $FREE_BEFORE -> $FREE_AFTER — the unified launch path leaks frames"
echo "ASSERT: pass  free frames identical before and after the session ($FREE_BEFORE)"

# ---- Boot 2: the negative control for argv. ----
S2="$WORK/neg"
KEYS2="$(typekeys "run wcn.elf beta.txt"),ret,wait:25000"
drive_session "$S2" "$KEYS2" "negative-control"
SER2="$S2/serial.txt"

grep -q 'WC ARGV 1 .* beta\.txt$' "$SER2" \
  || fail "the control was not handed beta.txt on argv"
grep -q "WC $(d neg_lines) .* beta\.txt$" "$SER2" \
  || fail "the control did not print $(d neg_file)'s counts for beta.txt — it is not ignoring argv, so it is not a control"
[[ "$(d neg_status)" != "$(d beta_status)" ]] \
  || setup_error "the control's status equals the real one; the control cannot distinguish anything"
echo "ASSERT: pass  the control ignores argv, prints $(d neg_file)'s counts for beta.txt, and exits differently"

# The control still gets a heap — the heap is a property of the LAUNCH, not of
# one binary.
grep -q 'WC HEAP FAIL' "$SER2" && fail "the control's malloc failed"
grep -q 'WC HEAP PTR ' "$SER2" || fail "the control printed no heap line"
echo "ASSERT: pass  the control also has a working heap — the heap comes from the launch path, not from the binary"

echo "M20-launch: PASS — one launch path (elf.dart has no enter_user; \`run\` goes through procCreate, which builds the argv stack in exactly one place) -> verify-freestanding -> TWO real QEMU boots. A C program written as \`int main(int argc, char **argv)\` was told which file to count by the shell AND read every byte of it through a \`malloc\`ed buffer: argc 2, argv[0] wc.elf, argv[1] alpha.txt, both ABI terminators NULL, heap buffer read back byte-for-byte (BAD 0), free()+malloc() reusing the same address (REUSE 1), $(d alpha_lines)/$(d alpha_words)/$(d alpha_chars) counted on the host and matched, exit status $(d alpha_status) derived from those counts; a control build ignoring argv printed $(d neg_file)'s counts for beta.txt and exited differently while still getting a heap; and the free-frame count returned exactly to baseline."
