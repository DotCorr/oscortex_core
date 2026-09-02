#!/usr/bin/env bash
# Regression coverage for the semantic DCDart gate used by Mac boot scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROBE="$CORE_DIR/scripts/verify-dcdart-compat.sh"

fail() { echo "DCDART-COMPAT: FAIL — $1" >&2; exit 1; }
[[ -f "$PROBE" ]] || fail "missing $PROBE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-dcdart-compat-test.XXXXXX")" \
  || fail "could not create temp directory"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/toolchain/core/dcc/bin" \
  "$WORK/toolchain/core/runtime/dc-core-bare"
: >"$WORK/toolchain/core/dcc/bin/dcc.dart"
: >"$WORK/toolchain/core/runtime/dc-core-bare/prelude.dart"

cat >"$WORK/bin/dart" <<'SH'
#!/usr/bin/env bash
set -eu
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi
done
[[ -n "$out" ]]
asm="${out}.s"
if [[ "${FAKE_DCDART_BAD:-0}" == 1 ]]; then
  cat >"$asm" <<'ASM'
.text
.globl oscortexDcdartCompatProbe
.type oscortexDcdartCompatProbe,@function
oscortexDcdartCompatProbe:
  xorl %eax, %eax
  ret
ASM
else
  cat >"$asm" <<'ASM'
.text
.globl oscortexDcdartCompatProbe
.type oscortexDcdartCompatProbe,@function
oscortexDcdartCompatProbe:
  movabsq $0xFEE00030, %rax
  movl $0x13579BDF, (%rax)
  movl $0x2468ACE0, (%rax)
  movl (%rax), %ecx
  movl (%rax), %eax
  addl %ecx, %eax
  ret
.section .rodata
.type oscortexCompatRodata,@object
.size oscortexCompatRodata,1
oscortexCompatRodata:
  .byte 0xA5
ASM
fi
clang -c -target x86_64-unknown-none-elf "$asm" -o "$out"
SH
chmod +x "$WORK/bin/dart"

PATH="$WORK/bin:$PATH" bash "$PROBE" "$WORK/toolchain" >"$WORK/good.log" 2>&1 \
  || { cat "$WORK/good.log" >&2; fail "compatible compiler fixture was rejected"; }
grep -q 'dcdart-compat: PASS' "$WORK/good.log" \
  || fail "compatible fixture emitted no PASS token"

if FAKE_DCDART_BAD=1 PATH="$WORK/bin:$PATH" \
  bash "$PROBE" "$WORK/toolchain" >"$WORK/bad.log" 2>&1; then
  fail "compiler fixture without Volatile/@rodata semantics was accepted"
fi
grep -Eq 'unused one-byte @rodata|Volatile accesses' "$WORK/bad.log" \
  || { cat "$WORK/bad.log" >&2; fail "negative fixture failed for the wrong reason"; }

grep -q 'bash "$COMPAT_PROBE" "$DCDART_HOME"' "$CORE_DIR/scripts/build-kernel.sh" \
  || fail "strict kernel build is not wired to the compatibility probe"
grep -q 'probing candidate' "$CORE_DIR/scripts/verify-de-mac.sh" \
  || fail "Mac auto-discovery does not probe non-pin candidates"

echo "DCDART-COMPAT: PASS — compatible dirty/local compilers pass by semantics; incomplete compilers fail"
