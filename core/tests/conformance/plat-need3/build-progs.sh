#!/usr/bin/env bash
# plat-need3: PLAT.ELF with eight DT_NEEDED + OUR stand-ins.
# Not glibc. Not libcef. ADR-0162.

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
[[ "${#NEEDED_ARR[@]}" -eq 8 ]] || fail "DT_NEEDED count is ${#NEEDED_ARR[@]}, expected 8"
[[ "${NEEDED_ARR[0]}" == "LIBC.SO" ]] || fail "first DT_NEEDED is ${NEEDED_ARR[0]}, not LIBC.SO"
[[ "${NEEDED_ARR[1]}" == "LIBM.SO" ]] || fail "second DT_NEEDED is ${NEEDED_ARR[1]}, not LIBM.SO"
[[ "${NEEDED_ARR[2]}" == "LIBDL.SO" ]] || fail "third DT_NEEDED is ${NEEDED_ARR[2]}, not LIBDL.SO"
[[ "${NEEDED_ARR[3]}" == "LIBPT.SO" ]] || fail "fourth DT_NEEDED is ${NEEDED_ARR[3]}, not LIBPT.SO"
[[ "${NEEDED_ARR[4]}" == "LIBGB.SO" ]] || fail "fifth DT_NEEDED is ${NEEDED_ARR[4]}, not LIBGB.SO"
[[ "${NEEDED_ARR[5]}" == "LIBGO.SO" ]] || fail "sixth DT_NEEDED is ${NEEDED_ARR[5]}, not LIBGO.SO"
[[ "${NEEDED_ARR[6]}" == "LIBNP.SO" ]] || fail "seventh DT_NEEDED is ${NEEDED_ARR[6]}, not LIBNP.SO"
[[ "${NEEDED_ARR[7]}" == "LIBNS.SO" ]] || fail "eighth DT_NEEDED is ${NEEDED_ARR[7]}, not LIBNS.SO"

for s in 'NEED3 START' 'VIA LIBC' 'VIA LIBM' 'VIA LIBDL' 'VIA LIBPT' \
         'VIA LIBGB' 'VIA LIBGO' 'VIA LIBNP' 'VIA LIBNS'; do
  strings -a "$OUT/plat.elf" | grep -q "$s" || fail "plat.elf lost $s"
done

# Cross-export hygiene: each face lives in exactly one stand-in.
FACES='write|need_fn|dl_fn|pt_fn|gb_fn|go_fn|np_fn|ns_fn'
x86_64-elf-nm "$OUT/libc.so" | grep -qE " [Tt] (need_fn|dl_fn|pt_fn|gb_fn|go_fn|np_fn|ns_fn)$" \
  && fail "libc.so must not export other faces"
x86_64-elf-nm "$OUT/libm.so" | grep -qE " [Tt] (write|dl_fn|pt_fn|gb_fn|go_fn|np_fn|ns_fn)$" \
  && fail "libm.so must not export other faces"
x86_64-elf-nm "$OUT/libdl.so" | grep -qE " [Tt] (write|need_fn|pt_fn|gb_fn|go_fn|np_fn|ns_fn)$" \
  && fail "libdl.so must not export other faces"
x86_64-elf-nm "$OUT/libpt.so" | grep -qE " [Tt] (write|need_fn|dl_fn|gb_fn|go_fn|np_fn|ns_fn)$" \
  && fail "libpt.so must not export other faces"
x86_64-elf-nm "$OUT/libgb.so" | grep -qE " [Tt] (write|need_fn|dl_fn|pt_fn|go_fn|np_fn|ns_fn)$" \
  && fail "libgb.so must not export other faces"
x86_64-elf-nm "$OUT/libgo.so" | grep -qE " [Tt] (write|need_fn|dl_fn|pt_fn|gb_fn|np_fn|ns_fn)$" \
  && fail "libgo.so must not export other faces"
x86_64-elf-nm "$OUT/libnp.so" | grep -qE " [Tt] (write|need_fn|dl_fn|pt_fn|gb_fn|go_fn|ns_fn)$" \
  && fail "libnp.so must not export other faces"
x86_64-elf-nm "$OUT/libns.so" | grep -qE " [Tt] (write|need_fn|dl_fn|pt_fn|gb_fn|go_fn|np_fn)$" \
  && fail "libns.so must not export other faces"

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — cap is 64 KiB"
for base in libc libm libdl libpt libgb libgo libnp libns; do
  SB=$(wc -c <"$OUT/${base}.so" | tr -d ' ')
  [[ "$SB" -le 65536 ]] || fail "${base}.so is $SB bytes — cap is 64 KiB"
done

echo "build-progs: PASS — plat.elf $BYTES (8 DT_NEEDED), eight stand-in .so files"
exit 0
