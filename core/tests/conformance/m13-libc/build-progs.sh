#!/usr/bin/env bash
# core/tests/conformance/m13-libc/build-progs.sh
#
# Builds the C LIBRARY and the two freestanding static ELF64 executables this
# harness puts on its test disk, and then CHECKS WHAT IT BUILT.
#
# THE LIBRARY IS COMPILED HERE, WITH THE PROGRAM, AND THAT IS THE POINT.
# core/user/libc is four .c files and one header; there is no archive, no
# install step and no prebuilt object checked in. Every harness that wants the
# library compiles it from source with the same flags as the program that uses
# it, so "the libc works" can never mean "the libc worked when somebody last
# built it".
#
# ONE SOURCE, TWO BUILDS, AND THE SECOND IS THE NEGATIVE CONTROL.
#   progL   the library as written:            -DLIBC_FREE_ENABLED=1
#   progN   the same source with `free()` off:  -DLIBC_FREE_ENABLED=0
# `libcFreeEnabled` is a `volatile const` word in .rodata rather than an
# `#ifdef`, so the two binaries have BYTE-IDENTICAL SEGMENT GEOMETRY and the
# same heap base, and the check below requires exactly that while requiring the
# files themselves to differ. Every difference between the two serial
# transcripts is then attributable to `free` and to nothing else.
#
# Usage:
#   build-progs.sh <outdir>      -> <outdir>/progL.elf, <outdir>/progN.elf
#
# Exit status: 0 on success, 1 on a build failure, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
[[ -d "$LIBC_DIR" ]] || setup_error "no libc at $LIBC_DIR"
for f in oslibc.h syscall.c string.c malloc.c printf.c; do
  [[ -f "$LIBC_DIR/$f" ]] || setup_error "$LIBC_DIR/$f is missing"
done

# EXACTLY m12-heap/build-progs.sh's flags plus -I for the library's header.
# SSE is still on (no `-mgeneral-regs-only`): M11 turned it on, M12 kept it, and
# a libc is exactly the kind of change that could quietly turn it back off to
# make a `printf` that touches XMM registers easier. It did not.
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
  -I"$LIBC_DIR"
)

LIBC_SRCS=(syscall.c string.c malloc.c printf.c)

build_one() {
  local tag="$1" id="$2" freeon="$3"
  local objs=()
  local s
  for s in "${LIBC_SRCS[@]}"; do
    clang "${CFLAGS[@]}" -DLIBC_FREE_ENABLED="$freeon" "$LIBC_DIR/$s" \
      -o "$OUT/${tag}_${s%.c}.o" || fail "clang could not compile libc/$s for prog$tag"
    objs+=("$OUT/${tag}_${s%.c}.o")
  done
  clang "${CFLAGS[@]}" -DPROG_ID="$id" "$SCRIPT_DIR/prog.c" -o "$OUT/prog$tag.o" \
    || fail "clang could not compile prog.c as prog$tag"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$tag.elf" "$OUT/prog$tag.o" "${objs[@]}" \
    || fail "x86_64-elf-ld could not link prog$tag.elf"
  [[ -s "$OUT/prog$tag.elf" ]] || fail "the linker reported success but produced no prog$tag.elf"
}

build_one L 0 1
build_one N 1 0

cmp -s "$OUT/progL.elf" "$OUT/progN.elf" && \
  fail "progL.elf and progN.elf are byte-identical — the negative control would be the same program as the thing it controls"

# ---------------------------------------------------------------------------
# THE COMPILER-EMITTED memcpy AND memset.
#
# core/user/libc/string.c claims these two symbols are not optional because
# clang -O2 emits CALLS to them from source that never names either. That claim
# is checked HERE, against the object file the compiler just produced, rather
# than believed: prog.o must have an UNDEFINED reference to both, and the
# relocations must come from prog.c's own struct assignment and array
# initialiser. If a future clang stops doing it, this fails loudly and the
# sentence in string.c gets rewritten rather than quietly becoming false.
# ---------------------------------------------------------------------------
for sym in memcpy memset; do
  x86_64-elf-nm -u "$OUT/progL.o" | grep -qE "U $sym\$" \
    || fail "progL.o has no undefined reference to $sym — clang did not emit a call to it, so core/user/libc/string.c's claim that these are compiler-required is no longer true and its header comment must be rewritten"
done
echo "    (clang -O2 emitted calls to memcpy AND memset from prog.c, which names neither: both are undefined in progL.o)"

# ---------------------------------------------------------------------------
# NOT ONE `call` INSIDE ANY OF THE FIVE STRING FUNCTIONS.
#
# LLVM's loop-idiom recogniser turns a byte-copy loop into a call to memcpy --
# including when the loop it is looking at IS memcpy, which produces infinite
# recursion and blows this OS's one-page user stack. string.c defeats it with
# volatile accesses. This is the check that would catch that coming back, and it
# is a disassembly check because the property is about the emitted code.
# ---------------------------------------------------------------------------
python3 - "$OUT/progL.elf" <<'PY' || fail "one of the libc's string functions contains a call instruction"
import re, subprocess, sys
out = subprocess.run(["x86_64-elf-objdump", "-d", sys.argv[1]], capture_output=True, text=True).stdout
cur, bad, seen = None, [], set()
want = {"memcpy", "memset", "strlen", "strcmp", "strcpy"}
for line in out.splitlines():
    m = re.match(r"^[0-9a-f]+ <([^>]+)>:", line)
    if m:
        cur = m.group(1)
        if cur in want:
            seen.add(cur)
        continue
    if cur in want and re.search(r"\bcall[q]?\b", line):
        bad.append("%s contains: %s" % (cur, line.strip()))
