/* core/tests/conformance/m20-ipc/prog.c
 *
 * M20's test program. ONE SOURCE, BUILT ONCE, WRITTEN TO TWO DISK SLOTS.
 *
 * WHY IT IS ONE PROGRAM AND NOT TWO
 * ---------------------------------------------------------------------------
 * m11 and m18 each build two different programs and the disk carries two
 * different images. This harness writes the SAME BYTES to both slots -- the
 * build script asserts they are byte-identical -- and the two processes take
 * DIFFERENT ROLES because `chanopen` hands the first caller side 0 and the
 * second side 1.
 *
 * That is the point. "The two processes behaved differently" is then a claim
 * about the KERNEL and not about two different programs, in the same way that
 * M19's "the same binary, two command lines, two answers" was a claim about the
 * kernel's argv and not about two builds.
 *
 * It also means the program has to be written to be either end of a
 * conversation without knowing which, which is what a real IPC client is.
 *
 * THE THREE MODES THIS PROGRAM CAN FIND ITSELF IN
 * ---------------------------------------------------------------------------
 *   side 0 -- the REQUESTER. Sends four requests of four different lengths,
 *             checks the reply to each, runs the refusal battery, then bursts
 *             the ring full and EXITS WHILE ITS PEER HAS READ NONE OF IT.
 *   side 1 -- the RESPONDER. Answers the four requests with replies DERIVED
 *             from what it actually received, then drains eight messages from a
 *             peer that no longer exists, then observes CHAN_PEERGONE on both a
 *             receive and a send.
 *   no process -- `chanopen` returns CHAN_NOPROC. This happens when the same
 *             binary is started with `run <lba>` as an M10-style program rather
 *             than with `proc coop`, and it is the negative control for
 *             GAP-0204: an endpoint is owned by a PROCESS ID and this thing has
 *             not got one.
 *
 * EVERY NUMBER THIS PROGRAM PRINTS OR EXITS WITH IS DERIVED FROM BYTES IT
 * ACTUALLY RECEIVED. The exit status is an FNV-1a hash of every payload byte
 * the kernel handed over, and `derive.py` computes the same hash on the host
 * from the same formulas. A kernel that delivered plausible-but-wrong bytes --
 * the previous message, a shifted copy, a truncation -- produces a different
 * 64-bit number and the harness fails.
 *
 * Freestanding: no libc, no `_start` from core/user/libc. `proc coop` enters at
 * e_entry with an EMPTY STACK and no argv (GAP-0149), so there is nothing for
 * start.c to unpack and this file defines its own entry point, exactly as
 * m11's and m18's programs do.
 */

typedef unsigned long u64;
typedef unsigned char u8;

/* --- the ABI ------------------------------------------------------------- */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_CHANOPEN 13
#define SYS_CHANSEND 14
#define SYS_CHANRECV 15

/* core/kernel/chan.dart's return values. Copied here rather than included,
 * because this program is freestanding and does not share a header with the
 * kernel -- and run.sh reads BOTH copies and requires them to agree, which is
 * the check that makes a private copy safe. */
#define CHAN_FLOOR 0xFFFFFFFFFFFFFF00UL
#define CHAN_BADPORT 0xFFFFFFFFFFFFFFFEUL
#define CHAN_NOPROC 0xFFFFFFFFFFFFFFFDUL
#define CHAN_BUSY 0xFFFFFFFFFFFFFFFCUL
#define CHAN_TWICE 0xFFFFFFFFFFFFFFFBUL
#define CHAN_BADEP 0xFFFFFFFFFFFFFFFAUL
#define CHAN_NOTOWNER 0xFFFFFFFFFFFFFFF9UL
#define CHAN_BADPTR 0xFFFFFFFFFFFFFFF8UL
#define CHAN_BADLEN 0xFFFFFFFFFFFFFFF7UL
#define CHAN_FULL 0xFFFFFFFFFFFFFFF6UL
#define CHAN_EMPTY 0xFFFFFFFFFFFFFFF5UL
#define CHAN_NOPEER 0xFFFFFFFFFFFFFFF4UL
#define CHAN_PEERGONE 0xFFFFFFFFFFFFFFF3UL
#define CHAN_TOOBIG 0xFFFFFFFFFFFFFFF2UL

