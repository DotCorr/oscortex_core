#!/usr/bin/env bash
# core/scripts/verify-mmio-volatile.sh
#
# PER-SITE proof that every MMIO access in this kernel SURVIVES OPTIMIZATION,
# with an automated negative control proving the detector can fail.
#
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# DCDart ADR-0069 split the pointer types: `Pointer<T>` is ordinary memory
# (plain, optimizable loads/stores -- the optimizer may delete, reorder,
# hoist, or COALESCE them) and `Volatile<T>` is the MMIO type (accesses
# survive exactly as written). This kernel's device accesses -- the VGA text
# cells at 0xB8000 and the linear framebuffer -- migrated to `Volatile<T>`
# (oscortex GAP-0069 / the mmio-volatile-migration branch). "It compiles" is
# not evidence of anything: the defect class this guards against is INVISIBLE
# to every value-checking harness (the value stays right; the device access
# disappears -- DCDart's GAP-0006/GAP-0027, measured in its ADR-0041). The
# only evidence is the surviving access in the compiled object, counted per
# site. This script is the assertion pattern of DCDart's own
# core/tests/conformance/volatile/run.sh, applied to this kernel's real
# sites.
#
# WHAT IS CHECKED, per migrated site
# ---------------------------------------------------------------------------
#   IR level (which half broke, if one does):
#     vgaPutCellAt   exactly 1 `store volatile i16`
#     vgaBlankAt     exactly 1 `store volatile i16`
#     vgaScroll      exactly 1 `load volatile i16` + 1 `store volatile i16`
#     fbPutPixel     exactly 1 `store volatile i32`
#     vmTestRo       exactly 1 `store volatile i8`  (the W^X fault probe — a
#                    store whose PURPOSE is to fault; ordinary, it is a store
#                    to a known-`constant` global, which is UB, and -O2
#                    deletes it: measured as VM FAULTS 2 -> 1)
#     vmTestRw       exactly 1 `store volatile i64` + 1 `load volatile i64`
#                    (the writable control — forwarding would make it vacuous)
#     shellFramesTest exactly 2 `store volatile i64`, shellFramesDrain 1,
#     pmmCheckWord   exactly 1 `load volatile i64` (the pmm memory-test
#                    class: stores verified by consequence, a mapping-probe
#                    touch, and the read-back they share)
#   plus the INVENTORY check: those nine functions are the ONLY functions in
#   the whole module containing a volatile operation. That is the ADR-0069
#   negative half per site: every ordinary `Pointer<T>` walk in this kernel
#   (heap, page tables, pmm bitmap, rodata tables, bss state words) emits
#   ZERO volatile ops, asserted by exhaustion rather than by sampling.
#
#   Object level, at the real -O2 pipeline flags (and ALSO on build/kmain.o,
#   the object `dcc build` actually produced, so the guarantee is pinned on
#   the shipped path, not only the probe path):
#     vgaPutCellAt   exactly 1 memory store, and it is 16-bit (movw)
#     vgaBlankAt     exactly 1 memory store, 16-bit
#     fbPutPixel     exactly 1 memory store, 32-bit (movl)
#     vgaScroll      >=1 16-bit load + >=1 16-bit store; ZERO wider-than-16
#                    memory accesses; the load stays INSIDE its loop
#                    (backward-branch check)
#     vgaClear       >=1 16-bit store; ZERO wider-than-16 memory stores; no
#                    calls (a memset call here would be a leaked runtime
#                    symbol AND a coalesced device write)
#   Loop bodies are asserted on ACCESS WIDTH, not on static instruction
#   count: unrolling a volatile access is legal (each dynamic access still
#   happens exactly once), so -O2 emitting five movw's per unrolled
#   iteration is correct -- what volatile forbids, and what the stripped IR
#   demonstrably gets, is MERGING adjacent device stores into one wide one.
#
#   Port I/O (ADR-0029 `asm sideeffect`, a different mechanism -- checked
#   because a hoisted port read is this kernel's worst failure mode: the
#   UART poll spins forever on a stale LSR and the machine just stops):
#     uartPutc       >=1 `in`, loop-resident; >=1 `out`
#   and, ONLY on trees that have the B1 serial-receive path (detected by
#   `uartEnableRx` in the source):
#     shellSerialIrq the drain loop's status poll re-reads the device every
#                    iteration: either the body contains loop-resident `in`
#                    instructions (inlined), or it calls uartHasByte each
#                    iteration (an opaque call boundary) and uartHasByte
#                    contains the `in`.
#
#   NEGATIVE CONTROL, automated, every run: strip the volatile keyword from
#   the emitted IR, recompile at -O2, and REQUIRE that the object-level
#   detector above would have failed -- specifically that vgaClear's device
#   stores get coalesced into a wide (movq) store. A check never seen to
#   fail is indistinguishable from one that cannot; the day the optimizer
#   stops exploiting the missing keyword, this control fails loudly and the
#   positive check must be redesigned, not trusted.
#
# HONEST LIMIT, so nobody over-reads a pass: for the STRAIGHT-LINE sites
# (vgaPutCellAt, vgaBlankAt, fbPutPixel) the store survives at -O2 even
# without volatile -- a store through a computed address is not provably dead
# -- so for those sites the negative control bites at the IR level (the
# `store volatile` grep fails on stripped IR), not at the codegen level. The
# codegen counts for those sites guard against a DIFFERENT regression
# (duplication or deletion by a future optimizer), the same 4a/4b split
# DCDart's harness documents for port I/O.
#
# The probe writes a transient helper into $DCDART_HOME/core/dcc/bin and
# removes it immediately -- the same pattern DCDart's own volatile harness
# uses, because dcc deletes its .ll and this harness needs to compile the
# same IR twice (once as emitted, once with volatile stripped).
#
# Usage:
#   DCDART_HOME=/path/to/DCDart core/scripts/verify-mmio-volatile.sh
#   core/scripts/verify-mmio-volatile.sh     # default: ../DCDart sibling
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() { echo "MMIO-VOLATILE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "MMIO-VOLATILE: FAIL — $1" >&2; exit 2; }

DCDART_HOME="${DCDART_HOME:-$REPO_DIR/../DCDart}"
[[ -d "$DCDART_HOME" ]] || setup_error "DCDART_HOME not found at $DCDART_HOME"
[[ -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]] || setup_error "$DCDART_HOME is not a DCDart checkout"
command -v dart >/dev/null 2>&1 || setup_error "dart not found on PATH (source env.sh)"
command -v clang >/dev/null 2>&1 || setup_error "clang not found on PATH"

OBJDUMP=""
for c in llvm-objdump objdump; do
  command -v "$c" >/dev/null 2>&1 && { OBJDUMP="$c"; break; }
done
[[ -n "$OBJDUMP" ]] || setup_error "neither llvm-objdump nor objdump found; this harness reads instructions and cannot run without one"

# THE PRELUDE, spelled exactly as this tree's own kmain.dart spells it
# (ADR-0043/GAP-0003: dcc-lower matches the annotation library by EXACT
# normalised-path equality, symlinks resolved on neither side — any other
# spelling makes every @bare invisible). Trees after ADR-0043 import through
# core/build/dcdart (a symlink this script maintains, as build-kernel.sh
# does); older branches import a literal ../../../DCDart sibling. Reading the
# import line covers both without this script hard-coding either.
KERNEL_DIR="$(cd "$CORE_DIR/kernel" && pwd -P)"
LINK_DIR="$(dirname "$KERNEL_DIR")/build"
mkdir -p "$LINK_DIR"
IMPORT_REL="$(sed -nE "s/^import '(\.[^']*dc-core-bare\/prelude\.dart)';.*/\1/p" "$KERNEL_DIR/kmain.dart" | head -1)"
[[ -n "$IMPORT_REL" ]] || setup_error "could not find kmain.dart's relative prelude import"
if [[ "$IMPORT_REL" == "../build/dcdart/"* ]]; then
  # ADR-0043 scheme: this script owns the symlink, exactly as build-kernel.sh.
  DCDART_LINK="$LINK_DIR/dcdart"
  if [[ -L "$DCDART_LINK" ]]; then
    rm -f "$DCDART_LINK"
  elif [[ -e "$DCDART_LINK" ]]; then
    setup_error "$DCDART_LINK exists and is not a symlink"
  fi
  ln -s "$DCDART_HOME" "$DCDART_LINK" || setup_error "could not create $DCDART_LINK"
