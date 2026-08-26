#!/usr/bin/env python3
"""core/tests/conformance/drm-abi/oracle.py

THE INDEPENDENT EXPECTATION. Produces, on the HOST, the request numbers the
guest program must print -- and it produces them three ways so that agreement
means something:

  port    the pinned libdrm uAPI headers + core/user/ports/libdrm/shim
          (which is where this port chooses LINUX's _IOC encoding), compiled by
          the HOST compiler for the HOST architecture. This is what the guest
          must match. It differs from the guest build in TARGET (arm64 macOS vs
          x86_64-unknown-none-elf) and in nothing else, so agreement is a claim
          about the STRUCT LAYOUTS being ABI-stable, which is what Linux's uAPI
          rule promises.

  linux   the LINUX KERNEL TREE's own include/uapi/drm headers, compiled with
          -D__linux__=1 so that drm.h takes its Linux branch and uses LINUX's
          OWN `_IOC` macros out of asm-generic/ioctl.h. Nothing of this port is
          involved. This is what makes "we implement the Linux encoding" a
          checked statement rather than a transcription.

  bsd     the same libdrm headers with BSD's real `_IOC` encoding -- the
          negative control's encoding. Reported so that run.sh can require the
          control's disagreement to be EXACTLY the 29 requests it claims.

Usage:
    oracle.py <libdrm-src> <shim-dir> <neg-shim-dir> <workdir> [<linux-uapi-dir>]

Writes <workdir>/oracle.json and prints a one-line summary.

Exit status: 0 on success, 2 on a setup error, 3 on a self-check failure.
"""

import json
import os
import re
import subprocess
import sys

HEADERS = ("drm.h", "virtgpu_drm.h")
NOT_A_REQUEST = {"DRM_IOCTL_BASE"}


def die(msg, code=3):
    sys.stderr.write("oracle: %s\n" % msg)
    raise SystemExit(code)


def names_from(incdir):
    out = []
    for h in HEADERS:
        try:
            src = open(os.path.join(incdir, h)).read()
        except OSError as e:
            die("cannot read %s/%s: %s" % (incdir, h, e), 2)
        for m in re.finditer(r"^#define\s+(DRM_IOCTL_[A-Z0-9_]+)\s", src, re.M):
            n = m.group(1)
            if n not in NOT_A_REQUEST and n not in out:
                out.append(n)
    return out


def build_and_run(work, tag, names, incdirs, defines):
    """Compile a host binary that prints each request number, and run it.

    Names the header can't define (a Linux tree older than libdrm's copy) come
    back as None rather than as a build failure, so version skew is DATA
    instead of an error.
    """
    c = os.path.join(work, "oracle_%s.c" % tag)
    with open(c, "w") as f:
        f.write("#include <stdio.h>\n")
        for h in HEADERS:
            f.write('#include "%s"\n' % h)
        f.write("int main(void){\n")
        for n in names:
            f.write('#ifdef %s\n  printf("%s %%08lx\\n", (unsigned long)(unsigned int)%s);\n'
                    '#else\n  printf("%s -\\n");\n#endif\n' % (n, n, n, n))
        f.write("  return 0;\n}\n")
    exe = os.path.join(work, "oracle_%s" % tag)
    cmd = ["clang", "-w"] + ["-D" + d for d in defines] \
        + ["-I" + d for d in incdirs] + [c, "-o", exe]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        die("host compile of the %s oracle failed:\n%s\n%s"
            % (tag, " ".join(cmd), r.stderr[:2000]), 2)
    r = subprocess.run([exe], capture_output=True, text=True)
    if r.returncode != 0:
        die("the %s oracle exited %d" % (tag, r.returncode))
    vals = {}
    for line in r.stdout.splitlines():
        k, v = line.split()
        vals[k] = None if v == "-" else int(v, 16)
    return vals


