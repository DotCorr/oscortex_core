#!/usr/bin/env bash
# core/tests/conformance/apps1/build-progs.sh
#
# Two FRAME apps from one source: APP1.ELF and APP2.ELF. They must differ
# on disk so `proc spawn` by 8.3 name is loading two programs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf; do
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

for app in 1 2; do
  clang "${CFLAGS[@]}" -DAPP="$app" "$SCRIPT_DIR/prog.c" -o "$OUT/app$app.o" \
    || fail "clang could not compile prog.c APP=$app"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/app$app.elf" "$OUT/app$app.o" \
    || fail "x86_64-elf-ld could not link app$app.elf"
  [[ -s "$OUT/app$app.elf" ]] || fail "linker reported success but produced no app$app.elf"
  x86_64-elf-readelf -lW "$OUT/app$app.elf" | grep -q "INTERP" \
    && fail "app$app.elf has a PT_INTERP"
  x86_64-elf-readelf -lW "$OUT/app$app.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
    && fail "app$app.elf has a W+X segment"
  x86_64-elf-readelf -lW "$OUT/app$app.elf" | grep -E 'LOAD[[:space:]]+0x[0-9a-f]+[[:space:]]+0x0+[[:space:]]' \
    && fail "app$app.elf has a PT_LOAD at vaddr 0 — empty data PHDR (elfErrCongruence)"
done

cmp -s "$OUT/app1.elf" "$OUT/app2.elf" && \
  fail "app1.elf and app2.elf are byte-identical — two names would be one program"

grep -q '#include "osframe.h"' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c does not include osframe.h"
grep -q 'oslibc.h' "$SCRIPT_DIR/prog.c" \
  && fail "prog.c includes oslibc.h — FRAME apps compile against osframe.h"
grep -q 'SYS_SBRK' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c never calls sbrk — spawn must prove a heap"
grep -q 'SYS_YIELD' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c never yields — residency needs the idle gate a tick"

BYTES1=$(wc -c <"$OUT/app1.elf" | tr -d ' ')
BYTES2=$(wc -c <"$OUT/app2.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/app1.elf ($BYTES1 bytes) and $OUT/app2.elf ($BYTES2 bytes)"
exit 0