/* --- the protocol. derive.py implements these same five formulas. --------- */

#define PORT 0
#define ROUNDS 4
#define BURST 8 /* == chanRingDepth: exactly enough to fill the ring */
#define MSGMAX 64

/* A spin is bounded so that a broken kernel produces a diagnosis instead of a
 * hung harness. Under `proc coop` the flow below needs at most two iterations
 * of any of these loops, so 64 is a hundred times more slack than it can use --
 * and it also bounds the SERIAL OUTPUT, because a refused `chansend` prints a
 * line and an unbounded retry loop would print thousands. */
#define SPINMAX 64

#define REQLEN(k) (8UL + 13UL * (u64)(k))
#define REPLEN(k) (64UL - REQLEN(k))

static u64 reqbyte(u64 k, u64 i) { return (0x41UL + ((k * 7UL + i * 11UL) % 26UL)) & 0xFFUL; }
static u64 burstbyte(u64 j, u64 i) { return (0xB0UL + 3UL * j + 5UL * i) & 0xFFUL; }

/* THE ROUND-3 REQUEST LIVES IN .rodata, AND THAT IS A POSITIVE CONTROL.
 *
 * Sending OUT OF a read-only user page is legitimate and must work: the kernel
 * only reads it. The other three requests are built in .bss and sent from a
 * writable page, so the harness gets both cases in one boot. `chanOwnsRead`
 * checks the U bit and not the W bit, and this is what proves the difference
 * from `chanOwnsWrite` is deliberate rather than accidental.
 *
 * The bytes are reqbyte(3, i) for i in 0..46, written out so the array is a
 * genuine .rodata initialiser rather than something the program computes at
 * startup into a writable buffer. build-progs.sh asserts its address is inside
 * the R+X PT_LOAD. */
static const u8 roReq[47] = {
    0x56, 0x47, 0x52, 0x43, 0x4E, 0x59, 0x4A, 0x55, 0x46, 0x51, 0x42, 0x4D,
    0x58, 0x49, 0x54, 0x45, 0x50, 0x41, 0x4C, 0x57, 0x48, 0x53, 0x44, 0x4F,
    0x5A, 0x4B, 0x56, 0x47, 0x52, 0x43, 0x4E, 0x59, 0x4A, 0x55, 0x46, 0x51,
    0x42, 0x4D, 0x58, 0x49, 0x54, 0x45, 0x50, 0x41, 0x4C, 0x57, 0x48,
};

/* .data content, so the RW PT_LOAD has a non-zero p_filesz (prog.ld's shape,
 * asserted by build-progs.sh, and the property m10's loader's zero-tail
 * handling depends on).
 *
 * IT IS WRITTEN AND THEN PRINTED, not merely written. A static object that is
 * only ever stored to is DEAD and clang -O2 deletes it outright -- which is how
 * the first build of this program produced an RW segment with p_filesz 0 and
 * failed build-progs.sh. Making the value reach `write` is what keeps the
 * segment real. */
static u8 progTouch[16] = {0x4D, 0x32, 0x30, 0x49, 0x50, 0x43, 0x00, 0x00,
                           0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88};

/* --- the syscall stub ---------------------------------------------------- */

static u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}

