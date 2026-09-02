/* core/tests/conformance/apps1/prog.c
 *
 * A named FRAME app. Built twice (-DAPP=1 / -DAPP=2) so the volume can
 * carry APP1.ELF and APP2.ELF as 8.3 files. Started with
 * `proc spawn APP1.ELF` (FAT name, not LBA): heap via sbrk, then stay
 * resident so the shell is the idle context (ADR-0053).
 *
 * Freestanding against osframe.h. Empty stack at e_entry is fine: this
 * program does not read argc/argv.
 */

#include "osframe.h"

#ifndef APP
#define APP 1
#endif

typedef unsigned long u64;

#define SBRK_FLOOR 0xFFFFFFFFFFFFF000UL
#define YIELD_SPIN 40000000UL

#if APP == 1
static const char msg[] = "APPS1 APP1\n";
static const char heap_ok[] = "APPS1 APP1 HEAP 1\n";
static const char heap_no[] = "APPS1 APP1 HEAP 0\n";
static volatile u64 keep = 0xA1100001UL;
#else
static const char msg[] = "APPS1 APP2\n";
static const char heap_ok[] = "APPS1 APP2 HEAP 1\n";
static const char heap_no[] = "APPS1 APP2 HEAP 0\n";
static volatile u64 keep = 0xA1100002UL;
#endif
static u64 scratch[8];

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}

static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }

static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }

void _start(void) {
  u64 p;

  scratch[0] = keep;
  wr(msg, sizeof(msg) - 1);
  p = sys1(SYS_SBRK, 16);
  if (p < SBRK_FLOOR) {
    wr(heap_ok, sizeof(heap_ok) - 1);
  } else {
    wr(heap_no, sizeof(heap_no) - 1);
  }

  for (;;) {
    volatile u64 spin = 0;
    while (spin < YIELD_SPIN) {
      spin = spin + 1;
    }
    sys1(SYS_YIELD, 0);
  }
}
