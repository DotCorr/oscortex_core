#!/usr/bin/env bash
# core/tests/conformance/d2-input/build-progs.sh
#
# Builds the two freestanding static ELF64 programs D2 puts on its disk:
#   progR  the queue reader -- pops, holds, reports
#   progE  exits on its first instruction -- so proc run has a second LBA
#
# Usage: build-progs.sh <outdir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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

for p in R E; do
  clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog$p.c" -o "$OUT/prog$p.o" \
    || fail "clang could not compile prog$p.c"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$p.elf" "$OUT/prog$p.o" \
    || fail "x86_64-elf-ld could not link prog$p.elf"
  [[ -s "$OUT/prog$p.elf" ]] || fail "linker reported success but produced no prog$p.elf"
done

cmp -s "$OUT/progR.elf" "$OUT/progE.elf" && \
  fail "progR.elf and progE.elf are byte-identical"

python3 - "$OUT/progR.elf" "$OUT/progE.elf" "$CORE_DIR/kernel/kbdq.dart" \
  "$SCRIPT_DIR/progR.c" <<'PY' || fail "the programs that were built are not the ones this harness needs"
import re, subprocess, sys

fails = []

def syscall_sites(elf):
    dis = subprocess.run(["x86_64-elf-objdump", "-d", elf],
                         capture_output=True, text=True).stdout
    return [l.strip() for l in dis.splitlines()
            if re.search(r"\bint\s+\$0x80\b", l)]

sites_r = syscall_sites(sys.argv[1])
if len(sites_r) < 4:
    fails.append("progR.elf contains %d int $0x80, expected several (write, preempts, kbdevent, exit)"
                 % len(sites_r))

sites_e = syscall_sites(sys.argv[2])
if len(sites_e) != 1:
    fails.append("progE.elf contains %d int $0x80, expected exactly 1 (exit)"
                 % len(sites_e))

src = open(sys.argv[3]).read()
m = re.search(r'^const int kbdqSysNo = (\d+);', src, re.M)
if not m or m.group(1) != "24":
    fails.append("kbdq.dart kbdqSysNo is %s, expected 24" % (m.group(1) if m else "missing"))

prog = open(sys.argv[4]).read()
pm = re.search(r'^#define SYS_KBDEVENT (\d+)$', prog, re.M)
if not pm or pm.group(1) != m.group(1):
    fails.append("progR.c SYS_KBDEVENT is %s, kbdq.dart says %s"
                 % (pm.group(1) if pm else "missing", m.group(1) if m else "missing"))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY

echo "build-progs: PASS — $OUT/progR.elf ($(wc -c <"$OUT/progR.elf" | tr -d ' ') bytes) and $OUT/progE.elf ($(wc -c <"$OUT/progE.elf" | tr -d ' ') bytes)"
exit 0
