#!/usr/bin/env bash
# core/tests/conformance/m11-proc/build-progs.sh
#
# Builds the TWO freestanding static ELF64 executables this harness puts on its
# test disk, and then CHECKS WHAT IT BUILT.
#
# THE POINT OF THIS FILE, IN ONE SENTENCE: it is m10-elf/build-prog.sh with its
# most important assertion INVERTED.
#
# M10 compiled with `-mgeneral-regs-only` and then asserted the disassembly
# contained no `%xmm` register, because core/boot/boot.S had never set
# CR4.OSFXSR and an SSE instruction was a #UD in ring 3 (GAP-0092). M11 sets
# those bits, so this script drops the flag and asserts the OPPOSITE: the
# compiler-generated body of `blobCopy` MUST contain an `%xmm` register. A
# program with no SSE in it would prove nothing about a kernel that just
# enabled SSE.
#
# `blobCopy` BY NAME, and not "the file", for a reason that is the whole
# difference between a check and a check that passes for the wrong reason: both
# programs contain hand-written `movq %rax, %xmm0` inside `xmmYield`, so a
# whole-file grep for `%xmm` would be satisfied by inline assembly and would
# pass on a program clang had emitted no vector code for at all. `blobCopy`
# contains no inline assembly. Its `%xmm` registers are the compiler's.
#
# Usage:
#   build-progs.sh <outdir>      -> <outdir>/progA.elf, <outdir>/progB.elf
#
# Exit status: 0 on success, 1 on a build failure, 2 on a setup error.

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

# ---------------------------------------------------------------------------
# Compile. Every flag is m10-elf/build-prog.sh's, MINUS ONE.
#
#   -target x86_64-unknown-none-elf   the same triple the KERNEL is built with.
#   -ffreestanding -nostdlib          no libc, no crt0. `_start` is the entry.
#   -fno-pic -fno-pie                 absolute addressing and ET_EXEC.
#   -mno-red-zone                     an interrupt taken in ring 3 switches to
#                                     RSP0, so the red zone is safe -- kept so
#                                     the program does not depend on that.
#   -fno-stack-protector              there is no __stack_chk_fail to call.
#   -fno-asynchronous-unwind-tables   no .eh_frame; nothing unwinds.
#   -fno-builtin                      so a loop is not rewritten into a call to
#                                     a memset that does not exist.
#   -O2                               deliberately optimised. At -O0 clang
#                                     emits no vector code and the milestone
#                                     would be untested.
#
# AND NOT `-mgeneral-regs-only`. Its absence is the milestone. It is asserted
# below by disassembly rather than by this comment.
# ---------------------------------------------------------------------------
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

for p in A B; do
  grep -q -- '-mgeneral-regs-only' <<<"${CFLAGS[*]}" && \
    fail "-mgeneral-regs-only is back in CFLAGS; this harness exists to build without it"
  clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog$p.c" -o "$OUT/prog$p.o" \
    || fail "clang could not compile prog$p.c"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$p.elf" "$OUT/prog$p.o" \
    || fail "x86_64-elf-ld could not link prog$p.elf"
  [[ -s "$OUT/prog$p.elf" ]] || fail "the linker reported success but produced no prog$p.elf"
done

cmp -s "$OUT/progA.elf" "$OUT/progB.elf" && \
  fail "progA.elf and progB.elf are byte-identical — 'two different programs ran' would be one program running twice"

# ---------------------------------------------------------------------------
# Check what was built, rather than trusting the flags.
# ---------------------------------------------------------------------------
python3 - "$OUT/progA.elf" "$OUT/progB.elf" <<'PY' || fail "the programs that were built are not the ones this harness needs"
import re, subprocess, sys

fails = []

