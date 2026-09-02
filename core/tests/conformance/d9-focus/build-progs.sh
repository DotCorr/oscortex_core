#!/usr/bin/env bash
# core/tests/conformance/d9-focus/build-progs.sh
#
# Builds D9's TWO client programs from ONE source (`-DSIDE=0` / `-DSIDE=1`)
# and checks that the things that were built are the things this harness
# needs. Same shape as d3-session's builder.
#
# Usage: build-progs.sh <outdir> <kerneldir>   -> <outdir>/progA.elf, progB.elf

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
KERNEL_DIR="${2:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir> <kerneldir>"
[[ -d "$KERNEL_DIR" ]] || setup_error "no kernel sources at $KERNEL_DIR"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-objdump x86_64-elf-readelf python3; do
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

for side in 0 1; do
  name=A
  [[ "$side" == 1 ]] && name=B
  clang "${CFLAGS[@]}" -DSIDE="$side" "$SCRIPT_DIR/prog.c" -o "$OUT/prog$name.o" \
    || fail "clang could not compile prog.c SIDE=$side"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$name.elf" "$OUT/prog$name.o" \
    || fail "x86_64-elf-ld could not link prog$name.elf"
  [[ -s "$OUT/prog$name.elf" ]] || fail "the linker reported success but produced no prog$name.elf"
done

cmp -s "$OUT/progA.elf" "$OUT/progB.elf" && \
  fail "progA.elf and progB.elf are byte-identical — the two windows would be the same program"

python3 - "$OUT/progA.elf" "$OUT/progB.elf" "$SCRIPT_DIR/prog.c" "$KERNEL_DIR/vm.dart" <<'PY' \
  || fail "the programs that were built are not the ones this harness needs"
import re, subprocess, sys

elf_a, elf_b, src, vmdart = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()
fails = []

def syscall_nums(elf):
    dis = subprocess.run(["x86_64-elf-objdump", "-d", elf],
                         capture_output=True, text=True).stdout
    nums = set()
    prev_imm = None
    for line in dis.splitlines():
        m = re.search(r"mov\s+\$0x([0-9a-f]+),%eax", line)
        if m:
            prev_imm = int(m.group(1), 16)
        if re.search(r"xor\s+%eax,%eax", line):
            prev_imm = 0
        if "int" in line and "$0x80" in line:
            if prev_imm is None:
                fails.append("%s: int $0x80 with no load of %%eax" % elf)
            else:
                nums.add(prev_imm)
    return nums, dis

want = {0, 1, 3, 16, 23, 24}
for elf, label in ((elf_a, "A"), (elf_b, "B")):
    nums, dis = syscall_nums(elf)
    extra = nums - want
    missing = want - nums
    if extra:
        fails.append("prog%s issues unexpected syscall(s) %s" % (label, sorted(extra)))
    if missing:
        fails.append("prog%s is missing syscall(s) %s — need exit/write/yield/shmcreate/wmsurface/kbdevent"
                     % (label, sorted(missing)))
    if 24 not in nums:
        fails.append("prog%s never issues syscall 24 — it cannot be testing kbdevent" % label)

code = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
code = re.sub(r"//[^\n]*", " ", code)
vm = open(vmdart).read()
mb = re.search(r"const int vmShmBase = (0x[0-9A-Fa-f]+);", vm)
if not mb:
    fails.append("could not read vmShmBase out of vm.dart")
else:
    base = int(mb.group(1), 16)
    lits = re.findall(r"0[xX]([0-9A-Fa-f]+)", code)
    if any(int(l, 16) == base for l in lits):
        fails.append("prog.c contains the literal 0x%X — vmShmBase" % base)

rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf_a],
                     capture_output=True, text=True).stdout
if "R_X86_64" in rel:
    fails.append("progA carries dynamic relocations; m10's loader processes none")

m = re.search(r"/\* 9\. THE HOLD\..*?\n    \{\n(.*?)\n    \}", text, re.S)
if not m:
    fails.append("the hold is gone or is no longer a block")
else:
    body = m.group(1)
    if "SYS_YIELD" not in body:
        fails.append("the hold does not yield — the unfocused client would never finish")
    if "volatile" not in body:
        fails.append("the hold's counter is not volatile")
    if "SYS_KBDEVENT" not in body:
        fails.append("the hold does not poll kbdevent")

if "volatile u32 *p" not in text:
    fails.append("the paint loop's pointer is not volatile")

if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    sys.exit(1)

print("build-progs: pass  two freestanding ELF64s, no relocations, syscalls %s, "
      "a hold that busy-spins and pops kbdevent, and NO shared-window address"
      % sorted(want))
PY
