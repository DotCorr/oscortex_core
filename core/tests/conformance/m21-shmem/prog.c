/* core/tests/conformance/m21-shmem/prog.c
 *
 * M21's test program. ONE SOURCE, BUILT ONCE, WRITTEN TO TWO DISK SLOTS.
 *
 * WHY IT IS ONE PROGRAM AND NOT TWO
 * ---------------------------------------------------------------------------
 * `make-image.py` writes the SAME BYTES to both slots and refuses to build an
 * image where they differ. Which process becomes the PRODUCER and which the
 * CONSUMER is decided ENTIRELY by which one `chanopen` answers first. So "one
 * process wrote a page and the other read it" is a claim about the KERNEL and
 * not about two different programs -- M20's discipline, and M19's before it.
 *
 * THE TWO ROLES
 * ---------------------------------------------------------------------------
 *   side 0 -- the PRODUCER. Creates a shared region, fills it with a pattern
 *             `derive.py` computes independently on the host, grants a
 *             READ-ONLY capability to its channel peer, and sends the peer the
 *             64-BYTE FRAME DESCRIPTOR that names it. Then it holds, so that
 *             both address spaces are simultaneously live and mapped while the
 *             harness walks them out of guest physical memory. Then it exits --
 *             BEFORE ITS PEER HAS FINISHED WITH THE REGION.
 *   side 1 -- the CONSUMER. Receives the descriptor, maps the region READ-ONLY,
 *             hashes every byte, acknowledges, and then WAITS FOR ITS PEER TO
 *             DIE and hashes every byte AGAIN. The second hash is the one that
 *             proves a region outlives its creator.
 *
 * THE MECHANISMS COMPOSE AND NEITHER OF THEM CHANGED. The descriptor is 8 x u64
 * = exactly 64 bytes, which is `chanMsgBytes` (ADR-0027 §2.3 promised this fits
 * and that `chan.dart` would not have to change; it did not). The message
 * carries the NAME of the region. The AUTHORITY was installed by `shmgrant`,
 * in the peer's own capability table, by the kernel. A forged descriptor
 * reaches nothing, and this program proves that by sending itself one.
 *
 * EVERY NUMBER THIS PROGRAM EXITS WITH IS DERIVED FROM BYTES IT ACTUALLY READ
 * THROUGH THE SHARED MAPPING. A kernel that mapped the wrong frame, mapped a
 * zero page, or gave the right bytes to the wrong side produces a different
 * 64-bit number and the harness fails.
 *
 * Freestanding: no libc. `proc coop` enters at e_entry with an EMPTY STACK and
 * no argv (GAP-0149), so this file defines its own entry point.
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
#define SYS_SHMCREATE 16
#define SYS_SHMGRANT 17
#define SYS_SHMMAP 18
#define SYS_SHMDROP 19

/* core/kernel/chan.dart's return values, copied rather than included because
 * this program is freestanding; run.sh reads BOTH copies and requires them to
 * agree, which is the check that makes a private copy safe. */
#define CHAN_FLOOR 0xFFFFFFFFFFFFFF00UL
#define CHAN_NOPEER 0xFFFFFFFFFFFFFFF4UL
#define CHAN_PEERGONE 0xFFFFFFFFFFFFFFF3UL
#define CHAN_EMPTY 0xFFFFFFFFFFFFFFF5UL
#define CHAN_FULL 0xFFFFFFFFFFFFFFF6UL

/* core/kernel/shm.dart's return values. Same rule: run.sh requires every one of
 * these to equal the kernel's `shmRet*` constant of the same name, and requires
 * the kernel to declare no refusal this program has not been taught. */
#define SHM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define SHM_NOPROC 0xFFFFFFFFFFFFFFFEUL
#define SHM_BADLEN 0xFFFFFFFFFFFFFFFDUL
#define SHM_NOSPACE 0xFFFFFFFFFFFFFFFCUL
#define SHM_NOMEM 0xFFFFFFFFFFFFFFFBUL
#define SHM_NOCAP 0xFFFFFFFFFFFFFFFAUL
#define SHM_BADCAP 0xFFFFFFFFFFFFFFF9UL
#define SHM_STALE 0xFFFFFFFFFFFFFFF8UL
#define SHM_BADEP 0xFFFFFFFFFFFFFFF7UL
#define SHM_NOPEER2 0xFFFFFFFFFFFFFFF6UL
#define SHM_TWICE 0xFFFFFFFFFFFFFFF5UL
#define SHM_MAPPED 0xFFFFFFFFFFFFFFF4UL
#define SHM_EXEC 0xFFFFFFFFFFFFFFF3UL
#define SHM_BADPERM 0xFFFFFFFFFFFFFFF2UL
#define SHM_NOTABLE 0xFFFFFFFFFFFFFFF1UL
#define SHM_MAPFAIL 0xFFFFFFFFFFFFFFF0UL

