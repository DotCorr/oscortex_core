/* core/tests/conformance/shm-multi/prog.c
 *
 * ADR-0158 — multi-mapper grow and shrink on one shm.
 * One binary, two roles (m21 discipline). Producer creates, grants,
 * grows while the peer is mapped, fills new pages; peer reads them
 * RO. Then producer shrinks; peer probes a freed page (must #PF).
 * A grow that only updates the owner's CR3 fails the peer read.
 * A shrink that leaves the peer mapped fails STILL MAPPED.
 */

typedef unsigned long u64;
typedef unsigned char u8;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_CHANOPEN 13
#define SYS_CHANSEND 14
#define SYS_CHANRECV 15
#define SYS_SHMCREATE 16
#define SYS_SHMGRANT 17
#define SYS_SHMMAP 18
#define SYS_SHMGROW 34
#define SYS_SHMSHRINK 35

#define CHAN_FLOOR 0xFFFFFFFFFFFFFF00UL
#define CHAN_EMPTY 0xFFFFFFFFFFFFFFF5UL
#define CHAN_FULL 0xFFFFFFFFFFFFFFF6UL
#define CHAN_NOPEER 0xFFFFFFFFFFFFFFF4UL

#define SHM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define SHM_NOPEER2 0xFFFFFFFFFFFFFFF6UL
#define SHM_RO 1UL

#define PORT 0
#define PAGEB 4096UL
#define VA0 0x10200000UL
#define OLD_PAGES 3UL
#define GROW_PAGES 6UL
#define SHRINK_PAGES 2UL
#define MARK0 0xA5UL
#define MARK_NEW 0x5AUL
#define MSGMAX 64
#define SPINMAX 4096
#define YIELD_AFTER_SHRINK 64UL

#define ACK_MAPPED 1UL
#define ACK_GROWN 2UL
#define ACK_PEER 3UL
#define ACK_SHRUNK 4UL

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}
static inline u64 sys2(u64 n, u64 a, u64 b) { return sys3(n, a, b, 0); }
static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }
static inline void yield(void) { sys3(SYS_YIELD, 0, 0, 0); }

static void wr(const char *s, u64 n) { sys2(SYS_WRITE, (u64)s, n); }

__attribute__((noreturn)) static void die(u64 code) {
  sys1(SYS_EXIT, code);
  for (;;) {
  }
}

static char line[96];
static u64 msg[8] __attribute__((aligned(8)));
static u64 rxw[8] __attribute__((aligned(8)));

static unsigned put(unsigned at, const char *s) {
  while (*s) {
    line[at++] = *s++;
  }
  return at;
}

static unsigned puthex(unsigned at, u64 v, unsigned digits) {
  static const char D[] = "0123456789ABCDEF";
  unsigned i = digits;
  while (i--) {
    line[at++] = D[(v >> (i * 4)) & 0xF];
  }
  return at;
}

static void emit(unsigned n) { wr(line, n); }

static void fill_page(u64 va, u64 page, u8 mark) {
  volatile u8 *p = (volatile u8 *)(va + page * PAGEB);
  u64 i;
  for (i = 0; i < PAGEB; i++) {
    p[i] = mark;
  }
}

static int check_page(u64 va, u64 page, u8 mark) {
  volatile u8 *p = (volatile u8 *)(va + page * PAGEB);
  u64 i;
  for (i = 0; i < PAGEB; i++) {
    if (p[i] != mark) {
      return 0;
    }
  }
  return 1;
}

static u64 send_ack(u64 ep, u64 tag) {
  u64 s;
  u64 r;
  msg[0] = tag;
  for (s = 0; s < SPINMAX; s++) {
    r = sys3(SYS_CHANSEND, ep, (u64)&msg[0], 8);
    if (r != CHAN_FULL) {
      return r;
    }
    yield();
  }
  return CHAN_FULL;
}

static u64 recv_ack(u64 ep, u64 want) {
  u64 s;
  u64 r;
  for (s = 0; s < SPINMAX; s++) {
    r = sys3(SYS_CHANRECV, ep, (u64)&rxw[0], MSGMAX);
    if (r != CHAN_EMPTY) {
      if (r >= 8 && rxw[0] == want) {
        return 0;
      }
      return 1;
    }
    yield();
  }
  return 2;
}

