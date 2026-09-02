#!/usr/bin/env python3
"""Host-side expected numbers for cef-load (ADR-0168)."""

MIX = 0x0000000000000168
PIXEL_RAW = 0x22840FFF8548C031
E_BADARG = 0xFFFFFFFFFFFFFFFE
RO = 42593760
RX = 189117488
PLAT_CAP = 0x1000000
APP_CAP = 0x200000


def main():
    derived = (PIXEL_RAW ^ MIX) & ((1 << 64) - 1)
    print("mix=%016X" % MIX)
    print("pixel_raw=%016X" % PIXEL_RAW)
    print("derived=%016X" % derived)
    print("ro=%016X" % RO)
    print("rx=%016X" % RX)
    print("badarg=%016X" % E_BADARG)
    print("msg_start=CEFLOAD START")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("pixel_line=PIXEL %016X" % derived)
    print("ro_line=RO %016X" % RO)
    print("rx_line=RX %016X" % RX)
    print("kernel_ro=CEF LOAD RO %016X" % RO)
    print("kernel_rx=RX %016X" % RX)
    print("dlopen_err=ERR FFFFFFFFFFFFFFFE")
    print("win=PROC PLAT 00 WIN 000000000DCFC000")
    print("slice_ceiling=12288")


if __name__ == "__main__":
    main()
