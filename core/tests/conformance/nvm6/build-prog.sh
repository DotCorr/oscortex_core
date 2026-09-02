#!/usr/bin/env bash
# core/tests/conformance/nvm6/build-prog.sh
#
# Builds one freestanding PROG.ELF whose write string and exit code
# are passed in. The harness derives both at test time.
#
# Usage: build-prog.sh <outdir> <stem> <32-hex-magic> <exit-hex>
#        -> <outdir>/<stem>.elf

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "build-prog: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-prog: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
STEM="${2:-}"
MAGIC="${3:-}"
EXIT_HEX="${4:-}"
[[ -n "$OUT" && -n "$STEM" && -n "$MAGIC" && -n "$EXIT_HEX" ]] \
  || setup_error "usage: build-prog.sh <outdir> <stem> <32-hex-magic> <exit-hex>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

[[ ${#MAGIC} -eq 32 ]] || setup_error "magic must be 32 hex chars, got ${#MAGIC}"
[[ "$MAGIC" =~ ^[0-9A-Fa-f]{32}$ ]] || setup_error "magic is not hex: $MAGIC"

for tool in clang x86_64-elf-ld x86_64-elf-readelf x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

CFLAGS=(
  -c
  -target x86_64-unknown-none-elf
  -ffreestanding
  -nostdlib
  -fno-pic
  -fno-pie
  -mgeneral-regs-only
  -mno-red-zone
  -fno-stack-protector
  -fno-asynchronous-unwind-tables
  -fno-builtin
  -O2
  -Wall
  -Wextra
  -Werror
  -DMAGIC_HEX="\"$MAGIC\""
  -DEXIT_CODE="0x$EXIT_HEX"
)

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/$STEM.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/$STEM.elf" "$OUT/$STEM.o" \
  || fail "x86_64-elf-ld could not link $STEM.elf"
[[ -s "$OUT/$STEM.elf" ]] || fail "linker reported success but produced no $STEM.elf"

x86_64-elf-readelf -lW "$OUT/$STEM.elf" | grep -q "INTERP" \
  && fail "$STEM.elf has a PT_INTERP — elf.dart refuses it by name"
x86_64-elf-readelf -lW "$OUT/$STEM.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "$STEM.elf has a W+X segment — elf.dart refuses it by name"
x86_64-elf-readelf -lW "$OUT/$STEM.elf" | grep -E 'LOAD[[:space:]]+0x[0-9a-f]+[[:space:]]+0x0+[[:space:]]' \
  && fail "$STEM.elf has a PT_LOAD at vaddr 0 — empty data PHDR (elfErrCongruence)"
x86_64-elf-objdump -d "$OUT/$STEM.elf" | grep -Eiq 'xmm|movaps|movdqa|addps' \
  && fail "$STEM.elf contains SSE — this machine has no OSFXSR (GAP-0092)"

BYTES=$(wc -c <"$OUT/$STEM.elf" | tr -d ' ')
echo "build-prog: PASS — $OUT/$STEM.elf ($BYTES bytes) MAGIC=$MAGIC EXIT=$EXIT_HEX"
exit 0
