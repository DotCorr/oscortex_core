#!/usr/bin/env bash
# core/tests/conformance/studio2b/build-progs.sh
#
# STUDIO.ELF from studio.c (osframe.h) plus APP1.ELF / APP2.ELF from
# apps1/prog.c so persist can select one planted name and not the other.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"
SRC="$FRAME_DIR/studio.c"
APP_SRC="$CORE_DIR/tests/conformance/apps1/prog.c"
APP_LD="$CORE_DIR/tests/conformance/apps1/prog.ld"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
[[ -f "$SRC" ]] || setup_error "no studio.c at $SRC"
[[ -f "$FRAME_DIR/osframe.h" ]] || setup_error "no osframe.h at $FRAME_DIR"
[[ -f "$APP_SRC" ]] || setup_error "no apps1 prog.c at $APP_SRC"

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
  -I"$FRAME_DIR"
)

clang "${CFLAGS[@]}" "$SRC" -o "$OUT/studio.o" \
  || fail "clang could not compile studio.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/studio.elf" "$OUT/studio.o" \
  || fail "x86_64-elf-ld could not link studio.elf"
[[ -s "$OUT/studio.elf" ]] || fail "linker reported success but produced no studio.elf"

clang "${CFLAGS[@]}" -DAPP=1 "$APP_SRC" -o "$OUT/app1.o" \
  || fail "clang could not compile apps1 prog.c APP=1"
x86_64-elf-ld -T "$APP_LD" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/app1.elf" "$OUT/app1.o" \
  || fail "x86_64-elf-ld could not link app1.elf"
[[ -s "$OUT/app1.elf" ]] || fail "linker reported success but produced no app1.elf"

clang "${CFLAGS[@]}" -DAPP=2 "$APP_SRC" -o "$OUT/app2.o" \
  || fail "clang could not compile apps1 prog.c APP=2"
x86_64-elf-ld -T "$APP_LD" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/app2.elf" "$OUT/app2.o" \
  || fail "x86_64-elf-ld could not link app2.elf"
[[ -s "$OUT/app2.elf" ]] || fail "linker reported success but produced no app2.elf"

grep -q '#include "osframe.h"' "$SRC" \
  || fail "studio.c does not include osframe.h"
grep -q 'oslibc.h' "$SRC" \
  && fail "studio.c includes oslibc.h — FRAME apps compile against osframe.h"
grep -qE '^#define SYS_' "$SRC" \
  && fail "studio.c copies SYS_* by hand — include osframe.h"
grep -q 'APPS.TXT' "$SRC" \
  || fail "studio.c does not bake APPS.TXT"
grep -q 'SEL.DAT' "$SRC" \
  || fail "studio.c does not name SEL.DAT — STUDIO2b is persist"
grep -q 'SYS_SPAWN' "$SRC" \
  || fail "studio.c never calls SYS_SPAWN — STUDIO2 is launch"
grep -q 'SYS_FDWRITE' "$SRC" \
  || fail "studio.c never calls SYS_FDWRITE — persist is a write"
grep -q 'SEL_BYTES' "$SRC" \
  || fail "studio.c has no SEL_BYTES — the write length must be named"
grep -qE 'APP1\.ELF|APP2\.ELF' "$SRC" \
  && fail "studio.c contains a catalog name — names must come from APPS.TXT"

x86_64-elf-readelf -lW "$OUT/studio.elf" | grep -q "INTERP" \
  && fail "studio.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/studio.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "studio.elf has a W+X segment"
x86_64-elf-readelf -lW "$OUT/app1.elf" | grep -q "INTERP" \
  && fail "app1.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/app2.elf" | grep -q "INTERP" \
  && fail "app2.elf has a PT_INTERP"

LC_ALL=C grep -a -q 'APP1.ELF' "$OUT/studio.elf" \
  && fail "studio.elf contains APP1.ELF as bytes — launch would not be from APPS.TXT"
LC_ALL=C grep -a -q 'APP2.ELF' "$OUT/studio.elf" \
  && fail "studio.elf contains APP2.ELF as bytes — the other plant must stay derived"

BYTES=$(wc -c <"$OUT/studio.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "studio.elf is $BYTES bytes; elfImageMax is 65536"
ABYTES=$(wc -c <"$OUT/app1.elf" | tr -d ' ')
[[ "$ABYTES" -le 65536 ]] || fail "app1.elf is $ABYTES bytes; elfImageMax is 65536"
BBYTES=$(wc -c <"$OUT/app2.elf" | tr -d ' ')
[[ "$BBYTES" -le 65536 ]] || fail "app2.elf is $BBYTES bytes; elfImageMax is 65536"

echo "build-progs: PASS — $OUT/studio.elf ($BYTES bytes), app1.elf ($ABYTES), app2.elf ($BBYTES)"
exit 0