fi
# Lexically normalise KERNEL_DIR/IMPORT_REL (fold ..) WITHOUT resolving
# symlinks — the same normalisation the Dart front end applies.
PRELUDE="$(python3 -c 'import os,sys; print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))' "$KERNEL_DIR" "$IMPORT_REL")"
[[ -f "$PRELUDE" ]] || setup_error "kmain.dart's prelude import resolves to $PRELUDE, which does not exist — for a pre-ADR-0043 tree, make a DCDart checkout (or symlink) available at that path"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-mmio.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# The exact clang invocation dcc's pipeline uses for a bare-x86_64 object
# (DCDart core/backend/lib/compile.dart): -O2, no red zone, no FP/SIMD
# registers, freestanding. Reproduced verbatim so the probe object is the
# shipped object's twin, not an approximation of it.
CLANG_FLAGS=(--target=x86_64-unknown-none-elf -O2 -mno-red-zone
  -mgeneral-regs-only -ffreestanding -fno-builtin -fno-stack-protector
  -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables)

# ---------------------------------------------------------------------------
# Step 1 — emit the kernel's IR through the same lowering dcc uses.
# ---------------------------------------------------------------------------
PROBE="$DCDART_HOME/core/dcc/bin/_oscortex_mmio_probe.dart"
cat > "$PROBE" <<'DART'
import 'dart:io';
import 'package:backend/llvm_emit.dart';
import 'package:backend/targets.dart';
import 'package:dcc_lower/lower.dart';

