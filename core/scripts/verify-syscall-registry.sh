#!/usr/bin/env bash
# core/scripts/verify-syscall-registry.sh
#
# THE CHECK BEHIND core/docs/syscall-registry.md.
#
# Syscall numbers on this OS are bare `const int` declarations in four kernel
# files and `#define`s in one header, with nothing between two subsystems and
# the same number. `docs/design/hot-files.md` §5.1 records that two agents
# both claimed 11, in two different files, and that a duplicate MERGES CLEAN,
# BUILDS CLEAN, BOOTS CLEAN AND MIS-DISPATCHES — a kernel where `read` and
# `fdwait` are the same number does not fail to build, it fails to be right.
#
# This reads three sources that must agree:
#   1. docs/syscall-registry.md   the allocator
#   2. core/kernel/*.dart         `const int <name>SysNo = <n>;`  — wait, the
#                                 real spelling is `<prefix>Sys<Thing>No`
#   3. core/user/libc/oslibc.h    `#define SYS_<THING> <n>`
#
# and fails on: a number allocated twice, a kernel constant whose value
# disagrees with its row, an oslibc.h define that disagrees with its row, or a
# kernel `*SysNo` constant with no row at all.
#
# Usage: verify-syscall-registry.sh
# Exit status: 0 consistent, 1 inconsistent, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() { echo "verify-syscall-registry: FAIL — $1" >&2; exit 1; }
setup_error() { echo "verify-syscall-registry: FAIL (setup) — $1" >&2; exit 2; }

REG="$CORE_DIR/docs/syscall-registry.md"
LIBC="$CORE_DIR/user/libc/oslibc.h"
[[ -f "$REG" ]] || setup_error "no registry at $REG"
[[ -f "$LIBC" ]] || setup_error "no oslibc.h at $LIBC"
command -v python3 >/dev/null 2>&1 || setup_error "python3 not found on PATH"

python3 - "$REG" "$LIBC" "$CORE_DIR/kernel" <<'PY'
import os, re, sys

reg_path, libc_path, kernel_dir = sys.argv[1:4]
reg = open(reg_path).read()

def problems():
    out = []

    # ---- 1. the registry's own rows ------------------------------------
    # Allocated rows carry a kernel constant in backticks; reserved rows do
    # not. Both forms start "| <n> | `name`" or "| <n> | name".
    allocated = {}   # number -> (name, kernel_const, libc_define)
    reserved = {}    # number -> name
    for line in reg.splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 2 or not cells[0].isdigit():
            continue
        n = int(cells[0])
        name = cells[1].strip("`")
        if len(cells) >= 6 and cells[2].startswith("`"):
            kconst = cells[2].strip("`")
            libcdef = cells[4].strip("`")
            if libcdef.startswith("*"):
                libcdef = None
            if n in allocated or n in reserved:
                out.append("syscall %d is in the registry twice" % n)
            allocated[n] = (name, kconst, libcdef)
        else:
            if n in allocated or n in reserved:
                out.append("syscall %d is in the registry twice" % n)
            reserved[n] = name

    if len(allocated) < 10:
        out.append("the registry lists only %d allocated syscalls; it listed 11 "
                   "when this check was written — is the table still a table?"
                   % len(allocated))

    # ---- 2. the kernel's constants -------------------------------------
    # Every `const int <something>Sys<...>No = <n>;` in core/kernel.
    kernel = {}      # constant name -> (number, file)
    pat = re.compile(r"^const int ([A-Za-z0-9_]*Sys[A-Za-z0-9_]*No) = (0x[0-9A-Fa-f]+|\d+);",
                     re.M)
    for f in sorted(os.listdir(kernel_dir)):
        if not f.endswith(".dart"):
            continue
        for m in pat.finditer(open(os.path.join(kernel_dir, f)).read()):
            kernel[m.group(1)] = (int(m.group(2), 0), f)

    if not kernel:
        out.append("no `const int *Sys*No` declarations found under %s — the "
                   "spelling this check greps for has changed" % kernel_dir)

    # every kernel constant must have a row, and agree with it
    by_const = {v[1]: (n, v[0]) for n, v in allocated.items()}
    for cname, (cval, cfile) in sorted(kernel.items()):
        if cname not in by_const:
            out.append("core/kernel/%s declares %s = %d and the registry has no "
                       "row for it" % (cfile, cname, cval))
            continue
        n, _ = by_const[cname]
        if n != cval:
            out.append("core/kernel/%s says %s = %d; the registry says %d"
                       % (cfile, cname, cval, n))

    # every allocated row must have its kernel constant
    for n, (name, kconst, _) in sorted(allocated.items()):
        if kconst not in kernel:
            out.append("the registry allocates %d to %s via %s, and no kernel "
                       "file declares that constant" % (n, name, kconst))

    # ---- 3. oslibc.h ---------------------------------------------------
    libc = {}
    for m in re.finditer(r"^#define (SYS_[A-Z0-9_]+) (\d+)$", open(libc_path).read(), re.M):
        libc[m.group(1)] = int(m.group(2))
    if not libc:
        out.append("no `#define SYS_* <n>` lines in oslibc.h")
    for n, (name, _, libcdef) in sorted(allocated.items()):
        if libcdef is None:
            continue
        if libcdef not in libc:
            out.append("the registry says syscall %d is %s in oslibc.h, and "
                       "oslibc.h does not define it" % (n, libcdef))
        elif libc[libcdef] != n:
            out.append("oslibc.h says %s = %d; the registry says %d"
                       % (libcdef, libc[libcdef], n))
    # and nothing in oslibc.h may name a number the registry has not allocated
    alloc_nums = set(allocated)
    for name, n in sorted(libc.items()):
        if n not in alloc_nums:
            out.append("oslibc.h defines %s = %d and the registry allocates no "
                       "such number" % (name, n))

    # ---- 4. the whole point: no number twice ----------------------------
    seen = {}
    for n, (name, _, _) in allocated.items():
        seen.setdefault(n, []).append(name)
    for n, name in reserved.items():
        seen.setdefault(n, []).append(name + " (reserved)")
    for n, names in sorted(seen.items()):
        if len(names) > 1:
            out.append("syscall %d is claimed by %s" % (n, " and ".join(names)))

    return out, allocated, reserved

probs, allocated, reserved = problems()
if probs:
    for p in probs:
        print("  " + p)
    sys.exit(1)
print("verify-syscall-registry: PASS — %d allocated (0..%d), %d reserved (%s), "
      "no number claimed twice, kernel and oslibc.h agree with the registry"
      % (len(allocated), max(allocated), len(reserved),
         ", ".join("%d=%s" % (n, reserved[n]) for n in sorted(reserved))))
PY
status=$?
[[ $status -eq 0 ]] || fail "the syscall registry, the kernel and oslibc.h disagree (above)"
exit 0
