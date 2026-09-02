#!/usr/bin/env python3
"""Host-side expected line for plat-dyn.

The dyn program writes DYN LINE + hex(SIG ^ MIX). A kernel that
skipped the interp and jumped at e_entry without mapping, or an
interp that printed a hardcoded string, cannot match unless the
dyn program actually ran.
"""

SIG = 0xA1260000C0DE0001
MIX = 0x0000000000000126


def main():
    print("sig=%016X" % SIG)
    print("mix=%016X" % MIX)
    print("xor=%016X" % (SIG ^ MIX))
    print("dyn_line=DYN LINE %016X" % (SIG ^ MIX))
    print("interp_map=INTERP MAP")
    print("dyn_start=DYN START")


if __name__ == "__main__":
    main()
