#!/usr/bin/env bash
# cef-somap: PLAT.ELF with all 32 real CEF DT_NEEDED sonames +
# OUR plat-need5 LIB*.SO faces + SOMAP.TXT. ADR-0176.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEED5="$(cd "$SCRIPT_DIR/../plat-need5" && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"
[[ -d "$NEED5" ]] || setup_error "plat-need5 sources missing"

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
  clang "${SO_CFLAGS[@]}" "$NEED5/$src" -o "$OUT/${outbase}.o" \
    || fail "clang could not compile $src"
  x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
    -soname="$soname" -T "$NEED5/$ld" \
    -o "$OUT/${outbase}.so" "$OUT/${outbase}.o" \
    || fail "x86_64-elf-ld could not link ${outbase}.so"
  [[ -s "$OUT/${outbase}.so" ]] || fail "no ${outbase}.so"
  x86_64-elf-readelf -hW "$OUT/${outbase}.so" | grep -q "DYN (Shared object" \
    || fail "${outbase}.so is not ET_DYN"
  x86_64-elf-nm "$OUT/${outbase}.so" | grep -qE " [Tt] ${export}$" \
    || fail "${outbase}.so has no exported ${export}"
  x86_64-elf-readelf -dW "$OUT/${outbase}.so" | grep -q "\[${soname}\]" \
    || fail "${outbase}.so SONAME is not ${soname}"
  x86_64-elf-readelf -lW "$OUT/${outbase}.so" | awk '$1=="LOAD"' | grep -q "RWE" \
    && fail "${outbase}.so has a W+X segment"
  x86_64-elf-readelf -lW "$OUT/${outbase}.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
    || fail "${outbase}.so has no RX LOAD"
}

# Official CEF DT_NEEDED order. Plants reuse plat-need5 faces.
build_so libdl.c libdl.ld libdl.so.2 dl_fn libdl
build_so libpt.c libpt.ld libpthread.so.0 pt_fn libpt
build_so libgb.c libgb.ld libglib-2.0.so.0 gb_fn libgb
build_so libgo.c libgo.ld libgobject-2.0.so.0 go_fn libgo
build_so libnp.c libnp.ld libnspr4.so np_fn libnp
build_so libns.c libns.ld libnss3.so ns_fn libns
build_so libnu.c libnu.ld libnssutil3.so nu_fn libnu
build_so libsm.c libsm.ld libsmime3.so sm_fn libsm
build_so libdb.c libdb.ld libdbus-1.so.3 db_fn libdb
build_so libgi.c libgi.ld libgio-2.0.so.0 gi_fn libgi
build_so libat.c libat.ld libatk-1.0.so.0 at_fn libat
build_so libab.c libab.ld libatk-bridge-2.0.so.0 ab_fn libab
build_so libcu.c libcu.ld libcups.so.2 cu_fn libcu
build_so libx1.c libx1.ld libX11.so.6 x1_fn libx1
build_so libxc.c libxc.ld libXcomposite.so.1 xc_fn libxc
build_so libxd.c libxd.ld libXdamage.so.1 xd_fn libxd
build_so libxe.c libxe.ld libXext.so.6 xe_fn libxe
build_so libxf.c libxf.ld libXfixes.so.3 xf_fn libxf
build_so libxr.c libxr.ld libXrandr.so.2 xr_fn libxr
build_so libgm.c libgm.ld libgbm.so.1 gm_fn libgm
build_so libex.c libex.ld libexpat.so.1 ex_fn libex
build_so libxb.c libxb.ld libxcb.so.1 xb_fn libxb
build_so libxk.c libxk.ld libxkbcommon.so.0 xk_fn libxk
build_so libca.c libca.ld libcairo.so.2 ca_fn libca
build_so libpg.c libpg.ld libpango-1.0.so.0 pg_fn libpg
build_so libud.c libud.ld libudev.so.1 ud_fn libud
build_so libas.c libas.ld libasound.so.2 as_fn libas
build_so libm.c libm.ld libm.so.6 need_fn libm
build_so libap.c libap.ld libatspi.so.0 ap_fn libap
build_so libgc.c libgc.ld libgcc_s.so.1 gc_fn libgc
build_so libc.c libc.ld libc.so.6 write libc
build_so libld.c libld.ld ld-linux-x86-64.so.2 ld_fn libld

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
  "$OUT/libdl.so" \
  "$OUT/libpt.so" \
  "$OUT/libgb.so" \
  "$OUT/libgo.so" \
  "$OUT/libnp.so" \
  "$OUT/libns.so" \
  "$OUT/libnu.so" \
  "$OUT/libsm.so" \
  "$OUT/libdb.so" \
  "$OUT/libgi.so" \
  "$OUT/libat.so" \
  "$OUT/libab.so" \
  "$OUT/libcu.so" \
  "$OUT/libx1.so" \
  "$OUT/libxc.so" \
  "$OUT/libxd.so" \
  "$OUT/libxe.so" \
  "$OUT/libxf.so" \
  "$OUT/libxr.so" \
  "$OUT/libgm.so" \
  "$OUT/libex.so" \
  "$OUT/libxb.so" \
  "$OUT/libxk.so" \
  "$OUT/libca.so" \
  "$OUT/libpg.so" \
  "$OUT/libud.so" \
  "$OUT/libas.so" \
  "$OUT/libm.so" \
  "$OUT/libap.so" \
  "$OUT/libgc.so" \
  "$OUT/libc.so" \
  "$OUT/libld.so" \
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
[[ "${#NEEDED_ARR[@]}" -eq 32 ]] || fail "DT_NEEDED count is ${#NEEDED_ARR[@]}, expected 32"
EXPECTED=(
  libdl.so.2
  libpthread.so.0
  libglib-2.0.so.0
  libgobject-2.0.so.0
  libnspr4.so
  libnss3.so
  libnssutil3.so
  libsmime3.so
  libdbus-1.so.3
  libgio-2.0.so.0
  libatk-1.0.so.0
  libatk-bridge-2.0.so.0
  libcups.so.2
  libX11.so.6
  libXcomposite.so.1
  libXdamage.so.1
  libXext.so.6
  libXfixes.so.3
  libXrandr.so.2
  libgbm.so.1
  libexpat.so.1
  libxcb.so.1
  libxkbcommon.so.0
  libcairo.so.2
  libpango-1.0.so.0
  libudev.so.1
  libasound.so.2
  libm.so.6
  libatspi.so.0
  libgcc_s.so.1
  libc.so.6
  ld-linux-x86-64.so.2
)
for i in "${!EXPECTED[@]}"; do
  [[ "${NEEDED_ARR[$i]}" == "${EXPECTED[$i]}" ]] \
    || fail "DT_NEEDED[$i] is ${NEEDED_ARR[$i]}, not ${EXPECTED[$i]}"