missing = want - seen
if missing:
    bad.append("these functions are not in the linked program at all: %s" % sorted(missing))
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "    (all five string functions are present in the linked program and not one of them contains a call instruction)"

python3 - "$OUT/progL.elf" "$OUT/progN.elf" <<'PY' || fail "the programs that were built are not the ones this harness needs"
import re, subprocess, sys

fails = []

# core/kernel/vm.dart / core/kernel/heap.dart, spelled here so that a build
# whose program no longer fits the window fails HERE rather than in QEMU.
PROG_BASE = 0x10000000
PROG_END = 0x10200000
STACK_PAGE = 0x101FF000
HEAP_TOP = 0x101FE000
PAGE = 0x1000


def load(elf, name):
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
        if not (PROG_BASE <= s["vaddr"] < STACK_PAGE):
            fails.append("%s: p_vaddr 0x%X is outside the kernel's program window" % (name, s["vaddr"]))
    if any(s["type"] in (2, 3) for s in segs):
        fails.append("%s: has PT_DYNAMIC or PT_INTERP -- not statically linked" % name)

    entry = int.from_bytes(blob[24:32], "little")
    off = entry - loads[0]["vaddr"]
    if off == 0:
        fails.append("%s: e_entry IS the first byte of the first PT_LOAD" % name)
    elif (off & 0xFFF) == 0:
        fails.append("%s: e_entry is 0x%X past the segment base, a whole number of pages" % (name, off))

    if (loads[1]["vaddr"] & 0xFFF) == 0:
        fails.append("%s: the RW segment's p_vaddr 0x%X is page-aligned" % (name, loads[1]["vaddr"]))
    if loads[1]["filesz"] == 0:
        fails.append("%s: the RW segment has p_filesz 0 -- the loader's read-a-sector path "
                     "would not be exercised at all" % name)
    if loads[1]["memsz"] <= loads[1]["filesz"]:
        fails.append("%s: the RW segment has no p_memsz - p_filesz tail" % name)

    hi = 0
    for s in loads:
        end = s["vaddr"] + s["memsz"]
        hi = max(hi, (end + PAGE - 1) & ~(PAGE - 1))
    room = (HEAP_TOP - hi) // PAGE
    if room < 400:
        fails.append("%s: only %d heap pages would fit above 0x%X. The library has grown "
                     "until it eats the heap it exists to manage." % (name, room, hi))

    syms = {}
    out = subprocess.run(["x86_64-elf-readelf", "-sW", elf], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 8 and re.fullmatch(r"[0-9a-f]{16}", f[1]):
            syms[f[7]] = int(f[1], 16)
    # Every symbol derive.py reads out of the file, plus the five string
    # functions and the allocator's two entry points: a linker that dropped one
    # would otherwise turn a derived check into a KeyError at the far end.
    for want in ("progId", "exitBase", "dataWord", "reqSize", "coalReq",
                 "mallocHdrBytes", "mallocAlign", "mallocMinSplit", "printfMax",
                 "libcWriteMax", "libcFreeEnabled",
                 "malloc", "free", "printf", "memcpy", "memset", "strlen",
                 "strcmp", "strcpy", "sbrk", "write"):
        if want not in syms:
            fails.append("%s: no symbol %s" % (name, want))

    whole = subprocess.run(["x86_64-elf-objdump", "-d", elf], capture_output=True, text=True).stdout
    if not re.search(r"%(x|y|z)mm\d", whole):
        fails.append("%s: no %%xmm register anywhere -- built without SSE, which M11 turned on" % name)

    rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf], capture_output=True, text=True).stdout
    if re.search(r"^\s*[0-9a-f]{8,}\s+[0-9a-f]{8,}\s+R_X86_64", rel, re.M):
        fails.append("%s: still has dynamic relocations; this kernel applies none" % name)

    return {"entry": entry, "loads": loads, "hi": hi, "room": room, "syms": syms}


a = load(sys.argv[1], "progL.elf")
b = load(sys.argv[2], "progN.elf")

# IDENTICAL GEOMETRY, DIFFERENT CONTENT.
if a and b:
    for i, (x, y) in enumerate(zip(a["loads"], b["loads"])):
        for k in ("vaddr", "filesz", "memsz", "flags", "offset"):
            if x[k] != y[k]:
                fails.append("PT_LOAD %d: progL's %s is 0x%X and progN's is 0x%X. The control "
                             "build must have IDENTICAL geometry or the two transcripts differ "
                             "for a reason other than free()." % (i, k, x[k], y[k]))
    if a["entry"] != b["entry"]:
        fails.append("the two builds have different e_entry (0x%X vs 0x%X)" % (a["entry"], b["entry"]))
    if a["hi"] != b["hi"]:
        fails.append("the two builds' heap bases differ: 0x%X vs 0x%X" % (a["hi"], b["hi"]))

if fails:
    print("build-progs: the built programs are wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)

print("    (one source and one libc, two builds: entry 0x%X, R+X %d/%d at 0x%X, R+W %d/%d at 0x%X, "
      "identical geometry, heap base 0x%X with room for %d pages)"
      % (a["entry"], a["loads"][0]["filesz"], a["loads"][0]["memsz"], a["loads"][0]["vaddr"],
         a["loads"][1]["filesz"], a["loads"][1]["memsz"], a["loads"][1]["vaddr"],
         a["hi"], a["room"]))
PY

echo "build-progs: PASS — $OUT/progL.elf ($(wc -c <"$OUT/progL.elf" | tr -d ' ') bytes) and $OUT/progN.elf ($(wc -c <"$OUT/progN.elf" | tr -d ' ') bytes), each carrying core/user/libc's four objects"
exit 0