Future<void> main(List<String> args) async {
  final module = await lowerToDCModule(
    args[0],
    preludeUri: File(args[1]).absolute.uri,
  );
  final target = DCTarget.parse(args[2], hostOsName: 'linux', hostArchName: 'x64');
  File(args[3]).writeAsStringSync(
    emitModule(module,
        targetTriple: target.triple,
        noRedZone: target.forbidsRedZone,
        freestanding: target.isFreestanding),
  );
}
DART
( cd "$DCDART_HOME/core" && dart dcc/bin/_oscortex_mmio_probe.dart \
    "$KERNEL_DIR/kmain.dart" "$PRELUDE" bare-x86_64 "$WORKDIR/kmain.ll" ) \
  >"$WORKDIR/emit.log" 2>&1
EMIT_STATUS=$?
rm -f "$PROBE"
[[ $EMIT_STATUS -eq 0 ]] || { cat "$WORKDIR/emit.log" >&2; fail "could not emit IR for kmain.dart"; }
[[ -s "$WORKDIR/kmain.ll" ]] || fail "emitted IR is empty"

# ---------------------------------------------------------------------------
# Step 2 — IR-level per-site assertions + the exhaustive inventory.
# ---------------------------------------------------------------------------
ir_body_of() { # ir_body_of <fnname>  -- prints the .ll body of @fnname
  awk -v fn="@$1(" '
    index($0, "define") == 1 && index($0, fn) { inside = 1; next }
    inside && $0 == "}" { inside = 0 }
    inside { print }
  ' "$WORKDIR/kmain.ll"
}

ir_expect() { # ir_expect <fn> <pattern> <count>
  local body; body="$(ir_body_of "$1")"
  [[ -n "$body" ]] || fail "IR: no function @$1 in kmain.ll — the per-site check would pass vacuously"
  local n; n="$(grep -c "$2" <<<"$body")"
  [[ "$n" -eq "$3" ]] || fail "IR: @$1 has $n occurrence(s) of '$2', expected exactly $3 — a Volatile<T> site lost (or duplicated) its volatile lowering (ADR-0069)"
}

