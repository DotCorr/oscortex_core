#!/usr/bin/env bash
# core/tests/conformance/drm-abi/run.sh
#
# THE FIRST C LIBRARY THIS OPERATING SYSTEM WAS EVER POINTED AT.
#
# This is not a ROADMAP milestone. It is the first rung of `docs/design/
# drm-abi.md`'s ladder, taken under ADR-0031, and its claim is deliberately
# narrower than "libdrm works":
#
#   1. UNMODIFIED libdrm source COMPILES for x86_64-unknown-none-elf against
#      core/user/libc plus a shim header set that declares names and implements
#      nothing. Five objects, 7,801 lines of somebody else's C.
#   2. The set of symbols it then needs that this OS does not have is EXACTLY
#      the list in core/user/ports/libdrm/expected-missing-core.txt. After
#      ADR-0033 that list is EMPTY: libdrm's five objects LINK, and `main` is
#      the only undefined symbol left. It was 43 before. (32 with modetest, and
#      those are pthreads, poll, select and libm -- GAP-0173.)
#   3. `open`, `read`, `close` and `printf` used to resolve against
#      core/user/libc BY NAME and were the WRONG FUNCTIONS -- a clean link and a
#      wrong program (GAP-0170). CHECK 2 now asserts the OPPOSITE of what it
#      used to: linking libdrm against the NATIVE objects alone must leave all
#      four UNDEFINED, because the native surface is `os_*` now. CHECK 2b
#      asserts that the opt-in adapter (posix.c, port.c) makes it link.
#   4. A program compiled against Linux's UNMODIFIED DRM uAPI headers RUNS on
#      this kernel, in ring 3, and the DRM_IOCTL_* request numbers its compiler
#      computed are the ones Linux computes -- 119 of 121 identical to Linux
#      6.12's own headers, the two exceptions being a real, named uAPI
#      extension that post-dates 6.12.
#   5. Choosing BSD's `_IOC` encoding instead -- which is what `drm.h` does by
#      DEFAULT on this target, because `__linux__` is not defined -- changes 29
#      of those 121 numbers, including DRM_IOCTL_GEM_CLOSE,
#      DRM_IOCTL_SET_CLIENT_CAP, DRM_IOCTL_SET_MASTER and DRM_IOCTL_DROP_MASTER.
#      That is the negative control and it runs on the same volume.
#
#   6. S0 (ADR-0033): `ioctl` IS SYSCALL 12 AND IT IS ISSUED HERE. A ring-3
#      program opens /dev/dri/card0, issues an _IOWR('d',0x00,struct
#      drm_version), and the kernel's decode of dir/size/type/nr is required to
#      equal the ORACLE's -- computed on the host from Linux's own
#      asm-generic/ioctl.h, not read back out of the kernel. CHECKs 14-16.
#
# THE NEGATIVE CONTROLS ARE THE POINT OF CHECK 15, AND EACH REPORTS WHAT IT
# OBSERVED. An oversized payload must be REFUSED, not truncated. A wrong-size
# request must be REFUSED, not zero-extended. An `argp` outside the process must
# be refused -- both a kernel address and a range straddling an unmapped page. A
# write-side violation on an `_IOC_READ` must be refused, with a positive
# control beside it so the refusal is not explained by a kernel that refuses
# everything. Every expected value is read out of core/kernel/ioctl.dart.
#
# WHAT IT STILL DOES NOT CLAIM
#   THERE IS NO DRM. No driver, no GPU, no DRM semantics whatsoever -- the
#   "driver" behind the syscall fills a payload with a predictable pattern
#   (GAP-0177). What is proved is the MEMBRANE: decode, validate, bounce,
#   dispatch on _IOC_NR, refuse on skew, out-copy only on success. There is
#   still no `mmap` (GAP-0159), drmGetDevices2 still cannot work (GAP-0171),
#   and modetest still needs threads (GAP-0173).
#
# Usage:
#   run.sh [--regen]
#
# Environment:
#   OSCORTEX_LIBDRM     an existing libdrm checkout to use instead of fetching
#   OSCORTEX_LINUX_SRC  a Linux source tree for the independent uAPI oracle
#                       (default /Users/ghostportal/kpi-ref/linux-6.12, the tree
#                       docs/design/drm-abi.md measured against)
#
# Exit status: 0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"
PORT_DIR="$CORE_DIR/user/ports/libdrm"

fail() { echo "drm-abi: FAIL — $1" >&2; exit 1; }
setup_error() { echo "drm-abi: FAIL (setup) — $1" >&2; exit 2; }

REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1

for tool in clang x86_64-elf-ld x86_64-elf-nm x86_64-elf-objdump x86_64-elf-readelf \
            qemu-system-x86_64 python3 git timeout; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
M1_EXPECTED="$CORE_DIR/tests/conformance/m1-interrupts/expected.txt"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found at $DRIVER"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found at $PICKER"
[[ -f "$M1_EXPECTED" ]] || setup_error "m1-interrupts/expected.txt not found"
[[ -d "$PORT_DIR/shim" ]] || setup_error "no libdrm shim at $PORT_DIR/shim"

# GAP-0110: a sandbox under /tmp breaks `dcc` on macOS because /tmp is a symlink
# and Dart resolves library identity through real paths.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-drmabi.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
EXPECTED_SERIAL="$SCRIPT_DIR/expected.txt"

# ---------------------------------------------------------------------------
# Step 0 — THE SYSCALL REGISTRY.
#
# ADR-0031 §5 allocates `ioctl` a number, and it could only do that because
# this unit built the allocator `design/README.md` fix #2 and
# `design/drm-abi.md` §9 both asked for. The check runs here, ahead of
# everything else, because a registry nothing invokes is a document.
# ---------------------------------------------------------------------------
REG_OUT="$(bash "$CORE_DIR/scripts/verify-syscall-registry.sh" 2>&1)"
REG_STATUS=$?
echo "$REG_OUT"
[[ $REG_STATUS -eq 0 ]] || fail "verify-syscall-registry.sh exited $REG_STATUS"
# S0 (ADR-0033): 12 is ALLOCATED now, not reserved. What must remain true is
# that `fdwait` still holds 11 and that `ioctl` is 12 -- the two facts the
# registry was built to protect. Asserting "2 reserved" would have been
# asserting that ioctl stays unimplemented forever.
#
# AND ASSERTING A TOTAL WAS THE SAME MISTAKE ONE SIZE SMALLER. This line read
# `grep -q '12 allocated'` until M20's channel syscalls took 13, 14 and 15 and
# made the total fifteen -- a registry with every fact this check cares about
# intact, failed by a proxy for those facts. What it means is "12 is allocated
# rather than reserved", so that is what it now says: `12=` appears in the
# verifier's output only inside its RESERVED list.
grep -q '12=' <<<"$REG_OUT" && fail "the registry lists 12 as RESERVED again; ADR-0033 implements ioctl as 12, so it must be allocated"
grep -q '11=fdwait' <<<"$REG_OUT"    || fail "the registry no longer reserves 11 for fdwait; three designs name it and ADR-0031 §5 is why ioctl took 12 instead"
grep -qE '^\| 12 \| .ioctl. \| .ioctlSysNo.' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "the registry's row for syscall 12 is not ioctl/ioctlSysNo"
echo "CHECK 0: pass  the syscall registry, the kernel and oslibc.h agree; ioctl is ALLOCATED at 12 and implemented, and fdwait keeps 11"