done

# Must NOT plant 8.3 stand-ins as the NEEDED strings.
x86_64-elf-readelf -dW "$OUT/plat.elf" | grep -q '\[LIBDL\.SO\]' \
  && fail "plat.elf DT_NEEDED still has LIBDL.SO — not the real soname door"
x86_64-elf-readelf -dW "$OUT/plat.elf" | grep -q '\[LIBC\.SO\]' \
  && fail "plat.elf DT_NEEDED still has LIBC.SO — not the real soname door"

strings -a "$OUT/plat.elf" | grep -q 'SOMAP START' \
  || fail "plat.elf lost SOMAP START"
for s in "${EXPECTED[@]}"; do
  strings -a "$OUT/plat.elf" | grep -qF "$s" \
    || fail "plat.elf lost soname string $s"
done

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — cap is 64 KiB"
for base in libdl libpt libgb libgo libnp libns libnu libsm libdb libgi libat libab \
            libcu libx1 libxc libxd libxe libxf libxr libgm libex libxb libxk libca \
            libpg libud libas libm libap libgc libc libld; do
  SB=$(wc -c <"$OUT/${base}.so" | tr -d ' ')
  [[ "$SB" -le 65536 ]] || fail "${base}.so is $SB bytes — cap is 64 KiB"
done

# Full SOMAP (32 lines) and miss-alias (omit ld-linux).
{
  printf 'libdl.so.2=LIBDL.SO\n'
  printf 'libpthread.so.0=LIBPT.SO\n'
  printf 'libglib-2.0.so.0=LIBGB.SO\n'
  printf 'libgobject-2.0.so.0=LIBGO.SO\n'
  printf 'libnspr4.so=LIBNP.SO\n'
  printf 'libnss3.so=LIBNS.SO\n'
  printf 'libnssutil3.so=LIBNU.SO\n'
  printf 'libsmime3.so=LIBSM.SO\n'
  printf 'libdbus-1.so.3=LIBDB.SO\n'
  printf 'libgio-2.0.so.0=LIBGI.SO\n'
  printf 'libatk-1.0.so.0=LIBAT.SO\n'
  printf 'libatk-bridge-2.0.so.0=LIBAB.SO\n'
  printf 'libcups.so.2=LIBCU.SO\n'
  printf 'libX11.so.6=LIBX1.SO\n'
  printf 'libXcomposite.so.1=LIBXC.SO\n'
  printf 'libXdamage.so.1=LIBXD.SO\n'
  printf 'libXext.so.6=LIBXE.SO\n'
  printf 'libXfixes.so.3=LIBXF.SO\n'
  printf 'libXrandr.so.2=LIBXR.SO\n'
  printf 'libgbm.so.1=LIBGM.SO\n'
  printf 'libexpat.so.1=LIBEX.SO\n'
  printf 'libxcb.so.1=LIBXB.SO\n'
  printf 'libxkbcommon.so.0=LIBXK.SO\n'
  printf 'libcairo.so.2=LIBCA.SO\n'
  printf 'libpango-1.0.so.0=LIBPG.SO\n'
  printf 'libudev.so.1=LIBUD.SO\n'
  printf 'libasound.so.2=LIBAS.SO\n'
  printf 'libm.so.6=LIBM.SO\n'
  printf 'libatspi.so.0=LIBAP.SO\n'
  printf 'libgcc_s.so.1=LIBGC.SO\n'
  printf 'libc.so.6=LIBC.SO\n'
  printf 'ld-linux-x86-64.so.2=LIBLD.SO\n'
} >"$OUT/somap.txt"
[[ "$(wc -l <"$OUT/somap.txt" | tr -d ' ')" -eq 32 ]] || fail "somap.txt line count"
grep -q 'ld-linux-x86-64.so.2=LIBLD.SO' "$OUT/somap.txt" || fail "somap missing ld-linux"

grep -v 'ld-linux-x86-64.so.2=' "$OUT/somap.txt" >"$OUT/somap-miss.txt"
[[ "$(wc -l <"$OUT/somap-miss.txt" | tr -d ' ')" -eq 31 ]] \
  || fail "somap-miss.txt should have 31 lines"
grep -q 'ld-linux-x86-64.so.2=' "$OUT/somap-miss.txt" \
  && fail "somap-miss still has ld-linux alias"

echo "build-progs: PASS — plat.elf $BYTES (DT_NEEDED×32 real CEF sonames), 32 faces, somap ready"
exit 0
