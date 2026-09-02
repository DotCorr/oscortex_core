#!/usr/bin/env bash
# core/tests/conformance/d7-click/build-progs.sh
#
# Builds D7's ONE client program and checks that the thing that was built
# is the thing this harness needs. Same shape as d2-compositor's builder.
#
# Usage: build-progs.sh <outdir> <kerneldir>   -> <outdir>/wm.elf

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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/wm.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/wm.elf" "$OUT/wm.o" \
  || fail "x86_64-elf-ld could not link wm.elf"
[[ -s "$OUT/wm.elf" ]] || fail "the linker reported success but produced no wm.elf"

python3 - "$OUT/wm.elf" "$SCRIPT_DIR/prog.c" "$KERNEL_DIR/vm.dart" <<'PY' \
  || fail "the program that was built is not the one this harness needs"
import re, subprocess, sys

elf, src, vmdart = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
fails = []

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
            fails.append("an int $0x80 with no immediately preceding load of %eax")
        else:
            nums.add(prev_imm)
declared = set()
for m in re.finditer(r"^#define SYS_[A-Z]+ (\d+)$", text, re.M):
    declared.add(int(m.group(1)))
extra = nums - declared
if extra:
    fails.append("issues syscall number(s) %s which it does not declare" % sorted(extra))
if 25 not in nums:
    fails.append("the program never issues syscall 25 — it cannot be testing wmevent")
if not nums:
    fails.append("no syscall sites found at all")

vm = open(vmdart).read()
mb = re.search(r"const int vmShmBase = (0x[0-9A-Fa-f]+);", vm)
if not mb:
    fails.append("could not read vmShmBase out of the kernel's vm.dart")
else:
    base = int(mb.group(1), 16)
    code = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    code = re.sub(r"//[^\n]*", " ", code)
    lits = re.findall(r"0[xX]([0-9A-Fa-f]+)", code)
    if any(int(l, 16) == base for l in lits):
        fails.append("prog.c contains the literal 0x%X — vmShmBase" % base)
    if re.search(r"\$0x%x\b" % base, dis):
        fails.append("the disassembly contains the immediate 0x%X" % base)

rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf],
                     capture_output=True, text=True).stdout
if "R_X86_64" in rel:
    fails.append("the binary carries dynamic relocations")

hdr = subprocess.run(["x86_64-elf-readelf", "-lW", elf],
                     capture_output=True, text=True).stdout
loads = re.findall(
    r"LOAD\s+0x[0-9a-f]+ 0x([0-9a-f]+) 0x[0-9a-f]+ 0x([0-9a-f]+) 0x([0-9a-f]+) (R E|RW )",
    hdr)
if len(loads) != 2:
    fails.append("expected exactly two PT_LOAD segments, found %d" % len(loads))
else:
    (rxva, rxf, rxm, rxfl), (rwva, rwf, rwm, rwfl) = loads
    if rxfl.strip() != "R E":
        fails.append("the first PT_LOAD is %r, expected R E" % rxfl)
    if rwfl.strip() != "RW":
        fails.append("the second PT_LOAD is %r, expected RW" % rwfl)
    if int(rwf, 16) == 0:
        fails.append("the RW segment has p_filesz 0 — .data was optimised away")
    if int(rwm, 16) <= int(rwf, 16):
        fails.append("the RW segment has no zero tail")

m = re.search(r"/\* 9\. THE HOLD\..*?\n    \{\n(.*?)\n    \}", text, re.S)
if not m:
    fails.append("the hold is gone or is no longer a block")
else:
    body = m.group(1)
    if "SYS_YIELD" in body:
        fails.append("the hold yields")
    if "volatile" not in body:
        fails.append("the hold's counter is not volatile")

if "volatile u32 *p" not in text:
    fails.append("the paint loop's pointer is not volatile")

if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    sys.exit(1)

print("build-progs: pass  one freestanding ELF64, no relocations, %d syscall site(s), "
      "numbers %s, two PT_LOAD segments, a hold that busy-spins, and NO shared-window address"
      % (dis.count("int    $0x80"), sorted(nums)))
PY
