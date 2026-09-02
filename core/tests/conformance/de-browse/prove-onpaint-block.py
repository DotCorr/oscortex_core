#!/usr/bin/env python3
"""Prove Content OnPaint cannot run on this process ABI (ADR-0123).

nm of a 558-byte cef_initialize extract is not OnPaint. This script
re-measures the official linux64 libcef.so deps and the loader
bounds. Exit 0 = leftover still holds. Exit 1 = the leftover claim
is stale (deps vanished, guest now calls cef_initialize, etc.).
Does not raise the de-browse assertion floor.
"""
from __future__ import annotations

import os
import re
import struct
import subprocess
import sys

CORE = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
GUEST = os.path.join(CORE, "plat/chrome/oschrome_guest.c")
CEF_C = os.path.join(CORE, "plat/chrome/oschrome_cef.c")
ELF_D = os.path.join(CORE, "kernel/elf.dart")
VM_D = os.path.join(CORE, "kernel/vm.dart")
STAMP = os.path.join(CORE, "build/cef-linux64/READY")
FETCH = os.path.join(CORE, "scripts/fetch-cef-linux64.sh")

NEEDED_PIN = [
    "libdl.so.2",
    "libpthread.so.0",
    "libglib-2.0.so.0",
    "libgobject-2.0.so.0",
    "libnspr4.so",
    "libnss3.so",
    "libnssutil3.so",
    "libsmime3.so",
    "libdbus-1.so.3",
    "libgio-2.0.so.0",
    "libatk-1.0.so.0",
    "libatk-bridge-2.0.so.0",
    "libcups.so.2",
    "libX11.so.6",
    "libXcomposite.so.1",
    "libXdamage.so.1",
    "libXext.so.6",
    "libXfixes.so.3",
    "libXrandr.so.2",
    "libgbm.so.1",
    "libexpat.so.1",
    "libxcb.so.1",
    "libxkbcommon.so.0",
    "libcairo.so.2",
    "libpango-1.0.so.0",
    "libudev.so.1",
    "libasound.so.2",
    "libm.so.6",
    "libatspi.so.0",
    "libgcc_s.so.1",
    "libc.so.6",
    "ld-linux-x86-64.so.2",
]
EXTRACT_SHA1 = "82f0dac25f8ab79701da064984d3c49ef2bedf0b"
EXTRACT_LEN = 558
CEF_VADDR = 0x2CE7700
TEXT_MIN = 180_000_000
WINDOW = 0x200000
IMAGE_MAX = 65536

fails: list[str] = []


def fail(msg: str) -> None:
    fails.append(msg)


def u16(b: bytes, o: int) -> int:
    return struct.unpack_from("<H", b, o)[0]


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def u64(b: bytes, o: int) -> int:
    return struct.unpack_from("<Q", b, o)[0]


def readelf_d(path: str) -> str:
    for tool in ("x86_64-elf-readelf", "readelf"):
        try:
            return subprocess.check_output([tool, "-d", path], text=True)
        except (OSError, subprocess.CalledProcessError):
            continue
    fail("no readelf for libcef.so")
    return ""