/* Permission words, as shm.dart defines them. */
#define SHM_R 1UL
#define SHM_W 2UL
#define SHM_X 4UL
#define SHM_RO 1UL
#define SHM_RW 3UL

/* --- the protocol. derive.py implements these same formulas. ------------- */

#define PORT 0
#define PAGES 4UL
#define PAGEB 4096UL
#define MSGMAX 64
#define SPINMAX 4096

/* The hold: how many yields side 0 spins with the region mapped in BOTH address
 * spaces before it exits. Bounded, so a broken kernel produces a diagnosis
 * rather than a hung harness, and long enough that the harness's monitor dump
 * lands inside it. run.sh reads this constant out of this file. */
#define HOLDSPIN 300000000UL

/* The consumer's wait for its peer to die.
 *
 * Small on purpose, and it is safe BECAUSE the hold above does not yield. The
 * consumer is suspended inside `yield` for the whole of the producer's hold and
 * is not running at all; it resumes only when the producer EXITS, and the very
 * next `chanrecv` it makes then returns CHAN_PEERGONE. So this bound is not a
 * timeout waiting out a hold -- it is slack around a scheduler handoff, and
 * every iteration of it that executes prints a `PROC YIELD` line the harness
 * would have to read. */
#define WAITSPIN 64UL

/* The byte at page `p`, offset `i`. derive.py computes the same function.
 * Deliberately depends on BOTH the page and the offset, so a kernel that mapped
 * the right number of pages in the wrong order, or mapped one page four times,
 * produces a different hash. */
static u64 patbyte(u64 p, u64 i) {
  return (0x5AUL + p * 31UL + i * 17UL + ((i >> 4) * 7UL)) & 0xFFUL;
}

/* Frame-descriptor word indices. Eight u64 = 64 bytes = chanMsgBytes exactly.
 * This is the shape ADR-0027 §2.3 said a compositor's descriptor would be. */
#define D_MAGIC 0
#define D_HANDLE 1
#define D_PAGES 2
#define D_STRIDE 3
#define D_WIDTH 4
#define D_HEIGHT 5
#define D_SEQ 6
#define D_SUM 7
#define DESC_MAGIC 0x4D3231534D454D31UL /* "M21SMEM1" */

/* --- the syscall stub ---------------------------------------------------- */

static u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}

static void shmExit(u64 code) {
  sys3(SYS_EXIT, code, 0, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
static u64 shmWrite(const void *p, u64 n) { return sys3(SYS_WRITE, (u64)p, n, 0); }
static void shmYield(void) { sys3(SYS_YIELD, 0, 0, 0); }
static u64 chanopen(u64 port) { return sys3(SYS_CHANOPEN, port, 0, 0); }
static u64 chansend(u64 ep, const void *p, u64 n) { return sys3(SYS_CHANSEND, ep, (u64)p, n); }
static u64 chanrecv(u64 ep, void *p, u64 n) { return sys3(SYS_CHANRECV, ep, (u64)p, n); }
static u64 shmcreate(u64 pages) { return sys3(SYS_SHMCREATE, pages, 0, 0); }
static u64 shmgrant(u64 ep, u64 h) { return sys3(SYS_SHMGRANT, ep, h, 0); }
static u64 shmmap(u64 h, u64 perms) { return sys3(SYS_SHMMAP, h, perms, 0); }
static u64 shmdrop(u64 h) { return sys3(SYS_SHMDROP, h, 0, 0); }

/* --- a very small formatter ---------------------------------------------- */

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
    shmWrite(line, lineLen);
  }
  lineLen = 0;
}

/* --- FNV-1a, 64-bit. derive.py computes the same value on the host. ------ */

#define FNV_OFF 0xCBF29CE484222325UL
#define FNV_PRM 0x00000100000001B3UL

static u64 fold1(u64 h, u64 b) {
  h = h ^ (b & 0xFFUL);
  return h * FNV_PRM;
}

/* --- buffers, all in .bss (a writable user page) ------------------------- */

static u64 txDesc[8];
static u64 rxDesc[8];
static u8 ackBuf[MSGMAX];

