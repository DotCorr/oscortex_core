#!/usr/bin/env bash
# core/tests/conformance/m20-ipc/build-progs.sh
#
# Builds THE ONE freestanding static ELF64 executable this harness puts on its
# test disk -- twice over, at two different sector numbers -- and then CHECKS
# WHAT IT BUILT.
#
# THIS IS m18-preempt/build-progs.sh WITH ITS CENTRAL ASSERTION INVERTED.
#
#   m18 requires progC.elf and progD.elf to DIFFER, because "two programs ran"
#   would otherwise be one program running twice. M20 requires the two disk
#   slots to be THE SAME BYTES, because the milestone's claim is that the two
#   processes take different roles ON THE KERNEL'S SAY-SO. `make-image.py`
#   writes one file to two slots and asserts the two sector ranges compare
#   equal; this script asserts the properties of the one binary.
#
# What is checked here that no boot could establish:
#
#   * THE PROGRAM ISSUES EXACTLY THE SIX SYSCALLS IT DECLARES and no others --
#     0 (exit), 1 (write), 3 (yield), 13 (chanopen), 14 (chansend), 15
#     (chanrecv). They were 11, 12 and 13 until the merge with S0: the syscall
#     registry had reserved 11 for `fdwait` and allocated 12 to `ioctl`, so the
#     channel moved to the next free numbers. See docs/syscall-registry.md and
#     GAP-0213. Read by walking backwards from every `int $0x80` to the last
#     thing that wrote RAX, which is m18's technique and is here for m18's
#     reason: collecting every immediate ever moved into RAX reports data as
#     syscall numbers.
#   * `roReq` IS IN A READ-ONLY SEGMENT. The program sends round 3's request
#     straight out of it, and the whole value of that positive control is that
#     the page is one ring 3 cannot write. If the linker put it in the RW
#     segment the control would be testing nothing.
#   * THE THIRTEEN REFUSAL CONSTANTS IN prog.c ARE THE THIRTEEN IN chan.dart.
#     The program carries a private copy of the kernel's return values because
#     it is freestanding and shares no header; this is the check that makes a
#     private copy safe rather than a second source of truth.
#   * m11's SEGMENT SHAPE, unchanged and for m11's reasons: two PT_LOAD
#     segments R+X and R+W, an e_entry that is neither the segment base nor
#     page-aligned, an RW segment that is not page-aligned and has a zero tail,
#     and no dynamic relocations.
#
# Usage:
#   build-progs.sh <outdir> <kerneldir>   -> <outdir>/ipc.elf
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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/ipc.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/ipc.elf" "$OUT/ipc.o" \
  || fail "x86_64-elf-ld could not link ipc.elf"
[[ -s "$OUT/ipc.elf" ]] || fail "the linker reported success but produced no ipc.elf"

python3 - "$OUT/ipc.elf" "$KERNEL_DIR/chan.dart" "$SCRIPT_DIR/prog.c" <<'PY' \
  || fail "the program that was built is not the one this harness needs"
import re, subprocess, sys

elf, chan_dart, prog_c = sys.argv[1], sys.argv[2], sys.argv[3]
fails = []
blob = open(elf, "rb").read()

# ---------------------------------------------------------------------------
# m11's ELF shape, unchanged.
# ---------------------------------------------------------------------------
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
if phentsize != 56:
    fails.append("e_phentsize is %d, expected 56" % phentsize)
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
    fails.append("%d PT_LOAD segments, expected 2" % len(loads))
    print("build-progs: the built program is wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
if loads[0]["flags"] != 5:
    fails.append("first PT_LOAD has p_flags %d, expected 5 (R+X)" % loads[0]["flags"])
if loads[1]["flags"] != 6:
    fails.append("second PT_LOAD has p_flags %d, expected 6 (R+W)" % loads[1]["flags"])
for s in loads:
    if (s["flags"] & 2) and (s["flags"] & 1):
        fails.append("a PT_LOAD is W+X; the kernel would refuse it")
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
if (loads[1]["vaddr"] & 0xFFF) == 0:
    fails.append("the RW segment's p_vaddr 0x%X is page-aligned" % loads[1]["vaddr"])
if loads[1]["filesz"] == 0:
    fails.append("the RW segment has p_filesz 0")
if loads[1]["memsz"] <= loads[1]["filesz"]:
    fails.append("the RW segment has no p_memsz - p_filesz tail")

rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf], capture_output=True, text=True).stdout
if re.search(r"^\s*[0-9a-f]{8,}\s+[0-9a-f]{8,}\s+R_X86_64", rel, re.M):
    fails.append("still has dynamic relocations; this kernel applies none")

# ---------------------------------------------------------------------------
# `roReq` IS IN THE READ-ONLY SEGMENT.
#
# The program sends round 3's request straight out of it, and the harness
# separately makes the kernel REFUSE a receive INTO it. Both halves of that
# depend on the page being one ring 3 cannot write, which is a property of
# where the linker put the symbol and of nothing else.
# ---------------------------------------------------------------------------
syms = subprocess.run(["x86_64-elf-readelf", "-sW", elf], capture_output=True, text=True).stdout
m = re.search(r"^\s*\d+:\s+([0-9a-f]+)\s+(\d+)\s+OBJECT\s+\S+\s+\S+\s+\S+\s+roReq\s*$",
              syms, re.M)