static void ipcExit(u64 code) {
  sys3(SYS_EXIT, code, 0, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
static u64 ipcWrite(const void *p, u64 n) { return sys3(SYS_WRITE, (u64)p, n, 0); }
static void ipcYield(void) { sys3(SYS_YIELD, 0, 0, 0); }
static u64 chanopen(u64 port) { return sys3(SYS_CHANOPEN, port, 0, 0); }
static u64 chansend(u64 ep, const void *p, u64 n) { return sys3(SYS_CHANSEND, ep, (u64)p, n); }
static u64 chanrecv(u64 ep, void *p, u64 n) { return sys3(SYS_CHANRECV, ep, (u64)p, n); }

/* --- a very small formatter --------------------------------------------- */

static u8 line[128];
static u64 lineLen;

static void put(const char *s) {
  while (*s != 0) {
    if (lineLen < sizeof(line)) {
      line[lineLen] = (u8)*s;
      lineLen = lineLen + 1;
    }
    s = s + 1;
  }
}

static void putHex(u64 v, u64 digits) {
  static const char hx[] = "0123456789ABCDEF";
  u64 i = digits;
  while (i > 0) {
    i = i - 1;
    if (lineLen < sizeof(line)) {
      line[lineLen] = (u8)hx[(v >> (i * 4)) & 0xF];
      lineLen = lineLen + 1;
    }
  }
}

static void flush(void) {
  if (lineLen > 0) {
    ipcWrite(line, lineLen);
  }
  lineLen = 0;
}

/* --- FNV-1a, 64-bit. derive.py computes the same value on the host. ------ */

#define FNV_OFF 0xCBF29CE484222325UL
#define FNV_PRM 0x00000100000001B3UL

static u64 fold(u64 h, const u8 *p, u64 n) {
  u64 i = 0;
  while (i < n) {
    h = h ^ (u64)p[i];
    h = h * FNV_PRM;
    i = i + 1;
  }
  return h;
}

/* --- buffers, all in .bss (a writable user page) ------------------------- */

static u8 txBuf[MSGMAX];
static u8 rxBuf[MSGMAX];
static u8 probeBuf[MSGMAX];

/* --- bounded spins ------------------------------------------------------- */

/* Retries only on the two answers that mean "not yet": CHAN_NOPEER (the peer
 * has not opened) and CHAN_FULL (the peer has not drained). Anything else --
 * success or a real refusal -- is returned to the caller immediately, so a
 * refusal cannot be silently retried away. */
static u64 spinSend(u64 ep, const void *p, u64 n, u64 *sawNoPeer, u64 *sawFull) {
  u64 s = 0;
  while (s < SPINMAX) {
    u64 r = chansend(ep, p, n);
    if (r == CHAN_NOPEER) {
      *sawNoPeer = *sawNoPeer + 1;
      ipcYield();
    } else if (r == CHAN_FULL) {
      *sawFull = *sawFull + 1;
      ipcYield();
    } else {
      return r;
    }
    s = s + 1;
  }
  return CHAN_FLOOR; /* exhausted: a distinct value no syscall returns */
}

static u64 spinRecv(u64 ep, void *p, u64 n, u64 *sawEmpty) {
  u64 s = 0;
  while (s < SPINMAX) {
    u64 r = chanrecv(ep, p, n);
    if (r == CHAN_EMPTY) {
      *sawEmpty = *sawEmpty + 1;
      ipcYield();
    } else {
      return r;
    }
    s = s + 1;
  }
  return CHAN_FLOOR;
}

/* --- the three roles ----------------------------------------------------- */

/* One refusal check. Prints what it asked for, what it got and what it wanted,
 * so a mismatch is diagnosable from the transcript without rerunning. */
static u64 chk(const char *name, u64 got, u64 want) {
  lineLen = 0;
  put("IPC CHK ");
  put(name);
  put(" GOT ");
  putHex(got, 16);
  put(" WANT ");
  putHex(want, 16);
  flush();
  if (got == want) {
    return 0;
  }
  return 1;
}

/* THE REFUSAL BATTERY. Every one of these is observed FROM RING 3, as a return
 * value, which is the only side of the boundary a program can testify about.
 * None of them changes any channel state, so the conversation continues
 * afterwards -- and the harness checks that it does. */
static u64 battery(u64 ep) {
  u64 bad = 0;
  bad = bad + chk("OPENBADPORT", chanopen(7), CHAN_BADPORT);
  bad = bad + chk("OPENTWICE", chanopen(PORT), CHAN_TWICE);
  bad = bad + chk("SENDBADEP", chansend(99, txBuf, 8), CHAN_BADEP);
  bad = bad + chk("SENDNOTOWNER", chansend(1, txBuf, 8), CHAN_NOTOWNER);
  bad = bad + chk("SENDLEN0", chansend(ep, txBuf, 0), CHAN_BADLEN);
  bad = bad + chk("SENDLEN65", chansend(ep, txBuf, 65), CHAN_BADLEN);
  /* A kernel address, below the program window. The confused-deputy shape. */
  bad = bad + chk("SENDKERNPTR", chansend(ep, (const void *)0x1000UL, 8), CHAN_BADPTR);
  /* THE OVERFLOW PROBE. `ptr + len` overflows a u64. DCDart traps on overflow
   * with a real `ud2`, so a kernel that added before it bounded would take a #UD
   * inside its own syscall handler -- ring 3 choosing which instruction the
   * kernel executes next. chanOwnsRead bounds `ptr` first, so this is a
   * refusal. */
  bad = bad + chk("SENDOVERFLOW", chansend(ep, (const void *)0xFFFFFFFFFFFFFFFFUL, 64),
                  CHAN_BADPTR);
  /* Just past the top of the program window: the last byte is outside. */
  bad = bad + chk("SENDSTRADDLE", chansend(ep, (const void *)0x101FFFFFUL, 8), CHAN_BADPTR);
  /* THE W^X CHECK, AND THE ONE THAT MATTERS MOST. The destination of a receive
   * is a page ring 3 can READ and cannot WRITE. The kernel must refuse rather
   * than write through it from ring 0. */
  bad = bad + chk("RECVROPTR", chanrecv(ep, (void *)roReq, 8), CHAN_BADPTR);
  bad = bad + chk("RECVLEN0", chanrecv(ep, rxBuf, 0), CHAN_BADLEN);
  bad = bad + chk("RECVLEN65", chanrecv(ep, rxBuf, 65), CHAN_BADLEN);
  bad = bad + chk("RECVBADEP", chanrecv(99, rxBuf, 8), CHAN_BADEP);
  bad = bad + chk("RECVNOTOWNER", chanrecv(1, rxBuf, 8), CHAN_NOTOWNER);
  /* And the channel is still healthy: nothing is queued for this side. */
  bad = bad + chk("RECVEMPTY", chanrecv(ep, rxBuf, 64), CHAN_EMPTY);
  return bad;
}

static void requester(u64 ep) {
  u64 bad = 0, hash = FNV_OFF, noPeer = 0, full = 0, empty = 0;
  u64 k = 0;

  while (k < ROUNDS) {
    u64 n = REQLEN(k);
    const u8 *src;
    u64 i = 0;
    while (i < n) {
      txBuf[i] = (u8)reqbyte(k, i);
      i = i + 1;
    }
    /* Round 3 is sent straight out of .rodata. Its bytes are the same formula,
     * so the responder cannot tell the difference and the kernel must not
     * either -- what differs is only that the source page is not writable. */
    if (k == 3) {
      src = roReq;
    } else {
      src = txBuf;
    }
    if (spinSend(ep, src, n, &noPeer, &full) != n) {
      bad = bad + 1;
    }

    u64 r = spinRecv(ep, rxBuf, MSGMAX, &empty);
    if (r != REPLEN(k)) {
      bad = bad + 1;
    } else {
      /* THE REPLY IS CHECKED AGAINST WHAT THIS SIDE SENT, byte for byte. The
       * responder derives its reply from the request it received, so a wrong
       * byte anywhere in either direction lands here. */
      u64 i2 = 0;
      while (i2 < r) {
        u64 want = ((u64)src[i2 % n] + i2 + 1) & 0xFFUL;
        if ((u64)rxBuf[i2] != want) {
          bad = bad + 1;
        }
        i2 = i2 + 1;
      }
      hash = fold(hash, rxBuf, r);
    }
    lineLen = 0;
    put("IPC A ROUND ");
    putHex(k, 1);
    put(" TX ");
    putHex(n, 2);
    put(" RX ");
    putHex(r, 2);
    put(" H ");
    putHex(hash, 16);
    flush();
    k = k + 1;
  }

  bad = bad + battery(ep);

  /* THE BURST. Exactly enough messages to fill the ring, then one more, which
   * must be refused -- and then this process EXITS, having read none of the
   * responses and leaving eight undelivered messages in the kernel. */
  u64 j = 0;
  while (j < BURST) {
    u64 i = 0;
    while (i < MSGMAX) {
      txBuf[i] = (u8)burstbyte(j, i);
      i = i + 1;
    }
    if (chansend(ep, txBuf, MSGMAX) != MSGMAX) {
      bad = bad + 1;
    }
    j = j + 1;
  }
  u64 over = chansend(ep, txBuf, MSGMAX);
  bad = bad + chk("SENDFULL", over, CHAN_FULL);

  lineLen = 0;
  put("IPC A DONE EP ");
  putHex(ep, 2);
  put(" NOPEER ");
  putHex(noPeer, 2);
  put(" FULL ");
  putHex(full, 2);
  put(" EMPTY ");
  putHex(empty, 2);
  put(" BAD ");
  putHex(bad, 4);
  flush();
  lineLen = 0;
  put("IPC A HASH ");
  putHex(hash, 16);
  flush();

  if (bad > 0) {
    ipcExit(0xDEAD000000000000UL | bad);
  }
  ipcExit(hash);
}

static void responder(u64 ep) {
  u64 bad = 0, hash = FNV_OFF, noPeer = 0, full = 0, empty = 0;
  u64 k = 0;

  while (k < ROUNDS) {
    u64 r = spinRecv(ep, rxBuf, MSGMAX, &empty);
    if (r != REQLEN(k)) {
      bad = bad + 1;
    } else {
      u64 i = 0;
      while (i < r) {
        if ((u64)rxBuf[i] != reqbyte(k, i)) {
          bad = bad + 1;
        }
        i = i + 1;
      }
      hash = fold(hash, rxBuf, r);
      /* THE REPLY IS DERIVED FROM THE BYTES THAT ARRIVED, not from k. A kernel
       * that delivered the wrong message would make this side compute a reply
       * the requester then rejects -- so one wrong byte fails on BOTH sides. */
      u64 m = REPLEN(k), i2 = 0;
      while (i2 < m) {
        txBuf[i2] = (u8)(((u64)rxBuf[i2 % r] + i2 + 1) & 0xFFUL);
        i2 = i2 + 1;
      }
      if (spinSend(ep, txBuf, m, &noPeer, &full) != m) {
        bad = bad + 1;
      }
    }
    lineLen = 0;
    put("IPC B ROUND ");
    putHex(k, 1);
    put(" RX ");
    putHex(r, 2);
    put(" H ");
    putHex(hash, 16);
    flush();
    k = k + 1;
  }

  /* WAIT FOR THE BURST WITHOUT CONSUMING ANY OF IT.
   *
   * A receive with a buffer too small for the queued message returns
   * CHAN_TOOBIG and LEAVES THE MESSAGE WHERE IT IS -- so this loop is both a
   * non-destructive "is anything there yet" probe and the test of that
   * property. On an empty ring it gets CHAN_EMPTY and yields; the first
   * 64-byte message that arrives turns it into CHAN_TOOBIG. */
  u64 probe = CHAN_FLOOR, s = 0;
  while (s < SPINMAX) {
    u64 r = chanrecv(ep, probeBuf, 8);
    if (r == CHAN_EMPTY) {
      empty = empty + 1;
      ipcYield();
    } else {
      probe = r;
      break;
    }
    s = s + 1;
  }
  bad = bad + chk("RECVTOOBIG", probe, CHAN_TOOBIG);

  /* AND NOW DRAIN EIGHT MESSAGES FROM A PEER THAT HAS ALREADY EXITED. They
   * were copied into kernel memory when they were sent; the sender's death
   * does not unsend them. Every byte is checked. */
  u64 j = 0;
  while (j < BURST) {
    u64 r = spinRecv(ep, rxBuf, MSGMAX, &empty);
    if (r != MSGMAX) {
      bad = bad + 1;
    } else {
      u64 i = 0;
      while (i < MSGMAX) {
        if ((u64)rxBuf[i] != burstbyte(j, i)) {
          bad = bad + 1;
        }
        i = i + 1;
      }
      hash = fold(hash, rxBuf, r);
    }
    lineLen = 0;
    put("IPC B BURST ");
    putHex(j, 1);
    put(" RX ");
    putHex(r, 2);
    put(" H ");
    putHex(hash, 16);
    flush();
    j = j + 1;
  }

  /* DRAINED, AND ONLY NOW IS THE PEER REPORTED GONE. Both directions say so. */
  bad = bad + chk("RECVGONE", chanrecv(ep, rxBuf, MSGMAX), CHAN_PEERGONE);
  bad = bad + chk("SENDGONE", chansend(ep, txBuf, 8), CHAN_PEERGONE);

  lineLen = 0;
  put("IPC B DONE EP ");
  putHex(ep, 2);
  put(" NOPEER ");
  putHex(noPeer, 2);
  put(" FULL ");
  putHex(full, 2);
  put(" EMPTY ");
  putHex(empty, 2);
  put(" BAD ");
  putHex(bad, 4);
  flush();
  lineLen = 0;
  put("IPC B HASH ");
  putHex(hash, 16);
  flush();

  if (bad > 0) {
    ipcExit(0xDEAD000000000000UL | bad);
  }
  ipcExit(hash);
}

/* THE NEGATIVE CONTROL. Reached when this binary is started with `run <lba>`
 * rather than `proc coop`: it is then an M10-style program in ring 3 with an
 * address space and no process slot, and an endpoint is owned by a PROCESS ID.
 * All three syscalls must refuse it by name. GAP-0204. */
static void noproc(void) {
  u64 bad = 0;
  bad = bad + chk("NPSEND", chansend(0, txBuf, 8), CHAN_NOPROC);
  bad = bad + chk("NPRECV", chanrecv(0, rxBuf, 8), CHAN_NOPROC);
  lineLen = 0;
  put("IPC NOPROC BAD ");
  putHex(bad, 4);
  flush();
  if (bad > 0) {
    ipcExit(0xDEAD000000000000UL | bad);
  }
  ipcExit(0x4E4F50524F43UL); /* "NOPROC" */
}

void _start(void) {
  lineLen = 0;
  u64 ep = chanopen(PORT);

  /* KEEP .data ALIVE, AND THE INDEX HAS TO BE OPAQUE.
   *
   * `progTouch[6] = progTouch[0] ^ progTouch[8]` is NOT enough: clang -O2
   * constant-folds both loads, prints the folded byte, and deletes the array --
   * which is exactly what the first build of this program did, producing an RW
   * segment with p_filesz 0. Indexing with a value that came back from a
   * SYSCALL forces a real load out of the initialised object, so the object has
   * to exist and `.data` has to be non-empty. */
  progTouch[6] = (u8)(progTouch[ep & 7UL] ^ progTouch[8]);


  lineLen = 0;
  put("IPC OPEN R ");
  putHex(ep, 16);
  put(" T ");
  putHex((u64)progTouch[6], 2);
  flush();

  if (ep == CHAN_NOPROC) {
    noproc();
  }
  if (ep >= CHAN_FLOOR) {
    ipcExit(0xDEAD000000000000UL | 0xFFUL);
  }
  if ((ep & 1UL) == 0UL) {
    requester(ep);
  }
  responder(ep);
}