/* .data content, so the RW PT_LOAD has a non-zero p_filesz (prog.ld's shape,
 * asserted by build-progs.sh). It is written AND PRINTED -- a static that is
 * only ever stored to is dead and clang -O2 deletes it outright. */
static u8 progTouch[16] = {0x4D, 0x32, 0x31, 0x53, 0x48, 0x4D, 0x00, 0x00,
                           0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88};

/* Counts every refusal this program OBSERVED with the value it expected. The
 * harness requires the exact number, so a control that silently stopped being
 * refused fails the build rather than passing quietly. */
static u64 controls;

static void expect(const char *name, u64 got, u64 want) {
  put(" M21 CTL ");
  put(name);
  put(" R ");
  putHex(got, 16);
  if (got == want) {
    put(" OK");
    controls = controls + 1;
  } else {
    put(" BAD WANT ");
    putHex(want, 16);
  }
  put("\n");
  flush();
}

/* ------------------------------------------------------------------------- */
/* SIDE 0 -- THE PRODUCER.                                                    */
/* ------------------------------------------------------------------------- */

static void producer(u64 ep) {
  u64 i, p, s;

  /* 1. Create the region. It comes back mapped READ-WRITE, at an address the
   *    KERNEL chose -- this program never proposes one. */
  u64 h = shmcreate(PAGES);
  if (h >= SHM_FLOOR) {
    put(" M21 P CREATE FAILED R ");
    putHex(h, 16);
    put("\n");
    flush();
    shmExit(1);
  }
  u64 va = 0;

  /* 2. Map is implicit in create, and `shmmap` on the creator's own handle must
   *    therefore be refused: it is already mapped here. A control, and it is
   *    also how this side learns the address without a second syscall --
   *    `shmcreate` returned a HANDLE, not an address, so the address comes from
   *    the descriptor formula below. */
  expect("REMAP", shmmap(h, SHM_RO), SHM_MAPPED);

  /* The region's address. The kernel prints it and the harness reads it from
   * the transcript; this program derives it the same way `shmRegionVa` does,
   * from the base and the slot, and the two are required to agree. */
  va = 0x10200000UL;

  /* 3. Fill it. Every byte depends on its page AND its offset. */
  for (p = 0; p < PAGES; p++) {
    volatile u8 *page = (volatile u8 *)(va + p * PAGEB);
    for (i = 0; i < PAGEB; i++) {
      page[i] = (u8)patbyte(p, i);
    }
  }

  /* 4. Hash what was written, so the two sides' exit codes are DIFFERENT
   *    numbers derived from the same bytes -- one exit status cannot satisfy
   *    both checks. The producer folds in a role tag. */
  u64 hash = FNV_OFF;
  hash = fold1(hash, 'P');
  for (p = 0; p < PAGES; p++) {
    volatile u8 *page = (volatile u8 *)(va + p * PAGEB);
    for (i = 0; i < PAGEB; i++) {
      hash = fold1(hash, page[i]);
    }
  }

  /* 5. Wait for the peer to open its end, then GRANT. */
  u64 ph = 0;
  for (s = 0; s < SPINMAX; s++) {
    ph = shmgrant(ep, h);
    if (ph != SHM_NOPEER2) {
      break;
    }
    shmYield();
  }
  if (ph >= SHM_FLOOR) {
    put(" M21 P GRANT FAILED R ");
    putHex(ph, 16);
    put("\n");
    flush();
    shmExit(2);
  }
  put(" M21 P GRANTED PH ");
  putHex(ph, 16);
  put(" VA ");
  putHex(va, 16);
  put("\n");
  flush();

  /* 6. NEGATIVE CONTROLS, from ring 3, as return values.
   *
   *    A FORGED HANDLE. Index 3 of this process's own capability table has
   *    never been filled, so this names nothing however plausible the number
   *    looks. This is the shape a forgery actually takes. */
  expect("FORGE_GRANT", shmgrant(ep, (3UL << 32) | 0xDEADBEEFUL), SHM_BADCAP);
  /*    A handle whose INDEX is valid and whose GENERATION is not. */
  expect("STALEGEN", shmgrant(ep, (h & ~0xFFFFFFFFUL) | 0x1234UL), SHM_STALE);
  /*    An endpoint this process does not own. */
  expect("BADEP", shmgrant(9UL, h), SHM_BADEP);
  /*    Granting the same region to the same peer twice. */
  expect("TWICE", shmgrant(ep, h), SHM_TWICE);
  /*    OUT-OF-RANGE LENGTHS, both ends. */
  expect("LEN0", shmcreate(0), SHM_BADLEN);
  expect("LENBIG", shmcreate(257UL), SHM_BADLEN);
  expect("LENHUGE", shmcreate(0xFFFFFFFFFFFFFFFFUL), SHM_BADLEN);

  /* 7. Send the FRAME DESCRIPTOR. Eight u64, 64 bytes, on M20's channel,
   *    unmodified. */
  txDesc[D_MAGIC] = DESC_MAGIC;
  txDesc[D_HANDLE] = ph;
  txDesc[D_PAGES] = PAGES;
  txDesc[D_STRIDE] = PAGEB;
  txDesc[D_WIDTH] = 1024;
  txDesc[D_HEIGHT] = PAGES * 4;
  txDesc[D_SEQ] = 1;
  txDesc[D_SUM] = hash;
  u64 sr = 0;
  for (s = 0; s < SPINMAX; s++) {
    sr = chansend(ep, txDesc, 64);
    if (sr != CHAN_FULL) {
      break;
    }
    shmYield();
  }
  if (sr != 64) {
    put(" M21 P SEND FAILED R ");
    putHex(sr, 16);
    put("\n");
    flush();
    shmExit(3);
  }

  /* 8. Wait for the consumer's ACK -- so that the hold below begins only once
   *    the region is mapped in BOTH address spaces. */
  u64 rr = CHAN_EMPTY;
  for (s = 0; s < SPINMAX; s++) {
    rr = chanrecv(ep, ackBuf, MSGMAX);
    if (rr != CHAN_EMPTY) {
      break;
    }
    shmYield();
  }
  put(" M21 P ACK R ");
  putHex(rr, 16);
  put(" CTLS ");
  putHex(controls, 4);
  put("\n");
  flush();

  /* 9. THE HOLD. Both processes are now alive and both map the region, and the
   *    harness dumps guest physical memory during this window and walks BOTH
   *    address spaces out of it.
   *
   *    A BUSY SPIN, NOT A YIELD LOOP, AND THE DIFFERENCE IS NOT PERFORMANCE.
   *    `proc.dart` prints `PROC YIELD a -> b SWITCHES n` on EVERY yield, so a
   *    hold long enough to dump memory in would have emitted hundreds of
   *    thousands of serial lines and buried the transcript this harness reads.
   *    It is also the state the dump actually wants: under `proc coop` nothing
   *    preempts, so the producer stays on the CPU with its own CR3 loaded while
   *    the consumer sits suspended inside `yield` with its address space fully
   *    built -- which is exactly m12-heap's "progH parked at a `jmp .` with
   *    progP suspended in a `yield`" (ADR-0022 §2), reached the same way.
   *
   *    `volatile` so -O2 cannot delete a loop with no effect, and BOUNDED so a
   *    broken kernel produces a diagnosis rather than a hung harness. */
  put(" M21 P HOLD\n");
  flush();
  {
    volatile u64 spin = 0;
    while (spin < HOLDSPIN) {
      spin = spin + 1;
    }
  }

  /* 10. And exit, WITH THE CONSUMER STILL HOLDING A CAPABILITY. The region's
   *     frames must survive this. */
  put(" M21 P EXIT H ");
  putHex(hash, 16);
  put("\n");
  flush();
  shmWrite(progTouch, sizeof(progTouch));
  shmExit(hash);
}

