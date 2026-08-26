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
#      the 43 in core/user/ports/libdrm/expected-missing-core.txt (76 with
#      modetest). That list is the deliverable. It is checked, not estimated.
#   3. TEN symbols resolve against core/user/libc BY NAME, and FOUR of those
#      have incompatible signatures or return conventions. THE LINK IS CLEAN
#      AND THE PROGRAM WOULD BE WRONG. This harness asserts that hazard exists
#      rather than leaving it to be found at run time.
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
# WHAT IT DOES NOT CLAIM, AND WILL NOT UNTIL `ioctl` EXISTS
#   Nothing here calls an ioctl. There is no `ioctl` syscall (GAP-0158) and no
#   device node (GAP-0158) and no `mmap` (GAP-0159). libdrm cannot be LINKED
#   into a program, only compiled: 43 symbols short. ADR-0031 §4 designs the
#   syscall; this harness is what will still be true after it is built.
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
grep -q '2 reserved' <<<"$REG_OUT"   || fail "the registry no longer reserves two numbers; ADR-0031 reserves 12 for ioctl and confirms 11 for fdwait"
grep -q '12=ioctl' <<<"$REG_OUT"   || fail "the registry does not reserve 12 for ioctl"
echo "CHECK 0: pass  the syscall registry, the kernel and oslibc.h agree; ioctl is reserved at 12 and fdwait keeps 11"

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
for s in open read close printf malloc free memcpy memset strcmp strlen; do
  grep -qx "$s" "$WORKDIR/port/provided.txt" \
    || fail "\`$s\` is not in the provided set; this harness's central claim assumed it was"
done

# 3a. The link really does bind them, silently. Linking libdrm's objects
#     against core/user/libc's leaves the 43 undefined and `main` -- and NOT
#     `open`, `read`, `close` or `printf`.
LINKLOG="$WORKDIR/link.txt"
x86_64-elf-ld -o "$WORKDIR/link.elf" "$WORKDIR"/port/obj/*.o "$WORKDIR"/port/libcobj/*.o \
  >"$LINKLOG" 2>&1
UNDEF=$(sed -n 's/.*undefined reference to `\([^'"'"']*\)'"'"'.*/\1/p' "$LINKLOG" | sort -u)
[[ -n "$UNDEF" ]] || fail "the link produced no undefined references at all; libdrm cannot already be complete"
for s in open read close printf; do
  echo "$UNDEF" | grep -qx "$s" \
    && fail "\`$s\` came out UNDEFINED; this harness's claim is that it binds silently, and it did not"
done
comm -23 <(echo "$UNDEF" | grep -v '^main$') "$PORT_DIR/expected-missing-core.txt" > "$WORKDIR/extra.txt"
[[ -s "$WORKDIR/extra.txt" ]] \
  && fail "the link needs symbols the object-level measurement did not list: $(tr '\n' ' ' < "$WORKDIR/extra.txt")"

# 3b. AND THEY ARE NOT THE SAME FUNCTIONS. Read out of the two sources, not
#     asserted: oslibc.h's `open` takes ONE argument and returns an unsigned
#     refusal at or above a floor; libdrm calls it with two or three and tests
#     the result for being negative.
grep -qE '^unsigned long open\(const char \*name\);' "$LIBC_DIR/oslibc.h" \
  || fail "oslibc.h no longer declares \`unsigned long open(const char *name)\`; the signature-clash finding needs rechecking"
grep -qE '^#define FILE_ERR_FLOOR' "$LIBC_DIR/oslibc.h" \
  || fail "oslibc.h no longer has FILE_ERR_FLOOR; the return-convention clash needs rechecking"
grep -qE 'open\(buf, *O_RDWR' "$LIBDRM_SRC/xf86drm.c" \
  || fail "libdrm no longer calls open() with a mode argument; recheck the clash"
grep -qE '^unsigned long read\(unsigned long fd, void \*buf, size_t len\);' "$LIBC_DIR/oslibc.h" \
  || fail "oslibc.h no longer declares read() returning unsigned long; recheck the clash"
echo "CHECK 2: pass  ten symbols bind against core/user/libc and FOUR of them are the wrong function — oslibc.h's open() takes one argument where libdrm passes two or three, and returns a refusal at or above FILE_ERR_FLOOR where libdrm tests for a negative int. The link is CLEAN. GAP-0170."

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

# 8h. THE WHOLE TRANSCRIPT, BYTE FOR BYTE.
if [[ $REGEN -eq 1 ]]; then
  cp "$SERIAL" "$EXPECTED_SERIAL"
  echo "REGEN: $EXPECTED_SERIAL rewritten ($(wc -c <"$SERIAL" | tr -d ' ') bytes)"
else
  [[ -f "$EXPECTED_SERIAL" ]] || setup_error "no golden at $EXPECTED_SERIAL (run with --regen once, and READ what it wrote)"
  cmp -s "$SERIAL" "$EXPECTED_SERIAL" \
    || { diff <(cat "$EXPECTED_SERIAL") <(cat "$SERIAL") | head -40 >&2
         fail "the captured serial output does not match $EXPECTED_SERIAL (first differences above)"; }
  echo "CHECK 14: pass  the whole $(wc -c <"$SERIAL" | tr -d ' ')-byte transcript matches the golden byte for byte"
fi

echo
echo "drm-abi: PASS — unmodified libdrm compiles for this OS ($N_MISS symbols short, $N_MISS_MT with modetest); a program built against Linux's unmodified DRM uAPI runs in ring 3 and agrees with Linux 6.12 on 119 of $O_COUNT request numbers; the BSD-encoding control disagrees on 29 and is rejected. No ioctl was issued, because there is no ioctl (GAP-0158)."
exit 0
