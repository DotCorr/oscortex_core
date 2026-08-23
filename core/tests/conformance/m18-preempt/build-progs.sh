#!/usr/bin/env bash
# core/tests/conformance/m18-preempt/build-progs.sh
#
# Builds the TWO freestanding static ELF64 executables this harness puts on its
# test disk, and then CHECKS WHAT IT BUILT.
#
# THIS IS m11-proc/build-progs.sh WITH ONE ASSERTION ADDED AND ONE INVERTED.
#
#   ADDED, and it is the milestone:  NEITHER PROGRAM CONTAINS A `yield`.
#     M11's two programs each call syscall 3 three times, and M11's whole
#     interleaving is those six calls. A kernel with no scheduler at all can run
#     them if it switches on the syscall. So this script disassembles both
#     linked executables and requires that the immediate 3 is never moved into
#     RAX -- the ABI's syscall-number register -- anywhere in either of them.
#     A program that cannot ask to be switched away is the only kind of program
#     that can test a kernel which switches it anyway.
#
#   INVERTED, for progC only:  IT CONTAINS NO `int $0x80` WHATSOEVER.
#     Not "no yield": no system call of any kind, count exactly zero. progC
#     cannot print, cannot exit, cannot read a clock and cannot be reasoned
#     with. It is docs/known-gaps.md GAP-0085's sentence -- "a process that
#     never yields cannot be stopped" -- compiled.
#
# Everything else is M11's, unchanged and for M11's reasons: -O2 without
# `-mgeneral-regs-only`, two PT_LOAD segments R+X and R+W, an e_entry that is
# neither the segment base nor page-aligned, an RW segment that is not
# page-aligned and has a zero tail, and `blobCopy` disassembled BY NAME so its
# `%xmm` registers are the compiler's rather than a hand-written `movq`.
#
# Usage:
#   build-progs.sh <outdir>      -> <outdir>/progC.elf, <outdir>/progD.elf
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

for p in C D; do
  grep -q -- '-mgeneral-regs-only' <<<"${CFLAGS[*]}" && \
    fail "-mgeneral-regs-only is back in CFLAGS; M11 removed it and M18 inherits that"
  clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog$p.c" -o "$OUT/prog$p.o" \
    || fail "clang could not compile prog$p.c"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$p.elf" "$OUT/prog$p.o" \
    || fail "x86_64-elf-ld could not link prog$p.elf"
  [[ -s "$OUT/prog$p.elf" ]] || fail "the linker reported success but produced no prog$p.elf"
done

cmp -s "$OUT/progC.elf" "$OUT/progD.elf" && \
  fail "progC.elf and progD.elf are byte-identical — 'two different programs ran' would be one program running twice"

python3 - "$OUT/progC.elf" "$OUT/progD.elf" <<'PY' || fail "the programs that were built are not the ones this harness needs"
import re, subprocess, sys

fails = []

def elf_shape(elf, name):
    blob = open(elf, "rb").read()
    if blob[0:4] != b"\x7fELF":
        fails.append("%s: no ELF magic" % name)
        return None
    if blob[4] != 2 or blob[5] != 1:
        fails.append("%s: not ELF64 little-endian" % name)
    if int.from_bytes(blob[16:18], "little") != 2:
        fails.append("%s: e_type is not 2 (ET_EXEC)" % name)
    if int.from_bytes(blob[18:20], "little") != 0x3E:
        fails.append("%s: e_machine is not 0x3E" % name)

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
        return None
    if loads[0]["flags"] != 5:
        fails.append("%s: first PT_LOAD has p_flags %d, expected 5 (R+X)" % (name, loads[0]["flags"]))
    if loads[1]["flags"] != 6:
        fails.append("%s: second PT_LOAD has p_flags %d, expected 6 (R+W)" % (name, loads[1]["flags"]))
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

    entry = int.from_bytes(blob[24:32], "little")
    off = entry - loads[0]["vaddr"]
    if off == 0:
        fails.append("%s: e_entry IS the first byte of the first PT_LOAD -- a kernel "
                     "that ignored e_entry would pass every behavioural check" % name)
    elif (off & 0xFFF) == 0:
        fails.append("%s: e_entry is 0x%X past the segment base, a whole number of pages"
                     % (name, off))
    if (loads[1]["vaddr"] & 0xFFF) == 0:
        fails.append("%s: the RW segment's p_vaddr 0x%X is page-aligned" % (name, loads[1]["vaddr"]))
    if loads[1]["filesz"] == 0:
        fails.append("%s: the RW segment has p_filesz 0" % name)
    if loads[1]["memsz"] <= loads[1]["filesz"]:
        fails.append("%s: the RW segment has no p_memsz - p_filesz tail" % name)

    rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf],
                         capture_output=True, text=True).stdout
    if re.search(r"^\s*[0-9a-f]{8,}\s+[0-9a-f]{8,}\s+R_X86_64", rel, re.M):
        fails.append("%s: still has dynamic relocations; this kernel applies none" % name)
    return {"entry": entry, "loads": loads}