static void producer(u64 ep) {
  u64 h;
  u64 ph;
  u64 r;
  u64 va;
  u64 i;
  u64 s;
  unsigned at;
  volatile u8 *probe;

  h = sys1(SYS_SHMCREATE, OLD_PAGES);
  if (h >= SHM_FLOOR) {
    at = put(0, "MULTI CREATE FAIL ");
    at = puthex(at, h & 0xFFUL, 2);
    emit(at);
    die(1);
  }
  va = VA0;
  for (i = 0; i < OLD_PAGES; i++) {
    fill_page(va, i, (u8)MARK0);
  }

  ph = SHM_NOPEER2;
  for (s = 0; s < SPINMAX; s++) {
    ph = sys2(SYS_SHMGRANT, ep, h);
    if (ph != SHM_NOPEER2) {
      break;
    }
    yield();
  }
  if (ph >= SHM_FLOOR) {
    at = put(0, "MULTI GRANT FAIL ");
    at = puthex(at, ph & 0xFFUL, 2);
    emit(at);
    die(2);
  }

  msg[0] = 0x4D554C5449UL;
  msg[1] = ph;
  msg[2] = OLD_PAGES;
  for (s = 0; s < SPINMAX; s++) {
    r = sys3(SYS_CHANSEND, ep, (u64)&msg[0], 24);
    if (r != CHAN_FULL) {
      break;
    }
    yield();
  }
  if (r != 24) {
    wr("MULTI SEND FAIL", 15);
    die(3);
  }

  if (recv_ack(ep, ACK_MAPPED) != 0) {
    wr("MULTI NO MAP ACK", 16);
    die(4);
  }

  r = sys2(SYS_SHMGROW, h, GROW_PAGES);
  if (r != 0) {
    at = put(0, "MULTI GROW FAIL ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(5);
  }
  for (i = OLD_PAGES; i < GROW_PAGES; i++) {
    fill_page(va, i, (u8)MARK_NEW);
  }
  if (!check_page(va, 0, (u8)MARK0) || !check_page(va, 1, (u8)MARK0)) {
    wr("MULTI GROW OLD LOST", 19);
    die(6);
  }

  if (send_ack(ep, ACK_GROWN) != 8) {
    wr("MULTI GROW ACK SEND FAIL", 24);
    die(7);
  }
  if (recv_ack(ep, ACK_PEER) != 0) {
    wr("MULTI NO PEER GROW", 18);
    die(8);
  }

  r = sys2(SYS_SHMSHRINK, h, SHRINK_PAGES);
  if (r != 0) {
    at = put(0, "MULTI SHRINK FAIL ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(9);
  }
  if (!check_page(va, 0, (u8)MARK0) || !check_page(va, 1, (u8)MARK0)) {
    wr("MULTI SHRINK OLD LOST", 21);
    die(10);
  }

  if (send_ack(ep, ACK_SHRUNK) != 8) {
    wr("MULTI SHRINK ACK SEND FAIL", 26);
    die(11);
  }

  /* Hand the CPU to the peer so it can probe the freed page first. */
  for (s = 0; s < YIELD_AFTER_SHRINK; s++) {
    yield();
  }

  wr("SHM MULTI OK", 12);
  wr("SHM MULTI PROBE", 15);
  probe = (volatile u8 *)(va + 4UL * PAGEB);
  *probe = (u8)0x11;
  wr("MULTI STILL MAPPED", 18);
  die(12);
}

static void consumer(u64 ep) {
  u64 s;
  u64 r;
  u64 ph;
  u64 va;
  u64 i;
  unsigned at;
  volatile u8 *probe;

  for (s = 0; s < SPINMAX; s++) {
    r = sys3(SYS_CHANRECV, ep, (u64)&rxw[0], MSGMAX);
    if (r != CHAN_EMPTY) {
      break;
    }
    yield();
  }
  if (r < 24) {
    wr("MULTI RECV FAIL", 15);
    die(20);
  }
  ph = rxw[1];

  va = sys2(SYS_SHMMAP, ph, SHM_RO);
  if (va >= SHM_FLOOR) {
    at = put(0, "MULTI MAP FAIL ");
    at = puthex(at, va & 0xFFUL, 2);
    emit(at);
    die(21);
  }
  if (va != VA0) {
    wr("MULTI BAD VA", 12);
    die(22);
  }
  if (!check_page(va, 0, (u8)MARK0)) {
    wr("MULTI PEER OLD BAD", 18);
    die(23);
  }

  if (send_ack(ep, ACK_MAPPED) != 8) {
    wr("MULTI MAP ACK FAIL", 18);
    die(24);
  }

  if (recv_ack(ep, ACK_GROWN) != 0) {
    wr("MULTI NO GROWN", 14);
    die(25);
  }

  for (i = OLD_PAGES; i < GROW_PAGES; i++) {
    if (!check_page(va, i, (u8)MARK_NEW)) {
      wr("MULTI PEER GROW BAD", 19);
      die(26);
    }
  }
  wr("SHM MULTI PEER GROW OK", 22);

  if (send_ack(ep, ACK_PEER) != 8) {
    wr("MULTI PEER ACK FAIL", 19);
    die(27);
  }

  if (recv_ack(ep, ACK_SHRUNK) != 0) {
    wr("MULTI NO SHRUNK", 15);
    die(28);
  }
  if (!check_page(va, 0, (u8)MARK0) || !check_page(va, 1, (u8)MARK0)) {
    wr("MULTI PEER SHRINK BAD", 21);
    die(29);
  }

  wr("SHM MULTI PEER SHRINK PROBE", 27);
  probe = (volatile u8 *)(va + 4UL * PAGEB);
  *probe = (u8)0x22;
  wr("MULTI PEER STILL MAPPED", 23);
  die(30);
}

void _start(void) {
  u64 ep;
  u64 s;

  ep = CHAN_NOPEER;
  for (s = 0; s < SPINMAX; s++) {
    ep = sys1(SYS_CHANOPEN, PORT);
    if (ep < CHAN_FLOOR) {
      break;
    }
    yield();
  }
  if (ep >= CHAN_FLOOR) {
    wr("MULTI OPEN FAIL", 15);
    die(40);
  }

  /* Side 0 is producer (ep == 0 on port 0); side 1 is consumer. */
  if (ep == 0) {
    producer(ep);
  } else {
    consumer(ep);
  }
  die(99);
}
