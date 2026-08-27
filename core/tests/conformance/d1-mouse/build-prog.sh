#!/usr/bin/env bash
# core/tests/conformance/d1-mouse/build-prog.sh
#
# Builds D1's one freestanding static ELF64 witness and then CHECKS WHAT IT
# BUILT. Same discipline as m18-preempt's and m20-ipc's build scripts, narrowed
# to what this milestone's program has to be:
#
#   * IT ISSUES EXACTLY THE THREE SYSCALLS IT DECLARES -- 0 (exit), 1 (write)
#     and 16 (mouse) -- and no others. Read by walking backwards from every
#     `int $0x80` to the last thing that wrote RAX, which is m18's technique and
#     is here for m18's reason: collecting every immediate ever moved into RAX
#     reports data as syscall numbers.
#   * IT ACTUALLY ISSUES 16. A program that never called the syscall under test
#     would still print two well-formed lines -- of zeroes -- and the harness's
#     ring-3 check would then be asserting the value of a variable this program
#     never asked the kernel for. This is the control for that.
#   * ITS `SYS_MOUSE` IS THE KERNEL'S `mouseSysNo`. The program carries a private
#     copy of the number because it is freestanding and shares no header; this is
#     the check that makes a private copy safe rather than a second source of
#     truth. `docs/syscall-registry.md` lists both places.
#   * m11's SEGMENT SHAPE, unchanged and for m11's reasons: two PT_LOAD segments
#     R+X and R+W, an e_entry that is neither the segment base nor page-aligned,
#     and no dynamic relocations.
#
# Usage:
#   build-prog.sh <outdir> <kerneldir>   -> <outdir>/ptr.elf
#
# Exit status: 0 on success, 1 on a build failure, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "build-prog: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-prog: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
KERNEL_DIR="${2:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-prog.sh <outdir> <kerneldir>"
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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/ptr.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/ptr.elf" "$OUT/ptr.o" \
  || fail "x86_64-elf-ld could not link ptr.elf"
[[ -s "$OUT/ptr.elf" ]] || fail "the linker reported success but produced no ptr.elf"

python3 - "$OUT/ptr.elf" "$KERNEL_DIR/mouse.dart" "$SCRIPT_DIR/prog.c" <<'PY' \
  || fail "the program that was built is not the one this harness needs"
import re, subprocess, sys

elf, mouse_dart, prog_c = sys.argv[1], sys.argv[2], sys.argv[3]
fails = []
blob = open(elf, "rb").read()

if blob[0:4] != b"\x7fELF":
    fails.append("no ELF magic")
if blob[4] != 2 or blob[5] != 1:
    fails.append("not ELF64 little-endian")
if int.from_bytes(blob[16:18], "little") != 2:
    fails.append("e_type is not 2 (ET_EXEC)")
if int.from_bytes(blob[18:20], "little") != 0x3E:
    fails.append("e_machine is not 0x3E")

phoff = int.from_bytes(blob[32:40], "little")
phentsize = int.from_bytes(blob[54:56], "little")
phnum = int.from_bytes(blob[56:58], "little")
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
    print("build-prog: the built program is wrong:", file=sys.stderr)
    print("    - %d PT_LOAD segments, expected 2" % len(loads), file=sys.stderr)
    sys.exit(1)
if loads[0]["flags"] != 5:
    fails.append("first PT_LOAD has p_flags %d, expected 5 (R+X)" % loads[0]["flags"])
if loads[1]["flags"] != 6:
    fails.append("second PT_LOAD has p_flags %d, expected 6 (R+W)" % loads[1]["flags"])
for s in loads:
    if (s["offset"] & 0xFFF) != (s["vaddr"] & 0xFFF):
        fails.append("p_offset 0x%X and p_vaddr 0x%X are not congruent mod 4096"
                     % (s["offset"], s["vaddr"]))
    if not (0x10000000 <= s["vaddr"] < 0x101FF000):
        fails.append("p_vaddr 0x%X is outside the kernel's program window" % s["vaddr"])