ir_expect vgaPutCellAt 'store volatile i16' 1
ir_expect vgaBlankAt   'store volatile i16' 1
ir_expect vgaScroll    'load volatile i16'  1
ir_expect vgaScroll    'store volatile i16' 1
ir_expect fbPutPixel   'store volatile i32' 1
# The two access-is-the-assertion probes (not MMIO — see vm.dart's comments):
# vmTestRo's store aims at a global LLVM knows is `constant`; written ordinary
# the store is UB and -O2 DELETES it (measured: the boot's VM FAULTS total
# drops from 2 to 1). vmTestRw's pair is the writable control; written
# ordinary the load is forwarded and never touches the page.
ir_expect vmTestRo     'store volatile i8'  1
ir_expect vmTestRw     'store volatile i64' 1
ir_expect vmTestRw     'load volatile i64'  1
# The memory-test class in pmm.dart: pattern stores verified by consequence
# (`frames test`'s RW check), the drain's mapping-probe touch, and the
# read-back helper both use. Ordinary, the store/readback pairs are legally
# forwardable and the tests could pass without touching a frame.
ir_expect shellFramesTest  'store volatile i64' 2
ir_expect shellFramesDrain 'store volatile i64' 1
ir_expect pmmCheckWord     'load volatile i64'  1
echo "MMIO-VOLATILE: step 2 ok — all nine migrated functions emit their volatile ops in the IR"

# The inventory: volatile ops appear in EXACTLY these functions and nowhere
# else. Both directions matter — a missing function is a demoted device
# access; an extra one is an over-migration silently taxing ordinary memory
# (GAP-0034's cost) or a new, unreviewed MMIO site.
EXPECTED_VOLATILE_FNS="fbPutPixel
pmmCheckWord
shellFramesDrain
shellFramesTest
vgaBlankAt
vgaPutCellAt
vgaScroll
vmTestRo
vmTestRw"
ACTUAL_VOLATILE_FNS="$(awk '
  index($0, "define") == 1 { fn = $0; sub(/^.*@/, "", fn); sub(/\(.*$/, "", fn) }
  /volatile/ { print fn }
' "$WORKDIR/kmain.ll" | sort -u)"
if [[ "$ACTUAL_VOLATILE_FNS" != "$EXPECTED_VOLATILE_FNS" ]]; then
  fail "IR inventory mismatch — functions containing volatile ops:
$ACTUAL_VOLATILE_FNS
expected exactly:
$EXPECTED_VOLATILE_FNS
A new MMIO site must be added to this script's inventory (and to the migration ADR's table); a missing one has been demoted to ordinary Pointer access."
fi
echo "MMIO-VOLATILE: step 2b ok — inventory exact: those nine functions are the ONLY volatile emitters (every ordinary Pointer walk is plain, ADR-0069's negative half)"

# ---------------------------------------------------------------------------
# Step 3 — object-level per-site assertions, on the probe object AND on the
# object dcc actually shipped (build/kmain.o), when present.
# ---------------------------------------------------------------------------
clang "${CLANG_FLAGS[@]}" -c "$WORKDIR/kmain.ll" -o "$WORKDIR/kmain.o" \
  >"$WORKDIR/cc.log" 2>&1 || { cat "$WORKDIR/cc.log" >&2; fail "clang -O2 could not compile the emitted IR"; }

body_of_fn() { # body_of_fn <objfile> <fnname>
  "$OBJDUMP" -d "$1" 2>/dev/null | awk -v fn="<$2>:" '
    index($0, fn) { inside = 1; next }
    inside && /^[[:space:]]*$/ { inside = 0 }
    inside { print }
  '
}

