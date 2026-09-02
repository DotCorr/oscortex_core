#!/usr/bin/env bash
# core/tests/conformance/de-chrome/build-progs.sh
#
# WIN.ELF (resident window) and PING.ELF (start-menu spawn target).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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
  -I"$CORE_DIR/user/frame"
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

link_one win.c win
link_one ping.c ping

cmp -s "$OUT/win.elf" "$OUT/ping.elf" && \
  fail "win.elf and ping.elf are byte-identical — spawn would load one program twice"

grep -q 'DE CHROME PING' "$SCRIPT_DIR/ping.c" \
  || fail "ping.c does not contain DE CHROME PING"
grep -q 'SYS_YIELD' "$SCRIPT_DIR/win.c" \
  || fail "win.c never yields — residency needs the idle gate a tick"
grep -q 'SYS_YIELD' "$SCRIPT_DIR/ping.c" \
  || fail "ping.c never yields"

BYTES1=$(wc -c <"$OUT/win.elf" | tr -d ' ')
BYTES2=$(wc -c <"$OUT/ping.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/win.elf ($BYTES1 bytes) and $OUT/ping.elf ($BYTES2 bytes)"
exit 0
