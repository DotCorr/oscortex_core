#!/usr/bin/env bash
# plat-need4: PLAT.ELF with sixteen DT_NEEDED + OUR stand-ins.
# Not glibc. Not libcef. ADR-0163.

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
build_so libgb.c libgb.ld LIBGB.SO gb_fn libgb
build_so libgo.c libgo.ld LIBGO.SO go_fn libgo
build_so libnp.c libnp.ld LIBNP.SO np_fn libnp
build_so libns.c libns.ld LIBNS.SO ns_fn libns
build_so libnu.c libnu.ld LIBNU.SO nu_fn libnu
build_so libsm.c libsm.ld LIBSM.SO sm_fn libsm
build_so libdb.c libdb.ld LIBDB.SO db_fn libdb
build_so libgi.c libgi.ld LIBGI.SO gi_fn libgi
build_so libat.c libat.ld LIBAT.SO at_fn libat
build_so libab.c libab.ld LIBAB.SO ab_fn libab
build_so libcu.c libcu.ld LIBCU.SO cu_fn libcu
build_so libx1.c libx1.ld LIBX1.SO x1_fn libx1

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
  "$OUT/libgb.so" "$OUT/libgo.so" "$OUT/libnp.so" "$OUT/libns.so" \
  "$OUT/libnu.so" "$OUT/libsm.so" "$OUT/libdb.so" "$OUT/libgi.so" \
  "$OUT/libat.so" "$OUT/libab.so" "$OUT/libcu.so" "$OUT/libx1.so" \
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
[[ "${#NEEDED_ARR[@]}" -eq 16 ]] || fail "DT_NEEDED count is ${#NEEDED_ARR[@]}, expected 16"
EXPECTED=(LIBC.SO LIBM.SO LIBDL.SO LIBPT.SO LIBGB.SO LIBGO.SO LIBNP.SO LIBNS.SO
          LIBNU.SO LIBSM.SO LIBDB.SO LIBGI.SO LIBAT.SO LIBAB.SO LIBCU.SO LIBX1.SO)
for i in "${!EXPECTED[@]}"; do
  [[ "${NEEDED_ARR[$i]}" == "${EXPECTED[$i]}" ]] \
    || fail "DT_NEEDED[$i] is ${NEEDED_ARR[$i]}, not ${EXPECTED[$i]}"
done

for s in 'NEED4 START' 'VIA LIBC' 'VIA LIBM' 'VIA LIBDL' 'VIA LIBPT' \
         'VIA LIBGB' 'VIA LIBGO' 'VIA LIBNP' 'VIA LIBNS' \
         'VIA LIBNU' 'VIA LIBSM' 'VIA LIBDB' 'VIA LIBGI' \
         'VIA LIBAT' 'VIA LIBAB' 'VIA LIBCU' 'VIA LIBX1'; do
  strings -a "$OUT/plat.elf" | grep -q "$s" || fail "plat.elf lost $s"
done

# Cross-export hygiene: each face lives in exactly one stand-in.
ALL_FACES='write|need_fn|dl_fn|pt_fn|gb_fn|go_fn|np_fn|ns_fn|nu_fn|sm_fn|db_fn|gi_fn|at_fn|ab_fn|cu_fn|x1_fn'
declare -A OWN=(
  [libc]=write [libm]=need_fn [libdl]=dl_fn [libpt]=pt_fn
  [libgb]=gb_fn [libgo]=go_fn [libnp]=np_fn [libns]=ns_fn
  [libnu]=nu_fn [libsm]=sm_fn [libdb]=db_fn [libgi]=gi_fn
  [libat]=at_fn [libab]=ab_fn [libcu]=cu_fn [libx1]=x1_fn
)
for base in "${!OWN[@]}"; do
  own="${OWN[$base]}"
  others=$(echo "$ALL_FACES" | tr '|' '\n' | grep -v "^${own}$" | paste -sd'|' -)
  x86_64-elf-nm "$OUT/${base}.so" | grep -qE " [Tt] (${others})$" \
    && fail "${base}.so must not export other faces"
done

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — cap is 64 KiB"
for base in libc libm libdl libpt libgb libgo libnp libns \
            libnu libsm libdb libgi libat libab libcu libx1; do
  SB=$(wc -c <"$OUT/${base}.so" | tr -d ' ')
  [[ "$SB" -le 65536 ]] || fail "${base}.so is $SB bytes — cap is 64 KiB"
done

echo "build-progs: PASS — plat.elf $BYTES (16 DT_NEEDED), sixteen stand-in .so files"
exit 0