if not m:
    fails.append("roReq is not in the symbol table -- the .rodata positive control is gone")
else:
    ro_addr, ro_size = int(m.group(1), 16), int(m.group(2))
    if ro_size != 47:
        fails.append("roReq is %d bytes, expected 47 (REQLEN(3))" % ro_size)
    rx = loads[0]
    rw = loads[1]
    if not (rx["vaddr"] <= ro_addr and ro_addr + ro_size <= rx["vaddr"] + rx["filesz"]):
        fails.append("roReq is at 0x%X, which is NOT inside the R+X PT_LOAD "
                     "[0x%X, 0x%X) -- the read-only positive control is testing nothing"
                     % (ro_addr, rx["vaddr"], rx["vaddr"] + rx["filesz"]))
    if rw["vaddr"] <= ro_addr < rw["vaddr"] + rw["memsz"]:
        fails.append("roReq is inside the WRITABLE PT_LOAD")
    # ...and its bytes are reqbyte(3, i), computed here rather than trusted.
    fo = rx["offset"] + (ro_addr - rx["vaddr"])
    got = blob[fo:fo + ro_size]
    want = bytes((0x41 + ((3 * 7 + i * 11) % 26)) & 0xFF for i in range(47))
    if got != want:
        fails.append("roReq's bytes are not reqbyte(3, i): got %r" % got[:16])

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
allowed = {0, 1, 3, 13, 14, 15}
extra = nums - allowed
if extra:
    fails.append("issues syscall number(s) %s; it declares only 0 (exit), 1 (write), "
                 "3 (yield), 13 (chanopen), 14 (chansend) and 15 (chanrecv). UNKNOWN "
                 "means the number reaching RAX is not a constant this script can read, "
                 "which is itself a reason to look."
                 % ", ".join(str(n) for n in sorted(extra, key=str)))
for need, why in ((13, "chanopen"), (14, "chansend"), (15, "chanrecv"), (3, "yield")):
    if need not in nums:
        fails.append("never loads %d into RAX -- it never calls `%s`" % (need, why))

# ---------------------------------------------------------------------------
# prog.c's PRIVATE COPY OF THE KERNEL'S RETURN VALUES IS THE KERNEL'S.
# ---------------------------------------------------------------------------
kern = open(chan_dart).read()
kv = {n: int(v, 16) for n, v in
      re.findall(r"^const int (chanRet\w+) = (0x[0-9A-Fa-f]+);", kern, re.M)}
src = open(prog_c).read()
pv = {n: int(v, 16) for n, v in
      re.findall(r"^#define (CHAN_\w+) (0x[0-9A-Fa-f]+)UL$", src, re.M)}
pairs = {
    "CHAN_FLOOR": "chanRetFloor", "CHAN_BADPORT": "chanRetBadPort",
    "CHAN_NOPROC": "chanRetNoProc", "CHAN_BUSY": "chanRetBusy",
    "CHAN_TWICE": "chanRetTwice", "CHAN_BADEP": "chanRetBadEp",
    "CHAN_NOTOWNER": "chanRetNotOwner", "CHAN_BADPTR": "chanRetBadPtr",
    "CHAN_BADLEN": "chanRetBadLen", "CHAN_FULL": "chanRetFull",
    "CHAN_EMPTY": "chanRetEmpty", "CHAN_NOPEER": "chanRetNoPeer",
    "CHAN_PEERGONE": "chanRetPeerGone", "CHAN_TOOBIG": "chanRetTooBig",
}
for c, d in sorted(pairs.items()):
    if d not in kv:
        fails.append("chan.dart has no %s" % d)
    elif c not in pv:
        fails.append("prog.c has no %s" % c)
    elif kv[d] != pv[c]:
        fails.append("prog.c's %s is 0x%X and chan.dart's %s is 0x%X"
                     % (c, pv[c], d, kv[d]))
# ...and the kernel has no refusal the program has not been told about, other
# than the one that cannot be provoked from ring 3.
unknown = set(kv) - set(pairs.values()) - {"chanRetCorrupt"}
if unknown:
    fails.append("chan.dart declares %s, which prog.c does not know about -- a new "
                 "refusal was added without teaching the program to recognise it"
                 % ", ".join(sorted(unknown)))

if fails:
    print("build-progs: the built program is wrong:", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)

print("    (ipc.elf: ET_EXEC EM_X86_64, entry 0x%X, R+X %d/%d at 0x%X, R+W %d/%d at 0x%X, "
      "no relocations, %d syscall site(s), numbers %s, roReq 47 bytes at 0x%X in the "
      "READ-ONLY segment)"
      % (entry, loads[0]["filesz"], loads[0]["memsz"], loads[0]["vaddr"],
         loads[1]["filesz"], loads[1]["memsz"], loads[1]["vaddr"],
         len(sites), sorted(nums, key=str), ro_addr))
print("    (all 14 of prog.c's CHAN_* return values are chan.dart's chanRet*, "
      "and chan.dart declares no refusal prog.c has not been taught)")
PY

echo "build-progs: PASS — $OUT/ipc.elf ($(wc -c <"$OUT/ipc.elf" | tr -d ' ') bytes), ONE binary for BOTH disk slots"
exit 0
