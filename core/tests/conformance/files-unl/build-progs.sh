#!/usr/bin/env bash
# core/tests/conformance/files-unl/build-progs.sh
#
# One freestanding PROG.ELF linked against oslibc (unlink / rename).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
[[ -d "$LIBC_DIR" ]] || setup_error "no libc at $LIBC_DIR"

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
  -I"$LIBC_DIR"
)

LIBC_SRCS=(syscall.c string.c malloc.c printf.c)
objs=()
for s in "${LIBC_SRCS[@]}"; do
  clang "${CFLAGS[@]}" -DLIBC_FREE_ENABLED=1 "$LIBC_DIR/$s" \
    -o "$OUT/${s%.c}.o" || fail "clang could not compile libc/$s"
  objs+=("$OUT/${s%.c}.o")
done
clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/prog.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/prog.elf" "$OUT/prog.o" "${objs[@]}" \
  || fail "x86_64-elf-ld could not link prog.elf"
[[ -s "$OUT/prog.elf" ]] || fail "no prog.elf"
x86_64-elf-readelf -lW "$OUT/prog.elf" | grep -q "INTERP" \
  && fail "prog.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/prog.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "prog.elf has a W+X segment"
grep -q 'unlink(' "$SCRIPT_DIR/prog.c" || fail "prog.c never calls unlink"
grep -q 'rename(' "$SCRIPT_DIR/prog.c" || fail "prog.c never calls rename"
grep -q 'SYS_UNLINK' "$LIBC_DIR/oslibc.h" || fail "oslibc.h has no SYS_UNLINK"
grep -q 'SYS_RENAME' "$LIBC_DIR/oslibc.h" || fail "oslibc.h has no SYS_RENAME"
BYTES=$(wc -c <"$OUT/prog.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/prog.elf ($BYTES bytes)"
exit 0
