#!/usr/bin/env bash
# core/tests/conformance/de-pace/build-progs.sh
#
# ONE resident client that commits a 16x16 damage rectangle forever (slot A)
# plus d3-session's SIDE=1 client (slot B), so the image maker's two slots are
# two different programs and the harness can spawn a second window when it
# wants the chrome signature to move.
#
# Usage: build-progs.sh <outdir> <kerneldir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D3="$(cd "$SCRIPT_DIR/../d3-session" && pwd)"

fail() { echo "de-pace build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "de-pace build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
KERNEL_DIR="${2:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir> <kerneldir>"
[[ -d "$KERNEL_DIR" ]] || setup_error "no kernel sources at $KERNEL_DIR"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror
)

clang "${CFLAGS[@]}" "$SCRIPT_DIR/client.c" -o "$OUT/progA.o" \
  || fail "clang could not compile de-pace/client.c"
x86_64-elf-ld -T "$D3/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/progA.elf" "$OUT/progA.o" || fail "could not link progA.elf"

clang "${CFLAGS[@]}" -DSIDE=1 "$D3/client.c" -o "$OUT/progB.o" \
  || fail "clang could not compile d3-session/client.c SIDE=1"
x86_64-elf-ld -T "$D3/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/progB.elf" "$OUT/progB.o" || fail "could not link progB.elf"

for p in A B; do
  [[ -s "$OUT/prog$p.elf" ]] || fail "linker produced no prog$p.elf"
  # m10's loader processes no relocations, so a program that carries any is a
  # program that would load and then jump somewhere nobody chose.
  x86_64-elf-readelf -rW "$OUT/prog$p.elf" | grep -q 'R_X86_64' \
    && fail "prog$p carries dynamic relocations"
done
cmp -s "$OUT/progA.elf" "$OUT/progB.elf" \
  && fail "progA and progB are byte-identical"

# The property the whole harness rests on: A's commits are PARTIAL damage.
grep -q 'D_W\] = DMG' "$SCRIPT_DIR/client.c" \
  || fail "de-pace/client.c no longer commits a small damage rectangle"
grep -q 'for (;;)' "$SCRIPT_DIR/client.c" \
  || fail "de-pace/client.c no longer commits forever"

echo "de-pace build-progs: PASS — progA $(wc -c <"$OUT/progA.elf" | tr -d ' ') bytes, progB $(wc -c <"$OUT/progB.elf" | tr -d ' ') bytes"
exit 0
