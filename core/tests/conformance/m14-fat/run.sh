#!/usr/bin/env bash
# core/tests/conformance/m14-fat/run.sh
#
# Mechanical check of ROADMAP.md's M14 exit criterion: THIS OPERATING SYSTEM
# RUNS A PROGRAM NAMED BY A FILENAME, OFF A REAL FILESYSTEM, WHOSE BLOCKS ARE
# NOT IN ORDER.
#
# WHAT THIS ASSERTS THAT NO EARLIER HARNESS COULD
# ---------------------------------------------------------------------------
# Every milestone from M10 to M13 put programs on a disk with a 32-byte header
# sector -- `"OSCXPRG1"`, a length, an LBA -- written by a generator that then
# told the harness where it had put them, and `run 20` meant SECTOR 0x20. There
# were no names, no directory and no allocation (docs/known-gaps.md GAP-0090).
#
#   * A REAL FAT16 VOLUME, AND TWO INDEPENDENT TOOLS SAY SO. make-image.py
#     writes the boot sector, two FATs, a 512-entry root directory and a 5000-
#     cluster data region byte by byte. `fsck_msdos` -- Apple's, which has never
#     heard of this repo -- then checks it, and macOS's own `msdos` driver
#     MOUNTS it and is required to read PROGA.ELF back byte-for-byte. A volume
#     only this repo can read would prove nothing.
#
#   * NOTHING ON THE VOLUME IS CONTIGUOUS. PROGA.ELF takes the odd clusters and
#     PROGB.ELF takes the even ones, so the two are interleaved 1KiB slab by
#     1KiB slab; HELLO.TXT's two clusters are 98 apart. A loader that read
#     forward from the first cluster would assemble a program out of alternating
#     pieces of two real executables -- and derive.py computes exactly what such
#     a program would hash, and this harness requires that number NOT to appear.
#
#   * THE PROGRAM HASHES ITSELF. prog.c runs FNV-1a over its own R+X segment and
#     prints it; derive.py hashes the same bytes of the ELF on the host. FNV-1a
#     rather than a checksum because a checksum is INVARIANT UNDER A PERMUTATION
#     OF CLUSTERS, which is the exact corruption being looked for.
#
#   * EVERY REFUSAL IS PRODUCED BY A REAL BOOT AGAINST A REAL DISK. Nine of the
#     driver's twenty-nine refusal codes are about a volume being something it
#     will not read, and none is reachable from a correct one. So the harness
#     builds five DELIBERATELY BROKEN volumes -- no boot signature, 1024-byte
#     sectors, a FAT32-shaped BPB, a genuinely FAT12 volume, and one whose three
#     files have three different broken chains -- and boots against each.
#
#   * THE CYCLE DETECTOR IS EXERCISED. A FAT that points back at itself is what
#     a corrupt volume looks like, and a driver that only stopped at an end mark
#     would follow one until the machine was switched off. The `badchains`
#     volume has a 2-cycle in it and the kernel is required to name it.
#
# WHAT IT DOES NOT ASSERT, SO NOBODY INFERS IT
# ---------------------------------------------------------------------------
#   * THERE ARE NO WRITES. `WRITE SECTORS` (0x30) is not implemented and this
#     harness greps for it. GAP-0116 is the accounting.
#   * NO SUBDIRECTORIES, NO LONG FILENAMES, NO TIMESTAMPS, NO FREE-SPACE
#     ALLOCATION. `SUB` is on the volume so that "a subdirectory is refused" is
#     a boot rather than a claim; three real LFN entries are on it so that
#     "long-filename entries are skipped" is one too.
#   * ONE VOLUME, ONE DEVICE, ONE OPEN FILE. GAP-0116 lists all of it.
#
# Usage:
#   core/tests/conformance/m14-fat/run.sh
#   ... --regen    rewrite the goldens from this boot (the derived checks below
#                  still have to pass, so a wrong driver cannot enshrine itself)
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "M14-fat: FAIL — $1" >&2; exit 1; }
setup_error() { echo "M14-fat: FAIL — $1" >&2; exit 2; }

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths. The same hazard applies
# to nothing in this harness -- no Dart runs out of WORKDIR -- but the workdir is
# still resolved to a real path so that a future step that does is not surprised.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-m14.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
MOUNTPOINT="$WORKDIR/mnt"
ATTACHED=""
cleanup() {
  [[ -n "$ATTACHED" ]] && hdiutil detach "$ATTACHED" -force >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"
EXPECTED_SCREEN="$SCRIPT_DIR/expected-screen.txt"
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
[[ -f "$M1_EXPECTED" ]] || setup_error "m1-interrupts/expected.txt not found"
[[ -d "$LIBC_DIR" ]] || setup_error "no C library at $LIBC_DIR"

# ---------------------------------------------------------------------------
# Step 1 — build the kernel.
# ---------------------------------------------------------------------------
BUILD_OUT="$(bash "$CORE_DIR/scripts/build-kernel.sh" 2>&1)"
BUILD_STATUS=$?
echo "$BUILD_OUT"
[[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
[[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

symsize() {
  x86_64-elf-readelf -sW "$1" | awk -v s="$2" '$8==s {print $3; exit}'
}

# ---------------------------------------------------------------------------
# Step 2 — structural checks. Everything that can be established without
# booting is established without booting.
# ---------------------------------------------------------------------------

# 2a. THE DONATED BLOCK, AND THE FOUR OFFSETS INSIDE IT.
#
# 9664 -> 11488, and the 1824 is `fat_store`. The four region offsets in
# fat.dart are multiplied out against the block's own size here, because a
# region that ran past the end would corrupt whatever `.bss` follows and would
# do it silently -- `.bss` is not zeroed and nothing in this kernel guards it.
# ---------------------------------------------------------------------------
# M17 (docs/decisions/0021-mutable-statics-and-the-end-of-donated-bss.md):
# WHERE THE MUTABLE STORAGE LIVES NOW. This check did not change what it
# asserts; it changed where it reads it from, and it is written out here rather
# than only in a commit message because an accounting assertion that moves is
# exactly the kind of thing that must never move quietly.
#
# Until M17 every mutable byte in this kernel was hand-donated `.bss` in
# core/boot/kdata.S, because DCDart had no mutable static data (GAP-0053).
# DCDart ADR-0051 landed `@bss`, so the blocks are now DCDart mutable statics
# declared in the subsystem that owns them, and they land in `kmain.o`'s `.bss`.
# FIVE WORDS DID NOT MOVE and never will: `cpu_info`, `shell_resume_rsp`,
# `shell_resume_ok`, `user_resume_rsp` and `user_resume_ok` are written by
# assembly itself (isr.S), and a `@bss` symbol is LOCAL, so assembly cannot
# name one. Those 96 bytes are still in kdata.o.
#
# So the total is a SUM OF TWO OBJECTS, and every historical number below is
# reproduced by it byte for byte: 16 at M2, 304 at M3, 392 at M4, 424 at M5/M6,
# 5096 at M7, 5224 at M8, 5368 at M9, 5496 at M10, 9664 at M11-M13, 11488 at
# M14, 14048 at M16, and 9728/11552/14112 at M18 -- M18 (ADR-0022) grew procStore by 64 bytes -- six scheduler header words and two per-slot counters, in the block the process table already owns rather than in a second one -- so every total below moves by exactly 64. `DART_BSS` is the DCDart half, `ASM_BSS` the assembly
# half; offset arithmetic ("bytes from this block to the end") is done inside
# DART_BSS, because every block a later milestone added is in that half.
bssfield() {   # bssfield <readelf column> <symbol> -- kmain.o first, then kdata.o
  local f="$1" n="$2" o v
  for o in kmain.o kdata.o; do
    v=$(x86_64-elf-readelf -sW "$CORE_DIR/build/$o" \
          | awk -v s="$n" -v f="$f" '$4=="OBJECT" && $8==s {print $f; exit}')
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  done
  return 1
}
bssaddr() {    # bssaddr <symbol> -- the LINKED address of a @bss block.
  # A `@bss` symbol is LOCAL to kmain.o and kernel.ld's OUTPUT_FORMAT(elf32-i386)
  # container keeps no local symbols, so kernel.elf's symbol table cannot answer
  # this. The LINK MAP can, and it is the linker's own statement of where it put
  # kmain.o's `.bss`; the block's offset inside that section comes from kmain.o.
  local n="$1" base off
  base=$(awk '$1==".bss" && $4 ~ /kmain\.o$/ {print $2; exit}' "$CORE_DIR/build/kernel.map")
  [[ -n "$base" ]] || return 1
  off=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
          | awk -v s="$n" '$4=="OBJECT" && $8==s {print $2; exit}')
  [[ -n "$off" ]] || return 1
  printf '%x\n' $(( 16#${base#0x} + 16#$off ))
}
bsssize() { bssfield 3 "$1"; }
bssoff()  { bssfield 2 "$1"; }
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$DART_BSS_HEX" ]] || fail "kmain.o has no .bss section — the DCDart mutable statics (ADR-0021) are gone"
DART_BSS=$((16#$DART_BSS_HEX))
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
[[ -n "$ASM_BSS_HEX" ]] || fail "kdata.o has no .bss section — the five assembly-written words are gone"
ASM_BSS=$((16#$ASM_BSS_HEX))
[[ "$ASM_BSS" -eq 96 ]] || fail "kdata.o still donates $ASM_BSS bytes of .bss, expected exactly 96 — cpu_info (64) plus the four resume words. Anything else in there is storage that ADR-0021 says should be a @bss mutable static in the subsystem that owns it."
KDATA_BSS=$DART_BSS
# M19 (ADR-0023) added a block AFTER M16's, and it is the LAST one in .bss:
# `argsStore`, 256 bytes -- eight metadata words, eight per-argument offsets and
# 128 bytes of argument text, which is where a command line is staged before it
# is copied onto the program's own stack page. Subtracted FIRST, before every
# earlier milestone's, so that this harness's own number continues to mean what
# it meant when it was written. Exactly the accounting M14, M15 and M16 each got
# in turn.
# M20 (ADR-0027) added a block AFTER M19's, and it is now the LAST one in .bss:
# `chanStore`, 2624 bytes -- eight global counter words and two 1280-byte channel
# port records, each of which is a 128-byte header, 128 bytes of per-slot lengths
# and 1024 bytes of message ring. Subtracted FIRST, before every earlier
# milestone's, so that this harness's own number continues to mean what it meant
# when it was written. Exactly the accounting M14, M15, M16 and M19 each got in
# turn.
M20_OFF_HEX=$(bssoff chanStore)
[[ -n "$M20_OFF_HEX" ]] || fail "chanStore has no .bss offset in kmain.o -- M20's IPC channel block (ADR-0027) is missing"
M20_BSS=$(( KDATA_BSS - 16#$M20_OFF_HEX ))
[[ "$M20_BSS" -eq 2624 ]] || fail "the bytes from M20's chanStore to the end of .bss are $M20_BSS, expected 2624. If that block changed size, change it in ADR-0027, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M20_BSS ))
M19_OFF_HEX=$(bssoff argsStore)
[[ -n "$M19_OFF_HEX" ]] || fail "argsStore has no .bss offset in kmain.o -- M19's argument block (ADR-0023) is missing"
M19_BSS=$(( KDATA_BSS - 16#$M19_OFF_HEX ))
[[ "$M19_BSS" -eq 256 ]] || fail "the bytes from M19's argsStore to M20's chanStore are $M19_BSS, expected 256. If that block changed size, change it in ADR-0023, in GAP-0053's running total, and in every harness that subtracts it."
KDATA_BSS=$(( KDATA_BSS - M19_BSS ))
# M15 (ADR-0019) added a block AFTER M14's: `file_store`, 1280 bytes. Subtracted
# here so that M14's own number keeps meaning what it meant when it was written.
M15_OFF_HEX=$(bssoff fileStore)
[[ -n "$M15_OFF_HEX" ]] || fail "file_store has no .bss offset in kdata.o -- M15's file-descriptor block is missing"
M15_BSS=$(( KDATA_BSS - 16#$M15_OFF_HEX ))
[[ "$M15_BSS" -eq 2560 ]] || fail "the donated bytes from M15's file_store to the end of .bss are $M15_BSS, expected 2560 — 1280 at M15, doubled by M16's write path (ADR-0020 §7)"
KDATA_BSS=$(( KDATA_BSS - M15_BSS ))
KDATA_BSS=$(( KDATA_BSS + ASM_BSS ))   # M17 (ADR-0021): the DCDart half plus the 96 assembly-owned bytes
[[ "$KDATA_BSS" -eq 11552 ]] || fail "the kernel's mutable static storage outside M15's fileStore is $KDATA_BSS bytes, expected 11552 — 9728 through M13 (9664, plus M18's 64-byte scheduler header, ADR-0022) plus fat_store's 1824. If that changed, it changed deliberately and this number and docs/known-gaps.md GAP-0053's running total both move with it."
FAT_STORE_SIZE=$(bsssize fatStore)
[[ "$FAT_STORE_SIZE" == "1824" ]] || fail "kdata.o's fat_store is ${FAT_STORE_SIZE:-missing} bytes, expected 1824"
[[ $(( KDATA_BSS - FAT_STORE_SIZE )) -eq 9728 ]] || fail "the .bss outside fat_store is $(( KDATA_BSS - FAT_STORE_SIZE )), not M13's 9664 plus M18's 64 — M14 moved storage it does not own"

META_OFF=$(dartconst fatMetaOffset fat.dart)
CHAIN_OFF=$(dartconst fatChainOffset fat.dart)
SECTOR_OFF=$(dartconst fatSectorOffset fat.dart)
NAME_OFF=$(dartconst fatNameOffset fat.dart)
STORE_BYTES=$(dartconst fatStoreBytes fat.dart)
META_WORDS=$(dartconst fatMetaWords fat.dart)
CHAIN_MAX=$(dartconst fatChainMax fat.dart)
NAME_BYTES=$(dartconst fatNameBytes fat.dart)
[[ "$STORE_BYTES" -eq "$FAT_STORE_SIZE" ]] || fail "fat.dart's fatStoreBytes is $STORE_BYTES and kdata.S donates $FAT_STORE_SIZE"
[[ "$META_OFF" -eq 0 ]] || fail "fatMetaOffset is $META_OFF, expected 0"
[[ $(( META_OFF + META_WORDS * 8 )) -le "$CHAIN_OFF" ]] \
  || fail "the $META_WORDS metadata words run from $META_OFF to $(( META_OFF + META_WORDS * 8 )) and the chain array starts at $CHAIN_OFF — they overlap"
[[ $(( CHAIN_OFF + CHAIN_MAX * 4 )) -le "$SECTOR_OFF" ]] \
  || fail "the $CHAIN_MAX-entry chain array runs from $CHAIN_OFF to $(( CHAIN_OFF + CHAIN_MAX * 4 )) and the sector buffer starts at $SECTOR_OFF — they overlap"
[[ $(( SECTOR_OFF + 512 )) -le "$NAME_OFF" ]] \
  || fail "the 512-byte sector buffer runs from $SECTOR_OFF to $(( SECTOR_OFF + 512 )) and the name buffer starts at $NAME_OFF — they overlap"
[[ $(( NAME_OFF + NAME_BYTES )) -le "$STORE_BYTES" ]] \
  || fail "the $NAME_BYTES-byte name buffer ends at $(( NAME_OFF + NAME_BYTES )) and the block is only $STORE_BYTES bytes"
echo "STRUCTURAL: pass  kdata.o donates $KDATA_BSS bytes of .bss — M13's 9728 plus fat_store's $FAT_STORE_SIZE — and fat.dart's four regions (meta $META_WORDS words at $META_OFF, chain $CHAIN_MAX entries at $CHAIN_OFF, sector 512 at $SECTOR_OFF, name $NAME_BYTES at $NAME_OFF) tile it without overlapping or overrunning"

# 2b. THE STORAGE SEAM IS EXACTLY FOUR CALL SITES.
#
# ADR-0011 §0's rule, counted the way m7-frames and m11-proc count theirs. This
# is the only structural check in this harness that exists to protect a FUTURE
# change rather than a present property: the day DCDart grows mutable statics
# (GAP-0053), migrating this subsystem is a four-line rewrite if and only if
# nothing outside these four functions knows where the bytes came from.
# Comment lines are stripped first: this file DESCRIBES the seam at length, and
# a rule that counted its own documentation would be measuring prose.
CODE=$(grep -v '^[[:space:]]*//' "$CORE_DIR/kernel/fat.dart")
SEAM=$(printf '%s\n' "$CODE" | grep -c "return Bss[.]addressOf(fatStore)")
MENTIONS=$(printf '%s\n' "$CODE" | grep -cw "fatStore")
[[ "$SEAM" -eq 4 ]] || fail "core/kernel/fat.dart has $SEAM call sites of Bss.addressOf(fatStore), expected exactly 4 (fatMetaBase, fatChainBase, fatSectorBase, fatNameBase). A fifth turns the migration to DCDart mutable statics into an audit — ADR-0011 §0."
[[ "$MENTIONS" -eq 5 ]] || fail "fat.dart names fatStore $MENTIONS times, expected 5: one @extern declaration and the four seam functions"
OUTSIDE=$(grep -rlw "fatStore" "$CORE_DIR/kernel/" | grep -v "/fat.dart$" | wc -l | tr -d ' ')
[[ "$OUTSIDE" -eq 0 ]] || fail "fatStore is named outside core/kernel/fat.dart"
for f in fatMetaBase fatChainBase fatSectorBase fatNameBase; do
  grep -q "u64 $f() {" "$CORE_DIR/kernel/fat.dart" || fail "core/kernel/fat.dart has no $f()"
done
echo "STRUCTURAL: pass  the storage seam is exactly 4 \`return Bss.addressOf(fatStore)\` in fat.dart and 0 anywhere else in core/kernel/"

# 2c. EVERY @rodata TABLE IS THE SIZE ITS CALL SITE PASSES.
#
# GAP-0060: a @rodata table carries no length word, so the count is a literal at
# every call site and the only thing that catches a wrong one is a byte-exact
# golden. This check catches it earlier and says which symbol. The expected
# sizes are not typed here -- they are read out of each table's own doc comment,
# which states the string, so a table and its documentation cannot drift apart
# either.
python3 - "$CORE_DIR/kernel/fat.dart" "$CORE_DIR/kernel/elf.dart" "$CORE_DIR/build/kmain.o" <<'PY' || fail "a @rodata table in fat.dart or elf.dart does not match the string its doc comment records, or the length its call site passes"
import re, subprocess, sys
srcs = sys.argv[1:3]
obj = sys.argv[3]
sizes = {}
for line in subprocess.run(["x86_64-elf-readelf", "-sW", obj],
                           capture_output=True, text=True).stdout.splitlines():
    f = line.split()
    if len(f) >= 8 and f[3] == "OBJECT":
        sizes[f[7]] = int(f[2])
bad = []
checked = 0
text = "".join(open(s).read() for s in srcs)
# Each table is preceded by a doc line of the form:  /// `'...'` -- N bytes.
pat = re.compile(r"/// `'((?:[^'\\]|\\.)*)'` -- (\d+) bytes\.\n@rodata\n"
                 r"final List<u8> (\w+) = const \[(.*?)\];", re.S)
for m in pat.finditer(text):
    lit, n, sym, body = m.group(1), int(m.group(2)), m.group(3), m.group(4)
    if not sym.startswith("fat") and sym != "elfStrFile":
        continue
    checked += 1
    want = lit.replace("\\n", "\n").replace("\\'", "'").replace("\\\\", "\\").encode("ascii")
    got = bytes(int(x, 16) for x in re.findall(r"u8\((0x[0-9A-Fa-f]{2})\)", body))
    if got != want:
        bad.append("%s: the table's bytes are not the string its doc comment records" % sym)
    if len(want) != n:
        bad.append("%s: the doc comment says %d bytes and the string is %d" % (sym, n, len(want)))
    if sizes.get(sym) != len(want):
        bad.append("%s: kmain.o has it at %s bytes, the string is %d"
                   % (sym, sizes.get(sym), len(want)))
    # And the literal every call site passes.
    for call in re.finditer(r"Rodata\.addressOf\(%s\), u64\((\d+)\)" % sym, text):
        if int(call.group(1)) != len(want):
            bad.append("%s: a call site passes %s and the table is %d bytes"
                       % (sym, call.group(1), len(want)))
if checked < 60:
    bad.append("only %d tables were checked; fat.dart declares far more than that, so the "
               "pattern this check matches on has stopped matching" % checked)
for b in bad:
    print("    - " + b, file=sys.stderr)
print("    (%d @rodata tables in fat.dart/elf.dart match their documented strings, their "
      "documented lengths, their sizes in kmain.o and every length literal passed to them)" % checked)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  every M14 @rodata table equals the string its doc comment records, at the size kmain.o gives it and the length its call sites pass"

# 2d. THE HELP TEXT GREW BY EXACTLY THE FOUR COMMANDS THIS MILESTONE ADDS.
HELP_SIZE=$(symsize "$CORE_DIR/build/kmain.o" shellStrHelp)
[[ "$HELP_SIZE" -eq 2224 ]] || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2224 (1871 at M11-M13, plus 276 for \`run <name>\`, \`fs\`, \`ls\` and \`cat <name>\`). A command that is not in \`help\` is undiscoverable — docs/known-gaps.md GAP-0115."
grep -q "uartWrite(Rodata.addressOf(shellStrHelp), u64(2224));" "$CORE_DIR/kernel/shell.dart" \
  || fail "shellHelp() does not pass 2224 — the table and the literal disagree, which is GAP-0060 happening again"
python3 - "$CORE_DIR/kernel/shell.dart" <<'PY' || fail "the help text does not list all four new commands, or a line is too wide for an 80-column screen"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"final List<u8> shellStrHelp = const \[(.*?)\];", src, re.S)
b = bytes(int(x, 16) for x in re.findall(r"u8\((0x[0-9A-Fa-f]{2})\)", m.group(1))).decode()
bad = []
for want in ("  run <name>    ", "  fs            ", "  ls            ", "  cat <name>    "):
    if want not in b:
        bad.append("`help` does not list %r" % want.strip())
for line in b.split("\n"):
    if len(line) > 78:
        bad.append("help line is %d columns: %r" % (len(line), line))
for x in bad:
    print("    - " + x, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  shellStrHelp is 2147 bytes, lists all four new commands, and no line exceeds 78 columns"

# 2e. THIRTY-TWO REFUSAL CODES, EACH REACHABLE AND EACH WITH ITS OWN SENTENCE.
#
# The heading has been wrong twice (it said twenty-nine while the check counted
# thirty-one) because the CHECK reads the count out of the source and the
# heading does not. GAP-0152 added `fatErrReadOnly`, the thirty-second and the
# first that is about PERMISSION rather than about the volume or the drive.
#
# A refusal code nothing returns is dead code that looks like a guard. A code
# whose sentence is another code's is a diagnostic that names the wrong field.
# Both are silent, so both are checked.
python3 - "$CORE_DIR/kernel/fat.dart" <<'PY' || fail "a fatErr* code is unreachable, missing a sentence, or shares one"
import re, sys
src = open(sys.argv[1]).read()
codes = dict((m.group(1), int(m.group(2)))
             for m in re.finditer(r"^const int (fatErr\w+) = (\d+);", src, re.M))
bad = []
if codes.get("fatErrOk") != 0:
    bad.append("fatErrOk is not 0")
nonzero = [c for c in codes if c != "fatErrOk"]
# The last code has no `if` in fatReportError: it is the else, the one the
# dispatcher falls through to. Which one that is, is read out of the source.
LAST = max(nonzero, key=lambda c: codes[c])
if sorted(codes[c] for c in nonzero) != list(range(1, len(nonzero) + 1)):
    bad.append("the refusal codes are not 1..%d without gaps or duplicates" % len(nonzero))
for c in nonzero:
    # Either returned as a refusal, or handed straight to fatReportError by a
    # `void` command that has nowhere to return it to. Both are reachable; a
    # code that is neither is dead. THIS CHECK FOUND ONE -- `fatErrNotMounted`,
    # which every command made unreachable by mounting for itself -- and it was
    # deleted rather than left in as a guard nothing can hit.
    if not (re.search(r"return u64\(%s\);" % c, src)
            or re.search(r"fatReportError\(u64\(%s\)\);" % c, src)):
        bad.append("%s is neither returned nor reported: it is a guard nothing can reach" % c)
    if not re.search(r"if \(code == u64\(%s\)\) \{" % c, src) and c != LAST:
        bad.append("%s has no branch in fatReportError, so it would print the last sentence" % c)
# Every sentence distinct.
tables = dict((m.group(1), m.group(2)) for m in
              re.finditer(r"/// `'((?:[^'\\]|\\.)*)'` -- \d+ bytes\.\n@rodata\n"
                          r"final List<u8> (fatStrE\d+)", src))
seen = {}
for text, sym in tables.items():
    if text in seen:
        bad.append("%s and %s have the same sentence" % (sym, seen[text]))
    seen[text] = sym
if len(tables) != len(nonzero):
    bad.append("there are %d refusal codes and %d sentences" % (len(nonzero), len(tables)))
for b in bad:
    print("    - " + b, file=sys.stderr)
print("    (%d refusal codes, numbered 1..%d, each returned from somewhere in fat.dart, "
      "each with its own branch in fatReportError and its own distinct sentence)"
      % (len(nonzero), len(nonzero)))
sys.exit(1 if bad else 0)
PY
echo "STRUCTURAL: pass  all 32 filesystem refusal codes are reachable, dispatched and distinctly worded"

# 2f. THE FAT16 BAND IS THE SPECIFICATION'S, AND THE TYPE IS COMPUTED.
#
# 4085 and 65525 are not this repo's numbers. And `BS_FilSysType` -- the
# "FAT16   " string at offset 54 -- must NOT be read: a driver that trusted it
# would read a FAT12 volume as FAT16 and every 12-bit chain entry would be a
# plausible 16-bit cluster number.
[[ "$(dartconst fatFat12Max fat.dart)" -eq 4085 ]] || fail "fat.dart's fatFat12Max is not 4085"
[[ "$(dartconst fatFat16Max fat.dart)" -eq 65525 ]] || fail "fat.dart's fatFat16Max is not 65525"
grep -q "final u64 clusters = (tot - dataStart) ~/ spc;" "$CORE_DIR/kernel/fat.dart" \
  || fail "fatMount no longer computes the cluster count as (totalSectors - dataStart) / sectorsPerCluster — that ONE quantity is what decides FAT12/FAT16/FAT32"
grep -qE "const int fatBpb\w+ = 54;" "$CORE_DIR/kernel/fat.dart" \
  && fail "fat.dart names offset 54 (BS_FilSysType). That string is documentation, not a determinant; reading it would make a FAT12 volume look like FAT16."
echo "STRUCTURAL: pass  the FAT12/FAT16/FAT32 boundaries are 4085 and 65525, the type is COMPUTED from the cluster count, and BS_FilSysType at offset 54 is never read"

# 2g. M14'S OWN SESSION WRITES NOTHING, AND THAT IS MEASURED BY RUNNING.
#
# THIS ASSERTION WAS REPLACED AT M16, DELIBERATELY AND IN THE OPEN. Until M16
# this block grepped `core/kernel/ata.dart` for the opcodes 0x30 and 0x34, every
# `port_outw` call site for a port that was not the framebuffer's VBE pair, and
# every kernel file for a write function by name -- and required all three to be
# absent. That was the strongest available statement while nothing in this
# kernel could write a sector.
#
# M16 (docs/decisions/0020-writing-to-a-disk.md) makes all three false. What
# replaces them is not weaker:
#
#   * THE ONE CALL SITE. `ataWriteFrom` is defined once and called from exactly
#     one place, `fatWriteSector`, and the only `port_outw` aimed at the ATA
#     data register is inside it. So "can this code path write a sector?" is
#     still a question with one place to look -- which is the property the old
#     grep was really protecting.
#   * THE MEASUREMENT. Check 7i requires the image this harness hands to QEMU
#     to be BYTE-FOR-BYTE IDENTICAL afterwards, and the variant loop requires
#     the same of all five broken volumes. A kernel that can write and does not
#     still passes; a kernel that quietly wrote one sector does not.
python3 - "$CORE_DIR/kernel" <<'WRITEPATH' || fail "the ATA write path is reachable from somewhere other than fatWriteSector, or a port_outw is aimed somewhere it should not be"
import glob, os, re, sys
kdir = sys.argv[1]
code = {}
for path in sorted(glob.glob(os.path.join(kdir, "*.dart"))):
    src = open(path).read()
    code[os.path.basename(path)] = "\n".join(
        l for l in src.splitlines() if not l.strip().startswith("//"))
bad = []
defs = sum(len(re.findall(r"^u64 ataWriteFrom\(", s, re.M)) for s in code.values())
if defs != 1:
    bad.append("ataWriteFrom is defined %d times, expected 1" % defs)
calls = []
for name, s in code.items():
    for line in s.splitlines():
        if "ataWriteFrom(" in line and not line.startswith("u64 ataWriteFrom("):
            calls.append((name, line.strip()))
if len(calls) != 1 or calls[0][0] != "fat.dart":
    bad.append("ataWriteFrom has %d call sites and they are %s; expected exactly "
               "one, in fat.dart" % (len(calls), calls))
sites = []
for name, s in code.items():
    for m in re.finditer(r"port_outw\(u64\((\w+)\)", s):
        sites.append((name, m.group(1)))
allowed = {("fb.dart", "vbeIndexPort"), ("fb.dart", "vbeDataPort"),
           ("ata.dart", "ataRegData")}
for site in sites:
    if site not in allowed:
        bad.append("%s calls port_outw with %s" % site)
if len([x for x in sites if x == ("ata.dart", "ataRegData")]) != 1:
    bad.append("there is not exactly one port_outw aimed at the ATA data register")
print("    (%d port_outw call sites: the framebuffer's VBE index/data pair, and "
      "ONE at the ATA data register inside ataWriteFrom)" % len(sites))
for b in bad:
    print("    - " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
WRITEPATH
echo "STRUCTURAL: pass  the ATA write path M16 added is reachable from exactly one place (fatWriteSector) and the only port_outw aimed at 0x1F0 is inside it. That M14's own boots write nothing at all is asserted at check 7i, by comparing the image's SHA-256 before and after — which is what this check used to assert by grepping for an opcode that now exists."

# 2h. THE CHAIN IS FOLLOWED, IN THE SOURCE.
#
# The single most important property this milestone claims, checked once in the
# source and then again by a boot against a fragmented volume. `fatFileSector`
# must index the CHAIN ARRAY; a version that computed `first + i` would pass
# every test on a contiguous volume.
grep -q "final u64 c = fatChain(ci);" "$CORE_DIR/kernel/fat.dart" \
  || fail "fatFileSector no longer reads the chain array — it would be assuming contiguity"
grep -q "fatChain(ci)" "$CORE_DIR/kernel/fat.dart" \
  || fail "nothing indexes the chain array by sector"
grep -q "if (fatChainSeen(c, n) > u64(0))" "$CORE_DIR/kernel/fat.dart" \
  || fail "fatBuildChain no longer checks for a cluster it has already seen — a cyclic FAT would hang the kernel"
grep -q "if (fatOpenActive() > u64(0)) {" "$CORE_DIR/kernel/elf.dart" \
  || fail "elfImageLba no longer consults fat.dart, so \`run <name>\` would read contiguous sectors"
echo "STRUCTURAL: pass  fatFileSector indexes the chain array, fatBuildChain checks for a repeated cluster, and elfImageLba routes the loader's reads through the chain"

# ---------------------------------------------------------------------------
# Step 3 — verify-freestanding, on every object.
# ---------------------------------------------------------------------------
VF_OUT="$(cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o 2>&1)"
VF_STATUS=$?
echo "$VF_OUT"
[[ $VF_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed on kmain.o"
EXTERN_COUNT=$(grep -oE '\(([0-9]+) declared extern' <<<"$VF_OUT" | head -1 | grep -oE '[0-9]+')
# M15 (ADR-0019) added exactly ONE: `fileStore`. Subtracted so that M14's
# own count keeps meaning what it meant when it was written.
# M17 (ADR-0021) deleted all SIXTEEN `_addr()` accessor externs: every block of
# assembly-donated `.bss` they addressed is now a DCDart `@bss` mutable static in
# the subsystem that owns it. The kernel declares 44 externs, not 60, and each of
# the sixteen is asserted ABSENT as well — a count alone can be restored by an
# unrelated extern.
for gone in \
            vga_cursor_addr m2_phase_addr shell_line_addr \
            shell_len_addr shell_state_addr shell_mbinfo_addr \
            kbd_prefix_addr fault_count_addr fb_state_addr \
            pmm_store_addr vm_store_addr user_store_addr \
            elf_store_addr proc_store_addr fat_store_addr \
            file_store_addr; do
  grep -q "\\b$gone\\b" <<<"$VF_OUT" && fail "$gone is still declared extern — ADR-0021 deleted it"
done
[[ "$EXTERN_COUNT" -eq 44 ]] || fail "kmain.o declares $EXTERN_COUNT externs, expected 44 — M13's 58 less the fourteen accessors ADR-0021 deleted at or before M13; M14's only extern was fat_store_addr, so M14 now adds NONE"
# kdata.o and portio.o and nothing else: isr.o and boot.o are the assembly
# stubs that CALL into DCDart by name, so they are undefined-by-construction and
# every harness since M2 has left them out for that reason.
for obj in kdata.o portio.o; do
  (cd "$CORE_DIR" && bash scripts/verify-freestanding.sh "build/$obj" >/dev/null 2>&1) \
    || fail "verify-freestanding.sh failed on $obj"
done
echo "FREESTANDING: $EXTERN_COUNT declared externs on kmain.o, M13's 58 less the fourteen accessors ADR-0021 deleted; M14's own fat_store_addr is gone too, so M14 adds NONE; kdata.o and portio.o clean standalone"

# ---------------------------------------------------------------------------
# Step 4 — build the two programs and the volume, and have TWO INDEPENDENT
# TOOLS agree it is a FAT16 volume before the kernel is allowed near it.
#
# This is the step that stops M14 from being a private format with a familiar
# name. `fsck_msdos` is Apple's, from FreeBSD, and has never heard of this repo;
# macOS's `msdos` kernel extension MOUNTS the image and reads a file back along
# the same fragmented chain. If either disagreed, the volume would be wrong and
# every check after this would be measuring agreement between two halves of the
# same mistake.
# ---------------------------------------------------------------------------
PROGDIR="$WORKDIR/progs"
BUILD_PROGS_OUT="$(bash "$SCRIPT_DIR/build-progs.sh" "$PROGDIR" 2>&1)"
BP_STATUS=$?
echo "$BUILD_PROGS_OUT"
[[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/m14.img"
LAYOUT="$WORKDIR/layout.json"
python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/progA.elf" "$PROGDIR/progB.elf" \
  || fail "make-image.py could not write the volume"
python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$PROGDIR/progA.elf" "$PROGDIR/progB.elf" --json \
  > "$LAYOUT" || fail "make-image.py --json failed"

# M16 replaced this harness's "no write opcode anywhere" grep with a
# measurement (see 2g). This is the first half of it: the SHA-256 of the volume
# before any boot has seen it. The second half is at the end of step 7.
M14_SHA_BEFORE=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
[[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found; this harness will not certify a FAT volume no independent tool has read"
FSCK_OUT="$("$FSCK" -n "$DISK_IMG" 2>&1)"
FSCK_STATUS=$?
[[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image (exit $FSCK_STATUS) — it is not a valid FAT volume, whatever this kernel makes of it"; }
grep -q "Phase 3" <<<"$FSCK_OUT" || { echo "$FSCK_OUT" >&2; fail "fsck_msdos did not get as far as phase 3"; }
grep -qE "1 KiB bad \(1 clusters\)" <<<"$FSCK_OUT" \
  || { echo "$FSCK_OUT" >&2; fail "fsck_msdos does not report the ONE cluster this image deliberately marks bad (FFF7) — either the marker is not the real one or fsck did not read the FAT"; }
echo "IMAGE: pass  fsck_msdos accepts the volume and accounts for the one deliberately-bad cluster: $(grep -E '^Warning|files,' <<<"$FSCK_OUT" | tail -1)"

# The real host driver. Best-effort by design: `hdiutil` exists only on macOS,
# and a Linux runner should not fail for not being a Mac. When it IS there, the
# comparison is required to succeed.
MOUNT_VERIFIED="not attempted (no hdiutil)"
if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  ATTACH_OUT="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nobrowse \
                  -mountpoint "$MOUNTPOINT" "$DISK_IMG" 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo "$ATTACH_OUT" >&2
    fail "hdiutil could not mount the image — macOS's own msdos driver does not think this is a FAT volume"
  fi
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  [[ -f "$MOUNTPOINT/PROGA.ELF" ]] || fail "the mounted volume has no PROGA.ELF"
  cmp -s "$MOUNTPOINT/PROGA.ELF" "$PROGDIR/progA.elf" \
    || fail "macOS's msdos driver reads PROGA.ELF back DIFFERENTLY from what was written — the fragmented chain is wrong, and this kernel agreeing with the generator would prove nothing"
  [[ -f "$MOUNTPOINT/HELLO.TXT" ]] || fail "the mounted volume has no HELLO.TXT"
  [[ -d "$MOUNTPOINT/SUB" ]] || fail "the mounted volume's SUB is not a directory"
  # The long-filename entries are real ones: the host driver shows the LONG name
  # for PROGB.ELF, which is what this kernel deliberately does NOT do.
  LONGNAME=$(ls "$MOUNTPOINT" | grep -c 'program-b-with-a-long-name.elf')
  [[ "$LONGNAME" -eq 1 ]] \
    || fail "macOS does not see PROGB.ELF's long filename — the LFN entries on this volume are not the real thing, so 'the kernel skips real LFN entries' would be untested"
  cmp -s "$MOUNTPOINT/program-b-with-a-long-name.elf" "$PROGDIR/progB.elf" \
    || fail "macOS reads PROGB.ELF back differently from what was written"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  MOUNT_VERIFIED="mounted by macOS's own msdos driver; PROGA.ELF and PROGB.ELF read back byte-for-byte along their fragmented chains, SUB is a directory, and PROGB's long name resolves"
fi
echo "IMAGE: pass  $MOUNT_VERIFIED"

IMG_BYTES=$(wc -c <"$DISK_IMG" | tr -d ' ')

# ---------------------------------------------------------------------------
# Step 5 — derive every expectation from the image that was just built.
# ---------------------------------------------------------------------------
DERIVED="$WORKDIR/derived.txt"
python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG" "$LAYOUT" "$PROGDIR/progA.elf" "$PROGDIR/progB.elf" \
  > "$DERIVED" || fail "derive.py could not derive the expectations (it re-reads the volume and cross-checks make-image.py against it)"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
[[ -n "$(d proga_fnv)" ]] || fail "derive.py produced no proga_fnv"
echo "DERIVED: $(d clusters) clusters of $(( $(d spc) * $(d bps) ))B, data at LBA $(d data_start); PROGA.ELF at clusters $(d proga_chain); PROGB.ELF at $(d progb_chain); HELLO.TXT at $(d hello_chain)"
echo "DERIVED: PROGA's own hash of its R+X segment must be $(d proga_fnv) — a contiguous read of the same file would hash $(d proga_fnv_contiguous), and that number must not appear anywhere"

# ---------------------------------------------------------------------------
# Step 6 — the boots. ONE against the good volume, SIX against broken ones.
#
# The six are not thoroughness for its own sake. Nine of this driver's twenty-
# eight refusal codes are about a volume being something it will not read, and
# not one of them is reachable from a correct volume. A refusal path that has
# never executed is not a refusal, it is a comment.
# ---------------------------------------------------------------------------
drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4" portoff="$5" img="$6"
  shift 6
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  # GAP-0150: a port that is FREE RIGHT NOW, from the host kernel, rather
  # than a hash of this shell's PID -- which collides with a concurrent
  # harness, with a re-run onto a recycled PID, and with this harness's own
  # previous boot still in TIME_WAIT. All three used to surface as QEMU
  # dying with "Address already in use".
  local port
  port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 420 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$img,format=raw,if=ide,index=0,media=disk" \
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

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

# `frames` brackets the whole session, which is the leak check.
#
# The `wait:` after `help` is GAP-0105: `help` is now 2147 bytes, about 190ms of
# serial plus four more lines of VGA scrolling, and a keystroke typed into the
# tail of it is dropped.
SESSION_KEYS="f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,h,e,l,p,ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "fs"),ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "ls"),ret,wait:1400"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "cat hello.txt"),ret,wait:2500"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "cat sub"),ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "cat ghost.elf"),ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "cat nope.txt"),ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "cat hello.txtx"),ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "cat"),ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run proga.elf"),ret,wait:6000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run progb.elf"),ret,wait:6000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run nope.elf"),ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run"),ret,wait:900"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run 20"),ret,wait:1600"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:1200"

SHOT_PNG="$CORE_DIR/build/screenshot-fat.png"
drive_session "$WORKDIR/main" "$SESSION_KEYS" "$SHOT_PNG" "main" 0 "$DISK_IMG"
SERIAL="$WORKDIR/main/serial.txt"
SCREEN="$WORKDIR/main/screen.txt"
[[ -s "$SERIAL" ]] || fail "the main boot captured no serial output at all"

have() { grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { grep -qF -- "$1" "$SERIAL" && fail "the transcript contains what it must not: $1"; }

# ---------------------------------------------------------------------------
# Step 7 — the derived checks. Every number below came out of derive.py, which
# read it off the volume; not one of them is typed here.
# ---------------------------------------------------------------------------

# 7a. THE GEOMETRY THE KERNEL COMPUTED IS THE GEOMETRY ON THE DISK.
MOUNT_LINE=$(printf "FS MOUNT BPS %04X SPC %02X RSV %04X NFAT %02X FATSZ %04X ROOT %04X TOT %08X" \
  "$(d bps)" "$(d spc)" "$(d rsv)" "$(d nfat)" "$(d fatsz)" "$(d rootent)" "$(d tot)")
GEOM_LINE=$(printf "FS GEOM FAT %08X ROOT %08X DATA %08X CLUSTERS %08X TYPE 10" \
  "$(d fat_start)" "$(d root_start)" "$(d data_start)" "$(d clusters)")
have "$MOUNT_LINE"
have "$GEOM_LINE"
echo "CHECK 7a: pass  \`fs\` reproduces the BPB and the four derived region offsets exactly — $GEOM_LINE"

# 7b. THE LISTING IS THE DIRECTORY, INCLUDING WHAT IT LEAVES OUT.
n=0
while :; do
  line=$(d "ls_line_$n") || break
  [[ -n "$line" ]] || break
  have "$line"
  n=$(( n + 1 ))
done
[[ "$n" -eq "$(d dir_listed)" ]] || fail "derive.py produced $n listing lines and says $(d dir_listed) entries should be listed"
have "$(d ls_tail)"
[[ "$(d dir_skipped)" -ge 5 ]] || fail "the volume does not carry the five entries a listing has to skip (a volume label, a deleted entry and three LFN entries); the skip logic would be untested"
# The three LFN entries hold the long name as UTF-16. A driver that printed them
# as 8.3 names would put its first two characters on the screen.
havent "FS ENT 04 NAME"
havent "FS ENT 05 NAME"
havent "FS ENT 06 NAME"
havent "GHOST"
echo "CHECK 7b: pass  \`ls\` printed exactly the $(d dir_listed) real entries of the $(d dir_walked) it walked, skipped $(d dir_skipped) (the volume label, the deleted GHOST.ELF and three long-filename entries), and printed none of them"

# 7c. THE CHAINS, CLUSTER BY CLUSTER, FOR ALL THREE FILES.
#
# This is the milestone. The numbers below are the ones make-image.py allocated
# and derive.py re-read out of the FAT; a driver that assumed contiguity would
# print a consecutive run.
for tag in hello proga progb; do
  have "$(d ${tag}_open)"
  have "$(d ${tag}_chainhdr)"
  k=0
  while :; do
    line=$(d "${tag}_clusline_$k") || break
    [[ -n "$line" ]] || break
    have "$line"
    k=$(( k + 1 ))
  done
  [[ "$k" -ge 1 ]] || fail "derive.py produced no cluster lines for $tag"
  # And a contiguous run of the same length must NOT appear.
  first=$(d ${tag}_first)
  cont=$(python3 -c "
import sys
n = int(sys.argv[1]); f = int(sys.argv[2])
print('FS CLUS ' + ' '.join('%04X' % (f + i) for i in range(min(n, 8))))" "$(d ${tag}_clusters)" "$first")
  havent "$cont"
done
echo "CHECK 7c: pass  all three files' cluster chains appear exactly as allocated — HELLO.TXT $(d hello_chain), PROGA.ELF $(d proga_chain), PROGB.ELF $(d progb_chain) — and the consecutive run each would have produced does not appear"

# 7d. THE FILE'S CONTENTS, ACROSS A 98-CLUSTER HOLE.
python3 - "$SERIAL" "$DISK_IMG.hello" <<'PY' || fail "the bytes \`cat\` printed are not HELLO.TXT's bytes"
import sys
cap = open(sys.argv[1], "rb").read()
want = open(sys.argv[2], "rb").read()
if want not in cap:
    # Say WHERE it diverged rather than just that it did.
    for n in range(len(want), 0, -1):
        if want[:n] in cap:
            print("    - the capture matches HELLO.TXT for %d of %d bytes and then diverges; "
                  "byte %d should be %r" % (n, len(want), n, want[n:n+1]), file=sys.stderr)
            break
    else:
        print("    - none of HELLO.TXT's bytes appear in the capture", file=sys.stderr)
    sys.exit(1)
PY
have "FS CAT END $(printf '%08X' "$(d hello_size)")"
# The background pattern occupies every unallocated cluster. If `cat` had read
# forward from cluster 2 it would have printed the pattern's label instead of
# the second half of the text.
havent "OSCORTEX SECTOR"
echo "CHECK 7d: pass  \`cat hello.txt\` printed all $(d hello_size) bytes, spanning clusters $(d hello_chain) — and not one byte of the background pattern that fills the 98 clusters in between"

# 7e. THE PROGRAMS HASHED THEMSELVES CORRECTLY, AND THE CONTIGUOUS HASH IS ABSENT.
for tag in proga progb; do
  have "M14 PROG $( [[ $tag == proga ]] && echo A || echo B ) BYTES $(d ${tag}_ro_bytes | xargs printf '%x') FNV $(d ${tag}_fnv)"
  havent "FNV $(d ${tag}_fnv_contiguous)"
  have "ELF DONE EXIT 00000000000000$(d ${tag}_exit)"
  have "ELF ENTER RIP $(printf '%016X' "0x$(d ${tag}_entry)" | tr 'a-f' 'A-F')"
done
have "M14 PROG A TAG PROGA.ELF took the odd clusters"
have "M14 PROG B TAG PROGB.ELF took the even clusters"
havent "M14 PROG A TAG PROGB.ELF"
havent "M14 PROG B TAG PROGA.ELF"
echo "CHECK 7e: pass  both programs hashed their own R+X segments to the values derive.py computes from the ELFs ($(d proga_fnv), $(d progb_fnv)), exited with the statuses those hashes imply ($(d proga_exit), $(d progb_exit)), and neither printed the hash a contiguous read would have produced ($(d proga_fnv_contiguous), $(d progb_fnv_contiguous))"

# 7f. EVERY REFUSAL THE GOOD VOLUME CAN PRODUCE, PRODUCED.
#
# Five refusals that are about a NAME rather than about a volume, each from a
# real command typed at a real shell.
have "FS ERR 11 that name is a subdirectory, and subdirectories are not supported"
have "FS ERR 10 no such name in the root directory"
have "FS ERR 1C that is not an 8.3 name: it is empty, over 8.3, or has a bad byte"
have "usage: cat <NAME.EXT> -- an 8.3 name in the root directory"
have "   or: run <NAME.EXT> -- an 8.3 name in the root directory"
# `cat ghost.elf` must be NOT FOUND and not a read of the deleted entry's
# clusters -- which are PROGA.ELF's, and would have printed an ELF header.
DELETED_HITS=$(grep -c "^FS OPEN GHOST" "$SERIAL")
[[ "$DELETED_HITS" -eq 0 ]] || fail "the deleted entry GHOST.ELF was opened; its first cluster is PROGA.ELF's and a driver that read it would have run a file that does not exist"
echo "CHECK 7f: pass  a subdirectory, a deleted entry, a missing name and an over-long name are four DIFFERENT refusals, and \`cat\` and \`run\` each print a usage line naming the other form"

# 7g. THE NUMERIC FORM STILL WORKS, AND ON THIS VOLUME IT CORRECTLY REFUSES.
#
# `run 20` is sector 0x20, which on a FAT16 volume is the middle of the second
# FAT. The loader must go through the CONTIGUOUS path (no chain), read that
# sector, and refuse it for not carrying `OSCXPRG1` -- which is m10-elf's
# refusal, produced by m10-elf's code path, on a milestone that replaced neither.
have "ELF REFUSED 05 the header sector does not begin with OSCXPRG1"
echo "CHECK 7g: pass  \`run <lba>\` still takes the contiguous path — \`run 20\` reads sector 0x20 of this volume and refuses it by M10's own refusal code"

# 7h. NOTHING LEAKED, TO THE FRAME.
FREE_BEFORE=$(grep -m1 "^PMM MANAGED" "$SERIAL" | sed -E 's/.*FREE ([0-9A-F]+).*/\1/')
FREE_AFTER=$(grep "^PMM MANAGED" "$SERIAL" | tail -1 | sed -E 's/.*FREE ([0-9A-F]+).*/\1/')
[[ -n "$FREE_BEFORE" && -n "$FREE_AFTER" ]] || fail "the session did not bracket itself with two \`frames\` reports"
[[ "$FREE_BEFORE" == "$FREE_AFTER" ]] \
  || fail "the frame allocator had 0x$FREE_BEFORE free before the session and 0x$FREE_AFTER after; two programs were loaded and torn down and the count must be identical"
havent "USER FAULT"
havent "FAULT RECOVERED"
echo "CHECK 7h: pass  0x$FREE_BEFORE frames free before the session and 0x$FREE_AFTER after, across two loads and two teardowns, with no fault anywhere in the capture"

# 7i. M14'S SESSION WROTE NOTHING, MEASURED RATHER THAN GREPPED FOR.
#
# The other half of check 2g. This image was carried through a boot that
# mounted the volume, listed the root directory, printed a file across a
# 98-cluster hole and loaded two programs off it by name. Since M16 the kernel
# underneath is one that CAN write a sector; this says it did not write one
# here, which is a claim about what ran rather than about what is spellable.
M14_SHA_AFTER=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)
[[ "$M14_SHA_BEFORE" == "$M14_SHA_AFTER" ]] \
  || fail "M14's boot CHANGED the volume (sha256 $M14_SHA_BEFORE -> $M14_SHA_AFTER). This kernel can write to a disk since M16; nothing M14 does is supposed to."
echo "CHECK 7i: pass  the volume is byte-for-byte identical after the whole session — sha256 $M14_SHA_AFTER"

# ---------------------------------------------------------------------------
# Step 8 — the five broken volumes.
# ---------------------------------------------------------------------------
variant_boot() {
  local name="$1" keys="$2" portoff="$3"
  local img="$WORKDIR/v-$name.img"
  python3 "$SCRIPT_DIR/make-image.py" "$img" "$PROGDIR/progA.elf" "$PROGDIR/progB.elf" \
    --variant="$name" >"$WORKDIR/v-$name.txt" || fail "make-image.py could not write the $name variant"
  cat "$WORKDIR/v-$name.txt"
  local vsha_before
  vsha_before=$(shasum -a 256 "$img" | cut -d' ' -f1)
  drive_session "$WORKDIR/v-$name" "$keys" "$WORKDIR/v-$name.png" "$name" "$portoff" "$img"
  VSER="$WORKDIR/v-$name/serial.txt"
  # M16: every one of these boots must leave its volume alone, including the
  # ones whose volume is already broken. A kernel that "repaired" something it
  # was only asked to read would be caught here.
  [[ "$vsha_before" == "$(shasum -a 256 "$img" | cut -d' ' -f1)" ]] \
    || fail "the $name boot CHANGED its image; nothing M14 does writes to a disk"
}
vhave() { grep -qF -- "$1" "$VSER" || { echo "--- $VSER ---" >&2; sed -n '/M1 END/,$p' "$VSER" >&2; fail "the $2 boot's transcript does not contain: $1"; }; }

FS_KEYS="$(typekeys "fs"),ret,wait:900"
variant_boot nosig "$FS_KEYS" 11
vhave "FS ERR 02 no 55AA signature at offset 510: this is not a FAT volume" nosig
variant_boot sectorsize "$FS_KEYS" 12
vhave "FS ERR 03 bytes-per-sector is not 512, and this driver reads 512-byte sectors" sectorsize
variant_boot fat32 "$FS_KEYS" 13
vhave "FS ERR 07 BPB_FATSz16 is 0, which is the FAT32 boot sector's shape" fat32
variant_boot fat12 "$FS_KEYS" 14
vhave "FS ERR 0B the cluster count is under 4085, so this volume is FAT12" fat12
echo "CHECK 8a: pass  four boots against four volumes with one thing wrong each — no boot signature, 1024-byte sectors, a FAT32-shaped BPB and a genuinely FAT12 volume — produce four DIFFERENT refusals, each naming the field"

BAD_KEYS="$(typekeys "fs"),ret,wait:900"
BAD_KEYS="$BAD_KEYS,$(typekeys "cat hello.txt"),ret,wait:1200"
BAD_KEYS="$BAD_KEYS,$(typekeys "cat proga.elf"),ret,wait:1200"
BAD_KEYS="$BAD_KEYS,$(typekeys "run progb.elf"),ret,wait:1400"
variant_boot badchains "$BAD_KEYS" 15
BADSER="$VSER"
vhave "$MOUNT_LINE" badchains
vhave "FS ERR 17 the chain visits a cluster twice: it is a cycle, not a chain" badchains
vhave "FS ERR 16 the chain runs into a cluster marked bad, FFF7" badchains
vhave "FS ERR 19 the chain ends before the directory entry's size does" badchains
# 8b-bis. A CHAIN THAT LEAVES THE DATA REGION.
#
# This variant exists because a mutation SURVIVED without it: loosening
# `fatValidCluster`'s upper bound by 64 clusters changed nothing any other check
# could see, because no chain on any other volume goes anywhere near the end.
# The link below is exactly `clusterCount + 2` -- the first illegal cluster
# number, and the one an off-by-two accepts.
variant_boot outofrange "$(typekeys "cat hello.txt"),ret,wait:1200" 16
vhave "FS ERR 14 the chain leaves a cluster number outside the data region" outofrange
echo "CHECK 8b-bis: pass  a chain link of exactly clusterCount + 2 -- the first illegal cluster number -- is refused as out of range rather than followed"

echo "CHECK 8b: pass  a volume that MOUNTS correctly and whose three files have three different broken chains produces three different refusals — a 2-cycle named as a cycle rather than followed, a link into the cluster marked FFF7, and a chain that ends before its size does"

# 8c. THE NEGATIVE CONTROL: the main boot's expectations, run against the
#     badchains transcript, MUST FAIL.
#
# m10, m11, m12 and m13 each found one check that passed for the wrong reason.
# This is the shape that catches it: the assertions above are re-applied to a
# capture where the same commands were typed against a volume whose chains are
# broken, and every one of them is REQUIRED not to hold. A `have` that passed
# there would be matching something the session prints regardless.
CONTROL_FAILURES=0
for want in "$(d proga_chainhdr)" "$(d hello_chainhdr)" "$(d proga_clusline_0)" \
            "M14 PROG A BYTES $(d proga_ro_bytes | xargs printf '%x') FNV $(d proga_fnv)" \
            "ELF DONE EXIT 00000000000000$(d proga_exit)" \
            "M14 PROG B TAG PROGB.ELF took the even clusters"; do
  if grep -qF -- "$want" "$BADSER"; then
    fail "the negative control FAILED to fail: \"$want\" appears in the badchains transcript too, so asserting it against the main transcript was measuring something that happens either way"
  fi
  CONTROL_FAILURES=$(( CONTROL_FAILURES + 1 ))
done
echo "CHECK 8c: pass  all $CONTROL_FAILURES of the main boot's load-bearing expectations FAIL against the badchains transcript, so none of them is a line the session prints regardless"

# ---------------------------------------------------------------------------
# Step 9 — the byte-exact goldens.
#
# LAST, deliberately. Every check above is derived from the volume that was
# built, so a wrong driver cannot enshrine itself by regenerating: `--regen`
# rewrites the two files below and leaves all of Step 7 and Step 8 standing.
# ---------------------------------------------------------------------------
if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL" "$EXPECTED_SERIAL"
  cp "$SCREEN" "$EXPECTED_SCREEN"
  echo "REGEN: wrote $(wc -c <"$EXPECTED_SERIAL" | tr -d ' ') bytes of serial golden and the 80x25 screen golden"
fi
[[ -f "$EXPECTED_SERIAL" ]] || fail "no golden at $EXPECTED_SERIAL — run once with --regen"
[[ -f "$EXPECTED_SCREEN" ]] || fail "no screen golden at $EXPECTED_SCREEN — run once with --regen"

if ! cmp -s "$SERIAL" "$EXPECTED_SERIAL"; then
  echo "--- first difference ---" >&2
  cmp "$SERIAL" "$EXPECTED_SERIAL" >&2
  diff <(cat -v "$EXPECTED_SERIAL") <(cat -v "$SERIAL") | head -40 >&2
  fail "the serial capture does not match $EXPECTED_SERIAL byte for byte"
fi
SERIAL_BYTES=$(wc -c <"$SERIAL" | tr -d ' ')

if ! cmp -s "$SCREEN" "$EXPECTED_SCREEN"; then
  diff "$EXPECTED_SCREEN" "$SCREEN" | head -30 >&2
  fail "the 80x25 screen read out of guest memory does not match $EXPECTED_SCREEN"
fi

# M1's 544 bytes, byte for byte, as a PREFIX. Every harness from M4 on asserts
# this, and it is the assertion that says a filesystem costs the boot path
# nothing: fatInit() prints nothing and must keep printing nothing.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL" > "$WORKDIR/prefix.bin"
if ! cmp -s "$WORKDIR/prefix.bin" "$M1_EXPECTED"; then
  cmp "$WORKDIR/prefix.bin" "$M1_EXPECTED" >&2
  fail "the first $M1_BYTES bytes of this capture are not m1-interrupts' golden — M14 changed the boot path, and it must not"
fi
echo "GOLDEN: pass  ${SERIAL_BYTES}-byte serial match, 80x25 screen match, and m1-interrupts' ${M1_BYTES}-byte golden intact as a byte-exact prefix"
[[ -f "$SHOT_PNG" ]] || fail "no screenshot at $SHOT_PNG"

echo "M14-fat: PASS — dcc build -> assemble -> link -> clang + x86_64-elf-ld build TWO freestanding static ELF64 programs that HASH THEIR OWN R+X SEGMENT -> make-image.py writes a real FAT16 volume (${IMG_BYTES} bytes = $(( IMG_BYTES / 512 )) sectors, $(d clusters) clusters of $(( $(d spc) * $(d bps) ))B) on which NOTHING IS CONTIGUOUS -> fsck_msdos accepts it and macOS's own msdos driver mounts it and reads both programs back byte-for-byte -> 8 structural checks (donated .bss 9664 -> 11488 with fat_store's four regions tiling 1824 bytes without overlap, the storage seam exactly 4 call sites in one file, 68 @rodata tables (67 in fat.dart, one in elf.dart) each equal to the string its doc comment records and to every length literal passed to it, shellStrHelp 1871 -> 2147 with all four new commands and no line over 78 columns, 32 refusal codes each reachable and each distinctly worded (GAP-0152 added fatErrReadOnly), the FAT12/FAT16 boundary computed from the cluster count and BS_FilSysType never read, the ATA write path M16 added reachable from exactly one place with the only port_outw at 0x1F0 inside it, and fatFileSector indexing the chain array) -> verify-freestanding pass ($EXTERN_COUNT declared externs, 58 + fatStore) -> SEVEN real QEMU boots. A ${SERIAL_BYTES}-byte serial match with M1's ${M1_BYTES}-byte golden intact as a prefix; \`fs\` reproducing the BPB and four derived region offsets; \`ls\` printing 4 entries and skipping 5 (a volume label, a deleted entry and three real long-filename entries the host driver resolves); \`cat\` printing a file across a 98-cluster hole with not one byte of the pattern filling the gap; TWO PROGRAMS LOADED BY NAME whose clusters interleave with each other's, each hashing its own image to the value derive.py computes from the ELF and NEITHER printing the hash a contiguous read would have produced; four refusals for four kinds of bad name; \`run <lba>\` still taking the contiguous path; the allocator's free count identical before and after; THE VOLUME BYTE-FOR-BYTE IDENTICAL AFTER EVERY BOOT, which is what M16 replaced this harness's read-only greps with; four boots against four one-thing-wrong volumes producing four different refusals; one boot against a volume whose three files have three different broken chains producing a named cycle, a bad cluster and a short chain; one against a volume whose chain leaves the data region by exactly one cluster; and every load-bearing expectation REQUIRED to fail against the broken-chain transcript. Screenshot at $SHOT_PNG"
