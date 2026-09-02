#!/usr/bin/env bash
# plat-dyn: a named platform ELF with PT_INTERP, plus our LD.SO.
# Not glibc. Not libc.so.6.

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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/dyn.c" -o "$OUT/dyn.o" \
  || fail "clang could not compile dyn.c"
x86_64-elf-ld -T "$SCRIPT_DIR/dyn.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/plat.elf" "$OUT/dyn.o" \
  || fail "x86_64-elf-ld could not link plat.elf"
[[ -s "$OUT/plat.elf" ]] || fail "linker reported success but produced no plat.elf"

clang "${CFLAGS[@]}" "$SCRIPT_DIR/ld.c" -o "$OUT/ld.o" \
  || fail "clang could not compile ld.c"
x86_64-elf-ld -T "$SCRIPT_DIR/ld.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/ld.so" "$OUT/ld.o" \
  || fail "x86_64-elf-ld could not link ld.so"
[[ -s "$OUT/ld.so" ]] || fail "linker reported success but produced no ld.so"

x86_64-elf-readelf -lW "$OUT/plat.elf" | grep -q "INTERP" \
  || fail "plat.elf has no PT_INTERP"
x86_64-elf-readelf -lW "$OUT/plat.elf" | grep -q "DYNAMIC" \
  && fail "plat.elf has PT_DYNAMIC — this door is not libc"
x86_64-elf-readelf -lW "$OUT/plat.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "plat.elf has a W+X segment"

x86_64-elf-readelf -lW "$OUT/ld.so" | grep -q "INTERP" \
  && fail "ld.so has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/ld.so" | grep -q "DYNAMIC" \
  && fail "ld.so has PT_DYNAMIC — must not be glibc"
x86_64-elf-readelf -lW "$OUT/ld.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "ld.so has a W+X segment"

INTERP_PATH=$(x86_64-elf-readelf -p .interp "$OUT/plat.elf" 2>/dev/null \
  | awk '/LD\.SO/{print $3; exit}')
[[ "$INTERP_PATH" == "LD.SO" ]] \
  || fail "plat.elf PT_INTERP is ${INTERP_PATH:-empty}, expected LD.SO"

strings -a "$OUT/ld.so" | grep -q 'INTERP MAP' \
  || fail "ld.so lost INTERP MAP"
strings -a "$OUT/plat.elf" | grep -q 'DYN LINE' \
  || fail "plat.elf lost DYN LINE"
strings -a "$OUT/ld.so" | grep -q 'DYN LINE' \
  && fail "ld.so contains DYN LINE — derived write must come from the dyn"
strings -a "$OUT/plat.elf" | grep -q 'INTERP MAP' \
  && fail "plat.elf contains INTERP MAP — interp write must come from ld.so"

PBYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
LBYTES=$(wc -c <"$OUT/ld.so" | tr -d ' ')
[[ "$PBYTES" -le 65536 ]] || fail "plat.elf is $PBYTES bytes — cap is 64 KiB"
[[ "$LBYTES" -le 65536 ]] || fail "ld.so is $LBYTES bytes — cap is 64 KiB"
[[ "$LBYTES" -le 8192 ]] || fail "ld.so is $LBYTES bytes — a tiny loader, not glibc"

echo "build-progs: PASS — plat.elf $PBYTES bytes (PT_INTERP LD.SO), ld.so $LBYTES bytes"
exit 0
