#!/usr/bin/env python3
"""Host-side expected numbers for cef-plt (ADR-0169)."""

MIX = 0x0000000000000169
FILL = 0xA5
FILL_N = 64
E_BADARG = 0xFFFFFFFFFFFFFFFE
RO = 42593760
RX = 189117488


def main():
    sig = 0
    for _ in range(FILL_N):
        sig = ((sig << 1) ^ FILL) & ((1 << 64) - 1)
    derived = (sig ^ MIX) & ((1 << 64) - 1)
    print("mix=%016X" % MIX)
    print("fill=%02X" % FILL)
    print("sig=%016X" % sig)
    print("derived=%016X" % derived)
    print("ro=%016X" % RO)
    print("rx=%016X" % RX)
    print("badarg=%016X" % E_BADARG)
    print("msg_start=CEFPLT START")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("line=LINE %016X" % derived)
    print("kernel_ro=CEF LOAD RO %016X" % RO)
    print("kernel_rx=RX %016X" % RX)
    print("plt_line=CEF PLT MEMSET ")
    print("dlopen_err=ERR FFFFFFFFFFFFFFFE")
    print("win=PROC PLAT 00 WIN 000000000DCFC000")
    print("slice_ceiling=12288")


if __name__ == "__main__":
    main()
