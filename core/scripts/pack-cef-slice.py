#!/usr/bin/env python3
"""Pack a measured official libcef.so slice as a tiny ET_DYN CEF.SO.

Bytes come from Spotify CEF linux64 libcef.so (ADR-0122 stamp):
  * 32 DT_NEEDED name strings (verbatim .dynstr)
  * 558-byte cef_initialize text (sha1 pinned)
  * one R_X86_64_64 whose addend is the first 8 official text bytes

This is not a rename of oschrome_on_paint. It is not full libcef.
It is the first real map/reloc/NEEDED door (ADR-0167 / cef-wire/).
"""
from __future__ import annotations

import hashlib
import os
import struct
import sys

EXTRACT_SHA1 = "82f0dac25f8ab79701da064984d3c49ef2bedf0b"
EXTRACT_LEN = 558
CEF_VADDR = 0x2CE7700
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
NEEDED_BLOB_SHA1 = "36d038b5f1f23f37d15968965cb33cf4097416e1"

PT_LOAD = 1
PT_DYNAMIC = 2
PF_X, PF_W, PF_R = 1, 2, 4
DT_NEEDED, DT_HASH, DT_STRTAB, DT_SYMTAB = 1, 4, 5, 6
DT_RELA, DT_RELASZ, DT_RELAENT = 7, 8, 9
DT_STRSZ, DT_SYMENT, DT_SONAME, DT_NULL = 10, 11, 14, 0
R_X86_64_64 = 1
STB_GLOBAL, STT_FUNC = 1, 2


def u16(b: bytes, o: int) -> int:
    return struct.unpack_from("<H", b, o)[0]


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def u64(b: bytes, o: int) -> int:
    return struct.unpack_from("<Q", b, o)[0]


def vaddr_to_file(data: bytes, vaddr: int) -> int:
    e_phoff = u64(data, 32)
    e_phentsize = u16(data, 54)
    e_phnum = u16(data, 56)
    for i in range(e_phnum):
        ph = e_phoff + i * e_phentsize
        if u32(data, ph) != PT_LOAD:
            continue
        p_offset = u64(data, ph + 8)
        p_vaddr = u64(data, ph + 16)
        p_filesz = u64(data, ph + 32)
        if p_vaddr <= vaddr < p_vaddr + p_filesz:
            return p_offset + (vaddr - p_vaddr)
    raise SystemExit("pack-cef-slice: vaddr 0x%x not in a LOAD" % vaddr)


def official_needed_and_text(so_path: str) -> tuple[list[str], bytes, int]:
    data = open(so_path, "rb").read()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[16] != 3:
        raise SystemExit("pack-cef-slice: not ELF64 ET_DYN")
    # Locate PT_DYNAMIC
    e_phoff = u64(data, 32)
    e_phentsize = u16(data, 54)
    e_phnum = u16(data, 56)
    dyn_off = dyn_sz = None
    for i in range(e_phnum):
        ph = e_phoff + i * e_phentsize
        if u32(data, ph) == PT_DYNAMIC:
            dyn_off = u64(data, ph + 8)
            dyn_sz = u64(data, ph + 32)
    if dyn_off is None:
        raise SystemExit("pack-cef-slice: no PT_DYNAMIC")
    strtab_va = None
    needed_offs: list[int] = []
    i = 0
    while i + 16 <= dyn_sz:
        tag, val = struct.unpack_from("<QQ", data, dyn_off + i)
        if tag == DT_NULL:
            break
        if tag == DT_NEEDED:
            needed_offs.append(val)
        elif tag == DT_STRTAB:
            strtab_va = val
        i += 16
    if strtab_va is None:
        raise SystemExit("pack-cef-slice: no DT_STRTAB")
    strtab_off = vaddr_to_file(data, strtab_va)
    names: list[str] = []
    for off in needed_offs:
        end = data.index(b"\x00", strtab_off + off)
        names.append(data[strtab_off + off:end].decode("ascii"))
    if names != NEEDED_PIN:
        raise SystemExit("pack-cef-slice: DT_NEEDED drifted:\n %s" % names)
    blob = b"".join(n.encode("ascii") + b"\x00" for n in names)
    if hashlib.sha1(blob).hexdigest() != NEEDED_BLOB_SHA1:
        raise SystemExit("pack-cef-slice: NEEDED blob sha1 mismatch")
    text_off = vaddr_to_file(data, CEF_VADDR)
    text = data[text_off:text_off + EXTRACT_LEN]
    if len(text) != EXTRACT_LEN:
        raise SystemExit("pack-cef-slice: short cef_initialize read")
    if hashlib.sha1(text).hexdigest() != EXTRACT_SHA1:
        raise SystemExit("pack-cef-slice: cef_initialize sha1 mismatch")
    addend = struct.unpack_from("<Q", text, 0)[0]
    return names, text, addend


def align_up(n: int, a: int) -> int:
    return (n + a - 1) & ~(a - 1)


