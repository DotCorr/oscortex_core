#!/usr/bin/env bash
# core/tests/conformance/de-retain/build-progs.sh
#
# TWO RESIDENT CLIENTS THAT COMMIT ONCE AND THEN GO QUIET FOREVER.
#
# That shape is the whole point of ADR-0190, and it is the shape de-pace does
# NOT have: de-pace's client floods the compositor with damage, so its window
# is re-blitted several hundred times a second and could never be seen to lose
# its body. d3-session's client attaches, paints, commits once and then yields
# in a loop — which is what DESK.ELF, FILES.ELF and SET.ELF do on the live
# door, and what every real application does between one redraw and the next.
#
# Usage: build-progs.sh <outdir> <kerneldir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D3="$(cd "$SCRIPT_DIR/../d3-session" && pwd)"

fail() { echo "de-retain build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "de-retain build-progs: FAIL — $1" >&2; exit 2; }

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

for side in 0 1; do
  slot=$([[ $side -eq 0 ]] && echo A || echo B)
  clang "${CFLAGS[@]}" -DSIDE=$side "$D3/client.c" -o "$OUT/prog$slot.o" \
    || fail "clang could not compile d3-session/client.c SIDE=$side"
  x86_64-elf-ld -T "$D3/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$slot.elf" "$OUT/prog$slot.o" \
    || fail "could not link prog$slot.elf"
  [[ -s "$OUT/prog$slot.elf" ]] || fail "linker produced no prog$slot.elf"
  x86_64-elf-readelf -rW "$OUT/prog$slot.elf" | grep -q 'R_X86_64' \
    && fail "prog$slot carries dynamic relocations"
done
cmp -s "$OUT/progA.elf" "$OUT/progB.elf" \
  && fail "progA and progB are byte-identical"

# THE PROPERTY THIS HARNESS RESTS ON. A client that committed again would
# repair its own body through wmComposeCommit and GAP-0333 would be invisible.
grep -q 'msg_commit' "$D3/client.c" \
  || fail "d3-session/client.c no longer commits"
python3 - "$D3/client.c" <<'PY' || exit 1
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index('void _start(void)'):]
loop = body[body.index('for (;;)'):]
if 'WM_COMMIT' in loop or 'SYS_WMSURFACE' in loop:
    raise SystemExit('de-retain build-progs: FAIL — d3-session/client.c '
                     'commits inside its idle loop; a client that keeps '
                     'committing repairs its own body and cannot show GAP-0333')
if body.count('WM_COMMIT') != 1:
    raise SystemExit('de-retain build-progs: FAIL — the client no longer '
                     'commits exactly once')
print('    the client commits exactly once and then only yields')
PY

echo "de-retain build-progs: PASS — progA $(wc -c <"$OUT/progA.elf" | tr -d ' ') bytes, progB $(wc -c <"$OUT/progB.elf" | tr -d ' ') bytes"
exit 0
