#!/usr/bin/env python3
"""Host-side expected lines for plat-rel.

The DYNAMIC plat writes DYN LINE + hex(reloc_word ^ MIX). reloc_word
is 0 in the file; LD.SO applies R_X86_64_64 so it becomes SIG.
Skip RELA and the line is MIX alone — that must not match.
The no-DYNAMIC plat writes NOD LINE from a compile-time XOR.
"""

SIG = 0xA1270000C0DE0001
NOD_SIG = 0xA1270000C0DE0002
MIX = 0x0000000000000127


def main():
    print("sig=%016X" % SIG)
    print("nod_sig=%016X" % NOD_SIG)
    print("mix=%016X" % MIX)
    print("xor=%016X" % (SIG ^ MIX))
    print("nod_xor=%016X" % (NOD_SIG ^ MIX))
    print("dyn_line=DYN LINE %016X" % (SIG ^ MIX))
    print("skip_line=DYN LINE %016X" % (0 ^ MIX))
    print("nod_line=NOD LINE %016X" % (NOD_SIG ^ MIX))
    print("interp_map=INTERP MAP")
    print("rela_ok=RELA OK")
    print("dyn_start=DYN START")
    print("nod_start=NOD START")


if __name__ == "__main__":
    main()
