#!/usr/bin/env bash
# core/tests/conformance/m10-elf/run.sh
#
# Mechanical check of ROADMAP.md's M10 exit criterion: this kernel can load a
# program it did not compile into itself off a disk, honour the addresses and
# permissions that program's own ELF headers ask for, run it at CPL 3, and
# report what it did.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# M9 ran code at CPL 3, and that code was 136 bytes of hand-written machine
# code in the kernel's own `.rodata` -- copied into whatever frame the allocator
# handed out, position-independent because it had to be, entered at the frame's
# first byte because that is where the copy put it. ADR-0013 §4 said so and
# GAP-0085 item 5 listed the absence.
#
# **NOTHING IN THIS KERNEL CHOSE ANY OF THE ADDRESSES BELOW.** The program is
# compiled and linked by build-prog.sh, written onto a disk by make-image.py,
# and every number the kernel acts on -- `e_entry`, each `p_vaddr`, each
# `p_flags` -- is read out of that file at run time. So every expectation in
# this harness is DERIVED FROM THE BINARY (derive.py's `Elf`) rather than typed:
#
#   * the entry point is the `e_entry` in the file, and boot B catches the CPU
#     executing at exactly that address;
#   * the message the program prints is the bytes at its `msg` symbol, read out
#     of the file image, compared to the serial capture byte for byte;
#   * the exit status is `exit_status + data_word`, both read out of the file --
#     one from the read-only segment, one from the writable one -- so a status
#     that matches proves both segments' CONTENTS arrived, and `.bss` was zero;
#   * the permissions of every mapped page are the ones that segment's `p_flags`
#     asks for, read out of the LIVE page tables in guest physical memory.
#
# A MALFORMED FILE IS REFUSED, NOT RUN
# ---------------------------------------------------------------------------
# make-image.py puts SEVEN programs on the disk. Six are the good one with ONE
# field changed, so the difference between "runs" and "refused with this
# sentence" is exactly that field:
#
#   badmagic   e_ident[0] 0x7F -> 0x7E
#   wx         the R+X segment's p_flags gains PF_W -- W^X applies to guests
#   interp     a PT_INTERP header: this loader does not link
#   badentry   e_entry moved onto the non-executable segment
#   gp         `mov %cr3,%rax` at e_entry -- loads, runs, and DIES in ring 3,
#              which is what tests the fault path's teardown
#   spin       `jmp .` at e_entry -- loads and never stops, so the tables can be
#              read with a loaded program ON THE CPU
#
# FOUR BOOTS, EACH MAKING A CLAIM THE OTHERS CANNOT
# ---------------------------------------------------------------------------
#   A  128M   the driven session: the good program runs to completion, then
#             every refusal in turn, then the fault control. Serial golden +
#             screen + PNG, and the allocator's free count back at its baseline
#             at the end -- nothing leaked across seven loads.
#   B  128M   THE PROGRAM IS LEFT RUNNING. `spin` never exits, so QEMU's own
#             `info registers` can be asked where the CPU is: CPL 3, CS 0x23,
#             RIP == e_entry. The page tables are then dumped -- at CR3 and at
#             the program's own page-table frame, two disjoint regions -- and
#             every page checked against the ELF's p_flags.
#   C  32M    NEGATIVE CONTROL -- a different machine. Different memory map,
#             different frames, and the program must still run and still exit
#             with the same status, which is a status derived from the FILE and
#             not from where it landed.
#   D  128M   NEGATIVE CONTROL -- no frames. `frames drain` first, so `run` must
#             REFUSE rather than load a program into pages nobody allocated.
#
# `qmp-drive.py` is REUSED from m2-console unchanged -- one driver, nine
# harnesses now.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart bash core/tests/conformance/m10-elf/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "M10-elf: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M10-elf: FAIL — $1" >&2
  exit 2
}

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf llvm-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
DERIVE="$SCRIPT_DIR/derive.py"
BUILD_PROG="$SCRIPT_DIR/build-prog.sh"
MAKE_IMAGE="$SCRIPT_DIR/make-image.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
for f in "$DERIVE" "$BUILD_PROG" "$MAKE_IMAGE"; do
  [[ -f "$f" ]] || setup_error "$f not found"
done
[[ -f "$DRIVER" ]] || setup_error "QMP driver not found at $DRIVER (m10-elf reuses m2-console's)"

M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$M1_EXPECTED" ]] || setup_error "M1 golden not found at $M1_EXPECTED"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m10.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

hexnum() { python3 -c "import sys; print(int(sys.argv[1], 16))" "$1"; }
dartconst() {
  awk -F'= *' -v n="$1" '$0 ~ ("^const int " n " =") { gsub(/;.*/,"",$2); print $2; exit }' \
    "$CORE_DIR/kernel/$2"
}

# ---------------------------------------------------------------------------
# Step 1 — build the kernel.
# ---------------------------------------------------------------------------
BUILD_LOG="$WORKDIR/build.log"
bash "$CORE_DIR/scripts/build-kernel.sh" >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
cat "$BUILD_LOG"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS (log above)"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
[[ -f "$KERNEL_ELF" ]] || fail "build-kernel.sh reported success but $KERNEL_ELF was not produced"

# ---------------------------------------------------------------------------
# Step 2 — build the PROGRAM and the disk it lives on.
#
# Before the structural checks, because several of them read fields out of the
# program to check the kernel's constants against.
# ---------------------------------------------------------------------------
bash "$BUILD_PROG" "$WORKDIR" || fail "the test program could not be built (see above)"
PROG_ELF="$WORKDIR/prog.elf"

DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
python3 "$MAKE_IMAGE" "$DISK_IMG" "$PROG_ELF" --emit "$WORKDIR/variants" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_GOOD=$(lba_of good)
LBA_BADMAGIC=$(lba_of badmagic)
LBA_WX=$(lba_of wx)
LBA_INTERP=$(lba_of interp)
LBA_BADENTRY=$(lba_of badentry)
LBA_GP=$(lba_of gp)
LBA_SPIN=$(lba_of spin)
IMG_BYTES=$(wc -c <"$DISK_IMG" | tr -d ' ')
echo "IMAGE: pass  $IMG_BYTES bytes = $(( IMG_BYTES / 512 )) sectors, 7 programs, generated and re-read from disk"

# ---------------------------------------------------------------------------
# Step 3 — structural checks (CLAUDE.md: anything checkable without booting
# should be).
# ---------------------------------------------------------------------------