def main() -> int:
    if not os.path.isfile(STAMP):
        st = subprocess.call(["bash", FETCH])
        if st != 0:
            print("prove-onpaint-block: FAIL — fetch-cef-linux64.sh exited %d" % st, file=sys.stderr)
            return 1
    stamp = open(STAMP).read()
    so = None
    for line in stamp.splitlines():
        if line.startswith("CEF_LIB="):
            so = line.split("=", 1)[1]
    if not so or not os.path.isfile(so):
        print("prove-onpaint-block: FAIL — no CEF_LIB in READY", file=sys.stderr)
        return 1

    data = open(so, "rb").read(64)
    if data[:4] != b"\x7fELF":
        fail("libcef.so is not ELF")
    if data[16] != 3:
        fail("libcef.so e_type is %d, want ET_DYN=3" % data[16])

    dyn = readelf_d(so)
    needed = re.findall(r"Shared library: \[([^\]]+)\]", dyn)
    if len(NEEDED_PIN) != 32:
        fail("NEEDED_PIN drifted from 32")
    if needed != NEEDED_PIN:
        fail("DT_NEEDED changed:\n  got %s\n  pin %s" % (needed, NEEDED_PIN))
    ph = ""
    for tool in ("x86_64-elf-readelf", "readelf"):
        try:
            ph = subprocess.check_output([tool, "-lW", so], text=True)
            break
        except (OSError, subprocess.CalledProcessError):
            continue
    if "DYNAMIC" not in ph:
        fail("libcef.so lost PT_DYNAMIC")

    size = os.path.getsize(so)
    if size < TEXT_MIN:
        fail("libcef.so is %d bytes; leftover assumed ~1.5GiB" % size)

    fp = open(so, "rb")
    hdr = fp.read(64)
    e_shoff = u64(hdr, 40)
    e_shentsize = u16(hdr, 58)
    e_shnum = u16(hdr, 60)
    e_shstrndx = u16(hdr, 62)
    fp.seek(e_shoff + e_shstrndx * e_shentsize)
    shstr = fp.read(e_shentsize)
    names_off = u64(shstr, 24)
    names_sz = u64(shstr, 32)
    fp.seek(names_off)
    names = fp.read(names_sz)
    text_off = text_addr = None
    fp.seek(e_shoff)
    sh_all = fp.read(e_shnum * e_shentsize)
    for i in range(e_shnum):
        off = i * e_shentsize
        n = names[u32(sh_all, off) :].split(b"\x00", 1)[0]
        if n == b".text":
            text_addr = u64(sh_all, off + 16)
            text_off = u64(sh_all, off + 24)
            text_sz = u64(sh_all, off + 32)
            if text_sz < TEXT_MIN:
                fail(".text is %d bytes; want >= %d" % (text_sz, TEXT_MIN))
            break
    if text_off is None or text_addr is None:
        fail("libcef.so has no .text")
        fn = b""
    else:
        rel = CEF_VADDR - text_addr
        fp.seek(text_off + rel)
        fn = fp.read(EXTRACT_LEN)
    fp.close()
    if fn:
        if len(fn) != EXTRACT_LEN:
            fail("cef_initialize short read")
        import hashlib

        sha = hashlib.sha1(fn).hexdigest()
        if sha != EXTRACT_SHA1:
            fail("cef_initialize bytes sha1 %s != %s" % (sha, EXTRACT_SHA1))
        # e8 rel32 at the first memset@plt (offset 0x5d in the official body).
        if fn[0x5D] != 0xE8:
            fail("cef_initialize+0x5d is 0x%02x, not CALL (memset@plt)" % fn[0x5D])
        disp = struct.unpack_from("<i", fn, 0x5E)[0]
        tgt = CEF_VADDR + 0x5D + 5 + disp
        if abs(tgt - CEF_VADDR) < EXTRACT_LEN:
            fail("first CALL stays inside the 558-byte extract (0x%x)" % tgt)

    guest = open(GUEST).read()
    if "parse_rgb" not in guest:
        fail("oschrome_guest.c lost parse_rgb — leftover paint path vanished")
    if "cef_initialize" in guest:
        fail("oschrome_guest.c names cef_initialize — that is a call-thunk")
    if "OnPaint" in guest and "Leftover" not in guest:
        fail("oschrome_guest.c claims OnPaint in the painter")
    cefc = open(CEF_C).read()
    if "int cef_initialize" in cefc:
        body = cefc.split("int cef_initialize", 1)[1]
        if "{" in body.split(";")[0]:
            fail("oschrome_cef.c defines cef_initialize")

    elf = open(ELF_D).read()
    if "elfImageMax = 65536" not in elf and "elfImageMax = %d" % IMAGE_MAX not in elf:
        if not re.search(r"elfImageMax\s*=\s*65536", elf):
            fail("elf.dart lost elfImageMax = 65536")
    if "PT_INTERP" not in elf or "PT_DYNAMIC" not in elf:
        fail("elf.dart lost the PT_INTERP / PT_DYNAMIC refusal")
    vm = open(VM_D).read()
    if "0x10200000" not in vm:
        fail("vm.dart lost vmProgEnd 0x10200000")

    if fails:
        for f in fails:
            print("    - " + f, file=sys.stderr)
        print("prove-onpaint-block: FAIL — leftover claim is stale", file=sys.stderr)
        return 1

    print(
        "prove-onpaint-block: leftover holds — official libcef OnPaint did not run; "
        "libcef.so NEEDED %d (.so); .text > %d; window %d; extract %d "
        "bytes still CALL memset@plt; next binary is ring-3 libc / "
        "process ABI (PT_INTERP, window, mmap/clone/TLS, the 32 .so)"
        % (len(NEEDED_PIN), TEXT_MIN, WINDOW, EXTRACT_LEN)
    )
    print("MISSING .so:")
    for n in NEEDED_PIN:
        print("  " + n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
