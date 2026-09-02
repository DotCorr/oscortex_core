#!/usr/bin/env bash
# core/tests/conformance/frame3/build-progs.sh
#
# Builds the kept client (core/user/frame/surf.c) against osframe.h
# with -DFRAME3=1 as SURF.ELF, and the no-kbdevent negative as NOKBD.ELF.
#
# Usage: build-progs.sh <outdir> <kerneldir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"
SRC="$FRAME_DIR/surf.c"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
KERNEL_DIR="${2:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir> <kerneldir>"
[[ -d "$KERNEL_DIR" ]] || setup_error "no kernel sources at $KERNEL_DIR"
[[ -f "$SRC" ]] || setup_error "no surf.c at $SRC"
[[ -f "$FRAME_DIR/osframe.h" ]] || setup_error "no osframe.h at $FRAME_DIR"
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
  -I"$FRAME_DIR"
)

clang "${CFLAGS[@]}" -DFRAME3=1 "$SRC" -o "$OUT/surf.o" \
  || fail "clang could not compile surf.c -DFRAME3=1"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/surf.elf" "$OUT/surf.o" \
  || fail "x86_64-elf-ld could not link surf.elf"
[[ -s "$OUT/surf.elf" ]] || fail "linker reported success but produced no surf.elf"

clang "${CFLAGS[@]}" -DFRAME3=1 -DNOKBD=1 "$SRC" -o "$OUT/nokbd.o" \
  || fail "clang could not compile surf.c -DFRAME3=1 -DNOKBD=1"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/nokbd.elf" "$OUT/nokbd.o" \
  || fail "x86_64-elf-ld could not link nokbd.elf"
[[ -s "$OUT/nokbd.elf" ]] || fail "linker reported success but produced no nokbd.elf"

cmp -s "$OUT/surf.elf" "$OUT/nokbd.elf" && \
  fail "surf.elf and nokbd.elf are byte-identical — kbdevent is missing from both or neither"

python3 - "$OUT/surf.elf" "$OUT/nokbd.elf" "$SRC" "$KERNEL_DIR/vm.dart" <<'PY' \
  || fail "the program that was built is not the one this harness needs"
import re, subprocess, sys

elf_s, elf_n, src, vmdart = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()
fails = []

if '#include "osframe.h"' not in text:
    fails.append("surf.c does not include osframe.h")
if "oslibc.h" in text:
    fails.append("surf.c includes oslibc.h — FRAME3's numbers live in osframe.h")
hand = re.findall(r"^#define\s+SYS_[A-Z0-9_]+\s+\d+", text, re.M)
if hand:
    fails.append("surf.c copies SYS_* by hand: %s" % hand)
if "SYS_KBDEVENT" not in text:
    fails.append("surf.c never names SYS_KBDEVENT")
if "THEME.DAT" not in text and 'THEME_FILE "THEME.DAT"' not in text:
    fails.append("surf.c does not name THEME.DAT")

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

# 0 exit, 1 write, 3 yield, 5 open, 7 close, 9 fdwrite, 16 shmcreate,
# 23 wmsurface, 24 kbdevent. No new number.
want_s = {0, 1, 3, 5, 7, 9, 16, 23, 24}
# NOKBD never pops the queue and never writes a file.
want_n = {0, 1, 3, 16, 23}
nums_s, dis_s = syscall_nums(elf_s)
nums_n, dis_n = syscall_nums(elf_n)

extra_s = nums_s - want_s
missing_s = want_s - nums_s
if extra_s:
    fails.append("SURF issues unexpected syscall(s) %s" % sorted(extra_s))
if missing_s:
    fails.append("SURF is missing syscall(s) %s" % sorted(missing_s))
if 24 in nums_n:
    fails.append("NOKBD issues kbdevent (24) — the colour negative is vacuous")
if 9 in nums_n or 5 in nums_n:
    fails.append("NOKBD issues open/fdwrite — it must not persist")
extra_n = nums_n - want_n
missing_n = want_n - nums_n
if extra_n:
    fails.append("NOKBD issues unexpected syscall(s) %s" % sorted(extra_n))
if missing_n:
    fails.append("NOKBD is missing syscall(s) %s" % sorted(missing_n))

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
        fails.append("surf.c contains the literal 0x%X — vmShmBase" % base)
    if re.search(r"\$0x%x\b" % base, dis_s, re.I):
        fails.append("surf.elf disassembly contains the immediate 0x%X" % base)

if "for (;;)" not in text and "for(;;)" not in text:
    fails.append("surf.c has no forever loop")
if "volatile" not in text:
    fails.append("surf.c has no volatile")

rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf_s],
                     capture_output=True, text=True).stdout
if "R_X86_64" in rel:
    fails.append("surf.elf carries dynamic relocations; m10's loader processes none")

hdr = subprocess.run(["x86_64-elf-readelf", "-lW", elf_s],
                     capture_output=True, text=True).stdout
if "INTERP" in hdr:
    fails.append("surf.elf has a PT_INTERP")
if re.search(r"LOAD.*RWE", hdr):
    fails.append("surf.elf has a W+X segment")
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
        fails.append("the RW segment has no zero tail (p_memsz %s <= p_filesz %s)"
                     % (rwm, rwf))

nbytes = __import__("os").path.getsize(elf_s)
if nbytes > 65536:
    fails.append("surf.elf is %d bytes; elfImageMax is 65536" % nbytes)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("build-progs: PASS — surf.elf (%d bytes) syscalls %s; nokbd.elf syscalls %s"
      % (nbytes, sorted(nums_s), sorted(nums_n)))
PY
