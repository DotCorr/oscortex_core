#!/usr/bin/env bash
# core/tests/conformance/m19-argv/run.sh
#
# Mechanical check of ROADMAP.md's M19 exit criterion: A C PROGRAM WRITTEN AS
# `int main(int argc, char **argv)` RUNS ON THIS OPERATING SYSTEM, IS TOLD WHICH
# FILE TO OPEN BY THE SHELL, AND THE SAME BINARY GIVEN DIFFERENT ARGUMENTS
# PRODUCES DIFFERENT DERIVED ANSWERS.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Every program on this machine before M19 entered at `_start` with an empty
# stack and nothing on it (GAP-0113's last item, GAP-0122 item 8), so every test
# program had its inputs COMPILED INTO IT: m15-fileio's has the string
# `"DATA.BIN"` in its own `.rodata`. M19 adds `core/kernel/args.dart`, which
# builds the System V x86-64 initial process stack in the program's own address
# space, and `core/user/libc/start.c`, which unpacks it and calls `main`.
#
#   * THE SAME BINARY, TWO DIFFERENT ARGUMENTS, TWO DIFFERENT ANSWERS. One boot
#     runs `run WC.ELF ALPHA.TXT` and `run WC.ELF BETA.TXT`. The two files
#     differ in ALL THREE of lines, words and bytes -- make-image.py refuses to
#     write a volume where any column agrees -- and derive.py counts both on the
#     host. A kernel that passed a plausible but constant argv would produce one
#     of these answers twice.
#
#   * argv[0] IS THE PROGRAM'S OWN NAME and argc IS WHAT THE SHELL WAS GIVEN.
#     Checked in the transcript AND, separately, in memory.
#
#   * THE STACK IS READ OUT OF GUEST PHYSICAL MEMORY AND CHECKED AGAINST THE
#     ABI. `check-stack.py` takes QEMU's own `xp` dump of the stack frame -- at
#     the physical address the kernel printed -- and requires: RSP 16-byte
#     aligned; argc at RSP; argc pointers, each inside the program's own mapped
#     user-readable page, strictly increasing, each naming the exact bytes the
#     harness typed; a NULL after them; a NULL envp; an AT_NULL auxv; and every
#     padding byte zero. IT NEVER LOOKS AT WHAT THE PROGRAM SAID ABOUT ITSELF.
#     A program is not a witness to its own stack.
#
#   * A NEGATIVE CONTROL THAT IS PRE-M19 BEHAVIOUR. WCN.ELF is a second build of
#     the same source that IGNORES argv and counts a compiled-in file name. Given
#     `BETA.TXT` it prints ALPHA.TXT's counts and a different exit status, both
#     of which derive.py predicts. This is the control that fails if argv is
#     merely present rather than actually used.
#
#   * TWO REFUSALS, AND THE SHELL SURVIVES BOTH. Nine arguments and 129 bytes of
#     argument text are refused by name, before a frame is allocated, and the
#     shell answers the next command.
#
#   * THE FRAME ALLOCATOR RETURNS EXACTLY TO BASELINE. `frames` brackets a
#     session that ran three programs with arguments; the free count must be
#     identical to the frame.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * THERE IS NO `envp`. The kernel writes a NULL there and there is no
#     environment, no `getenv`, no `setenv` and no `environ`. GAP-0146, and
#     check-stack.py asserts the NULL rather than assuming it.
#   * THERE IS NO AUXILIARY VECTOR beyond its AT_NULL terminator: no AT_PHDR,
#     no AT_PAGESZ, no AT_RANDOM, no AT_ENTRY. GAP-0147.
#   * THE SHELL HAS NO QUOTING, no escapes, no globbing and no redirection. A
#     run of spaces is one separator and that is the whole grammar. GAP-0145.
#   * `proc run` PASSES NO ARGUMENTS. It takes an LBA and enters ring 3 with RSP
#     at the top of an empty page, exactly as before M19, so m11-proc's and
#     m18-preempt's goldens do not move. GAP-0149 says what that costs.
#   * NOTHING HERE IS CONCURRENT and nothing here writes to the volume.
#
# Usage:
#   core/tests/conformance/m19-argv/run.sh
#   ... --regen    rewrite the goldens from this boot (every derived check below
#                  still has to pass, so a wrong kernel cannot enshrine itself)
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "M19-argv: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M19-argv: FAIL — $1" >&2; exit 2; }

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths. Resolved to a real path
# here for the same reason m14-fat and m15-fileio do it.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m19.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
[[ -f "$M1_EXPECTED" ]] || setup_error "m1-interrupts/expected.txt not found"
[[ -d "$LIBC_DIR" ]] || setup_error "no C library at $LIBC_DIR"