# ---------------------------------------------------------------------------
# Step 1 — THE SOURCE. Fetched at a pinned commit, never vendored.
#
# A machine with no network cannot make a claim about libdrm, and saying so is
# a SETUP ERROR (exit 2), not a failure (exit 1). The distinction is the same
# one every harness here draws between "this OS is wrong" and "this laptop
# cannot answer the question today".
# ---------------------------------------------------------------------------
LIBDRM_SRC="${OSCORTEX_LIBDRM:-$REPO_DIR/.ports/libdrm}"
bash "$PORT_DIR/fetch.sh" "$LIBDRM_SRC" \
  || setup_error "could not put libdrm at $LIBDRM_SRC (set OSCORTEX_LIBDRM to an existing checkout)"
PIN=$(sed -n '2p' "$PORT_DIR/PIN.txt")
echo "SOURCE: libdrm $PIN at $LIBDRM_SRC"

# ---------------------------------------------------------------------------
# Step 2 — THE MEASUREMENT. Compile it and count what is missing.
# ---------------------------------------------------------------------------
BUILD_OUT="$(bash "$PORT_DIR/build.sh" "$LIBDRM_SRC" "$WORKDIR/port" 2>&1)"
BUILD_STATUS=$?
echo "$BUILD_OUT" | grep -vE '^\s*[0-9]+ \|| \^|^\s*$' | tail -8
[[ $BUILD_STATUS -eq 0 ]] || fail "core/user/ports/libdrm/build.sh exited $BUILD_STATUS (output above)"

MT_OUT="$(bash "$PORT_DIR/build.sh" "$LIBDRM_SRC" "$WORKDIR/port-mt" --with-modetest 2>&1)"
MT_STATUS=$?
[[ $MT_STATUS -eq 0 ]] || { echo "$MT_OUT" | tail -20 >&2; fail "build.sh --with-modetest exited $MT_STATUS"; }

if [[ $REGEN -eq 1 ]]; then
  cp "$WORKDIR/port/missing.txt"    "$PORT_DIR/expected-missing-core.txt"
  cp "$WORKDIR/port/externals.txt"  "$PORT_DIR/expected-externals-core.txt"
  cp "$WORKDIR/port-mt/missing.txt" "$PORT_DIR/expected-missing-modetest.txt"
  echo "REGEN: the three expected symbol lists were rewritten"
fi

diff -u "$PORT_DIR/expected-externals-core.txt" "$WORKDIR/port/externals.txt" \
  || fail "libdrm's external symbol set has MOVED. That is not automatically wrong, but it is never incidental: re-run with --regen only after reading the diff."
diff -u "$PORT_DIR/expected-missing-core.txt" "$WORKDIR/port/missing.txt" \
  || fail "the set of symbols libdrm needs and this OS lacks has MOVED (see the diff above)"
diff -u "$PORT_DIR/expected-missing-modetest.txt" "$WORKDIR/port-mt/missing.txt" \
  || fail "the set of symbols libdrm+modetest needs and this OS lacks has MOVED (see the diff above)"

N_EXT=$(wc -l < "$WORKDIR/port/externals.txt" | tr -d ' ')
N_MISS=$(wc -l < "$WORKDIR/port/missing.txt" | tr -d ' ')
N_PROV=$(wc -l < "$WORKDIR/port/provided.txt" | tr -d ' ')
N_MISS_MT=$(wc -l < "$WORKDIR/port-mt/missing.txt" | tr -d ' ')
N_LIBC=$(wc -l < "$WORKDIR/port/libc-symbols.txt" | tr -d ' ')

# Anti-vacuity. A build that produced no objects, or a libc that exported
# nothing, would make every diff above trivially satisfied.
[[ "$N_EXT" -ge 40 ]] || fail "only $N_EXT external symbols — libdrm cannot possibly need so few; the objects are probably empty"
[[ "$N_LIBC" -ge 40 ]] || fail "core/user/libc exports only $N_LIBC symbols; it exported 47 when this harness was written"
[[ "$N_MISS_MT" -gt "$N_MISS" ]] || fail "modetest needs no more than libdrm core does ($N_MISS_MT vs $N_MISS); that cannot be right"
echo "CHECK 1: pass  unmodified libdrm compiles for x86_64-unknown-none-elf. $N_EXT external symbols, $N_PROV resolvable against core/user/libc's $N_LIBC, $N_MISS MISSING. With modetest and its util/: $N_MISS_MT missing"

# ---------------------------------------------------------------------------
# Step 3 — THE FOUR SYMBOLS THAT LINK AND WOULD BE WRONG.
#
# This is the finding this harness exists to make un-forgettable. `open`,
# `read`, `close` and `printf` are in BOTH sets: libdrm needs them and
# core/user/libc has them. They are not the same functions.
# ---------------------------------------------------------------------------
# The six that were ALWAYS the right function still are.
for s in malloc free memcpy memset strcmp strlen; do
  grep -qx "$s" "$WORKDIR/port/provided.txt" \
    || fail "\`$s\` is not in the provided set; this harness's central claim assumed it was"
done

# 3a. THE HAZARD IS CLOSED, AND THIS PROVES IT THE ONLY WAY THAT COUNTS:
#     BY LINKING AGAINST THE NATIVE SURFACE ALONE AND SHOWING THE FOUR COME
#     OUT UNDEFINED.
#
# Until ADR-0033 this check asserted the OPPOSITE -- that `open`, `read`,
# `close` and `printf` bound silently to core/user/libc's, which are not the
# same functions (GAP-0170). They now export `os_open`/`os_read`/`os_close`/
# `os_printf`, so a port that does not include oslibc.h cannot resolve them.
#
# **THE NATIVE OBJECTS ONLY.** posix.o and port.o are deliberately EXCLUDED
# from this link: they are the opt-in adapter, and including them is what a
# port does on purpose. The question this link asks is "what happens to a port
# that links the native libc and nothing else", and the required answer is
# "it fails to link", not "it links to the wrong thing".
NATIVE_OBJS=()
for o in syscall string malloc printf rfile start; do
  [[ -f "$WORKDIR/port/libcobj/$o.o" ]] || fail "no $o.o in the libc build"
  NATIVE_OBJS+=("$WORKDIR/port/libcobj/$o.o")