/* ------------------------------------------------------------------------- */
/* SIDE 1 -- THE CONSUMER.                                                    */
/* ------------------------------------------------------------------------- */

static u64 hashRegion(u64 va, u64 tag) {
  u64 h = FNV_OFF;
  u64 p, i;
  h = fold1(h, tag);
  for (p = 0; p < PAGES; p++) {
    volatile const u8 *page = (volatile const u8 *)(va + p * PAGEB);
    for (i = 0; i < PAGEB; i++) {
      h = fold1(h, page[i]);
    }
  }
  return h;
}

static void consumer(u64 ep) {
  u64 s;

  /* 1. Receive the frame descriptor. */
  u64 rr = CHAN_EMPTY;
  for (s = 0; s < SPINMAX; s++) {
    rr = chanrecv(ep, rxDesc, MSGMAX);
    if (rr != CHAN_EMPTY) {
      break;
    }
    shmYield();
  }
  if (rr != 64) {
    put(" M21 C RECV FAILED R ");
    putHex(rr, 16);
    put("\n");
    flush();
    shmExit(4);
  }
  if (rxDesc[D_MAGIC] != DESC_MAGIC) {
    put(" M21 C BAD MAGIC\n");
    flush();
    shmExit(5);
  }
  u64 ph = rxDesc[D_HANDLE];

  /* 2. NEGATIVE CONTROLS THAT MUST FAIL, BEFORE THE ONE THAT MUST WORK.
   *
   *    W^X. An executable shared page is a code-injection channel between two
   *    processes and this kernel has no way to ask for one: `vmShmMap` has no
   *    `exec` parameter and sets NX unconditionally. The REQUEST is refused by
   *    name so that ring 3 is told rather than quietly given something else. */
  expect("EXEC", shmmap(ph, SHM_R | SHM_X), SHM_EXEC);
  expect("EXEC_RW", shmmap(ph, SHM_RW | SHM_X), SHM_EXEC);
  /*    A READ-ONLY capability asking to be mapped WRITABLE. Privilege
   *    escalation expressed as an argument.
   *
   *    AND IT IS ALSO THE HANDLE-COLLISION EXPERIMENT. Both processes' handles
   *    are index 0 with the same generation, so `ph` here is NUMERICALLY THE
   *    SAME 64-BIT VALUE the producer holds -- and the producer's is
   *    read-write. If a handle were a global name, this call would succeed and
   *    hand a second writer a writable mapping. It is refused, because the
   *    number is an index into THIS process's table and that entry says
   *    read-only. That is what "a capability cannot be forged" means here, and
   *    it is why the claim does not rest on the number being hard to guess:
   *    the consumer KNOWS the number and still cannot widen it. */
  expect("ESCALATE", shmmap(ph, SHM_RW), SHM_BADPERM);
  /*    A permission word that is not one of the two legal ones. */
  expect("PERM0", shmmap(ph, 0), SHM_BADPERM);
  expect("PERM_W", shmmap(ph, SHM_W), SHM_BADPERM);
  /*    A FORGED HANDLE -- an index into THIS process's own capability table
   *    that the kernel never filled. Guessing cannot manufacture authority. */
  expect("FORGE_MAP", shmmap((2UL << 32) | 0x1234UL, SHM_RO), SHM_BADCAP);
  expect("FORGE_IDX", shmmap((99UL << 32), SHM_RO), SHM_BADCAP);
  expect("FORGE_DROP", shmdrop((3UL << 32) | 0xABCDUL), SHM_BADCAP);
  /*    Index 1 of this process's own table, which the kernel never filled.
   *    Every index this program has not been GRANTED is empty, whatever number
   *    is put in front of it. */
  expect("FORGE_IDX1", shmmap((1UL << 32), SHM_RO), SHM_BADCAP);

  /* 3. THE ONE THAT MUST WORK. */
  u64 va = shmmap(ph, SHM_RO);
  if (va >= SHM_FLOOR) {
    put(" M21 C MAP FAILED R ");
    putHex(va, 16);
    put("\n");
    flush();
    shmExit(6);
  }
  put(" M21 C MAPPED VA ");
  putHex(va, 16);
  put("\n");
  flush();
  /*    And a second map of the SAME capability is refused. */
  expect("REMAP", shmmap(ph, SHM_RO), SHM_MAPPED);

  /* 4. Read every byte through the shared mapping and hash it. */
  u64 h1 = hashRegion(va, 'C');

  /* 5. Acknowledge, so the producer knows both address spaces now map the
   *    region and can begin its hold. */
  ackBuf[0] = 'A';
  ackBuf[1] = 'C';
  ackBuf[2] = 'K';
  u64 sr = 0;
  for (s = 0; s < SPINMAX; s++) {
    sr = chansend(ep, ackBuf, 3);
    if (sr != CHAN_FULL) {
      break;
    }
    shmYield();
  }

  /* 6. WAIT FOR THE PRODUCER TO DIE.
   *
   *    `chanrecv` drains first and only then reports CHAN_PEERGONE (ADR-0027
   *    §5), so this is the kernel telling this process that the region's
   *    CREATOR HAS EXITED. */
  u64 gone = 0;
  for (s = 0; s < WAITSPIN; s++) {
    u64 r = chanrecv(ep, ackBuf, MSGMAX);
    if (r == CHAN_PEERGONE) {
      gone = 1;
      break;
    }
    shmYield();
  }
  put(" M21 C PEERGONE ");
  putHex(gone, 1);
  put("\n");
  flush();

  /* 7. AND READ THE WHOLE REGION AGAIN, WITH ITS CREATOR DEAD.
   *
   *    This is the assertion the milestone exists for. The producer's address
   *    space has been torn down -- `procSpaceFree` walked its page table and
   *    handed every present leaf to `freeFrame` -- and these frames are still
   *    here, still mapped, still holding the producer's bytes, because
   *    `freeFrame` consulted the shared bit-plane and declined. If the frames
   *    had been released and reused, this hash differs. */
  u64 h2 = hashRegion(va, 'C');
  if (h2 != h1) {
    put(" M21 C CONTENTS CHANGED AFTER PEER DEATH H1 ");
    putHex(h1, 16);
    put(" H2 ");
    putHex(h2, 16);
    put("\n");
    flush();
    shmExit(7);
  }
  put(" M21 C SURVIVED H ");
  putHex(h2, 16);
  put(" CTLS ");
  putHex(controls, 4);
  put("\n");
  flush();

#ifdef M21_ROFAULT
  /* THE STORE THAT MUST FAULT. Built only into the second binary, because it
   * kills this process and the exit code carrying the hash is lost with it --
   * which is exactly why the hash is PRINTED above rather than only returned.
   *
   * `W 0` in a page table and "a store actually faults" are the same claim only
   * if CR0.WP and the ring-3 boundary behave as M8 and M9 established. They are
   * separately tested, but M21 is the milestone that introduces a page ring 3
   * can REACH and must not WRITE, so the demonstration belongs here.
   *
   * TWO-SIDED, which is the point. If the mapping is read-only the CPU raises
   * #PF with error 0x7 (present, write, user) and the line below never prints.
   * If M21 ever maps a grantee writable, the store SUCCEEDS, the line prints,
   * and the harness fails on its presence -- so this control cannot pass by
   * accident in either direction. */
  put(" M21 C ROSTORE VA ");
  putHex(va, 16);
  put("\n");
  flush();
  {
    volatile u8 *ro = (volatile u8 *)va;
    ro[0] = 0xFF;
  }
  put(" M21 C ROSTORE SURVIVED -- THE SHARED MAPPING IS WRITABLE\n");
  flush();
  shmExit(0xBAD);
#endif

  /* 8. Drop the capability. This is the LAST one naming the region, so the
   *    kernel destroys it here and the frames go back to the allocator -- which
   *    is the line the harness brackets the `frames` count around. */
  u64 dr = shmdrop(ph);
  put(" M21 C DROP R ");
  putHex(dr, 16);
  put("\n");
  flush();
  /*    And the handle is now stale: the capability slot is empty. */
  expect("AFTERDROP", shmmap(ph, SHM_RO), SHM_BADCAP);
  expect("DROPTWICE", shmdrop(ph), SHM_BADCAP);

  put(" M21 C EXIT H ");
  putHex(h2, 16);
  put(" CTLS ");
  putHex(controls, 4);
  put("\n");
  flush();
  shmWrite(progTouch, sizeof(progTouch));
  shmExit(h2);
}