# ---------------------------------------------------------------------------
# Step 1 — build the kernel.
# ---------------------------------------------------------------------------
BUILD_OUT="$(bash "$CORE_DIR/scripts/build-kernel.sh" 2>&1)"
BUILD_STATUS=$?
echo "$BUILD_OUT"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
[[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

# ---------------------------------------------------------------------------
# Step 2 — structural checks. Everything that can be established without
# booting is established without booting.
# ---------------------------------------------------------------------------

# 2a. THE .bss ACCOUNTING, AND WHY M19's BLOCK IS THE LAST ONE.
#
# `argsStore` is 256 bytes of DCDart `@bss` and it is declared in `args.dart`,
# which kmain.dart lists LAST. That is not a filing preference: every harness
# from M2 onward measures "the donated bytes from MY block to the end of .bss",
# and a new block anywhere other than the end would change every one of those
# numbers at once. At the end, each older harness subtracts this one first and
# its own number keeps meaning in 2026 what it meant when it was written --
# exactly what M14, M15 and M16 each did in turn.
#
# So the total is 14112 + 256 = 14368: 9728 through M13 plus M18's scheduler
# header, plus fat_store's 1824, plus file_store's 2560, plus args_store's 256.
bssfield() {   # bssfield <readelf column> <symbol> -- kmain.o first, then kdata.o
  local f="$1" n="$2" o v
  for o in kmain.o kdata.o; do
    v=$(x86_64-elf-readelf -sW "$CORE_DIR/build/$o" \
          | awk -v s="$n" -v f="$f" '$4=="OBJECT" && $8==s {print $f; exit}')
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  done
  return 1
}
bsssize() { bssfield 3 "$1"; }
bssoff()  { bssfield 2 "$1"; }

DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section — the four assembly-written words are gone"
ASM_BSS=$((16#$ASM_BSS_HEX))
[[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o still donates $ASM_BSS bytes of .bss, expected exactly 96 — cpu_info (64) plus the four resume words. Anything else in there is storage that ADR-0021 says should be a @bss mutable static in the subsystem that owns it."
KDATA_BSS=$(( DART_BSS + ASM_BSS ))
[[ "$KDATA_BSS" -eq 14368 ]] || fail "the kernel's mutable static storage is $KDATA_BSS bytes, expected 14368 — 14112 through M18 plus args_store's 256. If that changed, it changed deliberately and this number, docs/known-gaps.md GAP-0053's running total, and every harness that subtracts a later milestone's block all move with it."

ARGS_STORE_SIZE=$(bsssize argsStore)
[[ "$ARGS_STORE_SIZE" == "256" ]] || fail "argsStore is ${ARGS_STORE_SIZE:-missing} bytes, expected 256"
ARGS_OFF=$(bssoff argsStore)
[[ -n "$ARGS_OFF" ]] || fail "argsStore has no .bss offset in kmain.o"
[[ $(( 16#$ARGS_OFF + ARGS_STORE_SIZE )) -eq "$DART_BSS" ]] \
  || fail "argsStore ends at $(( 16#$ARGS_OFF + ARGS_STORE_SIZE )) and kmain.o's .bss is $DART_BSS bytes — M19's block is NOT the last one, so every earlier harness's 'bytes from my block to the end' number has silently moved"
[[ $(( KDATA_BSS - ARGS_STORE_SIZE )) -eq 14112 ]] \
  || fail "the .bss outside args_store is $(( KDATA_BSS - ARGS_STORE_SIZE )), not M18's 14112 — M19 moved storage it does not own"

# The three regions inside the block, multiplied out against the block's own
# size. A region that ran past the end would corrupt whatever follows it in
# `.bss` and would do it silently: `.bss` is not zeroed and nothing guards it.
A_META_OFF=$(dartconst argsMetaOffset args.dart)
A_OFF_OFF=$(dartconst argsOffOffset args.dart)
A_TEXT_OFF=$(dartconst argsTextOffset args.dart)
A_STORE=$(dartconst argsStoreBytes args.dart)
A_META_WORDS=$(dartconst argsMetaWords args.dart)
A_MAX_COUNT=$(dartconst argsMaxCount args.dart)
A_MAX_BYTES=$(dartconst argsMaxBytes args.dart)
A_MIN_STACK=$(dartconst argsMinStack args.dart)
[[ "$A_STORE" -eq "$ARGS_STORE_SIZE" ]] || fail "args.dart says argsStoreBytes=$A_STORE and the image has $ARGS_STORE_SIZE"
[[ "$A_META_OFF" -eq 0 ]] || fail "argsMetaOffset is $A_META_OFF, expected 0"
[[ $(( A_META_OFF + A_META_WORDS * 8 )) -eq "$A_OFF_OFF" ]] \
  || fail "the $A_META_WORDS metadata words at $A_META_OFF do not end where the offset array begins ($A_OFF_OFF)"
[[ $(( A_OFF_OFF + A_MAX_COUNT * 8 )) -eq "$A_TEXT_OFF" ]] \
  || fail "the $A_MAX_COUNT offsets at $A_OFF_OFF do not end where the text begins ($A_TEXT_OFF)"
[[ $(( A_TEXT_OFF + A_MAX_BYTES )) -eq "$A_STORE" ]] \
  || fail "the $A_MAX_BYTES bytes of text at $A_TEXT_OFF do not end at the block's end ($A_STORE)"
echo "STRUCTURAL: pass  the kernel's mutable statics are 14368 bytes, 256 of them argsStore and argsStore is the LAST block in .bss: $A_META_WORDS metadata words at $A_META_OFF, $A_MAX_COUNT offsets at $A_OFF_OFF, $A_MAX_BYTES bytes of argument text at $A_TEXT_OFF, ending exactly at $A_STORE"

# 2b. THE STORAGE SEAM: ONE ACCESSOR PER REGION, THREE CALL SITES, ONE FILE.
SEAM=$(grep -cE "^  return Bss[.]addressOf[(]argsStore[)]" "$CORE_DIR/kernel/args.dart")
[[ "$SEAM" -eq 3 ]] || fail "args.dart has $SEAM \`return Bss.addressOf(argsStore)\` call sites, expected exactly 3 (ADR-0011 §0's seam discipline)"
OUTSIDE=$(grep -rlw "argsStore" "$CORE_DIR/kernel/" | grep -v "/args.dart$" | wc -l | tr -d ' ')
[[ "$OUTSIDE" -eq 0 ]] || fail "$OUTSIDE file(s) outside args.dart name argsStore"
echo "STRUCTURAL: pass  argsStore is reached through exactly 3 accessors in one file and is named nowhere else in core/kernel/"

# 2c. THE @rodata TABLES, EACH AGAINST ITS OWN CALL SITE.
#
# GAP-0060: a table and the length its `uartWrite` passes are two numbers, and
# a table that grew without its call site growing prints the next table's bytes.
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ -n "$got" ]] || fail "$sym not found in kmain.o"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
  grep -q "uartWrite(Rodata.addressOf($sym), u64($want));" "$CORE_DIR/kernel/args.dart" \
    || fail "no call site in args.dart passes u64($want) for $sym"
}
check_table argsStrArgs 11
check_table argsStrBytes 7
check_table argsStrVec 5
check_table argsStrStr 5
check_table argsStrArg 8
check_table argsStrAt 4
check_table argsStrSp 1
check_table argsStrE01 81
check_table argsStrE02 77
check_table argsStrE03 69
check_table argsStrE04 76
echo "STRUCTURAL: pass  all 11 of M19's @rodata tables are exactly the sizes their call sites pass"

# 2d. THE REFUSALS ARE DISTINCT VALUES WITH DISTINCT SENTENCES.
#
# M18's finding, applied here: an assertion a WRONG value still satisfies is
# worthless, so the values are required to be distinct and so are the messages.
# Two refusals that printed the same sentence would be one refusal wearing two
# names, and a boot could not tell which one it got.
python3 - "$CORE_DIR/kernel/args.dart" <<'PY' || fail "args.dart's refusal codes or their sentences are not distinct"
import re, sys
src = open(sys.argv[1]).read()
codes = dict(re.findall(r"^const int (argsErr[A-Za-z]+) = (\d+);", src, re.M))
if len(codes) < 5:
    print("    - fewer than five argsErr* constants", file=sys.stderr); sys.exit(1)
vals = [int(v) for v in codes.values()]
if len(set(vals)) != len(vals):
    print("    - duplicate refusal values: %r" % codes, file=sys.stderr); sys.exit(1)
# The four sentences, as byte tables, must differ from each other.
tables = {}
for m in re.finditer(r"final List<u8> (argsStrE\d+) = const \[(.*?)\];", src, re.S):
    body = bytes(int(x, 16) for x in re.findall(r"u8\(0x([0-9A-Fa-f]{2})\)", m.group(2)))
    tables[m.group(1)] = body
if len(tables) != 4:
    print("    - %d refusal sentences, expected 4" % len(tables), file=sys.stderr); sys.exit(1)
if len(set(tables.values())) != 4:
    print("    - two refusal sentences are the same bytes", file=sys.stderr); sys.exit(1)
for n, b in tables.items():
    if not b.endswith(b"\n"):
        print("    - %s does not end in a newline" % n, file=sys.stderr); sys.exit(1)
    if not b.startswith(b"run: "):
        print("    - %s does not begin `run: `" % n, file=sys.stderr); sys.exit(1)
PY
echo "STRUCTURAL: pass  five distinct refusal values and four distinct sentences, every one of them a complete \`run: \` line"

# 2e. THE ENTRY PATH USES THE COMPUTED RSP AND NOT THE STACK TOP.
#
# This is the mutation that would pass everything else: `enter_user(entry,
# vmProgStackTop, ...)` after building a perfectly good block puts the program
# on an empty stack and `_start`'s first instruction faults. It would be caught
# by a boot -- but naming it here says which line is load-bearing.
grep -q "enter_user(entry, rsp, u64(0), u64(userCodeSel), u64(userDataSel));" \
  "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart does not enter ring 3 with the RSP argsBuild computed"
grep -q "final u64 rsp = argsBuild(elfMeta(u64(elfMetaStackFrame)));" \
  "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart does not build the initial stack in the frame the loader mapped at vmProgStackPage"
# And the block is built in the program's own address space, never in the
# kernel's: `argsPhys` is the ONE place the virtual-to-physical conversion is
# written, and it is written once.
PHYS=$(grep -c "argsPhys(" "$CORE_DIR/kernel/args.dart")
[[ "$PHYS" -ge 4 ]] || fail "args.dart uses argsPhys $PHYS time(s); argsBuild writes four kinds of word through it"
DEF=$(grep -c "^u64 argsPhys(u64 frame, u64 va) {" "$CORE_DIR/kernel/args.dart")
[[ "$DEF" -eq 1 ]] || fail "argsPhys is defined $DEF times; the virtual-to-physical conversion must be written exactly once"
echo "STRUCTURAL: pass  ring 3 is entered with the RSP argsBuild computed, and the one virtual-to-physical conversion is written once"

# 2f. shellStrHelp AND THE `run` USAGE LINE.
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk '$8=="shellStrHelp"{print $3; exit}')
[[ -n "$HELP_SIZE" ]] || fail "shellStrHelp not found in kmain.o"
grep -q "uartWrite(Rodata.addressOf(shellStrHelp), u64($HELP_SIZE));" "$CORE_DIR/kernel/shell.dart" \
  || fail "shellHelp() does not pass $HELP_SIZE — the table and the literal disagree, which is GAP-0060"
echo "STRUCTURAL: pass  shellStrHelp is $HELP_SIZE bytes and its call site agrees"

# ---------------------------------------------------------------------------
# Step 3 — build the two programs, and check what was built.
# ---------------------------------------------------------------------------
PROGDIR="$WORKDIR/progs"
bash "$SCRIPT_DIR/build-progs.sh" "$PROGDIR" || fail "build-progs.sh failed"

# ---------------------------------------------------------------------------
# Step 3b — verify-freestanding.sh (CLAUDE.md rule 1), and the extern count.
#
# GAP-0167: this harness's PASS line has always claimed `-> verify-freestanding
# ->`, and until now that string was the ONLY mention of the script anywhere in
# the file. The claim was not false about the KERNEL -- seven other harnesses
# run the check against these same objects, so rule 1 was and is enforced -- but
# it was false about THIS HARNESS, and a sentence a reader audits is not
# contradicted by re-running the suite. Modelled on m18-preempt §3h.
VERIFY_OUT=$( (cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o \
                                  && bash scripts/verify-freestanding.sh build/kdata.o \
                                  && bash scripts/verify-freestanding.sh build/kernel.elf) 2>&1 )
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
[[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed (output above)"
# Belt and braces, as m8-paging and m13-libc do it: the status alone would be
# satisfied by a script that printed nothing at all.
grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT" \
  && fail "verify-freestanding.sh printed a FAIL line while exiting 0"
grep -c "FREESTANDING: pass" <<<"$VERIFY_OUT" | grep -qx 3 \
  || fail "expected exactly 3 FREESTANDING: pass lines (kmain.o, kdata.o, kernel.elf)"
EXTERN_COUNT=$(sed -n 's/.*(\([0-9]*\) declared extern(s).*/\1/p' <<<"$VERIFY_OUT" | head -1)
[[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares ${EXTERN_COUNT:-no} externs, expected 44 — UNCHANGED from M18. M19 builds the initial process stack in Dart and enters ring 3 through the enter_user stub that already existed; a new assembly primitive would be a different design."
echo "FREESTANDING: pass  $EXTERN_COUNT declared externs, unchanged from M18 — M19 added no assembly"

# ---------------------------------------------------------------------------
# Step 4 — the volume, and an independent tool's opinion of it.
# ---------------------------------------------------------------------------
DISK_IMG="$WORKDIR/disk.img"
LAYOUT="$WORKDIR/layout.json"
python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/wc.elf" "$PROGDIR/wcn.elf" --json \
  > "$LAYOUT" || fail "make-image.py could not write the volume"
[[ -s "$DISK_IMG" ]] || fail "make-image.py produced no image"

IMG_VERDICT="not checked (fsck_msdos not on PATH)"
if command -v fsck_msdos >/dev/null 2>&1; then
  FSCK_OUT="$(fsck_msdos -n "$DISK_IMG" 2>&1)"
  FSCK_STATUS=$?
  if [[ $FSCK_STATUS -ne 0 ]]; then
    echo "$FSCK_OUT" >&2
    fail "fsck_msdos refuses the volume this harness built (exit $FSCK_STATUS)"
  fi
  IMG_VERDICT="fsck_msdos calls it clean"
fi
echo "IMAGE: pass  $IMG_VERDICT"

# ---------------------------------------------------------------------------
# Step 5 — derive every expectation from the volume that was just built.
# ---------------------------------------------------------------------------
DERIVED="$WORKDIR/derived.txt"
python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG" "$PROGDIR/wc.elf" "$PROGDIR/wcn.elf" \
  "$CORE_DIR/kernel" "$LIBC_DIR" "$SCRIPT_DIR/prog.c" > "$DERIVED" \
  || fail "derive.py could not derive the expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
[[ -n "$(d alpha_chars)" ]] || fail "derive.py produced no counts"

# The two files must differ in every column, or "different argument, different
# answer" is not a claim this volume can support.
for col in lines words chars; do
  [[ "$(d alpha_$col)" != "$(d beta_$col)" ]] \
    || fail "ALPHA.TXT and BETA.TXT have the same $col count"
done
[[ "$(d alpha_status)" != "$(d beta_status)" ]] \
  || fail "the two files produce the same derived exit status"
echo "DERIVED: ALPHA.TXT is $(d alpha_lines) lines / $(d alpha_words) words / $(d alpha_chars) bytes, status $(d alpha_status), read in $(d alpha_reads) pieces of $(d chunk)"
echo "DERIVED: BETA.TXT is $(d beta_lines) / $(d beta_words) / $(d beta_chars), status $(d beta_status), in $(d beta_reads) pieces"
echo "DERIVED: both together are $(d both_lines) / $(d both_words) / $(d both_chars), status $(d both_status)"
echo "DERIVED: the negative control ignores argv and counts $(d neg_file), so given BETA.TXT it must print $(d neg_lines) $(d neg_words) $(d neg_chars) and exit $(d neg_status)"

# ---------------------------------------------------------------------------
# Step 6 — the boots.
# ---------------------------------------------------------------------------
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4"
  shift 4
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  # GAP-0150: the port is BOUND-THEN-RELEASED by pick-port.py rather than
  # derived from $$, and the launch is RETRIED if QEMU still loses the race.
  local attempt=0 port drive_status qemu_status qemu_pid
  while :; do
    attempt=$(( attempt + 1 ))
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
      --png "$png" \
      --screen-text "$outdir/screen.txt" \
      --keys "$keys" \
      "$@"
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
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot (log above)"
  fi
}

# ---- BOOT 1: the milestone. THE SAME BINARY, THREE DIFFERENT COMMAND LINES.
#
# `frames` brackets the session: the allocator's free count must be identical
# before and after three programs have been loaded, given arguments, run and
# torn down.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run wc.elf alpha.txt"),ret,wait:22000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run wc.elf beta.txt"),ret,wait:12000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run wc.elf -l alpha.txt beta.txt"),ret,wait:30000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:1200"

SHOT_PNG="$CORE_DIR/build/screenshot-argv.png"
drive_session "$WORKDIR/main" "$SESSION_KEYS" "$SHOT_PNG" "main"
SERIAL="$WORKDIR/main/serial.txt"
SCREEN="$WORKDIR/main/screen.txt"
[[ -s "$SERIAL" ]] || fail "the main boot captured no serial output at all"

have() { grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { grep -qF -- "$1" "$SERIAL" && fail "the transcript contains what it must not: $1"; }

# 7a. THE PROGRAM COUNTED THE FILE IT WAS TOLD TO COUNT, TWICE, DIFFERENTLY.
have "WC $(d alpha_lines) $(d alpha_words) $(d alpha_chars) alpha.txt"
have "WC $(d beta_lines) $(d beta_words) $(d beta_chars) beta.txt"
# And it did NOT print either file's answer against the other's name.
havent "WC $(d alpha_lines) $(d alpha_words) $(d alpha_chars) beta.txt"
havent "WC $(d beta_lines) $(d beta_words) $(d beta_chars) alpha.txt"
echo "CHECK 1: pass  one binary, two command lines, two DIFFERENT derived answers — $(d alpha_lines)/$(d alpha_words)/$(d alpha_chars) for alpha.txt and $(d beta_lines)/$(d beta_words)/$(d beta_chars) for beta.txt, both computed on the host from the volume this harness wrote"

# 7b. THE EXIT STATUS IS DERIVED FROM THE ARGUMENTS TOO.
have "USER EXIT CODE 00000000000000$(printf '%02X' 0x$(d alpha_status))"
have "USER EXIT CODE 00000000000000$(printf '%02X' 0x$(d beta_status))"
echo "CHECK 2: pass  the two runs exited $(d alpha_status) and $(d beta_status), each a function of the file the argument named"

# 7c. A FLAG ARGUMENT CHANGES WHAT THE PROGRAM DOES, AND TWO FILE ARGUMENTS ARE
#     BOTH USED. `-l` prints ONE column, and the totals are the sum.
have "WC $(d alpha_lines) alpha.txt"
have "WC $(d beta_lines) beta.txt"
have "WC TOTAL $(d both_lines) $(d both_words) $(d both_chars)"
have "WC MODE 1 FILES 2 STATUS $(d both_status)"
have "USER EXIT CODE 00000000000000$(printf '%02X' 0x$(d both_status))"
echo "CHECK 3: pass  \`run wc.elf -l alpha.txt beta.txt\` selected the lines column from argv[1] and counted BOTH files argv[2] and argv[3] named, totalling $(d both_lines)/$(d both_words)/$(d both_chars)"

# 7d. argv[0] IS THE PROGRAM'S OWN NAME AND argc IS WHAT THE SHELL WAS GIVEN.
have "ELF ARGS N 02"
have "ELF ARGS N 04"
have "ELF ARG 00 AT"
have "WC ARGC 2"
have "WC ARGC 4"
for pair in "0 wc.elf" "1 alpha.txt"; do
  set -- $pair
  grep -qE "WC ARGV $1 [0-9a-f]+ [0-9]+ $2\$" "$SERIAL" \
    || fail "the program never reported argv[$1] as $2"
done
echo "CHECK 4: pass  argv[0] is \`wc.elf\`, the name the shell was given, and argc is 2 and 4 for the two- and four-token command lines"

# 7e. THE TERMINATORS, AS THE PROGRAM SEES THEM (the memory check below is the
#     one that counts; this is the program agreeing with it).
have "WC TERM 0 0"
echo "CHECK 5: pass  the program reads NULL at argv[argc] and NULL at envp[0]"

# 7f. THE FRAME ALLOCATOR RETURNS EXACTLY TO BASELINE.
FREE_BEFORE=$(grep -m1 "PMM MANAGED" "$SERIAL" | sed -n 's/.*FREE \([0-9A-F]*\).*/\1/p')
FREE_AFTER=$(grep "PMM MANAGED" "$SERIAL" | tail -1 | sed -n 's/.*FREE \([0-9A-F]*\).*/\1/p')
[[ -n "$FREE_BEFORE" && -n "$FREE_AFTER" ]] || fail "the transcript has fewer than two \`PMM MANAGED\` lines"
[[ "$FREE_BEFORE" == "$FREE_AFTER" ]] \
  || fail "the frame allocator's free count went $FREE_BEFORE -> $FREE_AFTER across a session that ran three programs WITH ARGUMENTS; M19 leaks"
BASELINE=$(grep -m1 "PMM MANAGED" "$SERIAL" | sed -n 's/.*BASELINE \([0-9A-F]*\).*/\1/p')
[[ "$FREE_AFTER" == "$BASELINE" ]] \
  || fail "the free count after the session is $FREE_AFTER and the allocator's own baseline is $BASELINE"
echo "CHECK 6: pass  the frame allocator's free count is $FREE_AFTER before AND after three programs were loaded with arguments, run, and torn down — identical to the frame, and equal to its own baseline"

# 7g. M1's GOLDEN IS INTACT AS A PREFIX.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL" | cmp -s - "$M1_EXPECTED" \
  || fail "the first $M1_BYTES bytes of this boot are not m1-interrupts' golden — M19 moved a byte it does not own"
echo "CHECK 7: pass  the first $M1_BYTES bytes are m1-interrupts' golden, byte for byte"

# 7h. THE WHOLE TRANSCRIPT, BYTE FOR BYTE.
SERIAL_BYTES=$(wc -c <"$SERIAL" | tr -d ' ')
if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL" "$EXPECTED_SERIAL"
  cp "$SCREEN" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $EXPECTED_SERIAL ($SERIAL_BYTES bytes) and $EXPECTED_SCREEN"
else
  [[ -f "$EXPECTED_SERIAL" ]] || fail "no golden at $EXPECTED_SERIAL (run with --regen once, then read the diff)"
  cmp -s "$SERIAL" "$EXPECTED_SERIAL" || {
    diff <(cat "$EXPECTED_SERIAL") <(cat "$SERIAL") | head -60 >&2
    fail "the serial capture does not match $EXPECTED_SERIAL byte for byte"
  }
  [[ -f "$EXPECTED_SCREEN" ]] || fail "no screen golden at $EXPECTED_SCREEN"
  cmp -s "$SCREEN" "$EXPECTED_SCREEN" || {
    diff "$EXPECTED_SCREEN" "$SCREEN" | head -40 >&2
    fail "the VGA text buffer does not match $EXPECTED_SCREEN"
  }
  echo "CHECK 8: pass  $SERIAL_BYTES bytes of serial and the whole VGA text buffer match their goldens byte for byte"
fi

# ---- BOOT 2: THE STACK, READ OUT OF GUEST PHYSICAL MEMORY ------------------
#
# One command, so that `--addr-from-serial` matches exactly one `ELF STACK`
# line, and QEMU's own `xp` dumps the whole 4096-byte stack frame.
STACK_KEYS="$(typekeys "run wc.elf -w alpha.txt"),ret,wait:25000"
drive_session "$WORKDIR/stack" "$STACK_KEYS" "$WORKDIR/stack/shot.png" "stack" \
  --monitor-command 'xp/512gx {addr}' \
  --monitor-capture "$WORKDIR/stack/mon.txt" \
  --addr-from-serial 'ELF STACK [0-9A-F]{16} FRAME 0*([0-9A-F]+)'
STACK_SERIAL="$WORKDIR/stack/serial.txt"
grep -q "WC $(d alpha_words) alpha.txt" "$STACK_SERIAL" \
  || { sed -n '/M1 END/,$p' "$STACK_SERIAL" >&2; fail "the -w boot did not print alpha.txt's word count"; }

STACK_PAGE=$(dartconst vmProgStackPage vm.dart)
STACK_TOP=$(dartconst vmProgStackTop vm.dart)
python3 "$SCRIPT_DIR/check-stack.py" "$WORKDIR/stack/mon.txt" "$STACK_SERIAL" \
  "$A_MIN_STACK" "$STACK_PAGE" "$STACK_TOP" "wc.elf" "-w" "alpha.txt" \
  || fail "the initial process stack in guest memory is not the System V ABI's"

# AND THE CHECKER ITSELF HAS TEETH: given a command line that is NOT what was
# typed, it must refuse. A checker that passes everything checks nothing.
if python3 "$SCRIPT_DIR/check-stack.py" "$WORKDIR/stack/mon.txt" "$STACK_SERIAL" \
     "$A_MIN_STACK" "$STACK_PAGE" "$STACK_TOP" "wc.elf" "-w" "beta.txt" >/dev/null 2>&1; then
  fail "check-stack.py accepts a stack whose argv[2] is not what was typed — the memory check proves nothing"
fi
if python3 "$SCRIPT_DIR/check-stack.py" "$WORKDIR/stack/mon.txt" "$STACK_SERIAL" \
     "$A_MIN_STACK" "$STACK_PAGE" "$STACK_TOP" "wc.elf" "-w" >/dev/null 2>&1; then
  fail "check-stack.py accepts an argc that is not the number of tokens typed"
fi
echo "CHECK 9: pass  and the checker refuses a wrong argv and a wrong argc, so its acceptance means something"

# ---- BOOT 3: THE NEGATIVE CONTROL -----------------------------------------
NEG_KEYS="$(typekeys "run wcn.elf beta.txt"),ret,wait:22000"
drive_session "$WORKDIR/neg" "$NEG_KEYS" "$WORKDIR/neg/shot.png" "negative control"
NEG_SERIAL="$WORKDIR/neg/serial.txt"
nhave() { grep -qF -- "$1" "$NEG_SERIAL" || { sed -n '/M1 END/,$p' "$NEG_SERIAL" >&2; fail "the control transcript does not contain: $1"; }; }
nhavent() { grep -qF -- "$1" "$NEG_SERIAL" && fail "the control transcript contains what it must not: $1"; }

# The control was GIVEN beta.txt -- the kernel built that argv and the control's
# own argv report shows it -- and it counted the file compiled into it instead.
nhave "ELF ARG 01 AT"
nhave "WC ARGV 1 "
nhave "WC $(d neg_lines) $(d neg_words) $(d neg_chars) beta.txt"
nhavent "WC $(d beta_lines) $(d beta_words) $(d beta_chars) beta.txt"
nhave "USER EXIT CODE 00000000000000$(printf '%02X' 0x$(d neg_status))"
nhavent "USER EXIT CODE 00000000000000$(printf '%02X' 0x$(d beta_status))"
echo "CHECK 10: pass  the control build was handed the SAME argv and ignored it: given beta.txt it printed $(d neg_lines) $(d neg_words) $(d neg_chars) — $(d neg_file)'s counts — and exited $(d neg_status) instead of $(d beta_status)"

# ---- BOOT 4: THE REFUSALS, AND A SHELL THAT SURVIVES THEM -----------------
# BOTH SIDES OF BOTH BOUNDS, AND THE REFUSING SIDE IS ONE UNIT OVER.
#
# A bound asserted only from the refusing side is half a bound: "nine arguments
# are refused" is satisfied by a kernel that refuses two. So this boot runs
# EXACTLY argsMaxCount arguments and EXACTLY argsMaxBytes bytes and requires
# both to be ACCEPTED, and then one more of each and requires both to be
# REFUSED. The long argument is sized from args.dart's own constant rather than
# typed here: 120 = argsMaxBytes - len("wc.elf\0") - 1, so the accepted line is
# 128 bytes to the byte and the refused one is 129.
OKLEN=$(( A_MAX_BYTES - 7 - 1 ))
OKARG=$(python3 -c "import sys; print('x' * int(sys.argv[1]))" "$OKLEN")
LONGARG=$(python3 -c "import sys; print('x' * (int(sys.argv[1]) + 1))" "$OKLEN")
# argsMaxCount tokens exactly: the program name, a flag, and six file names.
MAXARGS="wc.elf -c alpha.txt beta.txt alpha.txt beta.txt alpha.txt beta.txt"
[[ $(echo $MAXARGS | wc -w | tr -d ' ') -eq "$A_MAX_COUNT" ]] \
  || fail "the maximal command line has $(echo $MAXARGS | wc -w) tokens, not argsMaxCount ($A_MAX_COUNT)"
REF_KEYS="$(typekeys "run wc.elf"),ret,wait:9000"
REF_KEYS="$REF_KEYS,$(typekeys "run wc.elf nosuch.txt"),ret,wait:9000"
REF_KEYS="$REF_KEYS,$(typekeys "run $MAXARGS"),ret,wait:90000"
REF_KEYS="$REF_KEYS,$(typekeys "run wc.elf $OKARG"),ret,wait:9000"
REF_KEYS="$REF_KEYS,$(typekeys "run wc.elf a b c d e f g h"),ret,wait:1200"
REF_KEYS="$REF_KEYS,$(typekeys "run wc.elf $LONGARG"),ret,wait:1200"
REF_KEYS="$REF_KEYS,$(typekeys "run wc.elf beta.txt"),ret,wait:12000"
drive_session "$WORKDIR/refuse" "$REF_KEYS" "$WORKDIR/refuse/shot.png" "refusals"
REF_SERIAL="$WORKDIR/refuse/serial.txt"
rhave() { grep -qF -- "$1" "$REF_SERIAL" || { sed -n '/M1 END/,$p' "$REF_SERIAL" >&2; fail "the refusal transcript does not contain: $1"; }; }

# argc == 1: the program ran, was given ONLY its own name, and said so.
rhave "ELF ARGS N 01"
rhave "WC ARGC 1"
rhave "WC USAGE"
rhave "USER EXIT CODE 0000000000000002"
# A name that is not on the volume: the OPEN is refused, from ring 3, as a
# return value, and the program reports it.
rhave "WC OPEN nosuch.txt REFUSED"
rhave "USER EXIT CODE 0000000000000004"
# EXACTLY argsMaxCount ARGUMENTS ARE ACCEPTED, and the program counted all six
# files it was given and totalled them.
rhave "ELF ARGS N 0$A_MAX_COUNT"
rhave "WC ARGC $A_MAX_COUNT"
rhave "WC MODE 3 FILES 6"
# EXACTLY argsMaxBytes BYTES ARE ACCEPTED, to the byte.
rhave "$(printf 'ELF ARGS N 02 BYTES %04X' "$A_MAX_BYTES")"
# One more of each is refused BY THE SHELL, by name.
E01=$(python3 -c "
import re,sys
src=open(sys.argv[1]).read()
m=re.search(r'final List<u8> argsStrE01 = const \[(.*?)\];', src, re.S)
print(bytes(int(x,16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1))).decode().rstrip())
" "$CORE_DIR/kernel/args.dart")
E02=$(python3 -c "
import re,sys
src=open(sys.argv[1]).read()
m=re.search(r'final List<u8> argsStrE02 = const \[(.*?)\];', src, re.S)
print(bytes(int(x,16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1))).decode().rstrip())
" "$CORE_DIR/kernel/args.dart")
rhave "$E01"
rhave "$E02"
# NOTHING WAS LOADED for either refusal: the refusal happens in the parse,
# before a frame is taken, so no ELF line follows it.
python3 - "$REF_SERIAL" "$E01" "$E02" <<'PY' || fail "a refused command line still reached the ELF loader"
import sys
lines = open(sys.argv[1], encoding="latin-1").read().splitlines()
for msg in sys.argv[2:]:
    i = [n for n, l in enumerate(lines) if l.strip() == msg]
    if not i:
        print("    - %r never appeared" % msg, file=sys.stderr); sys.exit(1)
    # The line IMMEDIATELY after the refusal must be the PROMPT. Nothing was
    # opened, nothing was loaded, no frame was taken: the shell said one
    # sentence and asked for the next command. (The prompt line carries the
    # NEXT command's echo, which is why only one line is examined.)
    nxt = lines[i[0] + 1] if i[0] + 1 < len(lines) else ""
    if not nxt.startswith("oscortex>"):
        print("    - after %r the kernel printed %r instead of the prompt"
              % (msg, nxt), file=sys.stderr)
        sys.exit(1)
PY
# THE SHELL IS ALIVE AFTERWARDS and runs the next program correctly.
rhave "WC $(d beta_lines) $(d beta_words) $(d beta_chars) beta.txt"
echo "CHECK 11: pass  argc 1 and a missing file are handled BY THE PROGRAM; BOTH BOUNDS ARE EXERCISED FROM BOTH SIDES -- exactly $A_MAX_COUNT arguments and exactly $A_MAX_BYTES bytes of argument text are ACCEPTED (the $A_MAX_COUNT-token line counting all six files it named), and $(( A_MAX_COUNT + 1 )) arguments and $(( A_MAX_BYTES + 1 )) bytes are REFUSED BY THE SHELL with their own sentences, before any frame is taken; and the shell then ran \`run wc.elf beta.txt\` correctly"

# ---- The exit criterion, stated once more against what actually happened. --
echo
echo "M19-argv: PASS — dcc build -> assemble -> link -> clang builds core/user/libc's SIX OBJECTS (M19's start.c among them, the only one that defines \`_start\`) AND ONE PROGRAM SOURCE TWICE, the second ignoring argv as a negative control -> make-image.py writes a FAT16 volume whose ALPHA.TXT and BETA.TXT differ in ALL THREE of lines, words and bytes and whose chains go backwards -> structural checks (the kernel's mutable statics 14112 -> 14368 with argsStore one 256-byte block that is the LAST in .bss so no earlier harness's accounting moves, its three regions tiling exactly, a 3-call-site storage seam in one file, 11 @rodata tables against their call sites, five distinct refusal values with four distinct sentences, and the entry path proven to use the computed RSP) -> build-progs checks (\`_start\` is the LIBRARY's, reads argc from (%rsp) and argv from 8(%rsp), and NEVER WRITES %rsp) -> verify-freestanding pass on kmain.o, kdata.o and kernel.elf (${EXTERN_COUNT} declared externs, unchanged from M18 — M19 added no assembly) -> FOUR real QEMU boots. A ${SERIAL_BYTES}-byte serial match with m1-interrupts' ${M1_BYTES}-byte golden intact as a prefix; A C PROGRAM WRITTEN AS \`int main(int argc, char **argv)\` TOLD BY THE SHELL WHICH FILE TO COUNT, counting alpha.txt to $(d alpha_lines)/$(d alpha_words)/$(d alpha_chars) and then, THE SAME BINARY, beta.txt to $(d beta_lines)/$(d beta_words)/$(d beta_chars), every number computed on the host from the volume this harness wrote and each exit status derived from its own file; a flag argument selecting one column and two file arguments both counted and totalled; THE INITIAL PROCESS STACK READ OUT OF GUEST PHYSICAL MEMORY WITH QEMU'S OWN MONITOR and checked against the System V ABI -- RSP 16-byte aligned, argc at RSP, every argv pointer inside the program's own mapped user page and naming the exact bytes typed, NULL argv terminator, NULL envp, AT_NULL auxv and every padding byte zero -- with the checker itself required to reject a wrong argv and a wrong argc; a control build handed the same argv and ignoring it, printing $(d neg_file)'s counts for beta.txt and a different exit status; argc 1 and a name that is not on the volume both handled from ring 3; nine arguments and a 129-byte argument refused by the shell before a frame was taken, with the shell alive and correct afterwards; and the frame allocator's free count identical, to the frame, before and after. Screenshot at $SHOT_PNG"
exit 0