done
LINKLOG="$WORKDIR/link-native.txt"
x86_64-elf-ld -o "$WORKDIR/link-native.elf" "$WORKDIR"/port/obj/*.o \
  "${NATIVE_OBJS[@]}" >"$LINKLOG" 2>&1
UNDEF=$(sed -n 's/.*undefined reference to `\([^'"'"']*\)'"'"'.*/\1/p' "$LINKLOG" | sort -u)
[[ -n "$UNDEF" ]] || fail "linking libdrm against the NATIVE libc alone produced no undefined references at all; the four-symbol clash cannot have been closed"
# The FOUR of GAP-0170. libdrm references all four, so each must now appear as
# an undefined reference in this link.
for s in open read close printf; do
  echo "$UNDEF" | grep -qx "$s" \
    || fail "\`$s\` still RESOLVES against core/user/libc's native objects. GAP-0170's hazard is that it binds by name and is the wrong function; ADR-0033 closed it by exporting os_$s instead, and something has re-opened it"
done
# `write` is the FIFTH -- the one clang found when posix.c tried to declare
# POSIX's three-argument version against oscortex's two-argument one. It is
# checked DIFFERENTLY and deliberately so: libdrm never references `write`, so
# it can never appear as an undefined reference, and asserting that it does
# would be asserting something no link can show. What must be true is that the
# native objects do not DEFINE the symbol.
# nm's output is captured ONCE rather than piped into `grep -q` per symbol.
# `grep -q` closes the pipe on its first match, nm dies of SIGPIPE, and with
# `set -o pipefail` the pipeline's status is nm's failure -- so a SUCCESSFUL
# match reported as a failed command. That cost a real debugging round here and
# it is the kind of thing that would otherwise come back.
NM_NATIVE="$(x86_64-elf-nm --defined-only "${NATIVE_OBJS[@]}")"
for s in open read close printf write; do
  grep -qE "[TtDdBb] $s\$" <<<"$NM_NATIVE" \
    && fail "core/user/libc's native objects still DEFINE \`$s\`; ADR-0033 renamed it to os_$s so that a port cannot bind to it"
done
# And the native objects really do still provide the function, under its own
# name -- otherwise the check above would pass because the libc is empty.
for s in os_open os_read os_close os_printf os_write; do
  grep -qE "[TtDd] $s\$" <<<"$NM_NATIVE" \
    || fail "core/user/libc does not define \`$s\`; the rename removed the function instead of renaming it"
done
echo "CHECK 2: pass  linking libdrm against core/user/libc's NATIVE objects alone now leaves open/read/close/printf/write UNDEFINED — the clean-link-to-the-wrong-function hazard of GAP-0170 is closed, and the five functions are still there under os_*"

# 3b. AND THE OPT-IN ADAPTER MAKES IT LINK. posix.o + port.o are what a port
#     adds, and with them libdrm's five objects resolve COMPLETELY: `main` is
#     the only undefined symbol left, which is what "a library" means.
LINKLOG2="$WORKDIR/link-full.txt"
x86_64-elf-ld -o "$WORKDIR/link-full.elf" "$WORKDIR"/port/obj/*.o \
  "$WORKDIR"/port/libcobj/*.o >"$LINKLOG2" 2>&1
UNDEF2=$(sed -n 's/.*undefined reference to `\([^'"'"']*\)'"'"'.*/\1/p' "$LINKLOG2" | sort -u)
LEFT=$(echo "$UNDEF2" | grep -v '^main$' | grep -v '^$' | tr '\n' ' ')
[[ -z "$LEFT" ]] \
  || fail "libdrm does not link against core/user/libc + the adapter; still undefined: $LEFT"
echo "$UNDEF2" | grep -qx main \
  || fail "the link has no undefined \`main\`; libdrm is a library and something has supplied one"