/* ------------------------------------------------------------------------- */

void _start(void) {
  u64 ep = chanopen(PORT);
  if (ep >= CHAN_FLOOR) {
    /* No process slot. Every shm syscall must refuse such a caller -- a
     * capability table IS slot storage and this thing has no slot.
     *
     * CURRENTLY UNREACHABLE, AND KEPT ANYWAY. This branch used to be entered by
     * starting the same binary with `run <lba>`, which was an M10-style load
     * with no process slot. ADR-0034 unified the launch path so `run` goes
     * through `procCreate`, so nothing the shell can start lands here any more
     * and `chanopen` always succeeds. GAP-0239 records that, in GAP-0214's
     * category: the kernel guard is LIVE and REACHABLE (an M9-style `user`
     * payload would hit it), it is this harness that can no longer reach it.
     * The code stays so that the day a no-slot payload exists, the test does
     * too. */
    put(" M21 NOPROC CHAN ");
    putHex(ep, 16);
    put("\n");
    flush();
    expect("NP_CREATE", shmcreate(PAGES), SHM_NOPROC);
    expect("NP_GRANT", shmgrant(0, 0), SHM_NOPROC);
    expect("NP_MAP", shmmap(0, SHM_RO), SHM_NOPROC);
    expect("NP_DROP", shmdrop(0), SHM_NOPROC);
    shmWrite(progTouch, sizeof(progTouch));
    shmExit(controls);
  }
  if (ep == 0) {
    producer(ep);
  }
  consumer(ep);
}