if any(s["type"] in (2, 3) for s in segs):
    fails.append("has PT_DYNAMIC or PT_INTERP -- not statically linked")

entry = int.from_bytes(blob[24:32], "little")
off = entry - loads[0]["vaddr"]
if off == 0:
    fails.append("e_entry IS the first byte of the first PT_LOAD -- a kernel that "
                 "ignored e_entry would pass every behavioural check")
elif (off & 0xFFF) == 0:
    fails.append("e_entry is 0x%X past the segment base, a whole number of pages" % off)

rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf], capture_output=True, text=True).stdout
if re.search(r"^\s*[0-9a-f]{8,}\s+[0-9a-f]{8,}\s+R_X86_64", rel, re.M):
    fails.append("still has dynamic relocations; this kernel applies none")

# ---------------------------------------------------------------------------
# THE SYSCALLS THIS PROGRAM CAN ISSUE.
# ---------------------------------------------------------------------------
dis = subprocess.run(["x86_64-elf-objdump", "-d", elf], capture_output=True, text=True).stdout
insns = [l.strip() for l in dis.splitlines() if re.match(r"^\s+[0-9a-f]+:\s", l)]
sites = [l for l in insns if re.search(r"\bint\s+\$0x80\b", l)]
if not sites:
    fails.append("no `int $0x80` at all -- this program cannot reach the kernel")
nums = set()
for i, l in enumerate(insns):
    if not re.search(r"\bint\s+\$0x80\b", l):
        continue
    num = "UNKNOWN"
    for j in range(i - 1, max(-1, i - 25), -1):
        p = insns[j]
        mm = re.search(r"\bmov[lq]?\s+\$(0x[0-9a-f]+),%(?:e|r)ax\b", p)
        if mm:
            num = int(mm.group(1), 16)
            break
        if re.search(r"\bxor[lq]?\s+%(e|r)ax,%(e|r)ax\b", p):
            num = 0
            break
        if re.search(r",%(e|r)ax\b", p) or re.search(r"\bcall\b", p):
            break
    nums.add(num)
allowed = {0, 1, 16}
extra = nums - allowed
if extra:
    fails.append("issues syscall number(s) %s; it declares only 0 (exit), 1 (write) "
                 "and 16 (mouse). UNKNOWN means the number reaching RAX is not a "
                 "constant this script can read, which is itself a reason to look."
                 % ", ".join(str(n) for n in sorted(extra, key=str)))
if 16 not in nums:
    fails.append("never loads 16 into RAX -- IT NEVER CALLS THE SYSCALL UNDER TEST, "
                 "and would still print two well-formed lines of zeroes")

# ---------------------------------------------------------------------------
# prog.c's PRIVATE COPY OF THE SYSCALL NUMBER IS THE KERNEL'S.
# ---------------------------------------------------------------------------
kern = open(mouse_dart).read()
m = re.search(r"^const int mouseSysNo = (\d+);", kern, re.M)
if not m:
    fails.append("mouse.dart declares no `const int mouseSysNo`")
else:
    kv = int(m.group(1))
    mp = re.search(r"^#define SYS_MOUSE (\d+)$", open(prog_c).read(), re.M)
    if not mp:
        fails.append("prog.c has no `#define SYS_MOUSE`")
    elif int(mp.group(1)) != kv:
        fails.append("prog.c's SYS_MOUSE is %s and mouse.dart's mouseSysNo is %d"
                     % (mp.group(1), kv))

if fails:
    print("build-prog: the built program is wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)

print("    (ptr.elf: ET_EXEC EM_X86_64, entry 0x%X, R+X %d/%d at 0x%X, R+W %d/%d at 0x%X, "
      "no relocations, %d syscall site(s), numbers %s -- 16 among them)"
      % (entry, loads[0]["filesz"], loads[0]["memsz"], loads[0]["vaddr"],
         loads[1]["filesz"], loads[1]["memsz"], loads[1]["vaddr"],
         len(sites), sorted(nums, key=str)))
PY

echo "build-prog: PASS — $OUT/ptr.elf ($(wc -c <"$OUT/ptr.elf" | tr -d ' ') bytes)"
exit 0
