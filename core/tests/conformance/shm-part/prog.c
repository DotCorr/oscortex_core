/* core/tests/conformance/shm-part/prog.c
 *
 * ADR-0160 — partial / offset map of a shm.
 * One binary, two roles. Producer creates 4 pages with distinct marks,
 * grants. Peer refuses an out-of-range offset, maps pages [1,3) only,
 * reads those marks, then probes page 0 (unmapped hole) — must #PF.
 * A map that installed every page would leave the hole readable and
 * print PART STILL MAPPED.
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

#define CHAN_FLOOR 0xFFFFFFFFFFFFFF00UL
#define CHAN_EMPTY 0xFFFFFFFFFFFFFFF5UL
#define CHAN_FULL 0xFFFFFFFFFFFFFFF6UL
#define CHAN_NOPEER 0xFFFFFFFFFFFFFFF4UL

#define SHM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define SHM_BADLEN 0xFFFFFFFFFFFFFFFDUL
#define SHM_NOPEER2 0xFFFFFFFFFFFFFFF6UL
#define SHM_RO 1UL

#define PORT 0
#define PAGEB 4096UL
#define VA0 0x10200000UL
#define PAGES 4UL
#define PART_OFF 1UL
#define PART_COUNT 2UL
#define MSGMAX 64
#define SPINMAX 4096

#define ACK_MAPPED 1UL
#define ACK_OWNER 2UL

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

  h = sys1(SYS_SHMCREATE, PAGES);
  if (h >= SHM_FLOOR) {
    at = put(0, "PART CREATE FAIL ");
    at = puthex(at, h & 0xFFUL, 2);
    emit(at);
    die(1);
  }
  va = VA0;
  for (i = 0; i < PAGES; i++) {
    fill_page(va, i, (u8)(0xA0UL + i));
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
    at = put(0, "PART GRANT FAIL ");
    at = puthex(at, ph & 0xFFUL, 2);
    emit(at);
    die(2);
  }

  msg[0] = 0x50415254UL;
  msg[1] = ph;
  msg[2] = PAGES;
  for (s = 0; s < SPINMAX; s++) {
    r = sys3(SYS_CHANSEND, ep, (u64)&msg[0], 24);
    if (r != CHAN_FULL) {
      break;
    }
    yield();
  }
  if (r != 24) {
    wr("PART SEND FAIL", 14);
    die(3);
  }

  if (recv_ack(ep, ACK_MAPPED) != 0) {
    wr("PART NO MAP ACK", 15);
    die(4);
  }

  wr("SHM PART OWNER OK", 17);
  if (send_ack(ep, ACK_OWNER) != 8) {
    wr("PART OWNER ACK FAIL", 19);
    die(5);
  }
  /* Hand the CPU to the peer so it can probe the hole. */
  for (s = 0; s < 64; s++) {
    yield();
  }
  die(0);
}

static void consumer(u64 ep) {
  u64 s;
  u64 r;
  u64 ph;
  u64 va;
  u64 range;
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
    wr("PART RECV FAIL", 14);
    die(20);
  }
  ph = rxw[1];

  /* Anti-vacuity: offset past the live page count must refuse. */
  range = (PAGES << 16) | 1UL;
  r = sys3(SYS_SHMMAP, ph, SHM_RO, range);
  if (r != SHM_BADLEN) {
    at = put(0, "PART BAD OFF NOT REFUSED ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(21);
  }
  wr("SHM PART BAD OFF OK", 19);

  range = (PART_OFF << 16) | PART_COUNT;
  va = sys3(SYS_SHMMAP, ph, SHM_RO, range);
  if (va >= SHM_FLOOR) {
    at = put(0, "PART MAP FAIL ");
    at = puthex(at, va & 0xFFUL, 2);
    emit(at);
    die(22);
  }
  if (va != (VA0 + PART_OFF * PAGEB)) {
    wr("PART BAD VA", 11);
    die(23);
  }
  if (!check_page(VA0, 1, (u8)0xA1) || !check_page(VA0, 2, (u8)0xA2)) {
    wr("PART MARKS BAD", 14);
    die(24);
  }

  if (send_ack(ep, ACK_MAPPED) != 8) {
    wr("PART MAP ACK FAIL", 17);
    die(25);
  }

  wr("SHM PART MAP OK", 15);

  if (recv_ack(ep, ACK_OWNER) != 0) {
    wr("PART NO OWNER ACK", 17);
    die(26);
  }

  wr("SHM PART HOLE PROBE", 19);
  probe = (volatile u8 *)(VA0 + 0UL * PAGEB);
  *probe = (u8)0x11;
  wr("PART STILL MAPPED", 17);
  die(27);
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
    wr("PART OPEN FAIL", 14);
    die(40);
  }

  if (ep == 0) {
    producer(ep);
  } else {
    consumer(ep);
  }
  die(99);
}
