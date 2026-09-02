#!/usr/bin/env bash
# core/tests/conformance/de-set/build-progs.sh
#
# Builds Settings (core/user/frame/set.c) against osframe.h as SET.ELF.
# The address of the surface comes from wmsurface(WM_OP_ATTACH).
#
# Usage: build-progs.sh <outdir> <kerneldir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"
SRC="$FRAME_DIR/set.c"
GLYPH_C="$CORE_DIR/plat/osgfx/osgfx_glyph.c"
GFX_H="$CORE_DIR/plat/osgfx"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
KERNEL_DIR="${2:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir> <kerneldir>"
[[ -d "$KERNEL_DIR" ]] || setup_error "no kernel sources at $KERNEL_DIR"
[[ -f "$SRC" ]] || setup_error "no set.c at $SRC"
[[ -f "$FRAME_DIR/osframe.h" ]] || setup_error "no osframe.h at $FRAME_DIR"
[[ -f "$GLYPH_C" ]] || setup_error "no osgfx_glyph.c"
[[ -f "$GFX_H/osgfx.h" ]] || setup_error "no osgfx.h"
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
  -I"$GFX_H"
)

clang "${CFLAGS[@]}" "$SRC" -o "$OUT/set.o" \
  || fail "clang could not compile set.c"
clang "${CFLAGS[@]}" "$GLYPH_C" -o "$OUT/osgfx_glyph.o" \
  || fail "clang could not compile osgfx_glyph.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/set.elf" "$OUT/set.o" "$OUT/osgfx_glyph.o" \
  || fail "x86_64-elf-ld could not link set.elf"
[[ -s "$OUT/set.elf" ]] || fail "linker reported success but produced no set.elf"

grep -qE 'osxui_app_(label_box|text|csd)' "$SRC" \
  || fail "set.c does not paint through osxui_app (outline / CSD)"
grep -q 'Appearance' "$SRC" || fail "set.c has no Appearance pane"
grep -q 'Devices' "$SRC" || fail "set.c has no Devices pane"

python3 - "$OUT/set.elf" "$SRC" "$KERNEL_DIR/vm.dart" <<'PY' \
  || fail "the program that was built is not the one this harness needs"
import re, subprocess, sys

elf, src, vmdart = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
fails = []

if '#include "osframe.h"' not in text:
    fails.append("set.c does not include osframe.h")
if "oslibc.h" in text:
    fails.append("set.c includes oslibc.h — Settings numbers live in osframe.h")
hand = re.findall(r"^#define\s+SYS_[A-Z0-9_]+\s+\d+", text, re.M)
if hand:
    fails.append("set.c copies SYS_* by hand: %s" % hand)
if "SYS_FDWAIT" in text:
    fails.append("set.c names SYS_FDWAIT — 11 stays reserved")
if re.search(r"#define\s+SYS_\w+\s+11\b", text):
    fails.append("set.c assigns syscall 11")

def syscall_nums(path):
    dis = subprocess.run(["x86_64-elf-objdump", "-d", path],
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
                fails.append("%s: int $0x80 with no load of %%eax" % path)
            else:
                nums.add(prev_imm)
    return nums, dis

want = {0, 1, 3, 5, 6, 7, 9, 16, 23, 24, 25}
nums, dis = syscall_nums(elf)
extra = nums - want
missing = want - nums
if extra:
    fails.append("SET issues unexpected syscall(s) %s" % sorted(extra))
if missing:
    fails.append("SET is missing syscall(s) %s — need exit/write/yield/"
                 "open/read/close/fdwrite/shmcreate/wmsurface/kbdevent/wmevent"
                 % sorted(missing))
if 11 in nums:
    fails.append("SET issues syscall 11 — fdwait is reserved")

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
        fails.append("set.c contains the literal 0x%X — vmShmBase. The address "
                     "is TOLD by wmsurface(WM_OP_ATTACH) (ADR-0051 s3)." % base)
    if re.search(r"\$0x%x\b" % base, dis, re.I):
        fails.append("set.elf disassembly contains the immediate 0x%X — vmShmBase"
                     % base)

for name in ("SYS_OPEN", "SYS_READ", "SYS_YIELD", "SYS_KBDEVENT",
             "SYS_WMEVENT", "SYS_WMSURFACE", "SYS_FDWRITE"):
    if name not in text:
        fails.append("set.c has no %s" % name)
if "FACTS.DAT" not in text:
    fails.append("set.c does not bake FACTS.DAT")
if "CHROME.DAT" not in text:
    fails.append("set.c does not bake CHROME.DAT")
if "for (;;)" not in text and "for(;;)" not in text:
    fails.append("set.c has no forever loop")
if "volatile" not in text:
    fails.append("set.c has no volatile — -O2 deletes a spin with no effect")
if "volatile u32 *p" not in text:
    fails.append("the paint pointer is not volatile")
if re.search(r"\b800\b", code) or re.search(r"\b600\b", code):
    fails.append("set.c bakes 800 or 600")
if re.search(r"0x00C09048", code, re.I) or re.search(r"0x00D8B060", code, re.I):
    fails.append("set.c bakes a chrome/title colour")
if re.search(r"guest OS", text, re.I):
    fails.append("set.c says guest OS")

rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf],
                     capture_output=True, text=True).stdout
if "R_X86_64" in rel:
    fails.append("set.elf carries dynamic relocations; m10's loader processes none")

hdr = subprocess.run(["x86_64-elf-readelf", "-lW", elf],
                     capture_output=True, text=True).stdout
if "INTERP" in hdr:
    fails.append("set.elf has a PT_INTERP")
if re.search(r"LOAD.*RWE", hdr):
    fails.append("set.elf has a W+X segment")
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

nbytes = __import__("os").path.getsize(elf)
if nbytes > 65536:
    fails.append("set.elf is %d bytes; elfImageMax is 65536" % nbytes)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("build-progs: PASS — set.elf (%d bytes) against osframe.h, "
      "syscalls %s, no vmShmBase, no fdwait" % (nbytes, sorted(nums)))
PY
