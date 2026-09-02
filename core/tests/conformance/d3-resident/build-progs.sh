#!/usr/bin/env bash
# core/tests/conformance/d3-resident/build-progs.sh
#
# Builds the two freestanding static ELF64 programs D3 puts on its disk:
#   progS  never yields, never exits  -- the resident spinner
#   progE  exits on its first instruction -- the negative control
#
# Usage: build-progs.sh <outdir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-objdump x86_64-elf-readelf; do
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

for p in S E; do
  clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog$p.c" -o "$OUT/prog$p.o" \
    || fail "clang could not compile prog$p.c"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$p.elf" "$OUT/prog$p.o" \
    || fail "x86_64-elf-ld could not link prog$p.elf"
  [[ -s "$OUT/prog$p.elf" ]] || fail "linker reported success but produced no prog$p.elf"
done

cmp -s "$OUT/progS.elf" "$OUT/progE.elf" && \
  fail "progS.elf and progE.elf are byte-identical"

python3 - "$OUT/progS.elf" "$OUT/progE.elf" <<'PY' || fail "the programs that were built are not the ones this harness needs"
import re, subprocess, sys

fails = []

def syscall_sites(elf):
    dis = subprocess.run(["x86_64-elf-objdump", "-d", elf],
                         capture_output=True, text=True).stdout
    return [l.strip() for l in dis.splitlines()
            if re.search(r"\bint\s+\$0x80\b", l)]

sites_s = syscall_sites(sys.argv[1])
if sites_s:
    fails.append("progS.elf contains %d int $0x80, expected ZERO" % len(sites_s))

sites_e = syscall_sites(sys.argv[2])
if len(sites_e) != 1:
    fails.append("progE.elf contains %d int $0x80, expected exactly 1 (exit)"
                 % len(sites_e))

dis_s = subprocess.run(["x86_64-elf-objdump", "-d", "--disassemble=_start",
                        sys.argv[1]], capture_output=True, text=True).stdout
if not re.search(r"\binc[q]?\s+%r15\b", dis_s):
    fails.append("progS.elf _start has no incq %r15")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY

echo "build-progs: PASS — $OUT/progS.elf ($(wc -c <"$OUT/progS.elf" | tr -d ' ') bytes) and $OUT/progE.elf ($(wc -c <"$OUT/progE.elf" | tr -d ' ') bytes)"
exit 0
