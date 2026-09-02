#!/usr/bin/env bash
# plat-need2: PLAT.ELF with four DT_NEEDED + OUR LIBC/LIBM/LIBDL/LIBPT.
# Not glibc. Not libcef. ADR-0160.

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

build_so() {
  local src="$1" ld="$2" soname="$3" export="$4" outbase="$5"
  clang "${SO_CFLAGS[@]}" "$SCRIPT_DIR/$src" -o "$OUT/${outbase}.o" \
    || fail "clang could not compile $src"
  x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
    -soname="$soname" -T "$SCRIPT_DIR/$ld" \
    -o "$OUT/${outbase}.so" "$OUT/${outbase}.o" \
    || fail "x86_64-elf-ld could not link ${outbase}.so"
  [[ -s "$OUT/${outbase}.so" ]] || fail "no ${outbase}.so"
  x86_64-elf-readelf -hW "$OUT/${outbase}.so" | grep -q "DYN (Shared object" \
    || fail "${outbase}.so is not ET_DYN"
  x86_64-elf-nm "$OUT/${outbase}.so" | grep -qE " [Tt] ${export}$" \
    || fail "${outbase}.so has no exported ${export}"
  x86_64-elf-readelf -lW "$OUT/${outbase}.so" | awk '$1=="LOAD"' | grep -q "RWE" \
    && fail "${outbase}.so has a W+X segment"
  x86_64-elf-readelf -lW "$OUT/${outbase}.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
    || fail "${outbase}.so has no RX LOAD"
}

build_so libc.c libc.ld LIBC.SO write libc
build_so libm.c libm.ld LIBM.SO need_fn libm
build_so libdl.c libdl.ld LIBDL.SO dl_fn libdl
build_so libpt.c libpt.ld LIBPT.SO pt_fn libpt

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
  -o "$OUT/plat.elf" "$OUT/plat.o" \
  "$OUT/libc.so" "$OUT/libm.so" "$OUT/libdl.so" "$OUT/libpt.so" \
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
[[ "${#NEEDED_ARR[@]}" -eq 4 ]] || fail "DT_NEEDED count is ${#NEEDED_ARR[@]}, expected 4"
[[ "${NEEDED_ARR[0]}" == "LIBC.SO" ]] || fail "first DT_NEEDED is ${NEEDED_ARR[0]}, not LIBC.SO"
[[ "${NEEDED_ARR[1]}" == "LIBM.SO" ]] || fail "second DT_NEEDED is ${NEEDED_ARR[1]}, not LIBM.SO"
[[ "${NEEDED_ARR[2]}" == "LIBDL.SO" ]] || fail "third DT_NEEDED is ${NEEDED_ARR[2]}, not LIBDL.SO"
[[ "${NEEDED_ARR[3]}" == "LIBPT.SO" ]] || fail "fourth DT_NEEDED is ${NEEDED_ARR[3]}, not LIBPT.SO"

strings -a "$OUT/plat.elf" | grep -q 'NEED2 START' \
  || fail "plat.elf lost NEED2 START"
strings -a "$OUT/plat.elf" | grep -q 'VIA LIBC' \
  || fail "plat.elf lost VIA LIBC"
strings -a "$OUT/plat.elf" | grep -q 'VIA LIBM' \
  || fail "plat.elf lost VIA LIBM"
strings -a "$OUT/plat.elf" | grep -q 'VIA LIBDL' \
  || fail "plat.elf lost VIA LIBDL"
strings -a "$OUT/plat.elf" | grep -q 'VIA LIBPT' \
  || fail "plat.elf lost VIA LIBPT"

# Cross-export hygiene: each face lives in exactly one stand-in.
x86_64-elf-nm "$OUT/libc.so" | grep -qE ' [Tt] (need_fn|dl_fn|pt_fn)$' \
  && fail "libc.so must not export other faces"
x86_64-elf-nm "$OUT/libm.so" | grep -qE ' [Tt] (write|dl_fn|pt_fn)$' \
  && fail "libm.so must not export other faces"
x86_64-elf-nm "$OUT/libdl.so" | grep -qE ' [Tt] (write|need_fn|pt_fn)$' \
  && fail "libdl.so must not export other faces"
x86_64-elf-nm "$OUT/libpt.so" | grep -qE ' [Tt] (write|need_fn|dl_fn)$' \
  && fail "libpt.so must not export other faces"

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
CBYTES=$(wc -c <"$OUT/libc.so" | tr -d ' ')
MBYTES=$(wc -c <"$OUT/libm.so" | tr -d ' ')
DBYTES=$(wc -c <"$OUT/libdl.so" | tr -d ' ')
PBYTES=$(wc -c <"$OUT/libpt.so" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — cap is 64 KiB"
[[ "$CBYTES" -le 65536 ]] || fail "libc.so is $CBYTES bytes — cap is 64 KiB"
[[ "$MBYTES" -le 65536 ]] || fail "libm.so is $MBYTES bytes — cap is 64 KiB"
[[ "$DBYTES" -le 65536 ]] || fail "libdl.so is $DBYTES bytes — cap is 64 KiB"
[[ "$PBYTES" -le 65536 ]] || fail "libpt.so is $PBYTES bytes — cap is 64 KiB"

echo "build-progs: PASS — plat.elf $BYTES (4 DT_NEEDED), libc $CBYTES, libm $MBYTES, libdl $DBYTES, libpt $PBYTES"
exit 0
