#!/usr/bin/env bash
# core/tests/conformance/mmap-file/build-progs.sh
#
# Freestanding PROG for ADR-0164 (no oslibc — shmfile unnamed).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

CFLAGS=(
  -c
  -target x86_64-unknown-none-elf
  -ffreestanding
  -nostdlib
  -fno-pic
  -fno-pie
  -mno-red-zone
  -fno-stack-protector
  -fno-asynchronous-unwind-tables
  -fno-builtin
  -O2
  -Wall
  -Wextra
  -Werror
)

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/prog.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/prog.elf" "$OUT/prog.o" \
  || fail "x86_64-elf-ld could not link prog.elf"
[[ -s "$OUT/prog.elf" ]] || fail "no prog.elf"
x86_64-elf-readelf -lW "$OUT/prog.elf" | grep -q "INTERP" \
  && fail "prog.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/prog.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "prog.elf has a W+X segment"
grep -q 'SYS_SHMFILE' "$SCRIPT_DIR/prog.c" || fail "prog.c never names SYS_SHMFILE"
grep -q 'PLANT.DAT' "$SCRIPT_DIR/prog.c" || fail "prog.c never opens PLANT.DAT"
BYTES=$(wc -c <"$OUT/prog.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/prog.elf ($BYTES bytes)"
exit 0
