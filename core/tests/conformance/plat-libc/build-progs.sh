#!/usr/bin/env bash
# ONE freestanding ELF (two FAT names) + OUR tiny LIBC.SO.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf x86_64-elf-nm; do
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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/plat.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/plat.elf" "$OUT/plat.o" \
  || fail "x86_64-elf-ld could not link plat.elf"
[[ -s "$OUT/plat.elf" ]] || fail "linker reported success but produced no plat.elf"

x86_64-elf-readelf -lW "$OUT/plat.elf" | grep -q "INTERP" \
  && fail "plat.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/plat.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "plat.elf has a W+X segment"

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — app ELF cap is 64 KiB"

SO_CFLAGS=(
  -c
  -target x86_64-unknown-none-elf
  -ffreestanding
  -nostdlib
  -fPIC
  -fno-stack-protector
  -fno-asynchronous-unwind-tables
  -fno-builtin
  -O2
  -Wall
  -Wextra
  -Werror
)
clang "${SO_CFLAGS[@]}" "$SCRIPT_DIR/libc.c" -o "$OUT/libc.o" \
  || fail "clang could not compile libc.c"
x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
  -T "$SCRIPT_DIR/libc.ld" \
  -o "$OUT/libc.so" "$OUT/libc.o" \
  || fail "x86_64-elf-ld could not link libc.so"
[[ -s "$OUT/libc.so" ]] || fail "no libc.so"
x86_64-elf-readelf -hW "$OUT/libc.so" | grep -q "DYN (Shared object" \
  || fail "libc.so is not ET_DYN"
x86_64-elf-nm "$OUT/libc.so" | grep -qE ' [Tt] write$' \
  || fail "libc.so has no exported write"
x86_64-elf-readelf -dW "$OUT/libc.so" | grep -q '(HASH)' \
  || fail "libc.so has no DT_HASH"
x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "libc.so has a W+X segment"
x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
  || fail "libc.so has no RX LOAD — call would be NX"
SO_BYTES=$(wc -c <"$OUT/libc.so" | tr -d ' ')
[[ "$SO_BYTES" -le 65536 ]] || fail "libc.so is $SO_BYTES bytes — image cap is 64 KiB"

echo "build-progs: PASS — $OUT/plat.elf ($BYTES bytes) + libc.so ($SO_BYTES bytes)"
exit 0
