#!/usr/bin/env bash
# core/tests/conformance/hid-sess/build-progs.sh
#
# Builds the ADR-0138 session client.
# Usage: build-progs.sh <outdir> <kerneldir>  -> <outdir>/prog.elf

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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/prog.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/prog.elf" "$OUT/prog.o" \
  || fail "x86_64-elf-ld could not link prog.elf"
[[ -s "$OUT/prog.elf" ]] || fail "empty prog.elf"

python3 - "$OUT/prog.elf" "$SCRIPT_DIR/prog.c" <<'PY' || fail "built program is not the hid-sess client"
import re, subprocess, sys
elf, src = sys.argv[1], sys.argv[2]
text = open(src).read()
fails = []
dis = subprocess.run(["x86_64-elf-objdump", "-d", elf],
                     capture_output=True, text=True).stdout
nums = set()
prev = None
for line in dis.splitlines():
    m = re.search(r"mov\s+\$0x([0-9a-f]+),%eax", line)
    if m:
        prev = int(m.group(1), 16)
    if re.search(r"xor\s+%eax,%eax", line):
        prev = 0
    if "int" in line and "$0x80" in line:
        if prev is None:
            fails.append("int $0x80 with no eax load")
        else:
            nums.add(prev)
            prev = None
need = {0, 1, 3, 16, 23, 24}
if not need.issubset(nums):
    fails.append("missing syscalls %s (have %s)" % (sorted(need - nums), sorted(nums)))
if 24 not in nums:
    fails.append("never issues syscall 24")
if "HID HOLD" not in text or "HID SESS" not in text:
    fails.append("source lost the session tags")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "build-progs: PASS — $OUT/prog.elf"
exit 0
