#!/usr/bin/env bash
# core/tests/conformance/studio1/build-progs.sh
#
# Builds the kept STUDIO.ELF client (core/user/frame/studio.c) against
# osframe.h. Catalog names must come from APPS.TXT, so this script
# refuses a binary that contains APP1.ELF as a literal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"
SRC="$FRAME_DIR/studio.c"

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

grep -q '#include "osframe.h"' "$SRC" \
  || fail "studio.c does not include osframe.h"
grep -q 'oslibc.h' "$SRC" \
  && fail "studio.c includes oslibc.h — FRAME apps compile against osframe.h"
grep -qE '^#define SYS_' "$SRC" \
  && fail "studio.c copies SYS_* by hand — include osframe.h"
grep -q 'APPS.TXT' "$SRC" \
  || fail "studio.c does not bake APPS.TXT"
grep -q 'SYS_OPEN' "$SRC" \
  || fail "studio.c never opens a file"
grep -q 'SYS_READ' "$SRC" \
  || fail "studio.c never reads"
grep -q 'SYS_YIELD' "$SRC" \
  || fail "studio.c never yields — residency needs the idle gate"
grep -qE 'APP1\.ELF|APP2\.ELF' "$SRC" \
  && fail "studio.c contains a catalog name — names must come from APPS.TXT"

x86_64-elf-readelf -lW "$OUT/studio.elf" | grep -q "INTERP" \
  && fail "studio.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/studio.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "studio.elf has a W+X segment"
x86_64-elf-readelf -lW "$OUT/studio.elf" | grep -E 'LOAD[[:space:]]+0x[0-9a-f]+[[:space:]]+0x0+[[:space:]]' \
  && fail "studio.elf has a PT_LOAD at vaddr 0 — empty data PHDR"

# A binary that baked APP1.ELF would still print it on a truncated volume.
LC_ALL=C grep -a -q 'APP1.ELF' "$OUT/studio.elf" \
  && fail "studio.elf contains APP1.ELF as bytes — the listing would not be from APPS.TXT"

BYTES=$(wc -c <"$OUT/studio.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "studio.elf is $BYTES bytes; elfImageMax is 65536"

echo "build-progs: PASS — $OUT/studio.elf ($BYTES bytes) against osframe.h"
exit 0
