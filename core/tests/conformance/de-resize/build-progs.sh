#!/usr/bin/env bash
# core/tests/conformance/de-resize/build-progs.sh
#
# WIN.ELF — resident window for SE-corner resize.

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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/win.c" -o "$OUT/win.o" \
  || fail "clang could not compile win.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/win.elf" "$OUT/win.o" \
  || fail "x86_64-elf-ld could not link win.elf"
[[ -s "$OUT/win.elf" ]] || fail "linker reported success but produced no win.elf"
x86_64-elf-readelf -lW "$OUT/win.elf" | grep -q "INTERP" \
  && fail "win.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/win.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "win.elf has a W+X segment"
x86_64-elf-readelf -lW "$OUT/win.elf" | grep -E 'LOAD[[:space:]]+0x[0-9a-f]+[[:space:]]+0x0+[[:space:]]' \
  && fail "win.elf has a PT_LOAD at vaddr 0 — empty data PHDR"

grep -q 'SYS_YIELD' "$SCRIPT_DIR/win.c" \
  || fail "win.c never yields — residency needs the idle gate a tick"
grep -q 'DE RS COMMIT' "$SCRIPT_DIR/win.c" \
  || fail "win.c does not contain DE RS COMMIT"

BYTES=$(wc -c <"$OUT/win.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/win.elf ($BYTES bytes)"
exit 0
