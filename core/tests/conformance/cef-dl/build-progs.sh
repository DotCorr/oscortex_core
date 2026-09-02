#!/usr/bin/env bash
# cef-dl: PLAT.ELF with real DT_NEEDED libdl.so.2 + OUR LIBDL.SO face.
# Soname is NOT an 8.3 string. ADR-0174. Not glibc. Not OnPaint.

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

clang "${SO_CFLAGS[@]}" "$SCRIPT_DIR/libdl.c" -o "$OUT/libdl.o" \
  || fail "clang could not compile libdl.c"
x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
  -soname=libdl.so.2 -T "$SCRIPT_DIR/libdl.ld" \
  -o "$OUT/libdl.so" "$OUT/libdl.o" \
  || fail "x86_64-elf-ld could not link libdl.so"
[[ -s "$OUT/libdl.so" ]] || fail "no libdl.so"
x86_64-elf-readelf -hW "$OUT/libdl.so" | grep -q "DYN (Shared object" \
  || fail "libdl.so is not ET_DYN"
x86_64-elf-nm "$OUT/libdl.so" | grep -qE " [Tt] dl_fn$" \
  || fail "libdl.so has no exported dl_fn"
x86_64-elf-readelf -dW "$OUT/libdl.so" | grep -q '\[libdl\.so\.2\]' \
  || fail "libdl.so SONAME is not libdl.so.2"
x86_64-elf-readelf -lW "$OUT/libdl.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "libdl.so has a W+X segment"
x86_64-elf-readelf -lW "$OUT/libdl.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
  || fail "libdl.so has no RX LOAD"

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
  -o "$OUT/plat.elf" "$OUT/plat.o" "$OUT/libdl.so" \
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

mapfile -t NEEDED_ARR < <(x86_64-elf-readelf -dW "$OUT/plat.elf" \
  | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]')
[[ "${#NEEDED_ARR[@]}" -eq 1 ]] || fail "DT_NEEDED count is ${#NEEDED_ARR[@]}, expected 1"
[[ "${NEEDED_ARR[0]}" == "libdl.so.2" ]] \
  || fail "DT_NEEDED is ${NEEDED_ARR[0]}, not libdl.so.2 (must be real Linux soname)"

# Must NOT plant the 8.3 stand-in as the NEEDED string.
strings -a "$OUT/plat.elf" | grep -q 'libdl.so.2' \
  || fail "plat.elf lost libdl.so.2 string"
x86_64-elf-readelf -dW "$OUT/plat.elf" | grep -q '\[LIBDL\.SO\]' \
  && fail "plat.elf DT_NEEDED is still LIBDL.SO — not the real soname door"

strings -a "$OUT/plat.elf" | grep -q 'CEFDL START' \
  || fail "plat.elf lost CEFDL START"
strings -a "$OUT/plat.elf" | grep -q 'VIA LIBDL.SO.2' \
  || fail "plat.elf lost VIA LIBDL.SO.2"

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
DBYTES=$(wc -c <"$OUT/libdl.so" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — cap is 64 KiB"
[[ "$DBYTES" -le 65536 ]] || fail "libdl.so is $DBYTES bytes — cap is 64 KiB"

# SOMAP body for the image (planted as SOMAP.TXT).
printf 'libdl.so.2=LIBDL.SO\n' >"$OUT/somap.txt"
[[ "$(wc -c <"$OUT/somap.txt" | tr -d ' ')" -ge 12 ]] || fail "somap.txt too short"

echo "build-progs: PASS — plat.elf $BYTES (DT_NEEDED=libdl.so.2), libdl $DBYTES, somap ready"
exit 0
