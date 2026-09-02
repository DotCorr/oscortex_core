#!/usr/bin/env bash
# Compile and inspect the DCDart features that are load-bearing for this kernel.
#
# This is intentionally a semantic compatibility check, not a version check.
# DCDART_PIN.txt once named a compiler commit that was later rewritten out of
# the public repository.  A Mac may still have that compiler (including as a
# dirty local checkout), so rejecting it by Git identity alone makes a known
# good toolchain impossible to use.

set -uo pipefail

say() { printf 'dcdart-compat: %s\n' "$*"; }
fail() { printf 'dcdart-compat: FAIL — %s\n' "$*" >&2; exit 1; }

DCDART_HOME="${1:-${DCDART_HOME:-}}"
[[ -n "$DCDART_HOME" ]] || fail "usage: $0 /path/to/DCDart"
[[ -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]] \
  || fail "$DCDART_HOME has no core/dcc/bin/dcc.dart"
PRELUDE="$DCDART_HOME/core/runtime/dc-core-bare/prelude.dart"
[[ -f "$PRELUDE" ]] || fail "$DCDART_HOME has no bare prelude"

for tool in dart clang python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found on PATH"
done

OBJDUMP=""
for tool in x86_64-elf-objdump llvm-objdump objdump; do
  if command -v "$tool" >/dev/null 2>&1; then
    OBJDUMP="$tool"
    break
  fi
done
[[ -n "$OBJDUMP" ]] || fail "no ELF objdump found"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-dcdart-compat.XXXXXX")" \
  || fail "could not create temporary directory"
trap 'rm -rf "$WORK"' EXIT
ln -s "$DCDART_HOME" "$WORK/dcdart" || fail "could not create probe toolchain link"

cat >"$WORK/probe.dart" <<'DART'
import 'dcdart/core/runtime/dc-core-bare/prelude.dart';

// This deliberately has no source-level reference.  The kernel contains
// one-byte @rodata globals whose addresses are consumed after lowering; the
// compiler must pin them through LLVM GlobalDCE.
@rodata
final List<u8> oscortexCompatRodata = const [u8(0xA5)];

@bare
u64 oscortexDcdartCompatProbe() {
  final u64 address = u64(0xFEE00030);
  Volatile<u32>.fromAddress(address).value = u32(0x13579BDF);
  Volatile<u32>.fromAddress(address).value = u32(0x2468ACE0);
  return Volatile<u32>.fromAddress(address).value.toU64() +
      Volatile<u32>.fromAddress(address).value.toU64();
}
DART

BUILD_LOG="$WORK/build.log"
(
  cd "$WORK"
  dart "$DCDART_HOME/core/dcc/bin/dcc.dart" build \
    --mode bare --target bare-x86_64 \
    --prelude "$WORK/dcdart/core/runtime/dc-core-bare/prelude.dart" \
    probe.dart -o "$WORK/probe.o"
) >"$BUILD_LOG" 2>&1 || {
  cat "$BUILD_LOG" >&2
  fail "compiler cannot build the Volatile/@rodata compatibility probe"
}
[[ -s "$WORK/probe.o" ]] || fail "probe compiler produced no object"

"$OBJDUMP" -t "$WORK/probe.o" >"$WORK/symbols.txt" 2>&1 \
  || fail "$OBJDUMP could not read the probe symbol table"
grep -Eq '[[:space:]]oscortexCompatRodata$' "$WORK/symbols.txt" \
  || fail "unused one-byte @rodata was removed (missing llvm.compiler.used semantics)"

"$OBJDUMP" -d "$WORK/probe.o" >"$WORK/disassembly.txt" 2>&1 \
  || fail "$OBJDUMP could not disassemble the probe"
python3 - "$WORK/disassembly.txt" <<'PY' || exit 1
import re
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(
    r"<_?oscortexDcdartCompatProbe>:\n(.*?)(?=\n[0-9a-fA-F]+ <|\Z)",
    text,
    re.S,
)
if not m:
    raise SystemExit(
        "dcdart-compat: FAIL — exported compatibility function is absent"
    )
body = m.group(1)
if re.search(r"\b(?:xmm|ymm|zmm)[0-9]+\b", body, re.I):
    raise SystemExit(
        "dcdart-compat: FAIL — freestanding probe uses FP/SIMD registers"
    )
# At -O2, ordinary accesses collapse these two stores and two reads.  A real
# Volatile lowering leaves at least four instructions with memory operands.
memory_ops = [
    line
    for line in body.splitlines()
    if re.search(r"\([^)]*\)|\[[^]]*\]", line)
    and re.search(r"\b(?:mov|add|ldr|str)", line, re.I)
]
if len(memory_ops) < 4:
    raise SystemExit(
        "dcdart-compat: FAIL — Volatile accesses were optimized/merged "
        f"(only {len(memory_ops)} memory operations remain)"
    )
PY

DESC="$(git -C "$DCDART_HOME" rev-parse --short HEAD 2>/dev/null || echo non-git)"
DIRTY=""
if [[ -n "$(git -C "$DCDART_HOME" status --porcelain 2>/dev/null)" ]]; then
  DIRTY=" +DIRTY"
fi
say "PASS — $DCDART_HOME @ ${DESC}${DIRTY}: Volatile stores/loads survive -O2, @rodata survives GlobalDCE, no FP/SIMD"
