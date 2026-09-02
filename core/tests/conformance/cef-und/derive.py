#!/usr/bin/env python3
"""Host-side expected numbers for cef-und (ADR-0170)."""

MIX = 0x0000000000000170
FILL = 0xA5
FILL_N = 64
BATCH = 5
UND_TOTAL = 1336
E_BADARG = 0xFFFFFFFFFFFFFFFE
RO = 42593760
RX = 189117488


def main():
    # Mirror prog.c: after tests, buf holds memmove result.
    buf = [0] * FILL_N
    # memset fill then memmove(buf+4, buf, 32) with prior 0x10+i pattern
    for i in range(FILL_N):
        buf[i] = 0x10 + i
    # memmove overlap: dest=buf+4, src=buf, n=32
    # simulate forward-safe via temp
    tmp = buf[:32]
    for i in range(32):
        buf[4 + i] = tmp[i]

    zlen = len("oscortex")
    sig = 0
    for i in range(FILL_N):
        sig = ((sig << 1) ^ buf[i]) & ((1 << 64) - 1)
    sig = ((sig << 1) ^ zlen) & ((1 << 64) - 1)
    sig = ((sig << 1) ^ BATCH) & ((1 << 64) - 1)
    derived = (sig ^ MIX) & ((1 << 64) - 1)

    print("mix=%016X" % MIX)
    print("batch=%016X" % BATCH)
    print("und_total=%d" % UND_TOTAL)
    print("und_bound=%d" % BATCH)
    print("und_remain=%d" % (UND_TOTAL - BATCH))
    print("sig=%016X" % sig)
    print("derived=%016X" % derived)
    print("ro=%016X" % RO)
    print("rx=%016X" % RX)
    print("badarg=%016X" % E_BADARG)
    print("msg_start=CEFUND START")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("line=LINE %016X" % derived)
    print("kernel_ro=CEF LOAD RO %016X" % RO)
    print("kernel_rx=RX %016X" % RX)
    print("plt_line=CEF PLT MEMSET ")
    print("und_line=CEF UND BATCH 0000000000000005")
    print("batch_user=BATCH 0000000000000005")
    print("dlopen_err=ERR FFFFFFFFFFFFFFFE")
    print("win=PROC PLAT 00 WIN 000000000DCFC000")
    print("bound_list=memset,memcpy,memmove,strlen,memcmp")


if __name__ == "__main__":
    main()
