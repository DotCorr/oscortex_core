#!/usr/bin/env bash
# core/tests/conformance/m21-shmem/build-progs.sh
#
# Builds M21's ONE test program and checks that the thing that was built is the
# thing this harness needs.
#
# WHAT IT ASSERTS ABOUT THE BINARY
#   * IT ISSUES EXACTLY THE SYSCALLS IT DECLARES and no others. A program that
#     reached the kernel through a number this harness does not know about would
#     be testing something nobody wrote down.
#   * NO DYNAMIC RELOCATIONS. m10's loader does not process any, so a binary
#     that needed them would load and then misbehave rather than be refused.
#   * m11's SEGMENT SHAPE: two PT_LOAD segments, R+X and R+W, an RW segment with
#     a NON-ZERO p_filesz and a zero tail (p_memsz > p_filesz), and an e_entry
#     that is neither the segment base nor page-aligned.
#   * THE HOLD IS A BUSY SPIN AND NOT A YIELD LOOP. `proc.dart` prints a line on
#     every yield, and a hold long enough to be useful would bury the transcript.
#
# Usage:
#   build-progs.sh <outdir> <kerneldir>   -> <outdir>/shm.elf
#
# Exit status: 0 on success, 1 on a build failure, 2 on a setup error.

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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/shm.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/shm.elf" "$OUT/shm.o" \
  || fail "x86_64-elf-ld could not link shm.elf"
[[ -s "$OUT/shm.elf" ]] || fail "the linker reported success but produced no shm.elf"

python3 - "$OUT/shm.elf" "$SCRIPT_DIR/prog.c" <<'PY' \
  || fail "the program that was built is not the one this harness needs"
import re, subprocess, sys

elf, src = sys.argv[1], sys.argv[2]
text = open(src).read()
fails = []

# --- the syscalls it actually issues -------------------------------------
dis = subprocess.run(["x86_64-elf-objdump", "-d", elf],
                     capture_output=True, text=True).stdout
# Every `int $0x80` is preceded by a `mov $N,%eax` in this program's shape.
nums = set()
prev_imm = None
for line in dis.splitlines():
    m = re.search(r"mov\s+\$0x([0-9a-f]+),%eax", line)
    if m:
        prev_imm = int(m.group(1), 16)
    if "int" in line and "$0x80" in line:
        if prev_imm is None:
            fails.append("an int $0x80 with no immediately preceding mov to %eax")
        else:
            nums.add(prev_imm)
declared = set()
for m in re.finditer(r"^#define SYS_[A-Z]+ (\d+)$", text, re.M):
    declared.add(int(m.group(1)))
extra = nums - declared
if extra:
    fails.append("issues syscall number(s) %s which it does not declare" % sorted(extra))
if not nums:
    fails.append("no syscall sites found at all — the program cannot be testing anything")

# --- no dynamic relocations ----------------------------------------------
rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf],
                     capture_output=True, text=True).stdout
if "R_X86_64" in rel:
    fails.append("the binary carries dynamic relocations; m10's loader processes none")

# --- segment shape --------------------------------------------------------
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
        fails.append("the RW segment has p_filesz 0 — .data was optimised away, and "
                     "m10's zero-tail handling would not be exercised")
    if int(rwm, 16) <= int(rwf, 16):
        fails.append("the RW segment has no zero tail (p_memsz %s <= p_filesz %s)"
                     % (rwm, rwf))
ehdr = subprocess.run(["x86_64-elf-readelf", "-hW", elf],
                      capture_output=True, text=True).stdout
em = re.search(r"Entry point address:\s+0x([0-9a-f]+)", ehdr)
if not em:
    fails.append("no entry point in the ELF header")
else:
    entry = int(em.group(1), 16)
    if entry % 0x1000 == 0:
        fails.append("e_entry 0x%x is page-aligned; m11's shape wants it not to be" % entry)

# --- the hold is a busy spin, not a yield loop ---------------------------
m = re.search(r"/\* 9\. THE HOLD\..*?\n  \{\n(.*?)\n  \}", text, re.S)
if not m:
    fails.append("the producer's hold is gone or no longer a block")
else:
    body = m.group(1)
    if "shmYield" in body:
        fails.append("the hold yields; proc.dart prints a line per yield and a hold long "
                     "enough to be useful would bury the transcript")
    if "volatile" not in body:
        fails.append("the hold's counter is not volatile; -O2 deletes a loop with no effect")

if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    sys.exit(1)

print("build-progs: pass  one freestanding ELF64, no relocations, %d syscall site(s), "
      "numbers %s, two PT_LOAD segments R+X and R+W with a non-zero .data and a zero "
      "tail, e_entry 0x%x, and a hold that busy-spins rather than yielding"
      % (dis.count("int    $0x80"), sorted(nums), entry))
PY