# AT&T-syntax access classifiers. A memory operand contains "(%r"; a store's
# memory operand is the LAST (destination) operand, a load's is the source.
count_stores_16() { grep -cE 'movw[[:space:]]+[^,]+, (-?0x[0-9a-f]+)?\(%r' <<<"$1"; }
count_stores_32() { grep -cE 'movl[[:space:]]+[^,]+, (-?0x[0-9a-f]+)?\(%r' <<<"$1"; }
count_stores_wide() { grep -cE 'mov(l|q)[[:space:]]+[^,]+, (-?0x[0-9a-f]+)?\(%r' <<<"$1"; }
count_loads_16() { grep -cE '(movzwl|movw)[[:space:]]+(-?0x[0-9a-f]+)?\(%r[^,]*\), ' <<<"$1"; }
count_loads_wide() { grep -cE 'movq?[[:space:]]+(-?0x[0-9a-f]+)?\(%r[^,]*\), %r' <<<"$1"; }
count_all_stores() { grep -cE 'mov[a-z]*[[:space:]]+[^,]+, (-?0x[0-9a-f]+)?\(%r' <<<"$1"; }

# Loop residency: the first instruction matching $2 in body $1 must have a
# backward branch at or before its address — i.e. it is INSIDE a loop, not
# hoisted above one. Plain bash $((16#..)) rather than gawk's strtonum, which
# macOS awk silently zeroes.
loop_resident() { # loop_resident <body> <insn-regex>
  local addr line cur tgt
  addr="$(grep -E "$2" <<<"$1" | head -1 | sed -E 's/^[[:space:]]*([0-9a-f]+):.*/\1/')"
  [[ -n "$addr" ]] || return 2
  while read -r line; do
    cur="$(sed -E 's/^[[:space:]]*([0-9a-f]+):.*/\1/' <<<"$line")"
    tgt="$(grep -oE '0x[0-9a-f]+' <<<"$line" | tail -1 | sed 's/^0x//')"
    [[ -n "$cur" && -n "$tgt" ]] || continue
    if (( 16#$tgt <= 16#$cur )) && (( 16#$tgt <= 16#$addr )); then
      return 0
    fi
  done < <(grep -E '[[:space:]]j[a-z]+[[:space:]]+0x[0-9a-f]+' <<<"$1")
  return 1
}

check_object() { # check_object <objfile> <label>
  local OBJ="$1" LABEL="$2" BODY n

  # Vacuous-pass guard.
  [[ "$("$OBJDUMP" -d "$OBJ" 2>/dev/null | grep -cE '^[[:space:]]+[0-9a-f]+:')" -ge 1 ]] \
    || fail "$LABEL: $OBJDUMP produced no instructions; every count below would pass vacuously"

  # vgaPutCellAt: exactly one store, 16-bit.
  BODY="$(body_of_fn "$OBJ" vgaPutCellAt)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for vgaPutCellAt"
  n="$(count_all_stores "$BODY")"
  [[ "$n" -eq 1 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaPutCellAt has $n memory stores, expected exactly 1 — the cell write was deleted or duplicated"; }
  [[ "$(count_stores_16 "$BODY")" -eq 1 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaPutCellAt's store is not the single 16-bit cell write"; }

  # vgaBlankAt: exactly one store, 16-bit.
  BODY="$(body_of_fn "$OBJ" vgaBlankAt)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for vgaBlankAt"
  n="$(count_all_stores "$BODY")"
  [[ "$n" -eq 1 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaBlankAt has $n memory stores, expected exactly 1"; }
  [[ "$(count_stores_16 "$BODY")" -eq 1 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaBlankAt's store is not 16-bit"; }

  # fbPutPixel: exactly one store, 32-bit. (The body also LOADS ordinary
  # memory — the fb state block via mul/add operands — so only stores are
  # counted here.)
  BODY="$(body_of_fn "$OBJ" fbPutPixel)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for fbPutPixel"
  n="$(count_all_stores "$BODY")"
  [[ "$n" -eq 1 ]] || { echo "$BODY" >&2; fail "$LABEL: fbPutPixel has $n memory stores, expected exactly 1 — the pixel write was deleted or duplicated"; }
  [[ "$(count_stores_32 "$BODY")" -eq 1 ]] || { echo "$BODY" >&2; fail "$LABEL: fbPutPixel's store is not the single 32-bit pixel write"; }

  # vgaScroll: 16-bit accesses only, load loop-resident.
  BODY="$(body_of_fn "$OBJ" vgaScroll)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for vgaScroll"
  [[ "$(count_loads_16 "$BODY")" -ge 1 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaScroll has no 16-bit load — the screen read side of the copy was eliminated"; }
  [[ "$(count_stores_16 "$BODY")" -ge 1 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaScroll has no 16-bit store"; }
  [[ "$(count_stores_wide "$BODY")" -eq 0 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaScroll contains a WIDER-than-16-bit memory store — adjacent device cell writes were coalesced, which volatile forbids (this is the exact shape the negative control produces)"; }
  [[ "$(count_loads_wide "$BODY")" -eq 0 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaScroll contains a wide memory load — device cell reads were coalesced"; }
  loop_resident "$BODY" '(movzwl|movw)[[:space:]]+(-?0x[0-9a-f]+)?\(%r[^,]*\), '
  case $? in
    0) : ;;
    1) echo "$BODY" >&2; fail "$LABEL: vgaScroll's cell load was HOISTED out of its loop" ;;
    2) echo "$BODY" >&2; fail "$LABEL: could not locate vgaScroll's cell load for the residency check" ;;
  esac

  # vgaClear: 16-bit stores only, no calls.
  BODY="$(body_of_fn "$OBJ" vgaClear)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for vgaClear"
  [[ "$(count_stores_16 "$BODY")" -ge 1 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaClear has no 16-bit store — the blank writes disappeared"; }
  [[ "$(count_stores_wide "$BODY")" -eq 0 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaClear contains a wide memory store — device stores were coalesced (volatile lost)"; }
  [[ "$(grep -cE '[[:space:]]call' <<<"$BODY")" -eq 0 ]] || { echo "$BODY" >&2; fail "$LABEL: vgaClear contains a call — a memset-shaped transformation replaced the per-cell device stores"; }

  # vmTestRo: the deliberate-fault probe — its one distinctive 0xFF byte
  # store must be in the object. This is the store -O2 provably deletes when
  # it is ordinary (the negative control for it is the measured VM FAULTS
  # 2 -> 1 regression; at the object level the store simply vanishes).
  BODY="$(body_of_fn "$OBJ" vmTestRo)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for vmTestRo"
  [[ "$(grep -cE 'movb[[:space:]]+\$(-0x1|0xff|255), (-?0x[0-9a-f]+)?\(%r' <<<"$BODY")" -ge 1 ]] \
    || { echo "$BODY" >&2; fail "$LABEL: vmTestRo's 0xFF probe store is GONE — the W^X self-test no longer faults, and 'vmtest ro' tests nothing (the VM FAULTS 2->1 regression)"; }

  # vmTestRw: the writable control — the store AND a genuine read-back must
  # both touch memory (forwarding the load would make the control vacuous).
  BODY="$(body_of_fn "$OBJ" vmTestRw)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for vmTestRw"
  [[ "$(grep -cE 'movq[[:space:]]+%r[^,]*, (-?0x[0-9a-f]+)?\(%r' <<<"$BODY")" -ge 1 ]] \
    || { echo "$BODY" >&2; fail "$LABEL: vmTestRw has no 64-bit store — the control never writes the page"; }
  [[ "$(grep -cE 'movq?[[:space:]]+(-?0x[0-9a-f]+)?\(%r[^,]*\), %r' <<<"$BODY")" -ge 1 ]] \
    || { echo "$BODY" >&2; fail "$LABEL: vmTestRw has no 64-bit load — the read-back was forwarded from the store and never touches the page, so the control is vacuous"; }

  # The pmm memory-test class: the pattern/touch stores and the read-back
  # load must all reach memory.
  BODY="$(body_of_fn "$OBJ" shellFramesTest)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for shellFramesTest"
  [[ "$(grep -cE 'movq[[:space:]]+%r[^,]*, (-?0x[0-9a-f]+)?\(%r' <<<"$BODY")" -ge 2 ]] \
    || { echo "$BODY" >&2; fail "$LABEL: shellFramesTest is missing its 64-bit pattern stores — the RW test writes nothing"; }
  BODY="$(body_of_fn "$OBJ" shellFramesDrain)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for shellFramesDrain"
  [[ "$(grep -cE 'movq[[:space:]]+%r[^,]*, (-?0x[0-9a-f]+)?\(%r' <<<"$BODY")" -ge 1 ]] \
    || { echo "$BODY" >&2; fail "$LABEL: shellFramesDrain's mapping-probe touch store is gone — a short identity map would no longer fault"; }
  BODY="$(body_of_fn "$OBJ" pmmCheckWord)"
  if [[ -n "$BODY" ]]; then
    [[ "$(grep -cE 'movq?[[:space:]]+(-?0x[0-9a-f]+)?\(%r[^,]*\), %r' <<<"$BODY")" -ge 1 ]] \
      || { echo "$BODY" >&2; fail "$LABEL: pmmCheckWord has no memory load — every verify-by-readback in pmm is vacuous"; }
  fi

  # uartPutc: the THRE poll — port read present, inside its loop, write kept.
  BODY="$(body_of_fn "$OBJ" uartPutc)"
  [[ -n "$BODY" ]] || fail "$LABEL: no disassembly for uartPutc"
  [[ "$(grep -cE '[[:space:]]inb?[[:space:]]' <<<"$BODY")" -ge 1 ]] || { echo "$BODY" >&2; fail "$LABEL: uartPutc has no port read — the THRE poll never observes the hardware"; }
  [[ "$(grep -cE '[[:space:]]outb?[[:space:]]' <<<"$BODY")" -ge 1 ]] || { echo "$BODY" >&2; fail "$LABEL: uartPutc has no port write"; }
  loop_resident "$BODY" '[[:space:]]inb?[[:space:]]'
  case $? in
    0) : ;;
    1) echo "$BODY" >&2; fail "$LABEL: uartPutc's LSR read was HOISTED out of the THRE poll loop — this wait spins forever on a stale status register" ;;
    2) echo "$BODY" >&2; fail "$LABEL: could not locate uartPutc's port read" ;;
  esac

  # B1 serial receive (only on trees that have it): the IRQ4 drain loop's
  # status poll must re-read the device every iteration.
  if grep -q 'uartEnableRx' "$KERNEL_DIR/uart.dart" 2>/dev/null; then
    BODY="$(body_of_fn "$OBJ" shellSerialIrq)"
    [[ -n "$BODY" ]] || fail "$LABEL: uartEnableRx exists but no disassembly for shellSerialIrq"
    if [[ "$(grep -cE '[[:space:]]inb?[[:space:]]' <<<"$BODY")" -ge 1 ]]; then
      # Inlined: the port read itself must be loop-resident.
      loop_resident "$BODY" '[[:space:]]inb?[[:space:]]'
      case $? in
        0) : ;;
        1) echo "$BODY" >&2; fail "$LABEL: shellSerialIrq's inlined LSR poll was HOISTED out of the drain loop — one interrupt would drain at most one stale status, and the console hangs with bytes waiting in the FIFO" ;;
        2) echo "$BODY" >&2; fail "$LABEL: could not locate shellSerialIrq's port read" ;;
      esac
    else
      # Not inlined: the poll must be an opaque call each iteration, and the
      # callee must really read the port.
      loop_resident "$BODY" '[[:space:]]call[[:space:]].*<uartHasByte>'
      case $? in
        0) : ;;
        1) echo "$BODY" >&2; fail "$LABEL: shellSerialIrq's uartHasByte call was hoisted out of the drain loop" ;;
        2) echo "$BODY" >&2; fail "$LABEL: shellSerialIrq contains neither a port read nor a loop-resident uartHasByte call — the drain loop polls nothing" ;;
      esac
      HB="$(body_of_fn "$OBJ" uartHasByte)"
      [[ -n "$HB" ]] || fail "$LABEL: no disassembly for uartHasByte"
      [[ "$(grep -cE '[[:space:]]inb?[[:space:]]' <<<"$HB")" -ge 1 ]] || { echo "$HB" >&2; fail "$LABEL: uartHasByte contains no port read"; }
    fi
    echo "MMIO-VOLATILE:   $LABEL: B1 serial-receive drain poll is device-re-reading and loop-resident"
  fi

  # D1 PS/2 mouse (only on trees that have it): the controller waits are
  # bounded port polls — each must re-read the status port inside its loop.
  if [[ -f "$KERNEL_DIR/mouse.dart" ]]; then
    local mf
    for mf in mouseWaitInput mouseWaitOutput; do
      BODY="$(body_of_fn "$OBJ" "$mf")"
      [[ -n "$BODY" ]] || fail "$LABEL: mouse.dart exists but no disassembly for $mf"
      [[ "$(grep -cE '[[:space:]]inb?[[:space:]]' <<<"$BODY")" -ge 1 ]] || { echo "$BODY" >&2; fail "$LABEL: $mf has no port read — the controller wait polls nothing"; }
      loop_resident "$BODY" '[[:space:]]inb?[[:space:]]'
      case $? in
        0) : ;;
        1) echo "$BODY" >&2; fail "$LABEL: $mf's status read was HOISTED out of its wait loop — the bounded spin decides on one stale status" ;;
        2) echo "$BODY" >&2; fail "$LABEL: could not locate $mf's port read" ;;
      esac
    done
    echo "MMIO-VOLATILE:   $LABEL: D1 PS/2 controller waits are device-re-reading and loop-resident"
  fi

  echo "MMIO-VOLATILE:   $LABEL: all per-site access counts, widths and loop residencies hold at -O2"
}

check_object "$WORKDIR/kmain.o" "probe object"

if [[ -f "$LINK_DIR/kmain.o" ]]; then
  check_object "$LINK_DIR/kmain.o" "shipped build/kmain.o"
else
  echo "MMIO-VOLATILE:   note: build/kmain.o not present (run core/scripts/build-kernel.sh to also pin the shipped object); probe object verified"
fi
echo "MMIO-VOLATILE: step 3 ok"

# ---------------------------------------------------------------------------
# Step 4 — NEGATIVE CONTROL. Strip volatile, recompile, REQUIRE the detector
# to fail: vgaClear's adjacent 16-bit device stores must coalesce into at
# least one wide (movq) store, the exact defect step 3 rejects.
# ---------------------------------------------------------------------------
sed -e 's/load volatile/load/' -e 's/store volatile/store/' \
  "$WORKDIR/kmain.ll" >"$WORKDIR/kmain_novol.ll"
grep -q 'volatile' "$WORKDIR/kmain_novol.ll" \
  && fail "negative control setup: could not strip volatile from the IR"
clang "${CLANG_FLAGS[@]}" -c "$WORKDIR/kmain_novol.ll" -o "$WORKDIR/kmain_novol.o" \
  >"$WORKDIR/ccnv.log" 2>&1 || { cat "$WORKDIR/ccnv.log" >&2; fail "negative control: clang -O2 could not compile the stripped IR"; }

NV_BODY="$(body_of_fn "$WORKDIR/kmain_novol.o" vgaClear)"
[[ -n "$NV_BODY" ]] || fail "negative control: no disassembly for vgaClear in the stripped object"
NV_WIDE="$(count_stores_wide "$NV_BODY")"
if [[ "$NV_WIDE" -lt 1 ]]; then
  echo "$NV_BODY" >&2
  fail "NEGATIVE CONTROL INCONCLUSIVE: with volatile stripped, -O2 kept vgaClear's stores 16-bit (0 wide stores). The width detector in step 3 is currently unfalsifiable by this method — the optimizer no longer coalesces the unprotected stores — so a future volatile regression would NOT be caught there. Redesign the detector before trusting a green run."
fi
echo "MMIO-VOLATILE: step 4 ok — negative control: stripping volatile makes -O2 coalesce vgaClear's device stores into $NV_WIDE wide store(s), so the step-3 detector is demonstrably able to fail"

echo "MMIO-VOLATILE: PASS — all nine migrated functions survive -O2 per site (IR keyword + exact object-level counts/widths + loop residency), the volatile inventory is exhaustive (ordinary Pointer<T> emits zero volatile ops), port-I/O polls are loop-resident, and the negative control proves the detector can fail"
exit 0