# 3a. DONATED `.bss` GREW FROM 5368 TO 5496, AND THIS HARNESS NOW OWNS THE
#     NUMBER.
#
# 16 (M2) -> 304 (M3) -> 392 (M4) -> 424 (M5) -> 424 (M6) -> 5096 (M7) ->
# 5224 (M8) -> 5368 (M9) -> 5496 (M10). Each time, ownership passes to the
# harness for the milestone that grew it, and the earlier harnesses keep
# asserting their own claim by SUBTRACTING the blocks that came after theirs.
# M10's 128 bytes are the ELF loader's state and nothing else -- in particular
# there is still NO SECTOR BUFFER in this file: `ataReadInto` reads into an
# address the caller owns. docs/known-gaps.md GAP-0053.
KDATA_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$KDATA_BSS_HEX" ]] || fail "kdata.o has no .bss section — the donated storage is missing"
KDATA_BSS=$(hexnum "$KDATA_BSS_HEX")
ELF_STORE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="elf_store"{print $3; exit}')
[[ "$ELF_STORE" == "128" ]] || fail "kdata.o's elf_store is ${ELF_STORE:-missing} bytes, expected 128"
M10_STORE="$ELF_STORE"
# M11 (ADR-0015) added a fifth block after M10's: `proc_store` (4160 bytes -- an
# 8-word header, four 512-byte process slots, and four 512-byte FXSAVE areas).
# Its `.align 16` is a CORRECTNESS requirement and not hygiene (`fxsave` on a
# misaligned operand is a #GP, not a slow path), and it also inserts 8 bytes of
# padding after `elf_store`, so M11 really costs 4168 bytes and not 4160.
#
# M11's share is therefore measured as EVERYTHING PAST THE END OF M10's BLOCK
# rather than as `proc_store`'s own size: the padding is charged to the
# milestone whose alignment made it necessary, and this harness's own number
# comes out exactly as it did before M11 existed.
M11_ELF_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="elf_store"{print $2; exit}')
[[ -n "$M11_ELF_OFF_HEX" ]] || fail "elf_store has no .bss offset in kdata.o"
# M15 (ADR-0019) added a block AFTER M14's: `file_store`, 1280 bytes -- 16
# metadata words, five rows of four file descriptors, and a one-sector bounce
# buffer. Subtracted FIRST, before M14's, so that this harness's own milestone's
# number continues to mean in 2026 what it meant when it was written.
M15_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="file_store"{print $2; exit}')
[[ -n "$M15_OFF_HEX" ]] || fail "file_store has no .bss offset in kdata.o -- M15's file-descriptor block is missing"
M15_BSS=$(( KDATA_BSS - 16#$M15_OFF_HEX ))
[[ "$M15_BSS" -eq 1280 ]] || fail "the donated bytes from M15's file_store to the end of .bss are $M15_BSS, expected 1280. If M15's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M15_BSS ))
# M14 (ADR-0018) added a SIXTH block after M11's: `fat_store` (1824 bytes -- 32
# metadata words, a 256-entry cluster chain, one sector buffer and an 8.3 name
# buffer). Its `.align 8` inserts NO padding, because `proc_store` ends at a
# multiple of 16. Measured as everything from `fat_store`'s offset to the end of
# `.bss` and subtracted out below, so that THIS harness's own number and M11's
# both come out exactly as they did before M14 existed.
M14_OFF_HEX=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$8=="fat_store"{print $2; exit}')
[[ -n "$M14_OFF_HEX" ]] || fail "fat_store has no .bss offset in kdata.o — M14's filesystem state block is missing"
M14_BSS=$(( KDATA_BSS - 16#$M14_OFF_HEX ))
[[ "$M14_BSS" -eq 1824 ]] || fail "the donated bytes from M14's fat_store to the end of .bss are $M14_BSS, expected 1824. If M14's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
M11_BSS=$(( KDATA_BSS - 16#$M11_ELF_OFF_HEX - M10_STORE - M14_BSS ))
[[ "$M11_BSS" -eq 4168 ]] || fail "the donated bytes past the end of M10's elf_store are $M11_BSS, expected 4168 (M11's 4160-byte proc_store plus the 8 bytes of padding its .align 16 needs). If M11's block changed size, change it in kdata.S's header, in GAP-0053, and in every harness that subtracts it."
[[ $(( KDATA_BSS - M11_BSS - M14_BSS )) -eq 5496 ]] || fail "kdata.o .bss is $KDATA_BSS bytes, of which $M11_BSS are M11's process table and $M14_BSS are M14's filesystem block, leaving $(( KDATA_BSS - M11_BSS - M14_BSS )) — expected 5496 (5368 through M9, plus 128 for the ELF loader's state). If you meant to grow it, say so in kdata.S's header and in GAP-0053."
for sym in $(x86_64-elf-readelf -sW "$CORE_DIR/build/kdata.o" | awk '$4=="OBJECT" && $8 ~ /buffer|sector|elf_scratch/ {print $8}'); do
  fail "kdata.o donates '$sym'. M10 was supposed to add NO sector buffer: ataReadInto reads into a frame from the allocator, which is the whole answer to ROADMAP.md's 'the kernel can now read a disk and has nowhere to put what it read'."
done
echo "STRUCTURAL: pass  kdata.o donates exactly 5496 bytes of .bss — 5368 inherited, 128 for the ELF loader, and still no sector buffer"

# 3b. THE STORAGE SEAM IS EXACTLY ONE CALL SITE.
#
# The fourth subsystem to use ADR-0011 §0's pattern, and the same check
# m7-frames, m8-paging and m9-ring3 make on theirs.
SEAM_SITES=$(grep -c '^\s*return elf_store_addr()' "$CORE_DIR/kernel/elf.dart")
[[ "$SEAM_SITES" -eq 1 ]] || fail "elf_store_addr() is returned from $SEAM_SITES functions in elf.dart, expected exactly 1 (elfMetaBase). The storage seam is the whole mutable-statics migration plan — see elf.dart's header."
STRAY=$(grep -n 'elf_store_addr()' "$CORE_DIR/kernel/elf.dart" | grep -vE '^\s*[0-9]+:\s*(//|///|\*)' | grep -vE 'external u64 elf_store_addr\(\);' | grep -vc 'return elf_store_addr()')
[[ "$STRAY" -eq 0 ]] || fail "elf.dart has $STRAY call(s) of elf_store_addr() outside elfMetaBase"
for f in "$CORE_DIR"/kernel/*.dart; do
  [[ "$(basename "$f")" == "elf.dart" ]] && continue
  grep -q 'elf_store_addr' "$f" && fail "$(basename "$f") references elf_store_addr — the loader's storage seam must not leak out of elf.dart"
done
echo "STRUCTURAL: pass  elf_store_addr() is called from exactly 1 function, in elf.dart's storage seam, and from no other kernel source"

# 3c. THE ELF FIELD OFFSETS elf.dart USES ARE THE REAL ONES.
#
# Every one of them is a byte offset into a structure this kernel did not write,
# and a wrong one reads a DIFFERENT FIELD of a real file and produces a
# plausible wrong answer -- `e_machine` at the wrong offset would reject a valid
# binary, `e_entry` at the wrong offset would jump somewhere nobody chose.
#
# So each constant is used to decode the program the harness just built, and the
# result is compared against what `x86_64-elf-readelf` says the same field is.
# Two independent decoders of a third party's file format.
python3 - "$CORE_DIR/kernel/elf.dart" "$PROG_ELF" <<'PY' || fail "core/kernel/elf.dart's ELF64 field offsets do not agree with x86_64-elf-readelf"
import re, subprocess, sys
src = open(sys.argv[1]).read()
blob = open(sys.argv[2], "rb").read()
def const(name):
    m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);$" % name, src, re.M)
    if not m:
        sys.exit("elf.dart has no `const int %s`" % name)
    return int(m.group(1), 0)
rh = subprocess.run(["x86_64-elf-readelf", "-hW", sys.argv[2]],
                    capture_output=True, text=True).stdout
def readelf(label):
    m = re.search(r"^\s*%s:\s+(.*)$" % re.escape(label), rh, re.M)
    if not m:
        sys.exit("readelf printed no %r" % label)
    return m.group(1).strip()
def u(off, n):
    return int.from_bytes(blob[off:off + n], "little")
fails = []
# e_ident
if blob[0:4] != bytes((const("elfIdentMag0"), const("elfIdentMag1"),
                       const("elfIdentMag2"), const("elfIdentMag3"))):
    fails.append("elfIdentMag0..3 are not 7F 'E' 'L' 'F'")
if u(const("elfOffClass"), 1) != const("elfClass64"):
    fails.append("elfOffClass/elfClass64 do not decode this ELF64 file's EI_CLASS")
if u(const("elfOffData"), 1) != const("elfData2Lsb"):
    fails.append("elfOffData/elfData2Lsb do not decode EI_DATA")
if u(const("elfOffVersion"), 1) != const("elfVersionCurrent"):
    fails.append("elfOffVersion/elfVersionCurrent do not decode EI_VERSION")
# the fields readelf also prints
entry = int(readelf("Entry point address"), 16)
if u(const("elfOffEntry"), 8) != entry:
    fails.append("elfOffEntry=%d decodes 0x%X but readelf says the entry point "
                 "is 0x%X" % (const("elfOffEntry"), u(const("elfOffEntry"), 8), entry))
phoff = int(readelf("Start of program headers").split()[0])
if u(const("elfOffPhoff"), 8) != phoff:
    fails.append("elfOffPhoff=%d decodes %d but readelf says %d"
                 % (const("elfOffPhoff"), u(const("elfOffPhoff"), 8), phoff))
phentsize = int(readelf("Size of program headers").split()[0])
if u(const("elfOffPhentsize"), 2) != phentsize:
    fails.append("elfOffPhentsize=%d decodes %d but readelf says %d"
                 % (const("elfOffPhentsize"), u(const("elfOffPhentsize"), 2), phentsize))
if const("elfPhdrSize") != phentsize:
    fails.append("elfPhdrSize is %d but a program header is %d bytes"
                 % (const("elfPhdrSize"), phentsize))
phnum = int(readelf("Number of program headers").split()[0])
if u(const("elfOffPhnum"), 2) != phnum:
    fails.append("elfOffPhnum=%d decodes %d but readelf says %d"
                 % (const("elfOffPhnum"), u(const("elfOffPhnum"), 2), phnum))
if u(const("elfOffType"), 2) != const("elfTypeExec"):
    fails.append("elfOffType/elfTypeExec do not decode ET_EXEC")
if "EXEC" not in readelf("Type"):
    fails.append("readelf says the program is %r, not EXEC" % readelf("Type"))
if u(const("elfOffMachine"), 2) != const("elfMachineX8664"):
    fails.append("elfOffMachine/elfMachineX8664 do not decode EM_X86_64")
# the program-header field offsets, against the same headers readelf lists
rl = subprocess.run(["x86_64-elf-readelf", "-lW", sys.argv[2]],
                    capture_output=True, text=True).stdout
rows = re.findall(r"^\s+(LOAD|INTERP|DYNAMIC|NOTE|PHDR|GNU_\S+)\s+0x([0-9a-f]+)\s+"
                  r"0x([0-9a-f]+)\s+0x[0-9a-f]+\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+"
                  r"([RWE ]+)\s", rl, re.M)
if len(rows) != phnum:
    fails.append("readelf lists %d program headers, the header says %d"
                 % (len(rows), phnum))
FLAG = {"R": 4, "W": 2, "E": 1}
for i, (kind, off, va, fsz, msz, flg) in enumerate(rows):
    base = phoff + i * phentsize
    got = {
        "type": u(base + const("elfPhOffType"), 4),
        "flags": u(base + const("elfPhOffFlags"), 4),
        "offset": u(base + const("elfPhOffOffset"), 8),
        "vaddr": u(base + const("elfPhOffVaddr"), 8),
        "filesz": u(base + const("elfPhOffFilesz"), 8),
        "memsz": u(base + const("elfPhOffMemsz"), 8),
    }
    want_flags = sum(FLAG[c] for c in flg if c in FLAG)
    if kind == "LOAD" and got["type"] != const("elfPtLoad"):
        fails.append("phdr %d: elfPhOffType decodes %d, readelf says LOAD"
                     % (i, got["type"]))
    for key, want in (("offset", int(off, 16)), ("vaddr", int(va, 16)),
                      ("filesz", int(fsz, 16)), ("memsz", int(msz, 16))):
        if got[key] != want:
            fails.append("phdr %d: elfPhOff%s decodes 0x%X, readelf says 0x%X"
                         % (i, key.capitalize(), got[key], want))
    if got["flags"] != want_flags:
        fails.append("phdr %d: elfPhOffFlags decodes %d, readelf's %r is %d"
                     % (i, got["flags"], flg.strip(), want_flags))
# PF_* bits
if (const("elfPfX"), const("elfPfW"), const("elfPfR")) != (1, 2, 4):
    fails.append("elfPfX/elfPfW/elfPfR are not 1/2/4")
if (const("elfPtLoad"), const("elfPtDynamic"), const("elfPtInterp")) != (1, 2, 3):
    fails.append("elfPtLoad/elfPtDynamic/elfPtInterp are not 1/2/3")
if fails:
    print("m10-elf: ELF field offsets FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (every e_* and p_* offset in elf.dart decodes prog.elf to the same "
      "value x86_64-elf-readelf reports)")
PY
echo "STRUCTURAL: pass  every ELF64 field offset in elf.dart decodes the built program to the same value x86_64-elf-readelf reports"

# 3d. THE PROGRAM WINDOW'S GEOMETRY, MULTIPLIED OUT AGAINST ITSELF.
#
# vm.dart states five numbers about the window separately, because `dcc` at
# DCDART_PIN.txt's commit refuses a `u64` literal built from a constant
# expression (GAP-0077). Separately-stated numbers can disagree, so they are
# multiplied out here -- against each other, against derive.py's copies, and
# against the address prog.ld actually links at.
VM_PROG_BASE=$(hexnum "$(dartconst vmProgBase vm.dart | sed 's/^0x//')")
VM_PROG_END=$(hexnum "$(dartconst vmProgEnd vm.dart | sed 's/^0x//')")
VM_PROG_BYTES=$(dartconst vmProgBytes vm.dart)
VM_PROG_PAGES=$(dartconst vmProgPages vm.dart)
VM_PROG_PD=$(dartconst vmProgPdIndex vm.dart)
VM_PROG_STACK=$(hexnum "$(dartconst vmProgStackPage vm.dart | sed 's/^0x//')")
VM_PROG_TOP=$(hexnum "$(dartconst vmProgStackTop vm.dart | sed 's/^0x//')")
VM_BIG=$(dartconst vmBigBytes vm.dart)
VM_PAGE=$(dartconst vmPageBytes vm.dart)
VM_MAP=$(dartconst vmMapBytes vm.dart)
[[ $(( VM_PROG_BASE + VM_PROG_BYTES )) -eq $VM_PROG_END ]] || fail "vmProgBase + vmProgBytes != vmProgEnd"
[[ $(( VM_PROG_PAGES * VM_PAGE )) -eq $VM_PROG_BYTES ]] || fail "vmProgPages * vmPageBytes != vmProgBytes"
[[ $(( VM_PROG_BYTES )) -eq $VM_BIG ]] || fail "the program window is $VM_PROG_BYTES bytes, expected exactly one 2MiB page directory entry ($VM_BIG) — otherwise it needs more than one page table"
[[ $(( VM_PROG_BASE / VM_BIG )) -eq $VM_PROG_PD ]] || fail "vmProgBase / vmBigBytes is $(( VM_PROG_BASE / VM_BIG )) but vmProgPdIndex is $VM_PROG_PD"
[[ $(( VM_PROG_BASE % VM_BIG )) -eq 0 ]] || fail "vmProgBase is not 2MiB-aligned, so it does not start at a page-directory entry"
[[ "$VM_PROG_BASE" -ge "$VM_MAP" ]] || fail "the program window at 0x$(printf %X "$VM_PROG_BASE") is INSIDE [0, vmMapBytes) — installing it would replace part of the kernel's own identity map"
[[ $(( VM_PROG_TOP )) -eq $VM_PROG_END ]] || fail "vmProgStackTop != vmProgEnd"
[[ $(( VM_PROG_STACK + VM_PAGE )) -eq $VM_PROG_TOP ]] || fail "vmProgStackPage + one page != vmProgStackTop"
python3 - "$DERIVE" "$VM_PROG_BASE" "$VM_PROG_END" "$VM_PROG_PAGES" "$VM_PROG_PD" "$VM_PROG_STACK" <<'PY' || fail "derive.py's copy of the program window's geometry does not match vm.dart's"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("derive", sys.argv[1])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
want = [int(x) for x in sys.argv[2:7]]
got = [d.PROG_BASE, d.PROG_END, d.PROG_PAGES, d.PROG_PD_INDEX, d.PROG_STACK_PAGE]
if got != want:
    sys.exit("derive.py has %r, vm.dart has %r" % (got, want))
PY
grep -q "0x$(printf %X "$VM_PROG_BASE" | tr 'A-F' 'a-f')\|$(printf '0x%x' "$VM_PROG_BASE")" "$SCRIPT_DIR/prog.ld" \
  || fail "prog.ld does not link at 0x$(printf %X "$VM_PROG_BASE"), which is vm.dart's vmProgBase. The kernel would refuse every segment with 'a PT_LOAD lies outside the program window'."
echo "STRUCTURAL: pass  the program window is one 2MiB page-directory entry (index $VM_PROG_PD) at 0x$(printf %X "$VM_PROG_BASE"), above vmMapBytes, and prog.ld links there"

# 3e. W^X IS ENFORCED BY THE MAPPING PRIMITIVE, NOT ONLY BY THE LOADER.
#
# elf.dart refuses a PF_W|PF_X segment; vmProgMap refuses a write+exec request
# INDEPENDENTLY, so a future caller that forgot to check cannot create such a
# page. Both refusals are behaviourally tested by the `wx` program below; this
# is the structural half, and it is here because a behavioural test can only
# ever exercise one of the two.
grep -q 'return u64(vmProgWx);' "$CORE_DIR/kernel/vm.dart" \
  || fail "vmProgMap no longer returns vmProgWx — the mapping primitive has stopped refusing writable+executable pages, and elf.dart's check would be the only thing standing between a guest and a W+X page"
grep -q 'return u64(elfErrWx);' "$CORE_DIR/kernel/elf.dart" \
  || fail "elf.dart no longer refuses a PF_W|PF_X PT_LOAD by name"
echo "STRUCTURAL: pass  a writable+executable page is refused twice, independently — by elfCheckPhdr on p_flags and by vmProgMap on its arguments"

# 3e2. EVERY FRAME HANDED TO RING 3 IS ZEROED, CHECKED STRUCTURALLY BECAUSE THE
#      BEHAVIOURAL CHECK CANNOT FAIL ON THIS MACHINE.
#
# **This is a check that is here because a better one was found to be vacuous,
# and saying so is the point.** The program reports its own `.bss` as
# `BSS[00] SUM=00`, and boot B compares every loaded page against the file byte
# for byte with everything outside p_filesz required to be zero. Both of those
# PASSED on a kernel built in the sandbox with `vmZeroFrame` deleted from
# elfLoadSegment -- because a freshly-booted QEMU hands out RAM that is already
# zero, and nothing in this kernel dirties a frame before the loader gets it.
# The allocator is next-fit from a forward-moving cursor, so no shell sequence
# can make `run` land on a frame something else has written. docs/known-gaps.md
# GAP-0094 has the measurement.
#
# So the zeroing is asserted where it CAN be: every `allocFrame()` in elf.dart
# is paired with a `vmZeroFrame`, except the page-table frame, which
# `vmProgTableInstall` zeroes itself. The behavioural checks are not weakened --
# they caught a mutation that read sectors straight into the destination frame,
# which is the same bug's other half -- but neither of them is what stops the
# zeroing being deleted.
ALLOCS=$(grep -c 'allocFrame();' "$CORE_DIR/kernel/elf.dart")
ZEROES=$(grep -c 'vmZeroFrame(' "$CORE_DIR/kernel/elf.dart")
[[ "$ALLOCS" -eq 5 ]] || fail "elf.dart calls allocFrame() $ALLOCS times, expected 5 (the header frame, the sector scratch frame, the page-table frame, one per segment page, and the stack page). If you added one, it needs a vmZeroFrame beside it — see GAP-0094."
[[ "$ZEROES" -eq 4 ]] || fail "elf.dart calls vmZeroFrame() $ZEROES times, expected 4 — one for every allocFrame() except the page-table frame, which vmProgTableInstall zeroes. EVERY frame this loader hands to ring 3 must be zeroed before anything is copied into it, and on QEMU no behavioural check can tell you when that stops happening (GAP-0094)."
grep -q '^    vmZeroFrame(frame);$' "$CORE_DIR/kernel/elf.dart" || fail "elfLoadSegment no longer zeroes the frame before copying the segment into it. The .bss tail would then hold whatever the frame last contained, and ring 3 can read it."
grep -q '  vmZeroFrame(ptFrame);' "$CORE_DIR/kernel/vm.dart" || fail "vmProgTableInstall no longer zeroes the page-table frame — 512 words of allocator litter installed as a page table is 512 mappings the CPU will believe"
echo "STRUCTURAL: pass  every one of elf.dart's 5 allocFrame() calls is paired with a zeroing (4 here, the page table's inside vmProgTableInstall) — asserted structurally because on QEMU the behavioural check for it cannot fail (GAP-0094)"

# 3f. EVERY @rodata TABLE IS THE SIZE ITS CALL SITE PASSES.
#
# GAP-0060: a @rodata table carries no length (DCDart ADR-0040), so every byte
# count is a hand-maintained literal. M10 adds 59 tables and grows shellStrHelp
# again (1589 -> 1658, one new command line).
check_table() {
  local sym="$1" want="$2" got
  got=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" | awk -v s="$sym" '$8==s {print $3; exit}')
  [[ -n "$got" ]] || fail "$sym not found in kmain.o — a @rodata table M10 depends on was not emitted (a table with no call site is dropped by the linker)"
  [[ "$got" -eq "$want" ]] || fail "$sym is $got bytes but its call site passes $want (known-gaps GAP-0060)"
}
check_table shellStrHelp 2147
check_table elfStrDisk 13
check_table elfStrImage 7
check_table elfStrBytes 7
check_table elfStrIdent 16
check_table elfStrData 6
check_table elfStrType 6
check_table elfStrMachine 9
check_table elfStrEntry 10
check_table elfStrPhoff 7
check_table elfStrPhnum 7
check_table elfStrSeg 8
check_table elfStrFlags 7
check_table elfStrVaddr 7
check_table elfStrOff 5
check_table elfStrFilesz 8
check_table elfStrMemsz 7
check_table elfStrLoad 15
check_table elfStrSegments 10
check_table elfStrZeroed 8
check_table elfStrSectors 9
check_table elfStrPage 9
check_table elfStrPa 4
check_table elfStrWindow 17
check_table elfStrEnter 14
check_table elfStrStack 10
check_table elfStrFrame 7
check_table elfStrDone 14
check_table elfStrPages 7
check_table elfStrTeardown 19
check_table elfStrTable 7
check_table elfStrRefused 12
check_table elfCmdRun 3
check_table elfCmdRunSp 4
check_table elfStrUsage 73
check_table elfStrE01 47
check_table elfStrE02 29
check_table elfStrE03 14
check_table elfStrE04 33
check_table elfStrE05 47
check_table elfStrE06 52
check_table elfStrE07 37
check_table elfStrE08 40
check_table elfStrE09 40
check_table elfStrE10 42
check_table elfStrE11 29
check_table elfStrE12 26
check_table elfStrE13 32
check_table elfStrE14 22
check_table elfStrE15 34
check_table elfStrE16 56
check_table elfStrE17 51
check_table elfStrE18 42
check_table elfStrE19 27
check_table elfStrE20 51
check_table elfStrE21 42
check_table elfStrE22 32
check_table elfStrE23 40
check_table elfStrE24 24
check_table elfStrE25 47
echo "STRUCTURAL: pass  all 59 M10 message/command tables plus shellStrHelp (1658 -> 1871 -> 2147; M11 added three command lines, M14 four) are exactly the sizes their call sites pass"

# 3g. EVERY REFUSAL CODE HAS ITS OWN SENTENCE, AND NO TWO SENTENCES ARE THE SAME.
#
# The claim elf.dart makes is that an ELF file it will not run is REJECTED WITH
# THE FIELD NAMED. Twenty-five codes sharing four messages would satisfy every
# behavioural test in this harness and would not be that claim.
python3 - "$CORE_DIR/kernel/elf.dart" "$CORE_DIR/build/kmain.o" <<'PY' || fail "elf.dart's refusal codes and messages do not line up one-to-one"
import re, subprocess, sys
src = open(sys.argv[1]).read()
codes = re.findall(r"^const int (elfErr\w+) = (\d+);$", src, re.M)
codes = [(n, int(v)) for n, v in codes if n != "elfErrOk"]
if [v for _, v in codes] != list(range(1, len(codes) + 1)):
    sys.exit("the elfErr* codes are not 1..%d without gaps: %r"
             % (len(codes), codes))
# One `uartWrite(... elfStrEnn ...)` per code, and one `if (code == ...)` arm
# per code bar the last (which is the fall-through).
arms = re.findall(r"if \(code == u64\((elfErr\w+)\)\) \{\n\s*uartWrite\(Rodata\.addressOf\((elfStr\w+)\), u64\((\d+)\)\);",
                  src)
named = {a for a, _, _ in arms}
missing = [n for n, _ in codes if n not in named]
if len(missing) != 1:
    sys.exit("elfReportError names %d of the %d codes explicitly; exactly one "
             "(the last) should be the fall-through. Unnamed: %r"
             % (len(named), len(codes), missing))
tables = [t for _, t, _ in arms]
fallthrough = re.findall(r"uartWrite\(Rodata\.addressOf\((elfStrE\d+)\), u64\(\d+\)\);\n\}", src)
tables += fallthrough
if len(set(tables)) != len(codes):
    sys.exit("%d distinct message tables for %d refusal codes -- two codes "
             "share a sentence" % (len(set(tables)), len(codes)))
# And the sentences themselves must differ, not merely the symbols.
out = subprocess.run(["x86_64-elf-readelf", "-sW", sys.argv[2]],
                     capture_output=True, text=True).stdout
size = {}
for line in out.splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == "OBJECT":
        size[f[7]] = (int(f[2]), int(f[1], 16))
sec = subprocess.run(["x86_64-elf-objdump", "-h", sys.argv[2]],
                     capture_output=True, text=True).stdout
m = re.search(r"\s+\d+ \.rodata\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", sec)
rodata_off = int(m.group(4), 16)
blob = open(sys.argv[2], "rb").read()
texts = {}
for t in set(tables):
    n, addr = size[t]
    texts[t] = blob[rodata_off + addr: rodata_off + addr + n]
if len(set(texts.values())) != len(texts):
    sys.exit("two refusal messages have identical bytes")
for t, b in texts.items():
    if not b.endswith(b"\n"):
        sys.exit("%s does not end in a newline" % t)
    if len(b) < 12:
        sys.exit("%s is only %d bytes -- that is not a sentence naming a field"
                 % (t, len(b)))
print("    (%d refusal codes, %d distinct sentences, read out of kmain.o's "
      ".rodata)" % (len(codes), len(texts)))
PY
echo "STRUCTURAL: pass  25 refusal codes, 25 distinct sentences, each naming the field that was wrong"

# ---------------------------------------------------------------------------
# Step 4 — verify-freestanding.sh (CLAUDE.md rule 1).
#
# ONE new extern, 52 -> 53, and that is a claim about the design: an ELF loader
# is arithmetic and memory, and neither needs a new instruction. `elf_store_addr`
# is the storage seam and nothing else.
# ---------------------------------------------------------------------------
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
VERIFY_OUT="$(OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" \
  "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" "$CORE_DIR/build/portio.o" "$KERNEL_ELF" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass"
fi
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VERIFY_OUT" | head -1 | grep -oE '[0-9]+')
# M11 (ADR-0015) added FIVE more -- `sse_enabled`, `cr4_read`, `fx_save`,
# `fx_restore` and `proc_store_addr`. They are subtracted BY NAME for the reason
# M8's twelve, M9's eight and M10's one are: this harness's claim is about ITS
# OWN milestone's count, and it must keep meaning what it meant before M11.
M11_EXTERNS="sse_enabled cr4_read fx_save fx_restore proc_store_addr"
M11_PRESENT=0
for sym in $M11_EXTERNS; do
  grep -q "\b$sym\b" <<<"$VERIFY_OUT" && M11_PRESENT=$(( M11_PRESENT + 1 ))
done
[[ "$M11_PRESENT" -eq 5 ]] || fail "only $M11_PRESENT of M11's 5 externs are in kmain.o's manifest ($M11_EXTERNS)"
# M15 (ADR-0019) added exactly ONE: `file_store_addr`, the file-descriptor
# table's storage seam. Subtracted for the same reason every block above is.
M15_PRESENT=0
grep -q "\bfile_store_addr\b" <<<"$VERIFY_OUT" && M15_PRESENT=1
[[ "$M15_PRESENT" -eq 1 ]] || fail "M15's file_store_addr is not in kmain.o's manifest"
EXTERN_COUNT=$(( EXTERN_COUNT - M15_PRESENT ))
# M14 (ADR-0018) added exactly ONE: `fat_store_addr`, the filesystem's storage
# seam. Subtracted for the same reason M11's is: this harness's claim is about
# ITS OWN milestone's count.
M14_PRESENT=0
grep -q "\bfat_store_addr\b" <<<"$VERIFY_OUT" && M14_PRESENT=1
[[ "$M14_PRESENT" -eq 1 ]] || fail "M14's fat_store_addr is not in kmain.o's manifest"
EXTERN_COUNT=$(( EXTERN_COUNT - M14_PRESENT ))
EXTERN_COUNT=$(( EXTERN_COUNT - M11_PRESENT ))
[[ "$EXTERN_COUNT" -eq 53 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 53 (52 from M9 plus M10's one, elf_store_addr)"
grep -q "elf_store_addr" <<<"$VERIFY_OUT" || fail "elf_store_addr is not in kmain.o's extern manifest"
grep -qE 'FREESTANDING: pass +.*kdata\.o$' <<<"$VERIFY_OUT" || fail "kdata.o no longer passes verify-freestanding.sh with zero declared externs (GAP-0056)"
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o — 52 from M9 plus exactly one, and kdata.o still passes standalone"

# ---------------------------------------------------------------------------
# Step 5 — the boots.
# ---------------------------------------------------------------------------
VM_FRAMES=$(dartconst vmFrameCount vm.dart)
TABLE_QWORDS=$(( VM_FRAMES * 512 ))
# 32KiB starting at the program window's page-table frame: the table itself
# plus the seven frames after it. The allocator hands out consecutive frames
# from a cursor, so the program's own pages land inside this window -- which is
# asserted below rather than assumed, with a diagnostic that says so. Dumping
# them is what lets boot B check the LOADED BYTES against the file, not merely
# the permissions.
PT_QWORDS=4096

drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5" mem="$6"
  shift 6
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port=$(( 47000 + ($$ % 8000) + portoff ))
  timeout 300 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m "$mem" \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  python3 "$DRIVER" \
    --port "$port" \
    --serial "$ser" \
    --wait-for 'M1 END\n' \
    --png "$png" \
    --screen-text "$outdir/screen.txt" \
    --keys "$keys" \
    "$@"
  local drive_status=$?
  wait "$qemu_pid" 2>/dev/null
  local qemu_status=$?
  if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot."
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu-system-x86_64 exited $qemu_status unexpectedly on the $label boot (log above)"
  fi
}

# `run <lba>` as a key list. The LBAs come from make-image.py's own layout, so
# nothing here is a number typed twice.
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

SESSION_KEYS="v,m,ret,wait:1500"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run $LBA_GOOD"),ret,wait:3000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run $LBA_BADMAGIC"),ret,wait:2000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run $LBA_WX"),ret,wait:2000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run $LBA_INTERP"),ret,wait:2000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run $LBA_BADENTRY"),ret,wait:2000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run $LBA_GP"),ret,wait:3000"
SESSION_KEYS="$SESSION_KEYS,r,u,n,ret,wait:600"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,u,s,e,r,ret,wait:1500"
SESSION_KEYS="$SESSION_KEYS,c,l,e,a,r,ret,wait:400"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run $LBA_GOOD"),ret,wait:3000"

SHOT_PNG="$CORE_DIR/build/screenshot-elf.png"
rm -f "$SHOT_PNG"

drive_session "$WORKDIR/session" "$SESSION_KEYS" "$SHOT_PNG" "session" 60 128M \
  --addr-from-serial 'VM CR3 ([0-9A-F]{16}) ' \
  --monitor-command 'info registers' \
  --monitor-command "xp/${TABLE_QWORDS}gx {addr}" \
  --monitor-capture "$WORKDIR/session/monitor.txt"

SERIAL_CAPTURE="$WORKDIR/session/serial.txt"
SCREEN_TEXT="$WORKDIR/session/screen.txt"

if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"
  cp "$SCREEN_TEXT" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $EXPECTED_SERIAL and $EXPECTED_SCREEN — the derived checks below still have to pass"
fi

[[ -f "$EXPECTED_SERIAL" ]] || setup_error "golden not found at $EXPECTED_SERIAL (run with --regen once to create it)"
[[ -f "$EXPECTED_SCREEN" ]] || setup_error "golden not found at $EXPECTED_SCREEN"

# ---------------------------------------------------------------------------
# Step 6 — assert.
# ---------------------------------------------------------------------------

# 6a. M1's whole golden must still be a byte-exact PREFIX of this capture.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL_CAPTURE" >"$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this boot do not match m1-interrupts/expected.txt — M10 changed M0/M1 serial output"
fi
echo "ASSERT: pass  M1's entire ${M1_BYTES}-byte golden is still a byte-exact prefix of this boot's serial output"

# 6b. The whole serial capture.
if ! cmp -s "$SERIAL_CAPTURE" "$EXPECTED_SERIAL"; then
  echo "--- first difference ---" >&2
  cmp "$SERIAL_CAPTURE" "$EXPECTED_SERIAL" >&2
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL_CAPTURE") | head -60 >&2
  fail "captured serial output did not exactly match $EXPECTED_SERIAL"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL_CAPTURE" | tr -d ' ')
echo "ASSERT: pass  ${SERIAL_BYTES}-byte serial capture matches expected.txt byte-for-byte"

# 6c. THE PROGRAM RAN, AND EVERY EXPECTATION COMES OUT OF THE BINARY.
if ! python3 - "$SERIAL_CAPTURE" "$DERIVE" "$PROG_ELF" "$LAYOUT_JSON" "$KERNEL_ELF" <<'PY'
import importlib.util, json, re, subprocess, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
elf = d.Elf(open(sys.argv[3], "rb").read())
layout = json.load(open(sys.argv[4]))
ksym = {}
for line in subprocess.run(["x86_64-elf-readelf", "-sW", sys.argv[5]],
                           capture_output=True, text=True).stdout.splitlines():
    m0 = re.match(r"\s*\d+:\s+([0-9a-fA-F]+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)", line)
    if m0:
        ksym[m0.group(2)] = int(m0.group(1), 16)
fails = []

# --- everything the harness expects, DERIVED FROM prog.elf -----------------
entry = elf.e_entry
msg = elf.sym_cstr("msg")
want_exit = elf.sym_u64("exit_status") + elf.sym_u64("data_word")
loads = elf.loads

# --- the header sector the kernel read, against make-image.py's layout -----
good = layout["good"]
m = re.search(r"^ELF DISK LBA ([0-9A-F]{8}) IMAGE ([0-9A-F]{8}) BYTES ([0-9A-F]{8})$",
              cap, re.M)
if not m:
    fails.append("no `ELF DISK` line -- the header sector was never read")
else:
    got = (int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16))
    want = (good["header_lba"], good["image_lba"], good["bytes"])
    if got != want:
        fails.append("the kernel read header LBA/image LBA/length %r but "
                     "make-image.py wrote %r" % (got, want))

# --- the ELF header, as the kernel decoded it ------------------------------
m = re.search(r"^ELF IDENT CLASS (\d) DATA (\d) TYPE ([0-9A-F]{4}) MACHINE ([0-9A-F]{4})$",
              cap, re.M)
if not m:
    fails.append("no `ELF IDENT` line")
else:
    if (int(m.group(1)), int(m.group(2)), int(m.group(3), 16), int(m.group(4), 16)) \
            != (elf.ei_class, elf.ei_data, elf.e_type, elf.e_machine):
        fails.append("the kernel decoded e_ident/e_type/e_machine as %r, the "
                     "file says (%d, %d, %d, %d)"
                     % (m.groups(), elf.ei_class, elf.ei_data, elf.e_type, elf.e_machine))

# --- THE ENTRY POINT IS NOT HARDCODED --------------------------------------
m = re.search(r"^ELF ENTRY ([0-9A-F]{16}) PHOFF ([0-9A-F]{16}) PHNUM ([0-9A-F]{4})$",
              cap, re.M)
if not m:
    fails.append("no `ELF ENTRY` line")
else:
    if int(m.group(1), 16) != entry:
        fails.append("the kernel reports e_entry 0x%X but the file says 0x%X"
                     % (int(m.group(1), 16), entry))
    if int(m.group(2), 16) != elf.e_phoff or int(m.group(3), 16) != elf.e_phnum:
        fails.append("the kernel reports phoff/phnum %s/%s, the file says %d/%d"
                     % (m.group(2), m.group(3), elf.e_phoff, elf.e_phnum))

# --- every program header, as the kernel read it ---------------------------
segs = re.findall(r"^ELF SEG (\d\d) TYPE ([0-9A-F]{8}) FLAGS ([0-9A-F]{8}) "
                  r"VADDR ([0-9A-F]{16}) OFF ([0-9A-F]{16}) FILESZ ([0-9A-F]{16}) "
                  r"MEMSZ ([0-9A-F]{16})$", cap, re.M)
first = segs[:elf.e_phnum]
if len(first) != elf.e_phnum:
    fails.append("the first load printed %d `ELF SEG` lines, the file has %d "
                 "program headers" % (len(first), elf.e_phnum))
for i, row in enumerate(first):
    p = elf.phdrs[i]
    got = (int(row[1], 16), int(row[2], 16), int(row[3], 16), int(row[4], 16),
           int(row[5], 16), int(row[6], 16))
    want = (p["type"], p["flags"], p["vaddr"], p["offset"], p["filesz"], p["memsz"])
    if got != want:
        fails.append("segment %d: the kernel read %r, the file holds %r"
                     % (i, [hex(x) for x in got], [hex(x) for x in want]))

# --- THE PAGES, AND THE PERMISSIONS p_flags ASKED FOR ----------------------
pages = re.findall(r"^ELF PAGE ([0-9A-F]{16}) P (\d) U (\d) W (\d) X (\d) PA ([0-9A-F]{16})$",
                   cap, re.M)
want_pages = elf.pages()
want_pages[d.PROG_STACK_PAGE] = (True, False)
first_pages = pages[:len(want_pages)]
got_map = {int(a, 16): (p, u, w, x, int(pa, 16)) for a, p, u, w, x, pa in first_pages}
if set(got_map) != set(want_pages):
    fails.append("the first load mapped %s; the ELF's p_vaddr/p_memsz (plus a "
                 "stack page) say %s"
                 % (sorted(hex(a) for a in got_map), sorted(hex(a) for a in want_pages)))
for va, (w, x) in sorted(want_pages.items()):
    if va not in got_map:
        continue
    gp, gu, gw, gx, pa = got_map[va]
    if (gp, gu) != ("1", "1"):
        fails.append("0x%X is P%s U%s, expected present and user-accessible"
                     % (va, gp, gu))
    if (gw, gx) != ("1" if w else "0", "1" if x else "0"):
        fails.append("0x%X is W%s X%s, but the segment's p_flags asks for W%d X%d"
                     % (va, gw, gx, w, x))
    if gw == "1" and gx == "1":
        fails.append("0x%X is BOTH writable and executable" % va)
    if pa & 0xFFF:
        fails.append("0x%X is backed by 0x%X, which is not 4KiB-aligned" % (va, pa))
    if pa < ksym["__kernel_end"]:
        fails.append("0x%X is backed by 0x%X, which is INSIDE the kernel image "
                     "-- the loader did not use the allocator" % (va, pa))

# --- IT RAN AT CPL 3, AND SAID WHAT THE FILE SAYS IT SHOULD ----------------
m = re.search(r"^ELF ENTER RIP ([0-9A-F]{16}) RSP ([0-9A-F]{16})\n"
              r"USER CS ([0-9A-F]{16}) SS ([0-9A-F]{16}) RFLAGS ([0-9A-F]{16}) CPL ([0-7])\n"
              r"USER WRITE (.*)\n"
              r"USER WRITE (BSS\[[0-9A-F]{2}\] SUM=[0-9A-F]{2})\n"
              r"USER EXIT CODE ([0-9A-F]{16}) SYSCALLS ([0-9A-F]{8}) REFUSALS ([0-9A-F]{8})$",
              cap, re.M)
if not m:
    fails.append("the program did not run to completion. Captured: %r"
                 % cap[cap.find("ELF ENTER"):][:600])
else:
    rip = int(m.group(1), 16)
    if rip != entry:
        fails.append("the kernel entered at 0x%X but the file's e_entry is 0x%X"
                     % (rip, entry))
    if int(m.group(2), 16) != d.PROG_STACK_TOP:
        fails.append("RSP was 0x%X, expected the top of the stack page 0x%X"
                     % (int(m.group(2), 16), d.PROG_STACK_TOP))
    if int(m.group(3), 16) != 0x23 or int(m.group(6)) != 3:
        fails.append("the program ran with CS %s / CPL %s, expected 0023 / 3 -- "
                     "the CS comes out of the frame the CPU pushed, so this is "
                     "the processor's own account" % (m.group(3), m.group(6)))
    if int(m.group(4), 16) != 0x1B:
        fails.append("SS is %s, expected 001B" % m.group(4))
    got_msg = m.group(7).encode("latin-1")
    if got_msg != msg:
        fails.append("the program printed %r; its `msg` symbol holds %r "
                     "(read out of the ELF file, not typed here)"
                     % (got_msg, msg))
    if m.group(8) != "BSS[00] SUM=00":
        fails.append("the program reports %r for its .bss. `BSS[xx]` is the "
                     "first byte and `SUM` is the sum of all 64; anything other "
                     "than 00/00 means the p_memsz - p_filesz tail was NOT "
                     "zeroed." % m.group(8))
    got_exit = int(m.group(9), 16)
    if got_exit != want_exit:
        fails.append("the program exited 0x%X; `exit_status` + `data_word` read "
                     "out of the ELF file is 0x%X. The first is in the R+X "
                     "segment and the second in the R+W one, so a mismatch says "
                     "a segment's CONTENTS did not arrive." % (got_exit, want_exit))
    if int(m.group(10), 16) != 4:
        fails.append("the program made %s syscalls, expected 4 (whoami, two "
                     "writes, exit)" % m.group(10))
    if int(m.group(11), 16) != 0:
        fails.append("%s syscalls were refused during a program that should have "
                     "made none that needed refusing" % m.group(11))

# --- and it was torn down completely ---------------------------------------
teardowns = re.findall(r"^ELF TEARDOWN FREED ([0-9A-F]{8}) TABLE ([0-9A-F]{16})$",
                       cap, re.M)
windows = [int(w, 16) for w in
           re.findall(r"^ELF WINDOW PAGES 00000200 USER ([0-9A-F]{8})$", cap, re.M)]
if not windows:
    fails.append("no `ELF WINDOW` line at all")
elif windows[-1] != 0:
    fails.append("after every program finished, %d pages of the program window "
                 "are still user-accessible" % windows[-1])
if len(want_pages) not in windows:
    fails.append("the user-accessible count in the program window is never %d -- "
                 "the program's pages were never actually mapped" % len(want_pages))
for n in windows:
    if n not in (0, len(want_pages)):
        fails.append("the program window's user-page count reached %d; only 0 "
                     "and %d are possible with one program" % (n, len(want_pages)))

# --- EVERY REFUSAL, EACH WITH ITS OWN SENTENCE, EACH LEAVING A LIVE SHELL ---
for lba_key, code, phrase in (
        ("badmagic", "08", "e_ident does not begin with 7F 45 4C 46"),
        ("wx", "12", "a PT_LOAD is both writable and executable"),
        ("interp", "11", "PT_INTERP or PT_DYNAMIC: this loader does not link"),
        ("badentry", "19", "e_entry is not inside a mapped executable page")):
    lba = layout[lba_key]["header_lba"]
    marker = "oscortex> run %x\n" % lba
    if marker not in cap:
        fails.append("the session never ran `run %x` (%s)" % (lba, lba_key))
        continue
    after = cap.split(marker, 1)[1].split("oscortex>", 1)[0]
    if ("ELF REFUSED %s %s" % (code, phrase)) not in after:
        fails.append("`run %x` (%s) did not print `ELF REFUSED %s %s`. It "
                     "printed: %r" % (lba, lba_key, code, phrase, after[:400]))
    if "ELF ENTER" in after:
        fails.append("`run %x` (%s) ENTERED RING 3 with a file it should have "
                     "refused" % (lba, lba_key))
    if "FAULT " in after:
        fails.append("`run %x` (%s) faulted instead of reporting -- a refusal "
                     "path must leave a running kernel" % (lba, lba_key))
    if not re.search(r"ELF WINDOW PAGES 00000200 USER 00000000", after):
        fails.append("after refusing %s the program window is not empty" % lba_key)

# --- THE FAULT CONTROL: it loads, it runs, it dies, and it is cleaned up ----
gp_lba = layout["gp"]["header_lba"]
marker = "oscortex> run %x\n" % gp_lba
if marker not in cap:
    fails.append("the session never ran the `gp` program")
else:
    after = cap.split(marker, 1)[1].split("oscortex>", 1)[0]
    if "ELF ENTER RIP %016X" % entry not in after:
        fails.append("the `gp` program was not entered at e_entry")
    if not re.search(r"^FAULT 0D ERR 0000000000000000 OP 0F20$", after, re.M):
        fails.append("the `gp` program did not #GP on `mov %%cr3,%%rax`. The "
                     "`OP 0F20` field is the kernel reading back, out of the "
                     "page it just mapped, the exact bytes make-image.py "
                     "patched into the file. Captured: %r" % after[:400])
    if not re.search(r"^USER FAULT VEC 0D ERR 0000000000000000 RIP %016X CPL 3$"
                     % entry, after, re.M):
        fails.append("the `gp` fault was not reported at e_entry with CPL 3")
    if "FAULT RECOVERED" not in after:
        fails.append("the shell did not survive the `gp` program's fault")
    if not re.search(r"ELF TEARDOWN FREED 0000000[0-9A-F] TABLE [0-9A-F]{16}", after):
        fails.append("the fault path did not tear the program down -- its pages "
                     "and its page table would be live for the rest of the boot")
    if not re.search(r"ELF WINDOW PAGES 00000200 USER 00000000", after):
        fails.append("after the `gp` program died the window is not empty")

# --- NOTHING LEAKED ACROSS SEVEN LOADS -------------------------------------
frames = re.findall(r"^PMM MANAGED [0-9A-F]{8} FREE ([0-9A-F]{8}) USED [0-9A-F]{8} "
                    r"BASELINE ([0-9A-F]{8})$", cap, re.M)
if len(frames) < 2:
    fails.append("expected two `frames` reports, found %d" % len(frames))
else:
    if frames[0] != frames[-1]:
        fails.append("the allocator's free count went %s -> %s across the "
                     "session. Every load and every refusal must give back "
                     "every frame it took." % (frames[0][0], frames[-1][0]))
    if frames[-1][0] != frames[-1][1]:
        fails.append("the allocator ends at FREE %s with BASELINE %s -- frames "
                     "are leaked" % frames[-1])

# --- the usage line, and M9 still works ------------------------------------
if "run: usage: run <lba>" not in cap:
    fails.append("`run` with no argument did not print the usage line")
if "USER WRITE HELLO FROM RING 3" not in cap:
    fails.append("M9's own payload no longer runs -- `user` is in this session "
                 "precisely so that adding a loader cannot quietly break the "
                 "thing the loader was built on top of")
if not cap.rstrip().endswith("oscortex>"):
    fails.append("the session does not end at a live prompt")

if fails:
    print("m10-elf: program check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (entry 0x%X and %d pages derived from prog.elf; message %r read out "
      "of its `msg` symbol; exit status 0x%X = exit_status + data_word read out "
      "of its two segments; .bss zero; four malformed files refused by name; a "
      "privileged instruction at e_entry faulting and torn down)"
      % (entry, len(want_pages), msg.decode(), want_exit))
PY
then
  fail "the loaded program did not behave as M10 claims: see the list above"
fi
echo "ASSERT: pass  a program the kernel did not compile ran at CPL 3 from its own e_entry, printed the bytes its own ELF holds, exited with the status its own two segments encode, and had a zeroed .bss; four malformed files were refused by name; and a privileged instruction at the entry point faulted and was cleaned up"

# 6d. THE ADDRESS SPACE AFTER THE SESSION.
if ! python3 - "$SERIAL_CAPTURE" "$DERIVE" "$WORKDIR/session/monitor.txt" \
     "$KERNEL_ELF" "$TABLE_QWORDS" <<'PY'
import importlib.util, re, subprocess, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
monitor = open(sys.argv[3], encoding="utf-8").read()
table_n = int(sys.argv[5])
sym = {}
for line in subprocess.run(["x86_64-elf-readelf", "-sW", sys.argv[4]],
                           capture_output=True, text=True).stdout.splitlines():
    m0 = re.match(r"\s*\d+:\s+([0-9a-fA-F]+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)", line)
    if m0:
        sym[m0.group(2)] = int(m0.group(1), 16)
fails = []
regs = d.parse_registers(monitor)
cr3 = regs["CR3"] & d.ADDR_MASK
if not regs.get("CR0", 0) & (1 << 16):
    fails.append("CR0.WP is CLEAR -- see known-gaps GAP-0080; every W=0 in this "
                 "harness is decorative")
if regs.get("CPL") != 0:
    fails.append("at the end of the session the CPU is at CPL %s, expected 0"
                 % regs.get("CPL"))
m = re.search(r"^VM CR3 ([0-9A-F]{16}) ", cap, re.M)
if not m or int(m.group(1), 16) != cr3:
    fails.append("the kernel reports CR3 %s but QEMU says %016X"
                 % (m.group(1) if m else "?", cr3))
# The block is selected by its command line AS SENT, and the session boot
# sent `{addr}` -- substituted with the sixteen-digit form the kernel
# printed. Matched as a prefix, exactly as m9's walker does.
mem = d.Memory().add(cr3, d.parse_xp(monitor, "xp/%dgx " % table_n))
tables = d.PageTables(cr3, mem)

# THE PAGE DIRECTORY ENTRY IS GONE. Not "the pages are unmapped" -- the whole
# page table has been taken out and its frame returned, so the window cannot be
# reached at all.
pml4e = tables.entry(cr3, 0)
pdpte = tables.entry(pml4e & d.ADDR_MASK, 0)
pd = pdpte & d.ADDR_MASK
pde = tables.entry(pd, d.PROG_PD_INDEX)
if pde & d.PRESENT:
    fails.append("PD_low[%d] is still present (0x%X) after every program "
                 "finished -- the program window's page table was not removed"
                 % (d.PROG_PD_INDEX, pde))
if tables.effective(d.PROG_BASE) is not None:
    fails.append("0x%X is still mapped after every program finished" % d.PROG_BASE)

# And nothing else above the identity map has been left behind either.
for i in range(d.MAP_BYTES // d.BIG_BYTES, 512):
    e = tables.entry(pd, i)
    if e & d.PRESENT:
        fails.append("PD_low[%d] (0x%X..) is present after the session; the only "
                     "entry M10 ever installs above the identity map is %d, and "
                     "it removes it" % (i, i * d.BIG_BYTES, d.PROG_PD_INDEX))
        break

# M9's own claim, re-made: no page of the 4KiB window is user-accessible.
leftover = tables.user_pages(0, d.FINE_BYTES)
if leftover:
    fails.append("%d page(s) of the 4KiB window are user-accessible after the "
                 "session, first at 0x%X" % (len(leftover), leftover[0]))
def pages(lo, hi):
    return (lo & ~0xFFF, (hi + 0xFFF) & ~0xFFF)
fails += d.check_supervisor(tables, *pages(sym["__kernel_start"], sym["__text_end"]), ".text")
fails += d.check_supervisor(tables, *pages(sym["__rodata_start"], sym["__rodata_end"]), ".rodata")
fails += d.check_supervisor(tables, *pages(sym["__data_start"], sym["__kernel_end"]), ".data/.bss")
fails += d.check_supervisor(tables, 0, d.LOW_BYTES, "the first megabyte")

if fails:
    print("m10-elf: post-session page-table check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (%d bytes of page tables walked at QEMU's own CR3=0x%X: the program "
      "window's page-directory entry is GONE, no entry above the identity map "
      "is present, and no page of the kernel is user-accessible)"
      % (mem.span, cr3))
PY
then
  fail "after seven loads the address space is not back where it started"
fi
echo "ASSERT: pass  the LIVE page tables after the session show the program window's page-directory entry removed entirely, nothing present above the identity map, and no user-accessible page anywhere"

# 6e. The framebuffer, and the screenshot.
if ! cmp -s "$SCREEN_TEXT" "$EXPECTED_SCREEN"; then
  echo "--- VGA text buffer as read from guest memory ---" >&2
  diff -u "$EXPECTED_SCREEN" "$SCREEN_TEXT" >&2
  fail "the VGA text buffer at 0xB8000 did not match $EXPECTED_SCREEN"
fi
echo "ASSERT: pass  the 80x25 VGA text buffer at 0xB8000 matches expected-screen.txt exactly"
[[ -s "$SHOT_PNG" ]] || fail "no screenshot was produced at $SHOT_PNG"
case "$(head -c 8 "$SHOT_PNG" | od -An -tx1 | tr -d ' \n')" in
  89504e470d0a1a0a) ;;
  *) fail "$SHOT_PNG is not a PNG" ;;
esac
echo "ASSERT: pass  screenshot written to $SHOT_PNG ($(wc -c <"$SHOT_PNG" | tr -d ' ') bytes, PNG)"

# ---------------------------------------------------------------------------
# Step 7 — BOOT B: THE PROGRAM IS LEFT RUNNING.
#
# `spin` is prog.elf with `jmp .` at e_entry, so RIP stays at e_entry forever
# and the machine can be inspected with a loaded program ON THE CPU:
#
#   * QEMU's own `info registers` must say CPL=3, CS=0x23, and RIP EXACTLY
#     e_entry. That is the most direct possible statement that this kernel
#     jumped where the file said to, made by a third party;
#   * the page tables are dumped from TWO disjoint regions -- the six frames at
#     CR3, and the program's own page-table frame, which came from the allocator
#     at run time and is nowhere near them -- and every page in the window is
#     checked against the ELF's own p_flags.
# ---------------------------------------------------------------------------
CR3_HEX=$(grep -m1 -oE '^VM CR3 [0-9A-F]{16}' "$SERIAL_CAPTURE" | awk '{print $3}')
[[ -n "$CR3_HEX" ]] || fail "could not read the CR3 out of the session capture"

SPIN_ELF="$WORKDIR/variants/prog-spin.elf"
[[ -s "$SPIN_ELF" ]] || fail "make-image.py did not emit the spin variant"
drive_session "$WORKDIR/spin" "v,m,ret,wait:1200,$(typekeys "run $LBA_SPIN"),ret,wait:3000" \
  "$WORKDIR/spin/shot.png" "spin" 61 128M \
  --addr-from-serial 'ELF STACK [0-9A-F]{16} FRAME [0-9A-F]{16} TABLE ([0-9A-F]{16})' \
  --monitor-command 'info registers' \
  --monitor-command "xp/${TABLE_QWORDS}gx 0x$CR3_HEX" \
  --monitor-command "xp/${PT_QWORDS}gx {addr}" \
  --monitor-capture "$WORKDIR/spin/monitor.txt"

# The ELF handed to this boot is the SPIN VARIANT, so every expectation below
# is derived from THAT file -- two bytes of it differ from prog.elf, and the
# byte-for-byte image check would (correctly) fail against the wrong one.
if ! python3 - "$WORKDIR/spin/serial.txt" "$DERIVE" "$WORKDIR/spin/monitor.txt" \
     "$SPIN_ELF" "$KERNEL_ELF" "$CR3_HEX" "$TABLE_QWORDS" "$PT_QWORDS" <<'PY'
import importlib.util, re, subprocess, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[2])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
monitor = open(sys.argv[3], encoding="utf-8").read()
elf = d.Elf(open(sys.argv[4], "rb").read())
cr3_hex, table_n, pt_n = sys.argv[6], int(sys.argv[7]), int(sys.argv[8])
sym = {}
for line in subprocess.run(["x86_64-elf-readelf", "-sW", sys.argv[5]],
                           capture_output=True, text=True).stdout.splitlines():
    m0 = re.match(r"\s*\d+:\s+([0-9a-fA-F]+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)", line)
    if m0:
        sym[m0.group(2)] = int(m0.group(1), 16)
fails = []
regs = d.parse_registers(monitor)

# --- QEMU's own account of where the CPU is --------------------------------
if regs.get("CPL") != 3:
    fails.append("QEMU reports CPL=%s while the loaded program should be "
                 "spinning in ring 3" % regs.get("CPL"))
if regs.get("CS") != 0x23:
    fails.append("QEMU reports CS=%04X, expected 0023" % (regs.get("CS") or 0))
if regs.get("SS") != 0x1B:
    fails.append("QEMU reports SS=%04X, expected 001B" % (regs.get("SS") or 0))
if regs.get("RIP") != elf.e_entry:
    fails.append("QEMU reports RIP=0x%X; the ELF's e_entry is 0x%X. The `spin` "
                 "program is `jmp .` AT its entry point, so these are equal or "
                 "the kernel jumped somewhere the file did not name."
                 % (regs.get("RIP") or 0, elf.e_entry))
if sym["__kernel_start"] <= (regs.get("RIP") or 0) < sym["__kernel_end"]:
    fails.append("RIP is inside the kernel image")

# --- the mapping the kernel reported, and the table it named ---------------
m = re.search(r"^ELF STACK ([0-9A-F]{16}) FRAME ([0-9A-F]{16}) TABLE ([0-9A-F]{16})$",
              cap, re.M)
if not m:
    sys.exit("the spin boot never printed its mapping: %r" % cap[-500:])
pt = int(m.group(3), 16)
cr3 = regs["CR3"] & d.ADDR_MASK
if int(cr3_hex, 16) != cr3:
    sys.exit("the tables were dumped at 0x%s but the CPU is using 0x%X"
             % (cr3_hex, cr3))

# TWO DISJOINT REGIONS. The program's page table came from the allocator at run
# time; a walker that only had the six frames at CR3 could not reach it, and one
# that returned zeroes instead of raising would report the program as unmapped.
mem = (d.Memory()
       .add(cr3, d.parse_xp(monitor, "xp/%dgx 0x%s" % (table_n, cr3_hex)))
       .add(pt, d.parse_xp(monitor, "xp/%dgx 0x%s" % (pt_n, m.group(3)))))
tables = d.PageTables(cr3, mem)

# --- THE CENTRAL CHECK: the tables carry the ELF's own p_flags -------------
fails += d.check_program_pages(tables, elf)

# The page table is reached through a page-directory entry that must itself
# carry U/S and W -- an interior entry is the ABSENCE of a veto, and one that
# withheld either would make every leaf under it unreachable or read-only
# whatever p_flags said.
pml4e = tables.entry(cr3, 0)
pdpte = tables.entry(pml4e & d.ADDR_MASK, 0)
pde = tables.entry(pdpte & d.ADDR_MASK, d.PROG_PD_INDEX)
if not pde & d.PRESENT:
    fails.append("PD_low[%d] is not present while a program is running"
                 % d.PROG_PD_INDEX)
if pde & d.HUGE:
    fails.append("PD_low[%d] is a 2MiB LEAF, not a pointer to a page table"
                 % d.PROG_PD_INDEX)
if not pde & d.USER:
    fails.append("PD_low[%d] does not have U/S set, so nothing under it can be "
                 "user-accessible" % d.PROG_PD_INDEX)
if not pde & d.WRITABLE:
    fails.append("PD_low[%d] does not have RW set, so the program's data page "
                 "cannot be writable whatever its leaf says" % d.PROG_PD_INDEX)
if (pde & d.ADDR_MASK) != pt:
    fails.append("PD_low[%d] points at 0x%X but the kernel printed the page "
                 "table's frame as 0x%X" % (d.PROG_PD_INDEX, pde & d.ADDR_MASK, pt))
if pde & d.NX:
    fails.append("PD_low[%d] has NX set, so the program's text page cannot be "
                 "executable whatever its leaf says" % d.PROG_PD_INDEX)

# --- and the kernel is out of reach WHILE ring 3 is on the CPU -------------
live4k = tables.user_pages(0, d.FINE_BYTES)
if live4k:
    fails.append("%d page(s) of the 4KiB identity window are user-accessible "
                 "while a loaded program runs, first at 0x%X. A program loaded "
                 "from a disk must not be able to reach the kernel's own pages."
                 % (len(live4k), live4k[0]))
def pages(lo, hi):
    return (lo & ~0xFFF, (hi + 0xFFF) & ~0xFFF)
fails += d.check_supervisor(tables, *pages(sym["__kernel_start"], sym["__text_end"]), ".text (program live)")
fails += d.check_supervisor(tables, *pages(sym["__rodata_start"], sym["__rodata_end"]), ".rodata (program live)")
fails += d.check_supervisor(tables, *pages(sym["__data_start"], sym["__kernel_end"]), ".data/.bss (program live)")
fails += d.check_supervisor(tables, 0, d.LOW_BYTES, "the first megabyte (program live)")
for lo, hi, label in ((d.FINE_BYTES, d.MAP_BYTES, "[4MiB, 128MiB) (program live)"),
                      (d.PCI_BASE, d.PCI_END, "the PCI hole (program live)")):
    big = tables.user_pages(lo, hi, step=d.BIG_BYTES)
    if big:
        fails.append("%d 2MiB page(s) in %s are user-accessible, first at 0x%X"
                     % (len(big), label, big[0]))

# --- THE LOADED BYTES, OUT OF GUEST PHYSICAL MEMORY ------------------------
#
# The strongest statement this harness makes, and the one that cannot pass for
# the wrong reason. For every page of the program window, the leaf names a
# physical frame; that frame's 4096 bytes are read out of the dump and compared
# against what a correct load MUST have put there, computed from the ELF alone:
#
#   * inside [p_vaddr, p_vaddr + p_filesz)  -> the file's own bytes;
#   * everywhere else                       -> ZERO.
#
# "Everywhere else" is three different things and they are all checked at once:
# the `p_memsz - p_filesz` tail (.bss), the bytes BELOW p_vaddr on a page a
# segment does not start at (prog.ld puts the RW segment 0x40 into its page for
# exactly this reason), and the bytes past p_memsz to the end of the frame. The
# last two belong to no segment at all -- and they are readable by ring 3, so a
# loader that left allocator litter there would be handing an untrusted program
# a page of whatever the kernel last did with that frame.
#
# **This is deliberately NOT the program's own `BSS[00] SUM=00` report.** That
# report is evidence and it passed on a kernel with the zeroing REMOVED, because
# a freshly-booted QEMU hands out RAM that is already zero. See
# docs/known-gaps.md GAP-0094: a check that can only fail when the frame
# happened to be dirty is a check that mostly does not run.
prog_pages = sorted(tables.mapped_pages(d.PROG_BASE, d.PROG_END))
lo_dump, hi_dump = pt, pt + pt_n * 8
want_image = {}
for p in elf.loads:
    lo = p["vaddr"] & ~0xFFF
    hi = (p["vaddr"] + p["memsz"] + 0xFFF) & ~0xFFF
    for a in range(lo, hi, d.PAGE_BYTES):
        img = want_image.setdefault(a, bytearray(d.PAGE_BYTES))
        for off in range(d.PAGE_BYTES):
            va = a + off
            if p["vaddr"] <= va < p["vaddr"] + p["filesz"]:
                img[off] = elf.blob[p["offset"] + (va - p["vaddr"])]
want_image[d.PROG_STACK_PAGE] = bytearray(d.PAGE_BYTES)   # the stack, all zero
checked = 0
for va in prog_pages:
    leaf = tables.leaf(va)
    pa = leaf & d.ADDR_MASK
    if not (lo_dump <= pa < hi_dump - d.PAGE_BYTES + 8):
        fails.append("0x%X is backed by frame 0x%X, which is outside the "
                     "%dKiB dumped at the page-table frame 0x%X. The allocator "
                     "hands out consecutive frames from a cursor, so this is "
                     "either a change in the allocator or a load that took its "
                     "frames from somewhere else."
                     % (va, pa, (hi_dump - lo_dump) // 1024, pt))
        continue
    got = b"".join(mem.qword(pa + o).to_bytes(8, "little")
                   for o in range(0, d.PAGE_BYTES, 8))
    want = bytes(want_image.get(va, bytearray(d.PAGE_BYTES)))
    if got != want:
        first = next(i for i in range(d.PAGE_BYTES) if got[i] != want[i])
        nz = sum(1 for i in range(d.PAGE_BYTES) if got[i] != want[i])
        kind = "a file byte" if want[first] else "ZERO (no segment covers it, or it is the p_memsz tail)"
        fails.append("page 0x%X (frame 0x%X) does not hold what the ELF says it "
                     "should: %d of 4096 bytes differ, first at offset 0x%X "
                     "where the file requires %s but memory holds 0x%02X. "
                     "Everything outside [p_vaddr, p_vaddr + p_filesz) must be "
                     "zero -- ring 3 can read this page."
                     % (va, pa, nz, first, kind, got[first]))
    else:
        checked += 1
if checked != len(prog_pages):
    pass  # the failures above already say which page and why

# And the permissions of the page the CPU is executing from, from its own leaf.
leaf = tables.leaf(elf.e_entry & ~0xFFF)
if leaf is None:
    fails.append("the entry point's page has no leaf entry")
else:
    if leaf & d.WRITABLE:
        fails.append("the text page is WRITABLE -- the program can rewrite its "
                     "own instructions")
    if leaf & d.NX:
        fails.append("the text page is NON-EXECUTABLE, yet the CPU is executing "
                     "from it")

if fails:
    print("m10-elf: live-program check FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (program live at RIP 0x%X == e_entry, CPL 3, CS 0023 by QEMU's own "
      "account; %d pages in the window, each carrying exactly the W and X its "
      "segment's p_flags asked for, reached through PD_low[%d] -> 0x%X; all "
      "%d pages' 4096 bytes compared against the ELF file byte for byte, with "
      "everything outside [p_vaddr, p_vaddr+p_filesz) required to be zero; no "
      "kernel page user-accessible)"
      % (regs["RIP"], len(elf.pages()) + 1, d.PROG_PD_INDEX, pt, checked))
PY
then
  fail "with a loaded program live in ring 3, the machine's own page tables do not match the ELF's program headers"
fi
echo "ASSERT: pass  with a loaded program LIVE in ring 3: QEMU reports CPL 3 / CS 0023 and RIP EXACTLY equal to the ELF's e_entry; the live page tables, dumped from two disjoint regions of guest memory, give every page precisely the permissions that segment's p_flags asked for (text read+execute, data and stack read+write, never both); every one of those pages holds, byte for byte out of guest physical memory, exactly what the ELF says it should -- the file's bytes inside p_filesz and ZERO everywhere else; and no kernel page is user-accessible"

# ---------------------------------------------------------------------------
# Step 8 — BOOT C: NEGATIVE CONTROL 1. A DIFFERENT MACHINE.
#
# 32MiB instead of 128. The memory map changes, so the allocator's answers
# change, so the frames behind the program's pages change -- and the program
# must still run, still print the same bytes, and still exit with the same
# status, because that status is derived from the FILE and not from where the
# file landed.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/small" "$(typekeys "run $LBA_GOOD"),ret,wait:3000" \
  "$WORKDIR/small/shot.png" "small-machine" 62 32M

if ! python3 - "$WORKDIR/small/serial.txt" "$SERIAL_CAPTURE" "$DERIVE" "$PROG_ELF" <<'PY'
import importlib.util, re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
big = open(sys.argv[2], "rb").read().decode("latin-1")
spec = importlib.util.spec_from_file_location("derive", sys.argv[3])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
elf = d.Elf(open(sys.argv[4], "rb").read())
want_exit = elf.sym_u64("exit_status") + elf.sym_u64("data_word")
fails = []
if "MB E 0000000007FE0000" in cap:
    fails.append("the 32MiB boot reports the 128MiB machine's memory map")
if elf.sym_cstr("msg").decode() not in cap:
    fails.append("the program did not print its message on the 32MiB machine")
if "USER EXIT CODE %016X" % want_exit not in cap:
    fails.append("the program did not exit with %016X on the 32MiB machine -- "
                 "the status is derived from the FILE, so it must not depend on "
                 "the machine" % want_exit)
if "ELF ENTER RIP %016X" % elf.e_entry not in cap:
    fails.append("the program was not entered at its own e_entry on the 32MiB "
                 "machine")
if "BSS[00] SUM=00" not in cap:
    fails.append(".bss was not zeroed on the 32MiB machine")
if not re.search(r"^ELF WINDOW PAGES 00000200 USER 00000000$", cap, re.M):
    fails.append("the 32MiB boot does not end with an empty program window")
def frames(text):
    return re.findall(r"^ELF PAGE [0-9A-F]{16} P \d U \d W \d X \d PA ([0-9A-F]{16})$",
                      text, re.M)
a, b = frames(cap), frames(big)
if a and b and a[:3] == b[:3]:
    print("    (note: the program landed on the same frames on both machines; "
          "the allocator's first free frame above the image did not move)")
if fails:
    print("m10-elf: small-machine control FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (32MiB machine: a different memory map, and the program still loads "
      "at its own p_vaddrs, runs at its own e_entry and exits with the status "
      "its own file encodes)")
PY
then
  fail "NEGATIVE CONTROL FAILED: the program did not load and run correctly on a different machine"
fi
if cmp -s "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL"; then
  fail "NEGATIVE CONTROL FAILED: a boot on a 32MiB machine produced the same serial capture as the 128MiB session"
fi
SMALL_DIFF=$(cmp "$WORKDIR/small/serial.txt" "$EXPECTED_SERIAL" 2>&1 | grep -oE '(byte|char) [0-9]+' | head -1)
SMALL_OFFSET=${SMALL_DIFF##* }
[[ "$SMALL_OFFSET" -le 544 ]] || fail "the 32MiB capture matches M1's entire 544-byte golden, so the boot-time memory-map report did not change with the machine"
echo "ASSERT: pass  negative control — on a 32MiB machine the memory map differs inside M1's own boot report, and the program still loads at its own p_vaddrs and exits with the status its own file encodes"

# ---------------------------------------------------------------------------
# Step 9 — BOOT D: NEGATIVE CONTROL 2. NO FRAMES.
#
# `frames drain` hands out every free frame, so `allocFrame()` returns 0 and
# `run` must REFUSE. This is what says the program's pages are really allocated
# rather than being addresses the loader was compiled to know: a kernel that
# mapped fixed frames would load happily with the allocator empty.
# ---------------------------------------------------------------------------
drive_session "$WORKDIR/nomem" \
  "f,r,a,m,e,s,spc,d,r,a,i,n,ret,wait:14000,$(typekeys "run $LBA_GOOD"),ret,wait:2000,$(typekeys "run $LBA_GOOD"),ret,wait:2000" \
  "$WORKDIR/nomem/shot.png" "no-frames" 63 128M

if ! python3 - "$WORKDIR/nomem/serial.txt" <<'PY'
import re, sys
cap = open(sys.argv[1], "rb").read().decode("latin-1")
fails = []
if not re.search(r"^PMM DRAIN NEXT 0000000000000000 FREE 00000000$", cap, re.M):
    fails.append("the drain did not exhaust the allocator, so this control "
                 "proves nothing")
after = cap.split("PMM DRAIN NEXT 0000000000000000")[-1]
if "ELF REFUSED 03 no free frame" not in after:
    fails.append("`run` did not refuse when the allocator was empty. Either it "
                 "loaded a program into pages nobody allocated, or it faulted "
                 "instead of reporting. Captured: %r" % after[:500])
if "ELF ENTER" in after:
    fails.append("`run` entered ring 3 despite the allocator being empty")
if "FAULT " in after:
    fails.append("a fault was reported on the no-frames boot -- the refusal path "
                 "is supposed to leave a running kernel")
if after.count("ELF REFUSED 03") < 2:
    fails.append("the second `run` did not refuse the same way -- the first "
                 "refusal must leave the machine exactly as it found it")
if not cap.rstrip().endswith("oscortex>"):
    fails.append("the no-frames boot does not end at a live prompt")
if fails:
    print("m10-elf: no-frames control FAILED", file=sys.stderr)
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    (allocator drained to zero; `run` refuses, reports why, maps nothing, "
      "and refuses identically a second time)")
PY
then
  fail "NEGATIVE CONTROL FAILED: with no free frames, 'run' did not refuse cleanly"
fi
echo "ASSERT: pass  negative control — with every frame drained, 'run' refuses with a diagnostic instead of loading, twice, and leaves the shell alive"

echo "M10-elf: PASS — dcc build -> assemble -> link -> clang + x86_64-elf-ld build a freestanding static ELF64 -> make-image.py writes seven programs onto a disk -> 8 structural checks (donated .bss 5368 -> 5496 with elf_store one 128-byte symbol and still no sector buffer, the storage seam exactly 1 call site, every ELF64 field offset in elf.dart decoding the built program to the same value readelf reports, the program window multiplied out against itself and against prog.ld, W^X refused independently by elfCheckPhdr and vmProgMap, every allocFrame paired with a zeroing, 59 @rodata sizes plus shellStrHelp 1658 -> 1871, and 25 refusal codes with 25 distinct sentences) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 52 + 1, kdata.o still clean standalone) -> FOUR real QEMU boots. A ${SERIAL_BYTES}-byte serial match with M1's 544-byte golden intact as a prefix; a program THIS KERNEL DID NOT COMPILE loaded off a disk, mapped at the p_vaddrs its own program headers name, entered at the e_entry its own header names, printing the bytes its own \`msg\` symbol holds and exiting with the status its own two segments encode, with .bss zeroed; the LIVE page tables read out of TWO disjoint regions of guest physical memory with the program still on the CPU, every page carrying exactly the W and X its segment's p_flags asked for and no kernel page reachable; QEMU's own registers reporting CPL 3 with RIP exactly equal to e_entry; four malformed files refused by name, each leaving a live shell; a privileged instruction at the entry point faulting, being reported at e_entry, and being torn down; the allocator's free count identical before and after seven loads; a 32MiB machine where all of it still holds; and a drained allocator where 'run' refuses instead of pretending. Screenshot at $SHOT_PNG"
exit 0
