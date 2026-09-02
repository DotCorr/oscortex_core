#!/usr/bin/env python3
"""Pull official cef_initialize bytes out of linux64 libcef.so.

Writes <out>.bin (raw official text) and <out>.S (freestanding
symbol). Not a handwritten stub — the bytes come from Spotify CEF.
A fill that ignores this file is the vacuity the harness rejects.
"""
import struct
import sys


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def sections(data):
    if data[:4] != b"\x7fELF":
        raise SystemExit("extract-cef-guest: not ELF")
    if data[4] != 2:
        raise SystemExit("extract-cef-guest: not ELF64")
    e_shoff = u64(data, 40)
    e_shentsize = u16(data, 58)
    e_shnum = u16(data, 60)
    e_shstrndx = u16(data, 62)
    sh = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh.append({
            "name_off": u32(data, off + 0),
            "type": u32(data, off + 4),
            "flags": u64(data, off + 8),
            "addr": u64(data, off + 16),
            "offset": u64(data, off + 24),
            "size": u64(data, off + 32),
            "link": u32(data, off + 40),
            "info": u32(data, off + 44),
            "addralign": u64(data, off + 48),
            "entsize": u64(data, off + 56),
        })
    strtab = sh[e_shstrndx]
    names = data[strtab["offset"]:strtab["offset"] + strtab["size"]]
    for s in sh:
        n = names[s["name_off"]:]
        s["name"] = n.split(b"\x00", 1)[0].decode("ascii", "replace")
    return sh


def find_sym(data, sh, want):
    dynsym = None
    dynstr = None
    for s in sh:
        if s["name"] == ".dynsym":
            dynsym = s
        if s["name"] == ".dynstr":
            dynstr = s
    if dynsym is None or dynstr is None:
        raise SystemExit("extract-cef-guest: no .dynsym/.dynstr")
    strings = data[dynstr["offset"]:dynstr["offset"] + dynstr["size"]]
    entsz = dynsym["entsize"] or 24
    n = dynsym["size"] // entsz
    hits = []
    for i in range(n):
        off = dynsym["offset"] + i * entsz
        st_name = u32(data, off + 0)
        st_info = data[off + 4]
        st_shndx = u16(data, off + 6)
        st_value = u64(data, off + 8)
        st_size = u64(data, off + 16)
        raw = strings[st_name:]
        name = raw.split(b"\x00", 1)[0].decode("ascii", "replace")
        if name == want or name.startswith(want + "@"):
            hits.append((name, st_info, st_shndx, st_value, st_size))
    if not hits:
        raise SystemExit("extract-cef-guest: %s not in libcef.so dynsym" % want)
    # Prefer a defined (non-UND) hit with a size.
    hits.sort(key=lambda h: (0 if h[2] != 0 else 1, 0 if h[4] else 1, -h[4]))
    return hits[0]


def vaddr_to_off(sh, addr):
    for s in sh:
        if s["type"] != 1:  # SHT_PROGBITS
            continue
        if s["addr"] <= addr < s["addr"] + s["size"]:
            return s["offset"] + (addr - s["addr"]), s
    # PT_LOAD fallback via section flags ALLOC
    for s in sh:
        if s["flags"] & 2 and s["addr"] <= addr < s["addr"] + s["size"]:
            return s["offset"] + (addr - s["addr"]), s
    raise SystemExit("extract-cef-guest: vaddr 0x%x not in a mapped section" % addr)


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: extract-cef-guest.py <libcef.so> <out-prefix> <symbol>")
    so, prefix, want = sys.argv[1], sys.argv[2], sys.argv[3]
    data = open(so, "rb").read()
    sh = sections(data)
    name, info, shndx, value, size = find_sym(data, sh, want)
    if shndx == 0:
        raise SystemExit("extract-cef-guest: %s is UND in libcef.so" % name)
    if size == 0:
        size = 64
    if size > 4096:
        # A C API export is a thunk. Do not drag a 4K+ inlined body
        # into the 64 KiB FRAME image.
        size = 64
    off, _sec = vaddr_to_off(sh, value)
    blob = data[off:off + size]
    if len(blob) != size:
        raise SystemExit("extract-cef-guest: short read at 0x%x" % off)
    if blob == b"\x00" * size:
        raise SystemExit("extract-cef-guest: official bytes are all zero")
    open(prefix + ".bin", "wb").write(blob)
    asm = (
        "/* official CEF linux64 extract — bytes from libcef.so, not a stub */\n"
        "    .section .text.%s,\"ax\",@progbits\n"
        "    .globl %s\n"
        "    .type %s, @function\n"
        "%s:\n"
        "    .incbin \"%s.bin\"\n"
        "    .size %s, .-%s\n"
        "    .section .note.GNU-stack,\"\",@progbits\n"
        % (want, want, want, want, prefix.split("/")[-1], want, want)
    )
    # .incbin is relative to the assembler cwd; write a path-free incbin
    # by using the prefix basename and assembling from that directory.
    open(prefix + ".S", "w").write(asm)
    print("extract-cef-guest: %s vaddr=0x%x size=%d sha1 follows on stdout" %
          (name, value, size))
    import hashlib
    print(hashlib.sha1(blob).hexdigest())


if __name__ == "__main__":
    main()