def build_slice(names: list[str], text: bytes, addend: int) -> bytes:
    # VAs / pages
    page = 0x1000
    text_va = page
    reloc_va = page * 2

    # --- dynstr ---
    dynstr = bytearray(b"\x00")  # index 0
    needed_offs = []
    for n in names:
        needed_offs.append(len(dynstr))
        dynstr += n.encode("ascii") + b"\x00"
    soname_off = len(dynstr)
    dynstr += b"libcef.so\x00"
    cef_off = len(dynstr)
    dynstr += b"cef_initialize\x00"
    dynstr = bytes(dynstr)

    # --- dynsym: null + cef_initialize ---
    dynsym = bytearray(24)  # null
    # st_name, st_info, st_other, st_shndx, st_value, st_size
    dynsym += struct.pack(
        "<IBBHQQ",
        cef_off,
        (STB_GLOBAL << 4) | STT_FUNC,
        0,
        1,  # fake shndx != UND
        text_va,
        EXTRACT_LEN,
    )
    dynsym = bytes(dynsym)
    nsym = 2

    # --- hash (sysv): nbucket=1, nchain=nsym ---
    # bucket[0] = 1; chain[0]=0; chain[1]=0
    hsh = struct.pack("<II", 1, nsym) + struct.pack("<I", 1) + struct.pack("<II", 0, 0)

    # --- rela: one R_X86_64_64 at reloc_va, addend = official first 8 ---
    rela = struct.pack("<QqQ", reloc_va, R_X86_64_64, addend)

    # Layout inside page 0 (file offset == VA for LOAD0)
    # ehdr(64) + 4*phdr(56) = 288
    ehdr_sz = 64
    phnum = 4
    phentsize = 56
    phoff = ehdr_sz
    cursor = phoff + phnum * phentsize  # 288

    hash_off = cursor
    cursor += len(hsh)
    dynsym_off = cursor
    cursor += len(dynsym)
    dynstr_off = cursor
    cursor += len(dynstr)
    rela_off = align_up(cursor, 8)
    cursor = rela_off + len(rela)
    dynamic_off = align_up(cursor, 8)

    # Build DYNAMIC
    dyn_entries = []
    for off in needed_offs:
        dyn_entries.append((DT_NEEDED, off))
    dyn_entries.extend([
        (DT_SONAME, soname_off),
        (DT_HASH, hash_off),
        (DT_STRTAB, dynstr_off),
        (DT_SYMTAB, dynsym_off),
        (DT_STRSZ, len(dynstr)),
        (DT_SYMENT, 24),
        (DT_RELA, rela_off),
        (DT_RELASZ, len(rela)),
        (DT_RELAENT, 24),
        (DT_NULL, 0),
    ])
    dyn_raw = b"".join(struct.pack("<QQ", t, v) for t, v in dyn_entries)
    if len(dyn_raw) > 2048:
        raise SystemExit("pack-cef-slice: DYNAMIC too large for door")

    load0_end = dynamic_off + len(dyn_raw)
    load0_filesz = align_up(load0_end, 16)
    if load0_filesz > page:
        raise SystemExit("pack-cef-slice: meta exceeds one page (%d)" % load0_filesz)

    text_off = page
    reloc_off = page * 2
    file_size = page * 3

    img = bytearray(file_size)

    # Program headers
    def write_phdr(idx, p_type, flags, offset, vaddr, filesz, memsz, align):
        o = phoff + idx * phentsize
        struct.pack_into("<IIQQQQQQ", img, o,
                         p_type, flags, offset, vaddr, vaddr, filesz, memsz, align)

    write_phdr(0, PT_LOAD, PF_R, 0, 0, load0_filesz, load0_filesz, page)
    write_phdr(1, PT_LOAD, PF_R | PF_X, text_off, text_va, EXTRACT_LEN, EXTRACT_LEN, page)
    write_phdr(2, PT_LOAD, PF_R | PF_W, reloc_off, reloc_va, 8, 8, page)
    write_phdr(3, PT_DYNAMIC, PF_R | PF_W, dynamic_off, dynamic_off, len(dyn_raw), len(dyn_raw), 8)

    # ELF header
    img[0:4] = b"\x7fELF"
    img[4] = 2  # ELFCLASS64
    img[5] = 1  # ELFDATA2LSB
    img[6] = 1  # EV_CURRENT
    struct.pack_into("<H", img, 16, 3)  # ET_DYN
    struct.pack_into("<H", img, 18, 62)  # EM_X86_64
    struct.pack_into("<I", img, 20, 1)
    struct.pack_into("<Q", img, 24, 0)  # e_entry
    struct.pack_into("<Q", img, 32, phoff)
    struct.pack_into("<Q", img, 40, 0)  # no shdrs
    struct.pack_into("<I", img, 48, 0)
    struct.pack_into("<H", img, 52, ehdr_sz)
    struct.pack_into("<H", img, 54, phentsize)
    struct.pack_into("<H", img, 56, phnum)
    struct.pack_into("<H", img, 58, 0)
    struct.pack_into("<H", img, 60, 0)
    struct.pack_into("<H", img, 62, 0)

    img[hash_off:hash_off + len(hsh)] = hsh
    img[dynsym_off:dynsym_off + len(dynsym)] = dynsym
    img[dynstr_off:dynstr_off + len(dynstr)] = dynstr
    img[rela_off:rela_off + len(rela)] = rela
    img[dynamic_off:dynamic_off + len(dyn_raw)] = dyn_raw
    img[text_off:text_off + EXTRACT_LEN] = text
    # reloc_word starts 0 — PLAT applies the RELA
    struct.pack_into("<Q", img, reloc_off, 0)

    return bytes(img)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: pack-cef-slice.py <libcef.so> <out/CEF.SO>", file=sys.stderr)
        return 2
    so_path, out_path = sys.argv[1], sys.argv[2]
    if not os.path.isfile(so_path):
        print("pack-cef-slice: missing %s" % so_path, file=sys.stderr)
        return 1
    names, text, addend = official_needed_and_text(so_path)
    blob = build_slice(names, text, addend)
    if len(blob) > 65536:
        print("pack-cef-slice: slice %d exceeds elfImageMax" % len(blob), file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    open(out_path, "wb").write(blob)
    print("pack-cef-slice: %s (%d bytes)" % (out_path, len(blob)))
    print("  needed=%d blob_sha1=%s" % (len(names), NEEDED_BLOB_SHA1))
    print("  cef_initialize sha1=%s addend=%016X" % (EXTRACT_SHA1, addend))
    return 0


if __name__ == "__main__":
    sys.exit(main())
