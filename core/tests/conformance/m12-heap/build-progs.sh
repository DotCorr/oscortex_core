#!/usr/bin/env bash
# core/tests/conformance/m12-heap/build-progs.sh
#
# Builds the TWO freestanding static ELF64 executables this harness puts on its
# test disk -- FROM ONE SOURCE FILE, TWICE -- and then CHECKS WHAT IT BUILT.
#
# WHY ONE SOURCE AND NOT TWO, IN ONE SENTENCE: the isolation claim this
# milestone makes is that two processes writing DIFFERENT patterns to THE SAME
# VIRTUAL ADDRESS each read back their own, and two programs only share a heap
# address if they have the same segment geometry.
#
# So `prog.c` is compiled twice with nothing different but two `-D` constants
# that land in `.rodata` behind a `volatile const`, and the check below reads both
# ELFs and REQUIRES their PT_LOAD geometry to be byte-identical while requiring
# the files themselves to differ. A `#if` would have folded a branch away, made
# the two binaries different sizes, given them different heap bases, and left
# nothing to argue about.
#
# Usage:
#   build-progs.sh <outdir>      -> <outdir>/progH.elf, <outdir>/progP.elf
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

# Exactly m11-proc/build-progs.sh's flags. SSE is still on (no
# `-mgeneral-regs-only`) because M11 turned it on and a milestone must not
# quietly build its programs the old way; the heap has nothing to do with it.
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

# The two -D pairs. The signatures are chosen so that every nibble differs and
# so that neither can be produced from the other by a shift or a mask -- a heap
# page holding the other process's data has to be unmistakable in a hex dump.
build_one() {
  local tag="$1" id="$2" sig="$3"
  clang "${CFLAGS[@]}" -DPROG_ID="$id" -DPROG_SIG="$sig" \
    "$SCRIPT_DIR/prog.c" -o "$OUT/prog$tag.o" \
    || fail "clang could not compile prog.c as prog$tag"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$tag.elf" "$OUT/prog$tag.o" \
    || fail "x86_64-elf-ld could not link prog$tag.elf"
  [[ -s "$OUT/prog$tag.elf" ]] || fail "the linker reported success but produced no prog$tag.elf"
}

build_one H 0 0x00A0000C0DE10000UL
build_one P 1 0x00B0000C0DE20000UL

cmp -s "$OUT/progH.elf" "$OUT/progP.elf" && \
  fail "progH.elf and progP.elf are byte-identical — the two processes would write the same pattern and 'each read back its own' would be vacuous"

python3 - "$OUT/progH.elf" "$OUT/progP.elf" <<'PY' || fail "the programs that were built are not the ones this harness needs"
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

    # e_entry is neither the segment base nor page-aligned (m10-elf's finding,
    # kept: an e_entry equal to the segment base lets a kernel that ignores
    # e_entry pass every behavioural check).
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

    # THE HEAP BASE, COMPUTED THE WAY THE KERNEL COMPUTES IT: one past the
    # highest page any PT_LOAD touches. `elfMapPage` rounds every p_vaddr down
    # and every end up, and `elfMetaHi` is the maximum.
    hi = 0
    for s in loads:
        end = s["vaddr"] + s["memsz"]
        hi = max(hi, (end + PAGE - 1) & ~(PAGE - 1))
    room = (HEAP_TOP - hi) // PAGE
    if room < 400:
        fails.append("%s: only %d heap pages would fit above 0x%X. The growth loop needs "
                     "enough room that exhausting the window is a real test." % (name, room, hi))

    # BOTH PATCH POINTS MUST EXIST AND MUST BE `nop; nop`. make-image.py writes
    # `EB FE` over one of them; if the two bytes there were half of a longer
    # instruction the variant would run something nobody wrote.
    syms = {}
    out = subprocess.run(["x86_64-elf-readelf", "-sW", elf], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 8 and re.fullmatch(r"[0-9a-f]{16}", f[1]):
            syms[f[7]] = int(f[1], 16)
    for want in ("heapHoldEarly", "heapHoldLate", "progSig", "progId"):
        if want not in syms:
            fails.append("%s: no symbol %s -- make-image.py and derive.py both need it" % (name, want))
    for want in ("heapHoldEarly", "heapHoldLate"):
        va = syms.get(want)
        if va is None:
            continue
        fo = None
        for s in loads:
            if s["vaddr"] <= va < s["vaddr"] + s["filesz"]:
                fo = s["offset"] + (va - s["vaddr"])
        if fo is None:
            fails.append("%s: %s at 0x%X is in no file-backed segment" % (name, want, va))
            continue
        if blob[fo:fo + 2] != b"\x90\x90":
            fails.append("%s: the first two bytes of %s are %s, expected 90 90 (nop; nop) -- "
                         "make-image.py's `jmp .` patch would split an instruction"
                         % (name, want, blob[fo:fo + 2].hex()))

    # Still built with SSE on (M11's property, not this milestone's, and it must
    # not silently regress).
    whole = subprocess.run(["x86_64-elf-objdump", "-d", elf], capture_output=True, text=True).stdout
    if not re.search(r"%(x|y|z)mm\d", whole):
        fails.append("%s: no %%xmm register anywhere -- built without SSE, which M11 turned on" % name)

    rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf], capture_output=True, text=True).stdout
    if re.search(r"^\s*[0-9a-f]{8,}\s+[0-9a-f]{8,}\s+R_X86_64", rel, re.M):
        fails.append("%s: still has dynamic relocations; this kernel applies none" % name)

    return {"entry": entry, "loads": loads, "hi": hi, "room": room, "syms": syms}


h = load(sys.argv[1], "progH.elf")
p = load(sys.argv[2], "progP.elf")

# THE ASSERTION THIS FILE EXISTS FOR: identical geometry, different content.
if h and p:
    for i, (a, b) in enumerate(zip(h["loads"], p["loads"])):
        for k in ("vaddr", "filesz", "memsz", "flags", "offset"):
            if a[k] != b[k]:
                fails.append("PT_LOAD %d: progH's %s is 0x%X and progP's is 0x%X. The two "
                             "programs must have IDENTICAL geometry or their heaps start at "
                             "different addresses and the isolation check compares nothing."
                             % (i, k, a[k], b[k]))
    if h["entry"] != p["entry"]:
        fails.append("the two builds have different e_entry (0x%X vs 0x%X)" % (h["entry"], p["entry"]))
    if h["hi"] != p["hi"]:
        fails.append("the two builds' heap bases differ: 0x%X vs 0x%X" % (h["hi"], p["hi"]))
    if h["syms"].get("progSig") != p["syms"].get("progSig"):
        fails.append("progSig is at a different address in the two builds")

if fails:
    print("build-progs: the built programs are wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)

print("    (one source, two builds: entry 0x%X, R+X %d/%d at 0x%X, R+W %d/%d at 0x%X, "
      "identical geometry, heap base 0x%X with room for %d pages, both patch points nop;nop)"
      % (h["entry"], h["loads"][0]["filesz"], h["loads"][0]["memsz"], h["loads"][0]["vaddr"],
         h["loads"][1]["filesz"], h["loads"][1]["memsz"], h["loads"][1]["vaddr"],
         h["hi"], h["room"]))
PY

echo "build-progs: PASS — $OUT/progH.elf ($(wc -c <"$OUT/progH.elf" | tr -d ' ') bytes) and $OUT/progP.elf ($(wc -c <"$OUT/progP.elf" | tr -d ' ') bytes)"
exit 0