def disasm(elf):
    return subprocess.run(["x86_64-elf-objdump", "-d", elf],
                          capture_output=True, text=True).stdout


def syscall_sites(dis):
    """Every `int $0x80` in the disassembly, as a list of lines."""
    return [l.strip() for l in dis.splitlines()
            if re.search(r"\bint\s+\$0x80\b", l)]


def syscall_numbers(dis):
    """The set of syscall numbers this program can actually issue.

    THE NAIVE VERSION OF THIS CHECK WAS WRONG AND THE FIRST RUN CAUGHT IT.
    Collecting every immediate ever moved into RAX reported 0xD1D2D3D4 as a
    syscall number -- that is progD's XMM pattern, on its way into `xmm0`
    through a general-purpose register, and it is not a syscall number at all.
    A check that reports a program is broken when it is correct is worse than
    no check.

    So this walks the instruction stream and, for each `int $0x80`, looks
    BACKWARDS for the last thing that wrote RAX before it. `mov $imm,%eax` (or
    %rax) contributes that immediate; `xor %eax,%eax` contributes 0 -- which is
    how clang spells `exit`, and why 0 never appears as an immediate anywhere.
    Anything else that writes RAX (a `movq %rdx,%rax`, a call's return value)
    contributes UNKNOWN, so the check cannot silently pass by failing to find
    the load."""
    insns = [l.strip() for l in dis.splitlines() if re.match(r"^\s+[0-9a-f]+:\s", l)]
    out = set()
    for i, l in enumerate(insns):
        if not re.search(r"\bint\s+\$0x80\b", l):
            continue
        num = "UNKNOWN"
        for j in range(i - 1, max(-1, i - 25), -1):
            p = insns[j]
            m = re.search(r"\bmov[lq]?\s+\$(0x[0-9a-f]+),%(?:e|r)ax\b", p)
            if m:
                num = int(m.group(1), 16)
                break
            if re.search(r"\bxor[lq]?\s+%(e|r)ax,%(e|r)ax\b", p):
                num = 0
                break
            if re.search(r",%(e|r)ax\b", p) or re.search(r"\bcall\b", p):
                break     # RAX written by something this cannot read
        out.add(num)
    return out


c = elf_shape(sys.argv[1], "progC.elf")
d = elf_shape(sys.argv[2], "progD.elf")
dis_c = disasm(sys.argv[1])
dis_d = disasm(sys.argv[2])

# ---------------------------------------------------------------------------
# progC: NOT ONE SYSTEM CALL.
# ---------------------------------------------------------------------------
sites_c = syscall_sites(dis_c)
if sites_c:
    fails.append("progC.elf contains %d `int $0x80` instruction(s), expected ZERO. "
                 "The whole point of this program is that it cannot ask the kernel "
                 "for anything -- including to be switched away. First one: %s"
                 % (len(sites_c), sites_c[0]))

# ...and its loop really is the two instructions the source says it is.
if not re.search(r"\binc[q]?\s+%r15\b", dis_c):
    fails.append("progC.elf has no `incq %r15` -- the progress counter this harness "
                 "reads out of the saved interrupt frame is not being incremented")
if not re.search(r"\bxor[l]?\s+%r15d,%r15d\b", dis_c):
    fails.append("progC.elf never zeroes R15, so a non-zero R15 in the saved frame "
                 "would not be this program's own count")
# THE LIVE RAX. progC loads a constant into RAX once and never writes it again,
# so the saved frame's RAX is the program's own register and a kernel that
# overwrote it during a preemption is visible. Without this, a mutation that
# copied `procYield`'s RAX patch into `procTick` SURVIVED the whole harness.
if not re.search(r"\bmovabsq?\s+\$0x[0-9a-f]+,%rax\b", dis_c):
    fails.append("progC.elf does not load a 64-bit constant into RAX. That constant is "
                 "the only live register value this suite has that a preemption could "
                 "silently overwrite, and run.sh compares the saved frame against it.")
# ...and nothing in the code that RUNS writes RAX again. `_start` by name, not
# the whole file: `progCTouch` exists only to give `.data` file content, is never
# called, and does use RAX. The anchor at end of line matters too -- an
# `xchg %ax,%ax` padding nop disassembles with `,%rax` inside an address operand.
dis_start = subprocess.run(
    ["x86_64-elf-objdump", "-d", "--disassemble=_start", sys.argv[1]],
    capture_output=True, text=True).stdout
