/* core/tests/conformance/d2-input/progR.c
 *
 * D2's ring-3 witness. It answers the question no kernel serial line can:
 * can a program at CPL 3 read the keyboard queue?
 *
 * Loaded with `proc run` so it has a process slot. The overflow half must
 * NOT pop and must NOT wait on `preempts`: a lone `proc run` process stays
 * on the CPU and that counter may not move (m18 is two processes). A
 * volatile busy-loop is the hold; the harness injects the burst into it.
 *
 * Phase 0: discard whatever `proc run`'s own Enter-break left in the ring.
 * Phase 1: print READY, collect SEQ_N events, print them.
 * Phase 2: print HOLD, burn time without popping, drain, report.
 *
 * SYS_KBDEVENT is declared here, not in oslibc.h -- docs/syscall-registry.md
 * records that 24 lives in exactly two places.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_KBDEVENT 24

#define KBD_POP 0UL
#define KBD_DROPPED 1UL
#define KBD_COUNT 2UL

#define SEQ_N 10
#define DEPTH 32

typedef unsigned long u64;

static u64 sys1(u64 n, u64 a) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a) : "memory", "cc");
  return r;
}

static u64 sys2(u64 n, u64 a, u64 b) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory", "cc");
  return r;
}

static void die(u64 code) {
  sys2(SYS_EXIT, code, 0);
  for (;;) {
  }
}

static char line[160];

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

static void emit(unsigned n) {
  sys2(SYS_WRITE, (u64)line, n);
}

volatile unsigned long burn;

void _start(void) {
  unsigned n;
  u64 seq[SEQ_N];
  u64 ovf[DEPTH];
  u64 i;
  u64 ev;
  u64 got;
  u64 junk;
  u64 on;
  u64 drop;

  junk = 0;
  while (sys1(SYS_KBDEVENT, KBD_POP) != 0) {
    junk = junk + 1;
    if (junk > 64) {
      break;
    }
  }

  n = put(0, "READY J ");
  n = puthex(n, junk, 2);
  emit(n);

  got = 0;
  burn = 0;
  while (got < SEQ_N) {
    ev = sys1(SYS_KBDEVENT, KBD_POP);
    if (ev != 0) {
      seq[got] = ev;
      got = got + 1;
    } else {
      burn = burn + 1;
      if (burn > 200000000UL) {
        break;
      }
    }
  }

  n = put(0, "SEQ N ");
  n = puthex(n, got, 2);
  n = put(n, " ");
  i = 0;
  while (i < got) {
    n = puthex(n, seq[i], 3);
    n = put(n, " ");
    i = i + 1;
  }
  emit(n);

  n = put(0, "HOLD");
  emit(n);

  /* Wait until the ring is full, then until the three extras have
     overflowed. A lone proc-run process does not keep incrementing
     preempts, so this is a syscall poll of the ring itself. */
  burn = 0;
  while (sys1(SYS_KBDEVENT, KBD_COUNT) < DEPTH) {
    if (sys1(SYS_KBDEVENT, KBD_DROPPED) > 0) {
      break;
    }
    burn = burn + 1;
    if (burn > 400000000UL) {
      break;
    }
  }
  burn = 0;
  while (sys1(SYS_KBDEVENT, KBD_DROPPED) < 3) {
    burn = burn + 1;
    if (burn > 400000000UL) {
      break;
    }
  }

  on = 0;
  while (on < DEPTH) {
    ev = sys1(SYS_KBDEVENT, KBD_POP);
    if (ev == 0) {
      break;
    }
    ovf[on] = ev;
    on = on + 1;
  }
  drop = sys1(SYS_KBDEVENT, KBD_DROPPED);

  n = put(0, "OVF N ");
  n = puthex(n, on, 2);
  n = put(n, " DROP ");
  n = puthex(n, drop, 2);
  emit(n);

  /* userWriteMax is 128. 32 events at 4 bytes each will not fit on one
     line, so they go out as two halves. */
  n = put(0, "EV0 ");
  i = 0;
  while (i < on && i < 16) {
    n = puthex(n, ovf[i], 3);
    n = put(n, " ");
    i = i + 1;
  }
  emit(n);
  n = put(0, "EV1 ");
  while (i < on) {
    n = puthex(n, ovf[i], 3);
    n = put(n, " ");
    i = i + 1;
  }
  emit(n);

  die((on & 0xFFUL) | ((drop & 0xFFUL) << 8) | ((got & 0xFFUL) << 16));
}