def check(elf, name):
    blob = open(elf, "rb").read()

    # 1. ELF64 little-endian ET_EXEC for x86-64, read out of the raw bytes with
    #    the same offsets core/kernel/elf.dart uses.
    if blob[0:4] != b"\x7fELF":
        fails.append("%s: no ELF magic" % name)
    if blob[4] != 2:
        fails.append("%s: EI_CLASS is %d, expected 2" % (name, blob[4]))
    if blob[5] != 1:
        fails.append("%s: EI_DATA is %d, expected 1" % (name, blob[5]))
    e_type = int.from_bytes(blob[16:18], "little")
    if e_type != 2:
        fails.append("%s: e_type is %d, expected 2 (ET_EXEC)" % (name, e_type))
    if int.from_bytes(blob[18:20], "little") != 0x3E:
        fails.append("%s: e_machine is not 0x3E" % name)

    # 2. Exactly two PT_LOAD segments, R+X and R+W, and no third.
    phoff = int.from_bytes(blob[32:40], "little")
    phentsize = int.from_bytes(blob[54:56], "little")
    phnum = int.from_bytes(blob[56:58], "little")
    if phentsize != 56:
        fails.append("%s: e_phentsize is %d, expected 56" % (name, phentsize))
    segs = []
    for i in range(phnum):
        p = blob[phoff + i * phentsize: phoff + (i + 1) * phentsize]
        segs.append({"type": int.from_bytes(p[0:4], "little"),
                     "flags": int.from_bytes(p[4:8], "little"),
                     "offset": int.from_bytes(p[8:16], "little"),
                     "vaddr": int.from_bytes(p[16:24], "little"),
                     "filesz": int.from_bytes(p[32:40], "little"),
                     "memsz": int.from_bytes(p[40:48], "little")})
    loads = [s for s in segs if s["type"] == 1]
    if len(loads) != 2:
        fails.append("%s: %d PT_LOAD segments, expected 2" % (name, len(loads)))
        return
    if loads[0]["flags"] != 5:
        fails.append("%s: first PT_LOAD has p_flags %d, expected 5" % (name, loads[0]["flags"]))
    if loads[1]["flags"] != 6:
        fails.append("%s: second PT_LOAD has p_flags %d, expected 6" % (name, loads[1]["flags"]))
    for s in loads:
        if (s["flags"] & 2) and (s["flags"] & 1):
            fails.append("%s: a PT_LOAD is W+X; the kernel would refuse it" % name)
        if (s["offset"] & 0xFFF) != (s["vaddr"] & 0xFFF):
            fails.append("%s: p_offset 0x%X and p_vaddr 0x%X are not congruent mod 4096"
                         % (name, s["offset"], s["vaddr"]))
        if not (0x10000000 <= s["vaddr"] < 0x101FF000):
            fails.append("%s: p_vaddr 0x%X is outside the kernel's program window"
                         % (name, s["vaddr"]))
    if any(s["type"] in (2, 3) for s in segs):
        fails.append("%s: has PT_DYNAMIC or PT_INTERP -- not statically linked" % name)

    # 2a. e_entry is neither the segment base nor page-aligned. m10-elf found
    #     that its e_entry HAPPENED to equal the segment base, which would have
    #     let a kernel ignoring e_entry pass everything; prog.ld's .rodata-first
    #     layout is the fix and this is the assertion that keeps it.
    entry = int.from_bytes(blob[24:32], "little")
    off = entry - loads[0]["vaddr"]
    if off == 0:
        fails.append("%s: e_entry IS the first byte of the first PT_LOAD -- a kernel "
                     "that ignored e_entry would pass every behavioural check" % name)
    elif (off & 0xFFF) == 0:
        fails.append("%s: e_entry is 0x%X past the segment base, a whole number of pages"
                     % (name, off))

    # 3. The RW segment's p_vaddr is deliberately NOT page-aligned, and has both
    #    a file-backed part and a zero tail.
    if (loads[1]["vaddr"] & 0xFFF) == 0:
        fails.append("%s: the RW segment's p_vaddr 0x%X is page-aligned" % (name, loads[1]["vaddr"]))
    if loads[1]["filesz"] == 0:
        fails.append("%s: the RW segment has p_filesz 0" % name)
    if loads[1]["memsz"] <= loads[1]["filesz"]:
        fails.append("%s: the RW segment has no p_memsz - p_filesz tail" % name)

    # 4. THE INVERTED CHECK. `blobCopy` must contain SSE, and it must be the
    #    COMPILER'S, so the symbol is disassembled on its own and its body is
    #    also required to contain no `int $0x80` -- the marker of this file's
    #    only inline-asm helpers.
    dis = subprocess.run(["x86_64-elf-objdump", "-d", "--disassemble=blobCopy", elf],
                         capture_output=True, text=True).stdout
    body = [l for l in dis.splitlines() if re.match(r"^\s+[0-9a-f]+:\s", l)]
    if not body:
        fails.append("%s: objdump found no blobCopy to disassemble" % name)
    else:
        xmm = [l.strip() for l in body if re.search(r"%(x|y|z)mm\d", l)]
        if not xmm:
            fails.append("%s: blobCopy contains NO %%xmm register. The program was built "
                         "without SSE, so it cannot test a kernel that just enabled it. "
                         "Check that -mgeneral-regs-only did not come back and that -O2 "
                         "is still on." % name)
        if any("int" in l and "0x80" in l for l in body):
            fails.append("%s: blobCopy contains an int $0x80 -- it is supposed to hold no "
                         "inline assembly at all, so that its %%xmm registers are the "
                         "compiler's" % name)

    # 5. The whole file must ALSO contain SSE somewhere outside blobCopy (the
    #    xmmYield helpers), which is what makes the per-process FPU test real.
    whole = subprocess.run(["x86_64-elf-objdump", "-d", elf],
                           capture_output=True, text=True).stdout
    if not re.search(r"pshufd", whole):
        fails.append("%s: no pshufd anywhere -- xmmYield's XMM signature is not being written"
                     % name)

    # 6. No relocations left to apply.
    rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf],
                         capture_output=True, text=True).stdout
    if re.search(r"^\s*[0-9a-f]{8,}\s+[0-9a-f]{8,}\s+R_X86_64", rel, re.M):
        fails.append("%s: still has dynamic relocations; this kernel applies none" % name)

    return {"entry": entry, "loads": loads}

a = check(sys.argv[1], "progA.elf")
b = check(sys.argv[2], "progB.elf")

if fails:
    print("build-progs: the built programs are wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)

for nm, r in (("progA.elf", a), ("progB.elf", b)):
    print("    (%s: ET_EXEC EM_X86_64, entry 0x%X, R+X %d/%d at 0x%X, R+W %d/%d at 0x%X, "
          "SSE present in blobCopy, no relocations)"
          % (nm, r["entry"], r["loads"][0]["filesz"], r["loads"][0]["memsz"],
             r["loads"][0]["vaddr"], r["loads"][1]["filesz"], r["loads"][1]["memsz"],
             r["loads"][1]["vaddr"]))
PY

echo "build-progs: PASS — $OUT/progA.elf ($(wc -c <"$OUT/progA.elf" | tr -d ' ') bytes) and $OUT/progB.elf ($(wc -c <"$OUT/progB.elf" | tr -d ' ') bytes)"
exit 0