start_body = [l for l in dis_start.splitlines() if re.match(r"^\s+[0-9a-f]+:\s", l)]
if not start_body:
    fails.append("progC.elf: objdump found no _start to disassemble")
rax_writes = [l.strip() for l in start_body if re.search(r",%[re]ax$", l.rstrip())]
if len(rax_writes) != 1:
    fails.append("progC.elf's _start writes RAX %d time(s), expected exactly 1 (the "
                 "movabs). If the loop touched RAX the saved-frame check would be "
                 "comparing against a moving target. Writes seen: %s"
                 % (len(rax_writes), rax_writes))

# ---------------------------------------------------------------------------
# NEITHER PROGRAM CAN YIELD.
# ---------------------------------------------------------------------------
for name, dis in (("progC.elf", dis_c), ("progD.elf", dis_d)):
    nums = syscall_numbers(dis)
    if 3 in nums:
        fails.append("%s loads 3 into RAX somewhere -- that is `yield` (syscall 3, "
                     "core/kernel/proc.dart procSysYieldNo). A program that can yield "
                     "cannot test a kernel that preempts." % name)

# progD must issue syscalls, and only the four it declares.
sites_d = syscall_sites(dis_d)
if not sites_d:
    fails.append("progD.elf contains no `int $0x80` at all -- it cannot report anything")
nums_d = syscall_numbers(dis_d)
allowed = {0, 1, 2, 10}       # exit, write, who, preempts -- progD's whole ABI.
extra = nums_d - allowed
if extra:
    fails.append("progD.elf issues syscall number(s) %s; it declares only "
                 "0 (exit), 1 (write), 2 (who) and 10 (preempts). UNKNOWN means the "
                 "number reaching RAX is not a constant this script can read, which "
                 "is itself a reason to look."
                 % ", ".join(str(n) for n in sorted(extra, key=str)))
if 10 not in nums_d:
    fails.append("progD.elf never loads 10 into RAX -- it never calls `preempts`, so "
                 "its loop is not driven by the kernel's tick-count criterion and "
                 "the boot would be a stopwatch")

# ---------------------------------------------------------------------------
# THE SSE ASSERTIONS, M11's, unchanged.
# ---------------------------------------------------------------------------
dis_blob = subprocess.run(
    ["x86_64-elf-objdump", "-d", "--disassemble=blobCopy", sys.argv[2]],
    capture_output=True, text=True).stdout
body = [l for l in dis_blob.splitlines() if re.match(r"^\s+[0-9a-f]+:\s", l)]
if not body:
    fails.append("progD.elf: objdump found no blobCopy to disassemble")
else:
    if not [l for l in body if re.search(r"%(x|y|z)mm\d", l)]:
        fails.append("progD.elf: blobCopy contains NO %xmm register. The program was "
                     "built without SSE, so it cannot test whether the FPU state "
                     "survived a preemption. Check -O2 is still on.")
    if any("int" in l and "0x80" in l for l in body):
        fails.append("progD.elf: blobCopy contains an int $0x80 -- it is supposed to "
                     "hold no inline assembly at all, so that its %xmm registers are "
                     "the compiler's")
if not re.search(r"pshufd", dis_d):
    fails.append("progD.elf: no pshufd anywhere -- xmmSpin's XMM signature is never "
                 "broadcast, so a kernel that restored one lane would pass")

# progC has no XMM at all, and that is worth saying out loud: its FPU state is
# the ZERO state procFxInit writes, so if the kernel leaked progD's registers
# into it nothing here would notice -- which is why progD, not progC, carries
# the FPU assertion.
if re.search(r"%(x|y|z)mm\d", dis_c):
    fails.append("progC.elf contains an %xmm register; it is meant to be three "
                 "integer instructions and a jump")

if fails:
    print("build-progs: the built programs are wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)

for nm, r, extra in (("progC.elf", c, "0 syscalls, incq %%r15 loop"),
                     ("progD.elf", d, "%d syscall site(s), numbers %s"
                      % (len(sites_d), sorted(nums_d, key=str)))):
    print("    (%s: ET_EXEC EM_X86_64, entry 0x%X, R+X %d/%d at 0x%X, R+W %d/%d at 0x%X, "
          "no relocations, %s)"
          % (nm, r["entry"], r["loads"][0]["filesz"], r["loads"][0]["memsz"],
             r["loads"][0]["vaddr"], r["loads"][1]["filesz"], r["loads"][1]["memsz"],
             r["loads"][1]["vaddr"], extra))
print("    (NEITHER program loads 3 into RAX: neither can call `yield`)")
PY

echo "build-progs: PASS — $OUT/progC.elf ($(wc -c <"$OUT/progC.elf" | tr -d ' ') bytes) and $OUT/progD.elf ($(wc -c <"$OUT/progD.elf" | tr -d ' ') bytes)"
exit 0