def linux_include_dirs(root, work):
    """Make a Linux source tree's uapi headers includable without `headers_install`.

    A kernel tree's `include/uapi` is not self-contained: `<asm/types.h>` and
    `<asm/ioctl.h>` are resolved at build time to either the architecture's own
    `arch/<a>/include/uapi/asm/` or to `include/uapi/asm-generic/`, by Kbuild.
    `make headers_install` is what normally does that; this does the same job
    for the six headers drm.h transitively needs, and no others, so that the
    oracle depends on a plain `git clone` of Linux rather than on a built tree.

    Returns (uapi_dir, bridge_dir).
    """
    root = os.path.abspath(root)
    # Accept either the tree root or its include/uapi.
    if os.path.isdir(os.path.join(root, "include", "uapi", "drm")):
        uapi = os.path.join(root, "include", "uapi")
        arch = os.path.join(root, "arch", "x86", "include", "uapi", "asm")
    elif os.path.isdir(os.path.join(root, "drm")):
        uapi = root
        arch = os.path.join(os.path.dirname(os.path.dirname(root)),
                            "arch", "x86", "include", "uapi", "asm")
    else:
        die("%s does not look like a Linux tree or its include/uapi" % root, 2)

    generic = os.path.join(uapi, "asm-generic")
    bridge = os.path.join(work, "asmbridge")
    os.makedirs(os.path.join(bridge, "asm"), exist_ok=True)
    # `bitsperlong.h` is taken from asm-generic ON PURPOSE, and this is the one
    # place the bridge is not a mechanical stand-in for `headers_install`.
    # x86's version reads `#ifdef __x86_64__`, which is FALSE on this arm64
    # host, so it would answer 32 and every `__kernel_size_t` in the uAPI would
    # come out four bytes wide -- moving DRM_IOCTL_VERSION from 0x40 to 0x38 and
    # producing a "divergence" that is an artefact of the host, not of the ABI.
    # (Observed, before this line existed.) asm-generic's version computes it
    # from `__CHAR_BIT__ * __SIZEOF_LONG__` and answers 64 on any LP64 host,
    # which is the model we want: the guest is x86_64 and x86_64 is LP64.
    GENERIC_FIRST = {"bitsperlong.h"}
    for h in ("types.h", "ioctl.h", "bitsperlong.h", "posix_types.h",
              "posix_types_64.h", "byteorder.h"):
        order = [generic, arch] if h in GENERIC_FIRST else [arch, generic]
        target = None
        for d in order:
            if os.path.exists(os.path.join(d, h)):
                target = os.path.join(d, h)
                break
        if target is None:
            continue
        with open(os.path.join(bridge, "asm", h), "w") as f:
            f.write('#include "%s"\n' % target)
    # `include/uapi/linux/stddef.h` pulls in `<linux/compiler_types.h>`, which
    # is a KERNEL-INTERNAL header; `make headers_install` deletes that include
    # rather than shipping it. An empty file is the same thing, and it is
    # deliberately empty rather than a copy: nothing in it affects a struct
    # layout, and copying kernel-internal headers is how a uAPI comparison
    # stops being a uAPI comparison.
    os.makedirs(os.path.join(bridge, "linux"), exist_ok=True)
    for stub in ("compiler_types.h",):
        with open(os.path.join(bridge, "linux", stub), "w") as f:
            f.write("/* headers_install removes this include; see oracle.py */\n")

    if not os.path.exists(os.path.join(bridge, "asm", "ioctl.h")):
        die("no asm/ioctl.h found under %s or %s — this is the header the whole "
            "comparison is about" % (arch, generic), 2)
    return uapi, bridge


def fnv1a(values):
    """FNV-1a/32 over the little-endian bytes of each 32-bit value, in order.

    A SECOND IMPLEMENTATION of prog.c's `fnv1a`, written from the algorithm
    rather than translated from that C, because a checksum whose expectation is
    a copy of the thing it checks is not an expectation.
    """
    h = 2166136261
    for v in values:
        for b in range(4):
            h ^= (v >> (b * 8)) & 0xFF
            h = (h * 16777619) & 0xFFFFFFFF
    return h


def main():
    if len(sys.argv) not in (5, 6):
        die("usage: oracle.py <libdrm-src> <shim> <neg-shim> <workdir> [<linux-uapi>]", 2)
    src, shim, negshim, work = sys.argv[1:5]
    linux_uapi = sys.argv[5] if len(sys.argv) == 6 else None

    incdrm = os.path.join(src, "include", "drm")
    names = names_from(incdrm)
    if len(names) < 100:
        die("only %d DRM_IOCTL_* names in %s" % (len(names), incdrm))

    os.makedirs(work, exist_ok=True)

    port = build_and_run(work, "port", names, [shim, incdrm], [])
    bsd = build_and_run(work, "bsd", names, [negshim, shim, incdrm], [])

    missing = [n for n in names if port.get(n) is None]
    if missing:
        die("the port oracle could not define %d requests: %s" % (len(missing), missing[:5]))

    port_vals = [port[n] for n in names]
    h = fnv1a(port_vals)

    bsd_diff = sorted(n for n in names if bsd.get(n) != port[n])

    result = {
        "count": len(names),
        "names": names,
        "port": {n: port[n] for n in names},
        "hash": "%x" % h,
        "bsd_differs": bsd_diff,
        "bsd_hash": "%x" % fnv1a([bsd[n] for n in names]),
        "zero_size": sum(1 for n in names if ((port[n] >> 16) & 0x3FFF) == 0),
        "max_size": max(((port[n] >> 16) & 0x3FFF) for n in names),
    }

    if linux_uapi:
        uapi, bridge = linux_include_dirs(linux_uapi, work)
        lin = build_and_run(
            work, "linux", names,
            [bridge, uapi, os.path.join(uapi, "drm")],
            ["__linux__=1", "__user="])
        result["linux_available"] = True
        result["linux_absent"] = sorted(n for n in names if lin.get(n) is None)
        result["linux_differs"] = sorted(
            n for n in names if lin.get(n) is not None and lin[n] != port[n])
        result["linux"] = {n: lin[n] for n in names}
    else:
        result["linux_available"] = False

    # Self-checks. An oracle that agreed with everything would make the whole
    # harness vacuous.
    if not bsd_diff:
        die("the BSD encoding produced identical numbers for all %d requests; "
            "the negative control cannot be a control" % len(names))
    if h == result["bsd_hash"]:
        die("the port hash and the BSD hash are equal; the control is vacuous")

    with open(os.path.join(work, "oracle.json"), "w") as f:
        json.dump(result, f, indent=1)

    print("oracle: %d requests, hash %s, BSD differs on %d, linux=%s"
          % (result["count"], result["hash"], len(bsd_diff),
             "yes" if result["linux_available"] else "no"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
