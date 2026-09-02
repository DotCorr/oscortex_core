#!/usr/bin/env bash
# plat-need: PLAT.ELF with two DT_NEEDED + OUR LIBC.SO + LIBM.SO.
# Not glibc. Not libcef.

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
  -soname=LIBC.SO -T "$SCRIPT_DIR/libc.ld" \
  -o "$OUT/libc.so" "$OUT/libc.o" \
  || fail "x86_64-elf-ld could not link libc.so"
[[ -s "$OUT/libc.so" ]] || fail "no libc.so"
x86_64-elf-readelf -hW "$OUT/libc.so" | grep -q "DYN (Shared object" \
  || fail "libc.so is not ET_DYN"
x86_64-elf-nm "$OUT/libc.so" | grep -qE ' [Tt] write$' \
  || fail "libc.so has no exported write"
x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "libc.so has a W+X segment"
x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
  || fail "libc.so has no RX LOAD"

clang "${SO_CFLAGS[@]}" "$SCRIPT_DIR/libm.c" -o "$OUT/libm.o" \
  || fail "clang could not compile libm.c"
x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
  -soname=LIBM.SO -T "$SCRIPT_DIR/libm.ld" \
  -o "$OUT/libm.so" "$OUT/libm.o" \
  || fail "x86_64-elf-ld could not link libm.so"
[[ -s "$OUT/libm.so" ]] || fail "no libm.so"
x86_64-elf-readelf -hW "$OUT/libm.so" | grep -q "DYN (Shared object" \
  || fail "libm.so is not ET_DYN"
x86_64-elf-nm "$OUT/libm.so" | grep -qE ' [Tt] need_fn$' \
  || fail "libm.so has no exported need_fn"
x86_64-elf-readelf -lW "$OUT/libm.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "libm.so has a W+X segment"
x86_64-elf-readelf -lW "$OUT/libm.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
  || fail "libm.so has no RX LOAD"

PROG_CFLAGS=(
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

clang "${PROG_CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/plat.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  --no-dynamic-linker --no-as-needed \
  -o "$OUT/plat.elf" "$OUT/plat.o" "$OUT/libc.so" "$OUT/libm.so" \
  || fail "x86_64-elf-ld could not link plat.elf"
[[ -s "$OUT/plat.elf" ]] || fail "no plat.elf"

x86_64-elf-readelf -lW "$OUT/plat.elf" | grep -q "INTERP" \
  && fail "plat.elf has a PT_INTERP — walk NEEDED without LD.SO"
x86_64-elf-readelf -lW "$OUT/plat.elf" | grep -q "DYNAMIC" \
  || fail "plat.elf has no PT_DYNAMIC"
x86_64-elf-readelf -lW "$OUT/plat.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "plat.elf has a W+X segment"
x86_64-elf-readelf -h "$OUT/plat.elf" | grep -q "EXEC" \
  || fail "plat.elf is not ET_EXEC"

NEEDED=$(x86_64-elf-readelf -dW "$OUT/plat.elf" | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]')
echo "$NEEDED" | grep -qx 'LIBC.SO' || fail "first DT_NEEDED is not LIBC.SO"
echo "$NEEDED" | grep -qx 'LIBM.SO' || fail "second DT_NEEDED is not LIBM.SO"
NCOUNT=$(echo "$NEEDED" | grep -c . || true)
[[ "$NCOUNT" -eq 2 ]] || fail "DT_NEEDED count is $NCOUNT, expected 2"

# Names must come from DT_NEEDED — prog must not hardcode the second call
# path as a string that bypasses the walk for LINE2.
strings -a "$OUT/plat.elf" | grep -q 'NEED START' \
  || fail "plat.elf lost NEED START"
strings -a "$OUT/plat.elf" | grep -q 'VIA LIBC' \
  || fail "plat.elf lost VIA LIBC"
strings -a "$OUT/plat.elf" | grep -q 'VIA LIBM' \
  || fail "plat.elf lost VIA LIBM"
strings -a "$OUT/libc.so" | grep -q 'need_fn' \
  && fail "libc.so must not export need_fn"
strings -a "$OUT/libm.so" | grep -qE '^write$' \
  && fail "libm.so must not export write"

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
CBYTES=$(wc -c <"$OUT/libc.so" | tr -d ' ')
MBYTES=$(wc -c <"$OUT/libm.so" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — cap is 64 KiB"
[[ "$CBYTES" -le 65536 ]] || fail "libc.so is $CBYTES bytes — cap is 64 KiB"
[[ "$MBYTES" -le 65536 ]] || fail "libm.so is $MBYTES bytes — cap is 64 KiB"

echo "build-progs: PASS — plat.elf $BYTES (2 DT_NEEDED), libc.so $CBYTES, libm.so $MBYTES"
exit 0