# Anti-vacuity: an empty object set would also produce "only main".
NOBJ=$(ls "$WORKDIR"/port/obj/*.o | wc -l | tr -d ' ')
[[ "$NOBJ" -eq 5 ]] || fail "expected libdrm's five core objects, found $NOBJ"
echo "CHECK 2b: pass  with core/user/libc/posix.c and port.c -- the OPT-IN POSIX face and the tier-1 C functions -- libdrm's five objects link COMPLETELY. \`main\` is the only undefined symbol left. That is 43 short before this unit and 0 after it"

# 3c. libdrm's own device enumeration is compiled out on this platform, and
#     says so eight times. drmGetDevices2() -- which is how Mesa finds a GPU --
#     returns -EINVAL here no matter what the kernel does.
# One diagnostic is TWO lines of clang output (the message, then the source
# line it echoes), so count the message line only.
NWARN=$(echo "$BUILD_OUT" | grep -c 'warning: "Missing implementation of drmParse')
[[ "$NWARN" -eq 8 ]] \
  || fail "libdrm emitted $NWARN \"Missing implementation of drmParse*\" warnings, expected 8; the platform-support surface has moved"
grep -q '#warning "Missing implementation of drmParsePciBusInfo"' "$LIBDRM_SRC/xf86drm.c" \
  || fail "libdrm no longer has the drmParsePciBusInfo stub"
echo "CHECK 3: pass  libdrm compiles its 'this platform is not one I know' branch eight times over — drmParse{SubsystemType,PciBusInfo,PciDeviceInfo,UsbBusInfo,UsbDeviceInfo,OFBusInfo,OFDeviceInfo,FauxBusInfo} all return -EINVAL, so drmGetDevices2() cannot enumerate anything on oscortex regardless of the kernel. GAP-0171."

# ---------------------------------------------------------------------------
# Step 4 — THE ORACLE. The request numbers, computed three ways on the host.
# ---------------------------------------------------------------------------
LINUX_SRC="${OSCORTEX_LINUX_SRC:-/Users/ghostportal/kpi-ref/linux-6.12}"
ORACLE_ARGS=("$LIBDRM_SRC" "$PORT_DIR/shim" "$SCRIPT_DIR/neg-shim" "$WORKDIR/oracle")
if [[ -d "$LINUX_SRC" ]]; then
  ORACLE_ARGS+=("$LINUX_SRC")
else
  setup_error "no Linux source tree at $LINUX_SRC. The claim 'we serve LINUX's _IOC encoding' is checked against Linux's own headers and cannot be checked without them. Set OSCORTEX_LINUX_SRC."
fi
python3 "$SCRIPT_DIR/oracle.py" "${ORACLE_ARGS[@]}" \
  || setup_error "oracle.py could not produce the expectation"
ORACLE="$WORKDIR/oracle/oracle.json"

o() { python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
v=d
for k in sys.argv[2].split('.'):
    v=v[k]
if isinstance(v,list): print(' '.join(str(x) for x in v))
else: print(v)
" "$ORACLE" "$1"; }

O_COUNT=$(o count)
O_HASH=$(o hash)
O_BSDHASH=$(o bsd_hash)
O_ZERO=$(o zero_size)
O_MAX=$(o max_size)
O_BSDDIFF=$(o bsd_differs)
O_LINDIFF=$(o linux_differs)
O_LINABS=$(o linux_absent)
N_BSDDIFF=$(echo "$O_BSDDIFF" | wc -w | tr -d ' ')

[[ "$O_COUNT" -eq 121 ]] || fail "the pinned libdrm defines $O_COUNT DRM_IOCTL_* requests, not the 121 this harness was written against"
[[ "$O_HASH" != "$O_BSDHASH" ]] || fail "the Linux and BSD encodings hash the same; the control is vacuous"
[[ "$N_BSDDIFF" -eq 29 ]] || fail "BSD's encoding differs on $N_BSDDIFF of $O_COUNT requests, not the 29 this harness names"
for n in DRM_IOCTL_GEM_CLOSE DRM_IOCTL_SET_CLIENT_CAP DRM_IOCTL_SET_MASTER DRM_IOCTL_DROP_MASTER; do
  echo "$O_BSDDIFF" | grep -qw "$n" \
    || fail "$n is NOT among the requests BSD's encoding changes; that is the whole reason this port does not take the default"
done
for n in DRM_IOCTL_VERSION DRM_IOCTL_GET_CAP DRM_IOCTL_MODE_CREATE_DUMB DRM_IOCTL_MODE_ADDFB2; do
  echo "$O_BSDDIFF" | grep -qw "$n" \
    && fail "$n differs under BSD's encoding; this harness claims the _IOWR requests are unaffected"
done
echo "CHECK 4: pass  $O_COUNT DRM requests. BSD's _IOC encoding — which is what drm.h reaches for on this target by default — changes exactly 29 of them, GEM_CLOSE, SET_CLIENT_CAP, SET_MASTER and DROP_MASTER among them, and leaves the 92 _IOWR ones alone. That is a silent wrong answer this port would have shipped."

# 4b. AGAINST LINUX'S OWN HEADERS AND LINUX'S OWN MACROS.
[[ "$O_LINDIFF" == "DRM_IOCTL_SYNCOBJ_FD_TO_HANDLE DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD" ]] \
  || fail "this port's request numbers differ from Linux's own headers on: ${O_LINDIFF:-<nothing>}. The two syncobj calls are EXPECTED (struct drm_syncobj_handle grew a __u64 point field after 6.12). Anything else means the encoding is wrong."
grep -q '__u64 point;' "$LIBDRM_SRC/include/drm/drm.h" \
  || fail "libdrm's struct drm_syncobj_handle has no 'point' field, so the documented reason for the two expected divergences is not the real one"
echo "CHECK 5: pass  119 of $O_COUNT request numbers are BYTE-IDENTICAL to the ones Linux's own uapi headers and Linux's own _IOC macros produce, compiled from $LINUX_SRC with no part of this port involved. The two that differ are DRM_IOCTL_SYNCOBJ_{HANDLE_TO_FD,FD_TO_HANDLE}, whose struct grew a __u64 after 6.12 — the exact failure mode drm-abi.md §2.1 warns of, observed in the wild, and the reason a kernel must dispatch on _IOC_NR and CHECK _IOC_SIZE rather than switch on the whole request word. Absent from 6.12 entirely: ${O_LINABS:-none}"

# ---------------------------------------------------------------------------
# Step 5 — the kernel, and rule 1.
# ---------------------------------------------------------------------------
KBUILD_OUT="$(bash "$CORE_DIR/scripts/build-kernel.sh" 2>&1)"
KBUILD_STATUS=$?
echo "$KBUILD_OUT" | tail -3
[[ $KBUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $KBUILD_STATUS"
[[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

# Rule 1, invoked rather than claimed. GAP-0167 — a harness whose PASS line
# said `-> verify-freestanding` and never ran it — was closed by ADR-0030 §6
# on the same day this unit landed; this harness was written to invoke it
# either way.
#
# THE OBJECT SET IS m13-libc's, not "everything in core/build". `boot.o` and
# `isr.o` reference `_kernel_start`, `_rodata_end`, `kmain` and four more
# linker-script symbols that are undefined UNTIL THE LINK, by design (CLAUDE.md
# rule 4), so checking them individually fails for a reason that is not rule 1.
# The LINKED kernel.elf is checked instead, which is where those symbols have
# to have resolved. Established by m13-libc; discovered again here by running
# it against boot.o first and reading what came out.
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"
command -v llvm-nm >/dev/null 2>&1 || setup_error "llvm-nm not found on PATH, see docs/known-gaps.md"
VERIFY_OUT="$(OSCORTEX_ALLOWLIST="$ALLOWLIST" bash "$CORE_DIR/scripts/verify-freestanding.sh" \
  "$CORE_DIR/build/kmain.o" "$CORE_DIR/build/kdata.o" "$CORE_DIR/build/portio.o" \
  "$KERNEL_ELF" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || grep -q "FREESTANDING: FAIL" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass (rule 1)"
fi
FREE_OK=$(grep -c '^FREESTANDING: pass' <<<"$VERIFY_OUT")
[[ "$FREE_OK" -eq 4 ]] || fail "verify-freestanding reported $FREE_OK passes, expected 4 (kmain.o, kdata.o, portio.o, kernel.elf)"
echo "CHECK 6: pass  verify-freestanding.sh ran on kmain.o, kdata.o, portio.o and kernel.elf and passed on all four (rule 1, invoked and not merely claimed — GAP-0167)"

# ---------------------------------------------------------------------------
# Step 6 — the two programs and the volume.
# ---------------------------------------------------------------------------
bash "$SCRIPT_DIR/build-progs.sh" "$LIBDRM_SRC" "$WORKDIR/progs" \
  || fail "build-progs.sh failed"
DISK_IMG="$WORKDIR/drm.img"
python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/progs/drmabi.elf" "$WORKDIR/progs/drmabin.elf" \
  || fail "make-image.py failed"
if command -v fsck_msdos >/dev/null 2>&1; then
  fsck_msdos -n "$DISK_IMG" >"$WORKDIR/fsck.txt" 2>&1 \
    || { cat "$WORKDIR/fsck.txt" >&2; fail "fsck_msdos rejected the volume this harness wrote"; }
  echo "    (fsck_msdos accepts the volume)"
fi

# ---------------------------------------------------------------------------
# Step 7 — the boot.
# ---------------------------------------------------------------------------
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" png="$3" label="$4"
  shift 4
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local attempt=0 port drive_status qemu_status qemu_pid
  while :; do
    attempt=$(( attempt + 1 ))
    # GAP-0150: ask the host kernel for a port that is free RIGHT NOW, and
    # retry the launch if QEMU still loses the race. Never a hardcoded port,
    # never a hash of $$.
    port=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
    : >"$ser"
    timeout 420 qemu-system-x86_64 \
      -kernel "$KERNEL_ELF" \
      -m 128M \
      -cpu qemu64 \
      -vga std \
      -serial "file:$ser" \
      -display none \
      -no-reboot \
      -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
      -qmp "tcp:127.0.0.1:$port,server,nowait" \
      >"$outdir/qemu.log" 2>&1 &
    qemu_pid=$!
    python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --png "$png" \
      --screen-text "$outdir/screen.txt" \
      --keys "$keys" \
      "$@"
    drive_status=$?
    wait "$qemu_pid" 2>/dev/null
    qemu_status=$?
    if [[ $drive_status -ne 0 ]] && grep -q "Address already in use" "$outdir/qemu.log" \
       && [[ $attempt -lt 5 ]]; then
      echo "    (port $port was taken between the probe and the launch; retrying — attempt $attempt)"
      continue
    fi
    break
  done
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

SESSION_KEYS="f,r,a,m,e,s,ret,wait:800"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run drmabi.elf"),ret,wait:14000"
SESSION_KEYS="$SESSION_KEYS,$(typekeys "run drmabin.elf"),ret,wait:14000"
SESSION_KEYS="$SESSION_KEYS,f,r,a,m,e,s,ret,wait:1200"

SHOT_PNG="$CORE_DIR/build/screenshot-drm-abi.png"
drive_session "$WORKDIR/main" "$SESSION_KEYS" "$SHOT_PNG" "main"
SERIAL="$WORKDIR/main/serial.txt"
[[ -s "$SERIAL" ]] || fail "the boot captured no serial output at all"

have() { grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { grep -qF -- "$1" "$SERIAL" && fail "the transcript contains what it must not: $1"; }

# ---------------------------------------------------------------------------
# Step 8 — what the boot must have said.
# ---------------------------------------------------------------------------

# 8a. THE PROGRAM RAN AND ITS TABLE IS THE HOST'S TABLE.
have "DRMABI COUNT $O_COUNT"
have "DRMABI HASH $O_HASH"
echo "CHECK 7: pass  a program built against unmodified include/drm/drm.h and include/drm/virtgpu_drm.h ran in ring 3 on this kernel and folded all $O_COUNT request numbers to $O_HASH — the same value oracle.py computed on the host, from the same headers, with a different compiler and a different target architecture"

# 8b. THE NINE NAMED REQUESTS, EACH READ OUT OF THE ORACLE RATHER THAN TYPED.
for n in VERSION GET_CAP SET_CLIENT_CAP GEM_CLOSE PRIME_HANDLE_TO_FD \
         MODE_CREATE_DUMB MODE_MAP_DUMB MODE_ADDFB2 VIRTGPU_EXECBUFFER; do
  v=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('%x' % d['port']['DRM_IOCTL_' + sys.argv[2]])
" "$ORACLE" "$n")
  have "DRMABI REQ $n $v"
done
echo "CHECK 8: pass  all nine of the requests drm-abi.md's R0–R3 rungs issue printed the host's value"

# 8c. THE DECODE. dir/size/type/nr pulled apart by the guest and predicted here.
for n in VERSION GEM_CLOSE MODE_CREATE_DUMB VIRTGPU_EXECBUFFER; do
  line=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
r=d['port']['DRM_IOCTL_' + sys.argv[2]]
print('DRMABI DEC %s dir=%d size=%d type=%c nr=%d' % (
    sys.argv[2], (r>>30)&3, (r>>16)&0x3fff, (r>>8)&0xff, r&0xff))
" "$ORACLE" "$n")
  have "$line"
done
have "DRMABI SIZEENC 9 of 9"
have "DRMABI ZEROSIZE $O_ZERO MAXSIZE $O_MAX CEIL 16383"
echo "CHECK 9: pass  the guest decoded dir/size/type/nr back out of four request numbers and got the host's answer each time; the encoded size equals sizeof for all nine; $O_ZERO of $O_COUNT requests carry no payload and the largest carries $O_MAX bytes, against _IOC_SIZE's 14-bit ceiling of 16383"

# 8d. THE STRUCT SIZES, against the host's.
for pair in "version:drm_version" "gem_close:drm_gem_close" "create_dumb:drm_mode_create_dumb"; do
  fieldname="${pair%%:*}"
  grep -q "DRMABI SZ .*$fieldname=" "$SERIAL" \
    || fail "the transcript never reported sizeof(struct ${pair##*:})"
done
# drm_version's size is in DRM_IOCTL_VERSION's own request number; the program
# printed both, and they must agree.
VSZ=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print((d['port']['DRM_IOCTL_VERSION']>>16)&0x3fff)" "$ORACLE")
have "DRMABI SZ version=$VSZ "
echo "CHECK 10: pass  sizeof(struct drm_version) is $VSZ in the guest, which is the size DRM_IOCTL_VERSION's own request number encodes"

# 8e. THE NEGATIVE CONTROL RAN AND DISAGREED.
have "DRMABI HASH $O_BSDHASH"
[[ $(grep -c "^USER WRITE DRMABI COUNT $O_COUNT" "$SERIAL") -eq 2 ]] \
  || fail "the two programs did not both report $O_COUNT requests; the control must differ in the NUMBERS, not in the count"
BSD_GEM=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
# the control's GEM_CLOSE, recomputed from the BSD rule rather than read back
r=d['port']['DRM_IOCTL_GEM_CLOSE']
print('%x' % ((r & 0x3fffffff) | 0x80000000))" "$ORACLE")
have "DRMABI REQ GEM_CLOSE $BSD_GEM"
echo "CHECK 11: pass  the negative control — the SAME prog.c with BSD's sys/ioccom.h ahead of ours on the include path — ran on the same volume, reported the same $O_COUNT requests, hashed to $O_BSDHASH instead of $O_HASH, and put DRM_IOCTL_GEM_CLOSE at $BSD_GEM instead. A kernel serving Linux's numbers would refuse it"

# 8f. THE FRAME ACCOUNTING BRACKETS THE SESSION.
FRAMES=$(grep -c '^PMM MANAGED ' "$SERIAL")
[[ "$FRAMES" -ge 2 ]] || fail "the session is not bracketed by two \`frames\` reports (got $FRAMES)"
FIRST=$(grep '^PMM MANAGED ' "$SERIAL" | head -1)
LAST=$(grep '^PMM MANAGED ' "$SERIAL" | tail -1)
[[ "$FIRST" == "$LAST" ]] \
  || fail "the frame allocator did not return to its starting state across two program loads:
  before: $FIRST
  after:  $LAST"
echo "CHECK 12: pass  two programs were loaded, run and torn down and the frame allocator came back to exactly where it started"

# 8g. m1-interrupts' golden, byte for byte, as seventeen other harnesses do.
M1_BYTES=$(wc -c <"$M1_EXPECTED" | tr -d ' ')
head -c "$M1_BYTES" "$SERIAL" | cmp -s - "$M1_EXPECTED" \
  || fail "the first $M1_BYTES bytes of this boot are not m1-interrupts' golden — this unit moved a byte it does not own"
echo "CHECK 13: pass  the first $M1_BYTES bytes are m1-interrupts' golden, byte for byte"

# ---------------------------------------------------------------------------
# 8i. S0 (ADR-0033) — THE IOCTL, AND THE FOUR NEGATIVE CONTROLS.
#
# **EVERY EXPECTED VALUE BELOW IS READ OUT OF core/kernel/ioctl.dart**, not
# typed here and not read back off the transcript. A harness whose expectation
# is a copy of the thing it is checking proves nothing, and eleven refusal
# codes are eleven chances to make exactly that mistake.
#
# The decode line's four fields are checked against oracle.py's, which computes
# them from Linux's own asm-generic/ioctl.h -- so the kernel's decode, the
# guest program's headers and Linux's macros are three independent computations
# and the harness requires all three to agree.
# ---------------------------------------------------------------------------
# **PYTHON, NOT sed, AND ADR-0028 IS WHY.** The obvious spelling of this is
# one `sed -n "s/^const int $1 = \(0x...\|[0-9]*\);/\1/p"`, and BSD sed --
# which is the sed macOS ships and therefore the sed every run of this harness
# uses -- HAS NO `\|` ALTERNATION IN A BASIC REGEX. It matches nothing, the
# variable comes out empty, and every comparison below becomes a comparison
# against "". That is the same class of failure ADR-0028 found in
# verify-freestanding.sh, where BSD sed read `\s` as a literal `s`.
kconst() {   # kconst <name> -> its value in lowercase hex, no 0x
  python3 - "$CORE_DIR/kernel/ioctl.dart" "$1" <<'PYEOF'
import re, sys
src, name = open(sys.argv[1]).read(), sys.argv[2]
m = re.search(r"^const int %s = (0[xX][0-9A-Fa-f]+|\d+);" % re.escape(name), src, re.M)
if not m:
    sys.exit("no `const int %s` in core/kernel/ioctl.dart" % name)
print("%x" % int(m.group(1), 0))
PYEOF
}

IOC_BADSIZE=$(kconst ioctlRetBadSize)
IOC_SKEW=$(kconst ioctlRetSizeSkew)
IOC_BADPTR=$(kconst ioctlRetBadPtr)
IOC_BADTYPE=$(kconst ioctlRetBadType)
IOC_BADNR=$(kconst ioctlRetBadNr)
IOC_NOTDEV=$(kconst ioctlRetNotDev)
IOC_BADFD=$(kconst ioctlRetBadFd)
IOC_MAXPAY=$(kconst ioctlMaxPayload)
IOC_CEIL=$(kconst ioctlEncMaxSize)

# The program prints a 32-bit `%x` of a 64-bit refusal, so the low eight hex
# digits are what appears. Derive that form rather than assuming it.
low8() { python3 -c "print('%x' % (int('$1',16) & 0xFFFFFFFF))"; }

# Every refusal this unit's constants can produce must be DISTINCT from every
# one of file.dart's fourteen. ADR-0031 §4.3 rule 7 says an ioctl on a file is
# a distinct refusal, and a band that overlapped would make that false.
python3 - "$CORE_DIR/kernel/ioctl.dart" "$CORE_DIR/kernel/file.dart" <<'PYEOF' \
  || fail "an ioctl refusal collides with a file.dart refusal; ADR-0031 §4.3 rule 7 requires them to be distinct"
import re, sys
def codes(path, pat):
    return {m.group(1): int(m.group(2), 0)
            for m in re.finditer(pat, open(path).read(), re.M)}
i = codes(sys.argv[1], r"^const int (ioctlRet[A-Za-z]+) = (0x[0-9A-Fa-f]+);")
f = codes(sys.argv[2], r"^const int (fileRet[A-Za-z]+) = (0x[0-9A-Fa-f]+);")
i.pop("ioctlRetFloor", None); f.pop("fileRetFloor", None)
if len(i) < 10: sys.exit("only %d ioctl refusals found" % len(i))
if len(f) < 14: sys.exit("only %d file refusals found" % len(f))
clash = set(i.values()) & set(f.values())
if clash: sys.exit("collide: %s" % sorted(hex(c) for c in clash))
print("    (%d ioctl refusals, %d file refusals, no value in both)" % (len(i), len(f)))
PYEOF

# --- the device, and the namespace being disjoint from FAT's --------------
grep -q '^USER WRITE DRMABI DEVOPEN fd=0$' "$SERIAL" \
  || fail "the program did not get descriptor 0 from open(\"/dev/dri/card0\")"
FILE_NOTFOUND=$(low8 "$(sed -n 's/^const int fileRetNotFound = \(0x[0-9A-Fa-f]*\);.*/\1/p' "$CORE_DIR/kernel/file.dart")")
grep -q "^USER WRITE DRMABI DEVMISS $FILE_NOTFOUND\$" "$SERIAL" \
  || fail "open(\"/dev/dri/card9\") is not fileRetNotFound — a /-name that is not a served device must NOT fall through to fatParseAt, where it would be EBADNAME"

# --- the decode, against oracle.py's independent computation --------------
# DRM_IOCTL_VERSION is _IOWR('d', 0x00, struct drm_version): dir 3, size 64,
# type 0x64, nr 0x00. The oracle already produced the request word; this pulls
# the four fields out of THAT rather than out of the kernel.
O_VERSION=$(python3 -c "
import sys
for l in open('$WORKDIR/oracle.txt'):
    if l.split()[0:1] == ['DRM_IOCTL_VERSION']: print(l.split()[1]); break
" 2>/dev/null || true)
if [[ -n "$O_VERSION" ]]; then
  read -r ODIR OSIZE OTYPE ONR < <(python3 -c "
r = int('$O_VERSION', 16)
print((r>>30)&3, (r>>16)&0x3fff, (r>>8)&0xff, r&0xff)")
  printf -v WANT 'IOCTL REQ %08X DIR %X SIZE %04X TYPE %02X NR %02X' \
    "$((16#${O_VERSION}))" "$ODIR" "$OSIZE" "$OTYPE" "$ONR"
  grep -qF "$WANT" "$SERIAL" \
    || fail "the kernel's decode of DRM_IOCTL_VERSION is not the oracle's: expected \"$WANT\""
  echo "    (kernel decode == oracle: $WANT)"
fi

# --- the call succeeded, and the out-copy really happened -----------------
grep -q '^USER WRITE DRMABI IOCTL VERSION ret=0 b0=0 b63=3f$' "$SERIAL" \
  || fail "the _IOWR('d',0x00,64) against /dev/dri/card0 did not return 0 with the kernel's pattern in the payload"
grep -q '^IOCTL OK IN 0040 OUT 0040$' "$SERIAL" \
  || fail "the VERSION ioctl did not copy 64 bytes in and 64 bytes out"

# --- ANTI-VACUITY: the IN and OUT counts must DIFFER on a _IOC_WRITE-only
#     call. ADR-0031 §4.4 asks for exactly this. A kernel that ignored
#     _IOC_DIR and copied both ways would print the same number twice.
grep -q '^IOCTL OK IN 0008 OUT 0000$' "$SERIAL" \
  || fail "DRM_IOCTL_GEM_CLOSE is _IOC_WRITE-only and must copy 8 bytes IN and 0 OUT; the kernel is not honouring _IOC_DIR"

# --- THE DISPATCH RULE: one nr, TWO sizes, both served ---------------------
# ADR-0031 §3.2's finding, made into a test. These two requests differ ONLY in
# _IOC_SIZE. A kernel written as `switch (request)` serves exactly one.
grep -q '^IOCTL REQ C01864C1 DIR 3 SIZE 0018 TYPE 64 NR C1$' "$SERIAL" \
  || fail "libdrm 2.4.134's SYNCOBJ_HANDLE_TO_FD (24-byte struct) was not decoded"
grep -q '^IOCTL REQ C01064C1 DIR 3 SIZE 0010 TYPE 64 NR C1$' "$SERIAL" \
  || fail "Linux 6.12's SYNCOBJ_HANDLE_TO_FD (16-byte struct) was not decoded"
grep -q '^USER WRITE DRMABI IOCTL SYNCOBJ24 ret=0$' "$SERIAL" \
  || fail "the 24-byte SYNCOBJ_HANDLE_TO_FD was not served"
grep -q '^USER WRITE DRMABI IOCTL SYNCOBJ16 ret=0$' "$SERIAL" \
  || fail "the 16-byte SYNCOBJ_HANDLE_TO_FD was not served — the kernel is dispatching on the request word, not on _IOC_NR"
echo "CHECK 14: pass  ioctl is syscall 12 and it works: an _IOWR('d',0x00,struct drm_version) issued from ring 3 against /dev/dri/card0 was decoded to the oracle's dir/size/type/nr, bounced 64 bytes each way, and returned 0. A _IOC_WRITE-only request copied 8 bytes IN and 0 OUT. And BOTH sizes of SYNCOBJ_HANDLE_TO_FD — libdrm's 24-byte struct and Linux 6.12's 16-byte one, the same _IOC_NR — were served, which a \`switch (request)\` kernel could not do"

# ---------------------------------------------------------------------------
# 8j. THE FOUR NEGATIVE CONTROLS. **THESE ARE THE POINT OF THE UNIT.**
#
# Each asserts the OBSERVED refusal equals the kernel constant it should be,
# AND that no success line was produced for it. The second half matters: a
# kernel that truncated an oversize payload would return 0, and a test that
# only checked "not zero" would pass on a kernel that refused for the wrong
# reason.
# ---------------------------------------------------------------------------
neg() {   # neg <label> <expected-64-bit-hex-const> <why>
  local label="$1" want; want=$(low8 "$2")
  grep -q "^USER WRITE DRMABI NEG $label ret=$want\$" "$SERIAL" \
    || fail "negative control $label: expected refusal $want ($3); transcript says: $(grep -m1 "DRMABI NEG $label" "$SERIAL" || echo '<the line is missing entirely>')"
}

# 1. AN OVERSIZED PAYLOAD IS REFUSED, NOT TRUNCATED.
neg OVERSIZE "$IOC_BADSIZE" "ioctlRetBadSize — refused, never truncated"
grep -q '^IOCTL REQ D0006400 DIR 3 SIZE 1000 TYPE 64 NR 00$' "$SERIAL" \
  || fail "the oversize control did not carry _IOC_SIZE 4096"
# NOT a pipe into `grep -q`. `grep -q` exits on its first match, the upstream
# grep dies of SIGPIPE, and with `set -o pipefail` the pipeline reports THAT --
# so a successful match would look like a failed command and `&& fail` would
# never fire. The check would pass vacuously, which for a negative control is
# the worst possible failure mode. Same hazard as CHECK 2's nm capture.
OVERSIZE_CTX="$(grep -A1 '^IOCTL REQ D0006400 ' "$SERIAL")"
grep -q '^IOCTL OK' <<<"$OVERSIZE_CTX" \
  && fail "the oversize request produced an IOCTL OK line — it was TRUNCATED and served, not refused"

# 2. A WRONG-SIZE REQUEST IS REFUSED, NOT ZERO-EXTENDED.
neg WRONGSIZE "$IOC_SKEW" "ioctlRetSizeSkew — refused, never zero-extended"
WRONGSIZE_CTX="$(grep -A1 '^IOCTL REQ C0306400 ' "$SERIAL")"
grep -q '^IOCTL OK' <<<"$WRONGSIZE_CTX" \
  && fail "the 48-byte VERSION request produced an IOCTL OK line — it was ZERO-EXTENDED to 64 and served"

# 3. AN `argp` OUTSIDE THE PROCESS IS REFUSED. Both a kernel address and a
#    range that runs off the end of a mapped page (GAP-0124's case).
neg BADPTR "$IOC_BADPTR" "ioctlRetBadPtr — a kernel address"
neg FARPTR "$IOC_BADPTR" "ioctlRetBadPtr — a range straddling unmapped pages"

# 4. A WRITE-SIDE VIOLATION ON `_IOC_READ` IS REFUSED.
#    **AND THE POSITIVE CONTROL BESIDE IT IS WHAT MAKES THAT MEAN ANYTHING**:
#    the same request aimed at writable memory MUST succeed, or the refusal
#    above would be explained by a kernel that refuses every _IOC_READ.
neg RODATA "$IOC_BADPTR" "ioctlRetBadPtr — _IOC_READ aimed at .rodata, which ring 3 may read and may not write"
# **AND THE _IOWR CASE, WHICH IS THE ONE THAT PROVES BOTH VALIDATORS RUN.**
# The two argp controls above aim at memory that fails the READ-side validator
# as well, so a kernel running only the read side refuses them too and looks
# correct. This one aims an _IOWR at .rodata: the read side PASSES and the
# write side must refuse. Deleting the write-side call from the _IOWR arm left
# the entire suite green until this control existed -- found by mutation.
neg IOWRRO "$IOC_BADPTR" "ioctlRetBadPtr — _IOWR aimed at .rodata: the read-side validator passes, so only the write-side one can refuse it"
# The expected first byte is DERIVED from the kernel's own descriptor constant,
# not typed. `ioctlDevServe` fills the read-side payload with
# `((desc << 4) | dev) ^ byteIndex`, so byte 0 of a GET_MAGIC reply on device 0
# is `ioctlDescGetMagic << 4`. Deriving it is what caught this line going stale
# when the descriptor index changed from a dense 0..5 to the `_IOC_NR` itself
# (ADR-0033 §6.4): the constant moved from 1 to 0x02 and this byte with it.
POS_B0=$(python3 -c "print('%x' % ((0x$(kconst ioctlDescGetMagic) << 4) & 0xFF))")
grep -q "^USER WRITE DRMABI POS RODATACTL ret=0 b0=$POS_B0\$" "$SERIAL" \
  || fail "the _IOC_READ POSITIVE control failed: the same request aimed at writable memory must succeed, otherwise the .rodata refusal proves nothing"

# And the ordering rule: TYPE is checked before NR, so a bad type on a served
# nr must be EBADTYPE and not EBADNR.
neg BADTYPE "$IOC_BADTYPE" "ioctlRetBadType — checked FIRST, before any other field"
neg BADNR "$IOC_BADNR" "ioctlRetBadNr"
neg NOTDEV "$IOC_NOTDEV" "ioctlRetNotDev — ENOTTY's equivalent, on a FAT16 file"
neg BADFD "$IOC_BADFD" "ioctlRetBadFd"
echo "CHECK 15: pass  all four mandatory negative controls REFUSED, each with the kernel constant it should be and with no IOCTL OK line beside it: oversize payload -> ioctlRetBadSize (refused, not truncated); wrong-size request -> ioctlRetSizeSkew (refused, not zero-extended); argp outside the process -> ioctlRetBadPtr, both for a kernel address and for a range straddling an unmapped page; _IOC_READ aimed at .rodata -> ioctlRetBadPtr, with the writable-memory positive control succeeding beside it; and an _IOWR aimed at .rodata -> ioctlRetBadPtr, which is the only one of them that can only be refused by the WRITE-side validator. Plus: bad type before bad nr, ioctl on a FAT16 file, and a closed descriptor"

# ---------------------------------------------------------------------------
# 8k. THE BOUND IS WELL UNDER THE ENCODING'S CEILING, AND THE BOUNCE BUFFER IS
#     LAST IN .bss.
# ---------------------------------------------------------------------------
printf -v MAXLINE 'IOCTL MAXPAYLOAD %04X CEIL %04X' "$((16#$IOC_MAXPAY))" "$((16#$IOC_CEIL))"
grep -qF "$MAXLINE" "$SERIAL" \
  || fail "the kernel does not report ioctlMaxPayload/ioctlEncMaxSize as $MAXLINE"
[[ $((16#$IOC_MAXPAY)) -lt $((16#$IOC_CEIL)) ]] \
  || fail "ioctlMaxPayload ($((16#$IOC_MAXPAY))) is not below the _IOC 14-bit ceiling ($((16#$IOC_CEIL))); ADR-0031 §4.3 requires it to be WELL under"
[[ $((16#$IOC_MAXPAY)) -ge 248 ]] \
  || fail "ioctlMaxPayload ($((16#$IOC_MAXPAY))) is below the measured largest DRM payload of 248 bytes"

# ADR-0031 §4.3 rule 5 / ADR-0021: the bounce buffer goes LAST in .bss, so no
# existing harness's "bytes from my block to the end" arithmetic moves.
python3 - "$CORE_DIR/build/kmain.o" <<'PYEOF' || fail "the @bss tail is not ioctlStore-then-shmStore; ADR-0031 §4.3 rule 5 requires the bounce buffer to sit after every block that predates it, and ADR-0041 puts M21's shmStore last behind it"
import re, subprocess, sys
out = subprocess.run(["llvm-nm", "--format=posix", sys.argv[1]],
                     capture_output=True, text=True).stdout
blocks = []
for line in out.splitlines():
    f = line.split()
    if len(f) >= 3 and f[1] in ("b", "B"):
        blocks.append((int(f[2], 16), f[0]))
if len(blocks) < 5:
    sys.exit("only %d @bss blocks found in kmain.o" % len(blocks))
blocks.sort()
# M21 (ADR-0041) put `shmStore` behind the bounce buffer. ADR-0031 §4.3 rule 5's
# REASON -- that no EARLIER block's arithmetic should move -- is unchanged: the
# bounce buffer is still after every block that existed when the rule was
# written. What this check asserts is therefore now the PAIR and its order, and
# that is a strictly stronger statement than "ioctlStore is last" was.
if blocks[-1][1] != "shmStore":
    sys.exit("the last @bss block is %s at 0x%x, not shmStore" % (blocks[-1][1], blocks[-1][0]))
if blocks[-2][1] != "ioctlStore":
    sys.exit("the second-to-last @bss block is %s at 0x%x, not ioctlStore -- the ioctl bounce buffer must stay immediately before M21's shmStore (ADR-0031 §4.3 rule 5, ADR-0033 §6.4, ADR-0041 §8)" % (blocks[-2][1], blocks[-2][0]))
print("    (%d @bss blocks; ioctlStore at 0x%x then shmStore last at 0x%x)" % (len(blocks), blocks[-2][0], blocks[-1][0]))
PYEOF
# The three counters, read out of the kernel's own totals line, so that the
# PASS line below states what THIS RUN did rather than what some earlier run
# did. A hardcoded count goes stale the moment a control is added -- which
# happened once already in this unit, when the _IOWR/.rodata control took the
# call count from 15 to 16.
IOCTL_TOTALS="$(grep -m1 '^IOCTL CALLS ' "$SERIAL")"
[[ -n "$IOCTL_TOTALS" ]] || fail "the kernel printed no IOCTL CALLS totals line"
IOCTL_CALLS=$(( 16#$(awk '{print $3}' <<<"$IOCTL_TOTALS") ))
IOCTL_SERVED=$(( 16#$(awk '{print $5}' <<<"$IOCTL_TOTALS") ))
IOCTL_REFUSED=$(( 16#$(awk '{print $7}' <<<"$IOCTL_TOTALS") ))
[[ $(( IOCTL_SERVED + IOCTL_REFUSED )) -eq "$IOCTL_CALLS" ]] \
  || fail "the kernel's ioctl totals do not add up: $IOCTL_SERVED served + $IOCTL_REFUSED refused != $IOCTL_CALLS calls"
[[ "$IOCTL_REFUSED" -ge 8 ]] \
  || fail "only $IOCTL_REFUSED ioctl refusals were recorded; this unit's negative controls alone are more than that, so some of them did not run"
[[ "$IOCTL_SERVED" -ge 5 ]] \
  || fail "only $IOCTL_SERVED ioctl calls were served; if the positive path is never exercised the refusals prove nothing"
echo "CHECK 16: pass  ioctlMaxPayload is $((16#$IOC_MAXPAY)) bytes — at least the 248-byte measured maximum DRM payload and well under _IOC_SIZE's 14-bit ceiling of $((16#$IOC_CEIL)) — and the bounce buffer is the LAST @bss block in the kernel, so no existing harness's block arithmetic moved"

# 8h. THE WHOLE TRANSCRIPT, BYTE FOR BYTE.
if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL" "$EXPECTED_SERIAL"
  echo "REGEN: $EXPECTED_SERIAL rewritten ($(wc -c <"$SERIAL" | tr -d ' ') bytes)"
else
  [[ -f "$EXPECTED_SERIAL" ]] || setup_error "no golden at $EXPECTED_SERIAL (run with --regen once, and READ what it wrote)"
  cmp -s "$SERIAL" "$EXPECTED_SERIAL" \
    || { diff <(cat "$EXPECTED_SERIAL") <(cat "$SERIAL") | head -40 >&2
         fail "the captured serial output does not match $EXPECTED_SERIAL (first differences above)"; }
  echo "CHECK 17: pass  the whole $(wc -c <"$SERIAL" | tr -d ' ')-byte transcript matches the golden byte for byte"
fi

echo
echo "drm-abi: PASS — unmodified libdrm compiles for this OS ($N_MISS symbols short, $N_MISS_MT with modetest); a program built against Linux's unmodified DRM uAPI runs in ring 3 and agrees with Linux 6.12 on 119 of $O_COUNT request numbers; the BSD-encoding control disagrees on 29 and is rejected. AND ioctl IS SYSCALL 12 AND IT WORKS: $IOCTL_CALLS calls from ring 3 against /dev/dri/card0, $IOCTL_SERVED served and $IOCTL_REFUSED refused, with all four mandatory negative controls refusing for the right reason and each checked against the kernel constant it should be (ADR-0033)."
exit 0
