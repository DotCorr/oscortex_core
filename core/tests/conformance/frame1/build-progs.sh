#!/usr/bin/env bash
# core/tests/conformance/frame1/build-progs.sh
#
# Freestanding ABITST.ELF against core/user/frame/osframe.h, not oslibc.h.
# The header is the ABI; this program is the proof a second author can
# include it instead of copying SYS_* into a .c.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/abitst.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/abitst.elf" "$OUT/abitst.o" \
  || fail "x86_64-elf-ld could not link abitst.elf"
[[ -s "$OUT/abitst.elf" ]] || fail "linker reported success but produced no abitst.elf"

entry=$(x86_64-elf-readelf -hW "$OUT/abitst.elf" | awk '/Entry point/ {print $NF}')
[[ "$entry" != "0x10000000" ]] \
  || fail "abitst.elf's entry is the start of the first segment"
x86_64-elf-readelf -lW "$OUT/abitst.elf" | grep -q "INTERP" \
  && fail "abitst.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/abitst.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "abitst.elf has a W+X segment"

# Must include osframe.h and must not pull oslibc.h.
grep -q '#include "osframe.h"' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c does not include osframe.h"
grep -q 'oslibc.h' "$SCRIPT_DIR/prog.c" \
  && fail "prog.c includes oslibc.h — FRAME1's point is the frame header"

BYTES=$(wc -c <"$OUT/abitst.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/abitst.elf ($BYTES bytes) compiled against osframe.h"
