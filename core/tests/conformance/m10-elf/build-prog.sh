#!/usr/bin/env bash
# core/tests/conformance/m10-elf/build-prog.sh
#
# Builds the freestanding static ELF64 executable the M10 harness puts on its
# test disk, and then CHECKS WHAT IT BUILT.
#
# THE PROGRAM IS BUILT HERE, NOT COMMITTED, and that is the point. A committed
# binary would make "the kernel ran a real ELF" a claim about a blob somebody
# produced once; a build makes it a claim about a toolchain anyone can re-run.
# run.sh derives every expectation -- the entry point, the message bytes, the
# exit status, the segment permissions -- from THIS output rather than from a
# literal, so changing prog.c changes what the harness expects.
#
# The exact commands are also in docs/decisions/0014-elf-loader.md §2.
#
# Usage:
#   build-prog.sh <outdir>       -> <outdir>/prog.elf
#
# Exit status: 0 on success, 1 on a build failure, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "build-prog: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-prog: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-prog.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# ---------------------------------------------------------------------------
# Compile. Every flag is load-bearing and none of them is a style preference:
#
#   -target x86_64-unknown-none-elf   the same target triple the KERNEL is
#                                     built with (core/scripts/build-kernel.sh),
#                                     so this is not a cross-toolchain accident.
#   -ffreestanding -nostdlib          no libc, no crt0, no _init. `_start` is
#                                     the entry and nothing runs before it.
#   -fno-pic -fno-pie                 absolute addressing and ET_EXEC. A PIE is
#                                     ET_DYN and needs relocation this kernel
#                                     does not do -- and refuses by name.
#   -mgeneral-regs-only               NO SSE. core/boot/boot.S sets exactly one
#                                     bit of CR4 (PAE) and never OSFXSR, so an
#                                     SSE instruction is a #UD on this machine.
#                                     At -O2 clang emits them for an ordinary
#                                     memcpy or a vectorised loop. GAP-0092.
#   -mno-red-zone                     harmless here (an interrupt taken in ring
#                                     3 switches to RSP0, so the red zone is
#                                     safe) and kept so the program does not
#                                     depend on that being true.
#   -fno-stack-protector              there is no __stack_chk_fail to call.
#   -fno-asynchronous-unwind-tables   no .eh_frame; nothing unwinds.
#   -fno-builtin                      so a loop is not rewritten into a call to
#                                     a memset that does not exist.
#   -O2                               deliberately optimised. -O0 would hide the
#                                     SSE question rather than answer it.
# ---------------------------------------------------------------------------
CFLAGS=(
  -c
  -target x86_64-unknown-none-elf
  -ffreestanding
  -nostdlib
  -fno-pic
  -fno-pie
  -mgeneral-regs-only
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

# ---------------------------------------------------------------------------
# Link. -T prog.ld puts .text+.rodata in a PF_R|PF_X segment and .data+.bss in
# a PF_R|PF_W one; -z max-page-size=0x1000 is what makes p_offset and p_vaddr
# congruent modulo 4096, which is the property core/kernel/elf.dart relies on
# and checks. --build-id=none keeps the file byte-identical across rebuilds.
# ---------------------------------------------------------------------------
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/prog.elf" "$OUT/prog.o" \
  || fail "x86_64-elf-ld could not link prog.elf"

[[ -s "$OUT/prog.elf" ]] || fail "the linker reported success but produced no prog.elf"

# ---------------------------------------------------------------------------
# Check what was built, rather than trusting the flags.
# ---------------------------------------------------------------------------
python3 - "$OUT/prog.elf" <<'PY' || fail "the program that was built is not the one this harness needs"
import re, subprocess, sys
elf = sys.argv[1]
blob = open(elf, "rb").read()
fails = []

# 1. It is an ELF64 little-endian ET_EXEC for x86-64. Read out of the raw bytes,
#    with the same offsets core/kernel/elf.dart uses -- so the two agree about
#    where the fields are, or this fails before a boot does.
if blob[0:4] != b"\x7fELF":
    fails.append("no ELF magic")
if blob[4] != 2:
    fails.append("e_ident[EI_CLASS] is %d, expected 2 (ELFCLASS64)" % blob[4])
if blob[5] != 1:
    fails.append("e_ident[EI_DATA] is %d, expected 1 (little-endian)" % blob[5])
e_type = int.from_bytes(blob[16:18], "little")
e_machine = int.from_bytes(blob[18:20], "little")
if e_type != 2:
    fails.append("e_type is %d, expected 2 (ET_EXEC). A PIE is ET_DYN and this "
                 "kernel refuses it." % e_type)
if e_machine != 0x3E:
    fails.append("e_machine is 0x%X, expected 0x3E" % e_machine)

# 2. Exactly two PT_LOAD segments, R+X and R+W, and no third.
phoff = int.from_bytes(blob[32:40], "little")
phentsize = int.from_bytes(blob[54:56], "little")
phnum = int.from_bytes(blob[56:58], "little")
if phentsize != 56:
    fails.append("e_phentsize is %d, expected 56" % phentsize)
segs = []
for i in range(phnum):
    p = blob[phoff + i * phentsize: phoff + (i + 1) * phentsize]
    segs.append({
        "type": int.from_bytes(p[0:4], "little"),
        "flags": int.from_bytes(p[4:8], "little"),
        "offset": int.from_bytes(p[8:16], "little"),
        "vaddr": int.from_bytes(p[16:24], "little"),
        "filesz": int.from_bytes(p[32:40], "little"),
        "memsz": int.from_bytes(p[40:48], "little"),
    })
loads = [s for s in segs if s["type"] == 1]
if len(loads) != 2:
    fails.append("%d PT_LOAD segments, expected 2" % len(loads))
else:
    if loads[0]["flags"] != 5:
        fails.append("the first PT_LOAD has p_flags %d, expected 5 (PF_R|PF_X)"
                     % loads[0]["flags"])
    if loads[1]["flags"] != 6:
        fails.append("the second PT_LOAD has p_flags %d, expected 6 (PF_R|PF_W)"
                     % loads[1]["flags"])
for s in loads:
    if s["flags"] & 2 and s["flags"] & 1:
        fails.append("a PT_LOAD is W+X; the kernel would refuse it")
    if (s["offset"] & 0xFFF) != (s["vaddr"] & 0xFFF):
        fails.append("p_offset 0x%X and p_vaddr 0x%X are not congruent mod 4096"
                     % (s["offset"], s["vaddr"]))
    if not (0x10000000 <= s["vaddr"] < 0x101FF000):
        fails.append("p_vaddr 0x%X is outside the kernel's program window"
                     % s["vaddr"])
if any(s["type"] in (2, 3) for s in segs):
    fails.append("the program has a PT_DYNAMIC or PT_INTERP header -- it is not "
                 "statically linked")

# 2a. THE ENTRY POINT IS NOT THE START OF THE SEGMENT, AND NOT PAGE-ALIGNED.
#
# prog.ld puts .rodata before .text for exactly this reason. If e_entry were the
# first byte of the first PT_LOAD, a kernel that ignored e_entry entirely -- and
# jumped to the segment base, or to a hardcoded address -- would satisfy every
# behavioural check in run.sh. It is asserted here rather than assumed, because
# it is a property of the link script that a later edit could quietly undo.
if len(loads) >= 1:
    if entry_off := (int.from_bytes(blob[24:32], "little") - loads[0]["vaddr"]):
        if entry_off & 0xFFF == 0:
            fails.append("e_entry is 0x%X past the segment base, which is a "
                         "whole number of pages. It must be a non-page-aligned "
                         "offset so that a kernel ignoring e_entry cannot pass."
                         % entry_off)
    else:
        fails.append("e_entry IS the first byte of the first PT_LOAD. A kernel "
                     "that ignored e_entry and jumped to the segment base would "
                     "pass every check in run.sh -- see prog.ld's note on why "
                     ".rodata is linked before .text.")

# 3a. The RW segment's p_vaddr is deliberately NOT page-aligned (prog.ld adds
#     0x40), so the loader's handling of a segment that does not start on a page
#     boundary is exercised by the program that actually runs. Asserted here so
#     that "simplifying" the link script cannot silently drop the coverage.
if len(loads) == 2 and (loads[1]["vaddr"] & 0xFFF) == 0:
    fails.append("the RW segment's p_vaddr 0x%X is page-aligned. prog.ld makes "
                 "it deliberately unaligned so that core/kernel/elf.dart's "
                 "handling of a partial first page is tested by the program "
                 "that runs." % loads[1]["vaddr"])

# 3. The RW segment must have BOTH a file-backed part and a zero tail, or the
#    two halves of the .bss claim are not both tested.
if len(loads) == 2:
    if loads[1]["filesz"] == 0:
        fails.append("the RW segment has p_filesz 0 -- nothing tests that file "
                     "bytes reach a writable segment")
    if loads[1]["memsz"] <= loads[1]["filesz"]:
        fails.append("the RW segment has no p_memsz - p_filesz tail -- nothing "
                     "tests that .bss is zeroed")

# 4. NO SSE. The flag is not the evidence; the disassembly is.
dis = subprocess.run(["x86_64-elf-objdump", "-d", elf],
                     capture_output=True, text=True).stdout
bad = [l.strip() for l in dis.splitlines() if re.search(r"%(x|y|z)mm\d", l)]
if bad:
    fails.append("the program contains %d SSE/AVX instruction(s), first `%s`. "
                 "core/boot/boot.S never sets CR4.OSFXSR, so this is a #UD in "
                 "ring 3 -- see docs/known-gaps.md GAP-0092."
                 % (len(bad), bad[0]))

# 5. No relocations left to apply: nothing here relocates.
rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf],
                     capture_output=True, text=True).stdout
if re.search(r"^\s*[0-9a-f]{8,}\s+[0-9a-f]{8,}\s+R_X86_64", rel, re.M):
    fails.append("prog.elf still has dynamic relocations; this kernel applies none")

if fails:
    print("build-prog: the built program is wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)

entry = int.from_bytes(blob[24:32], "little")
print("    (ET_EXEC EM_X86_64, entry 0x%X, %d PT_LOAD: R+X %d/%d bytes at 0x%X, "
      "R+W %d/%d bytes at 0x%X, no SSE, no relocations)"
      % (entry, len(loads), loads[0]["filesz"], loads[0]["memsz"], loads[0]["vaddr"],
         loads[1]["filesz"], loads[1]["memsz"], loads[1]["vaddr"]))
PY

echo "build-prog: PASS — $OUT/prog.elf ($(wc -c <"$OUT/prog.elf" | tr -d ' ') bytes)"
exit 0
