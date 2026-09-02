#!/usr/bin/env bash
# core/tests/conformance/wm-clip/build-progs.sh
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
CFLAGS=(-c -target x86_64-unknown-none-elf -ffreestanding -nostdlib -fno-pic -fno-pie
  -mno-red-zone -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror)
link_one() {
  local src="$1" stem="$2"
  clang "${CFLAGS[@]}" "$SCRIPT_DIR/$src" -o "$OUT/$stem.o" || fail "clang $src"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/$stem.elf" "$OUT/$stem.o" || fail "ld $stem"
  [[ -s "$OUT/$stem.elf" ]] || fail "empty $stem.elf"
  x86_64-elf-readelf -lW "$OUT/$stem.elf" | grep -q "INTERP" && fail "$stem has PT_INTERP"
  x86_64-elf-readelf -lW "$OUT/$stem.elf" | awk '$1=="LOAD"' | grep -q "RWE" && fail "$stem W+X"
}
link_one a.c a
link_one b.c b
grep -q 'WM_OFFER' "$SCRIPT_DIR/a.c" || fail "a.c missing OFFER"
grep -q 'WM_TAKE' "$SCRIPT_DIR/b.c" || fail "b.c missing TAKE"
echo "build-progs: PASS — $OUT/a.elf $OUT/b.elf"
exit 0
