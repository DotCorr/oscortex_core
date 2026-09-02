/* core/user/libc/printf.c — a printf with EXACTLY five conversions, and a loud
 * failure for the sixth.
 *
 * THE FIVE ARE %s %d %x %c AND %%. THERE IS NO SIXTH, AND THAT IS THE FEATURE.
 * Every other character after a `%` -- a width (`%5d`), a flag (`%-s`), a length
 * modifier (`%ld`), a conversion this file does not implement (`%u`, `%p`,
 * `%f`, `%o`), or a `%` at the very end of the format string -- produces the two
 * characters `%!` in the output and consumes the offending character.
 *
 * That choice is the reason this file is worth reading. The cheap way to write
 * a printf subset is to skip what you do not understand, and the result is a
 * program that prints `Total: ` where it meant `Total: 42` and a golden file
 * that enshrines it. A `%!` in a serial capture is a diff, a failed harness and
 * a five-second diagnosis. m13-libc's test program deliberately formats a `%q`
 * and the harness REQUIRES `%!` to be in the capture, so this paragraph is
 * checked rather than promised.
 *
 * ONE CALL IS ONE WRITE IS ONE LINE. There is no buffering across calls, no
 * `\n` convention and no `stdout`. The kernel's `userSysWrite` prints
 * `USER WRITE `, then the bytes, then a newline of its own; and `elfOwns`
 * refuses any length above `userWriteMax` (128). So a formatted string longer
 * than PRINTF_MAX (120) is not something this OS can print in one call, and
 * this printf says so in the output -- the line ends in `%!OVF` and the call
 * returns -1 -- instead of quietly truncating. A silent truncation is
 * the same failure as a silently-skipped conversion, one layer down.
 *
 * `%x` is LOWERCASE, which is what C says. Every hex number the KERNEL prints is
 * uppercase, which makes the two trivially distinguishable in a capture, and
 * m13-libc/run.sh relies on that: `USER WRITE ... 1000` in lowercase came from a
 * ring-3 printf and could not have come from `uartPutHex`.
 */

#include "oslibc.h"

/* PRINTF_MAX bytes of message, then room for the overflow marker, and the whole
 * thing still under the kernel's 128-byte limit: 120 + 5 = 125. */
#define OVF_MARK "%!OVF"
#define OVF_LEN 5

static char buf[PRINTF_MAX + 8];

static unsigned long put(unsigned long n, char c) {
  if (n < PRINTF_MAX) {
    buf[n] = c;
    return n + 1;
  }
  return PRINTF_MAX + 1; /* one past the end: the sentinel for "overflowed" */
}

static unsigned long puts_(unsigned long n, const char *s) {
  if (!s) {
    s = "(null)";
  }
  while (*s) {
    n = put(n, *s++);
    if (n > PRINTF_MAX) {
      return n;
    }
  }
  return n;
}

/* [v] in base [base], into [n]. Digits are produced backwards into a local and
 * then copied, which is the only reason this needs a temporary at all. 20 is
 * enough for 2^64-1 in decimal. */
static unsigned long putnum(unsigned long n, unsigned long v, unsigned long base) {
  char t[24];
  unsigned long i = 0;
  if (v == 0) {
    t[i++] = '0';
  }
  while (v) {
    unsigned long d = v % base;
    t[i++] = (char)(d < 10 ? '0' + d : 'a' + (d - 10));
    v /= base;
  }
  while (i) {
    n = put(n, t[--i]);
    if (n > PRINTF_MAX) {
      return n;
    }
  }
  return n;
}

int os_printf(const char *fmt, ...) {
  __builtin_va_list ap;
  unsigned long n = 0;
  __builtin_va_start(ap, fmt);

  while (*fmt && n <= PRINTF_MAX) {
    char c = *fmt++;
    if (c != '%') {
      n = put(n, c);
      continue;
    }
    char k = *fmt;
    if (k == 0) {
      /* A trailing `%` with nothing after it. Not silently dropped. */
      n = put(n, '%');
      n = put(n, '!');
      break;
    }
    fmt++;
    if (k == '%') {
      n = put(n, '%');
    } else if (k == 'c') {
      n = put(n, (char)__builtin_va_arg(ap, int));
    } else if (k == 's') {
      n = puts_(n, __builtin_va_arg(ap, const char *));
    } else if (k == 'd') {
      /* Widened to `long` before the negation, so INT_MIN does not become
       * itself. `-(-2147483648)` in `int` is undefined and on this target is
       * the same number back, which would print the sign and then the wrong
       * digits -- the classic one, and it is one line to not have it. */
      long v = (long)__builtin_va_arg(ap, int);
      if (v < 0) {
        n = put(n, '-');
        v = -v;
      }
      n = putnum(n, (unsigned long)v, 10);
    } else if (k == 'x') {
      n = putnum(n, (unsigned long)__builtin_va_arg(ap, unsigned int), 16);
    } else {
      /* THE SIXTH CONVERSION. Everything not named above lands here, loudly.
       * No argument is consumed, because this printf has no idea what size the
       * argument for an unknown conversion would be, and guessing would put
       * every later conversion in the call out of step. */
      n = put(n, '%');
      n = put(n, '!');
    }
  }
  __builtin_va_end(ap);

  if (n > PRINTF_MAX) {
    unsigned long i;
    const char *m = OVF_MARK;
    for (i = 0; i < OVF_LEN; i++) {
      buf[PRINTF_MAX + i] = m[i];
    }
    write(buf, PRINTF_MAX + OVF_LEN);
    return -1;
  }
  if (n == 0) {
    return 0;
  }
  unsigned long w = write(buf, n);
  return w == SYS_REFUSED ? -1 : (int)w;
}
