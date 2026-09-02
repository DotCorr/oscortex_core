#!/usr/bin/env bash
# core/tests/conformance/de-shm/build-progs.sh
#
# Three derived ELFs that each attach a surface (ADR-0109).

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

link_one() {
  local src="$1" stem="$2"
  clang "${CFLAGS[@]}" "$SCRIPT_DIR/$src" -o "$OUT/$stem.o" \
    || fail "clang could not compile $src"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/$stem.elf" "$OUT/$stem.o" \
    || fail "x86_64-elf-ld could not link $stem.elf"
  [[ -s "$OUT/$stem.elf" ]] || fail "linker reported success but produced no $stem.elf"
  x86_64-elf-readelf -lW "$OUT/$stem.elf" | grep -q "INTERP" \
    && fail "$stem.elf has a PT_INTERP"
  x86_64-elf-readelf -lW "$OUT/$stem.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
    && fail "$stem.elf has a W+X segment"
  x86_64-elf-readelf -lW "$OUT/$stem.elf" | grep -E 'LOAD[[:space:]]+0x[0-9a-f]+[[:space:]]+0x0+[[:space:]]' \
    && fail "$stem.elf has a PT_LOAD at vaddr 0 — empty data PHDR"
}

link_one a.c a
link_one b.c b
link_one c.c c

cmp -s "$OUT/a.elf" "$OUT/b.elf" && fail "a.elf and b.elf are byte-identical"
cmp -s "$OUT/a.elf" "$OUT/c.elf" && fail "a.elf and c.elf are byte-identical"
cmp -s "$OUT/b.elf" "$OUT/c.elf" && fail "b.elf and c.elf are byte-identical"

grep -q 'DE SHM A' "$SCRIPT_DIR/a.c" || fail "a.c does not contain DE SHM A"
grep -q 'DE SHM B' "$SCRIPT_DIR/b.c" || fail "b.c does not contain DE SHM B"
grep -q 'DE SHM C' "$SCRIPT_DIR/c.c" || fail "c.c does not contain DE SHM C"
grep -q 'SYS_YIELD' "$SCRIPT_DIR/a.c" || fail "a.c never yields"
grep -q 'SYS_YIELD' "$SCRIPT_DIR/b.c" || fail "b.c never yields"
grep -q 'SYS_YIELD' "$SCRIPT_DIR/c.c" || fail "c.c never yields"

BA=$(wc -c <"$OUT/a.elf" | tr -d ' ')
BB=$(wc -c <"$OUT/b.elf" | tr -d ' ')
BC=$(wc -c <"$OUT/c.elf" | tr -d ' ')
echo "build-progs: PASS — a.elf $BA, b.elf $BB, c.elf $BC"
exit 0
