/* core/user/libc/string.c — memcpy, memset, strlen, strcmp, strcpy.
 *
 * THESE ARE NOT OPTIONAL AND THAT IS A MEASURED CLAIM, NOT A STYLE POINT.
 * clang at -O2 emits CALLS to `memcpy` and `memset` from ordinary C that never
 * names either -- a struct assignment becomes a `call memcpy`, a large local
 * array initialised to zero becomes a `call memset` -- and it does so even with
 * `-ffreestanding -fno-builtin`, because those flags stop it treating a call
 * the SOURCE wrote as known, not stop it emitting one of its own. A freestanding
 * program without these two symbols fails to link, and m13-libc/build-progs.sh
 * requires a compiler-emitted `call ... <memcpy>` to be present in the test
 * program's disassembly so that this paragraph cannot quietly become false.
 *
 * THE LOOPS GO THROUGH `volatile` POINTERS, AND THE REASON IS A HAZARD THIS
 * TOOLCHAIN DOES NOT CURRENTLY EXHIBIT. Say it that way round, because the
 * first version of this comment said it the other way and mutation testing
 * caught it.
 *
 * The hazard is real and well known: a compiler's loop-idiom recogniser rewrites
 * `while (n--) *d++ = c;` into a call to `memset`, and if the loop it is looking
 * at IS the body of `memset` the result calls itself forever and blows the
 * one-page stack this OS gives a process. GCC does it through
 * `-ftree-loop-distribute-patterns`, which is why freestanding builds there pass
 * `-fno-tree-loop-distribute-patterns`. A `volatile` store cannot be coalesced
 * into a library call by any conforming transform, so the idiom cannot match.
 *
 * WHAT WAS MEASURED HERE: Apple clang 17 at -O2 for x86_64-unknown-none-elf
 * emits NO call from the plain, non-volatile versions of these five loops --
 * with `-fno-builtin` and without it. LLVM's LoopIdiomRecognize declines to
 * rewrite a loop into a call to the function that contains it. A mutation that
 * removed every `volatile` from this file was run through the whole harness with
 * the golden regenerated and SURVIVED: nothing here can currently tell the two
 * versions apart except the size of the code. GAP-0114 records that.
 *
 * So the `volatile` stays as a cheap, portable guard against a compiler this
 * project does not use today, and its cost is stated rather than hidden: these
 * are byte-at-a-time loops with volatile accesses, several times slower than a
 * word-at-a-time memcpy. Nothing in this OS is throughput-bound yet.
 *
 * m13-libc/build-progs.sh disassembles all five functions and requires NOT ONE
 * `call` instruction inside any of them. That check is correct, it would catch
 * the hazard the day a toolchain introduced it, and -- on this toolchain -- it
 * is a check that currently has nothing to catch.
 */

#include "oslibc.h"

void *memcpy(void *dst, const void *src, size_t n) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  volatile const unsigned char *s = (volatile const unsigned char *)src;
  size_t i;
  for (i = 0; i < n; i++) {
    d[i] = s[i];
  }
  return dst;
}

void *memset(void *dst, int c, size_t n) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  unsigned char v = (unsigned char)c;
  size_t i;
  for (i = 0; i < n; i++) {
    d[i] = v;
  }
  return dst;
}

size_t strlen(const char *s) {
  volatile const unsigned char *p = (volatile const unsigned char *)s;
  size_t n = 0;
  while (p[n] != 0) {
    n++;
  }
  return n;
}

int strcmp(const char *a, const char *b) {
  volatile const unsigned char *x = (volatile const unsigned char *)a;
  volatile const unsigned char *y = (volatile const unsigned char *)b;
  size_t i = 0;
  for (;;) {
    unsigned char ca = x[i];
    unsigned char cb = y[i];
    if (ca != cb) {
      /* The sign, not the magnitude, is the contract -- and the comparison is
       * done as `unsigned char` because a plain `char` is signed on this target
       * and strcmp("\x80", "\x01") would then come back negative. */
      return ca < cb ? -1 : 1;
    }
    if (ca == 0) {
      return 0;
    }
    i++;
  }
}

char *strcpy(char *dst, const char *src) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  volatile const unsigned char *s = (volatile const unsigned char *)src;
  size_t i = 0;
  for (;;) {
    unsigned char c = s[i];
    d[i] = c;
    if (c == 0) {
      return dst;
    }
    i++;
  }
}
