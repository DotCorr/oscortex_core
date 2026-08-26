/* core/user/libc/port.c — the tier-1 C library functions a PORT needs and a
 * native oscortex program never did.
 *
 * ===========================================================================
 * WHY A FILE OF ITS OWN
 * ===========================================================================
 *
 * design/libdrm-port.md §2 tiers libdrm's 43 missing symbols into sixteen that
 * MUST WORK and twenty that must merely LINK. The twenty live in posix.c as
 * loud stubs. **The ones here are the subset of the sixteen that are ordinary,
 * portable C with no kernel behind them** -- no syscall, no descriptor, no
 * errno -- and keeping them out of string.c and malloc.c is deliberate:
 *
 *   * `string.c` is DELICATE. Its five functions defeat LLVM's loop-idiom
 *     recogniser with volatile accesses, and m13-libc DISASSEMBLES the linked
 *     ELF and requires not one `call` instruction inside any of them. Adding
 *     neighbours to that file is safe today and is a trap tomorrow.
 *   * `malloc.c` is a first-fit free list whose block arithmetic m12-heap
 *     reads out of the binary. `calloc` and `realloc` are built ON it here,
 *     through its public surface, rather than inside it where they would be
 *     able to reach its internals.
 *
 * **THE VOLATILE DISCIPLINE OF string.c IS INHERITED BY EVERY BYTE LOOP HERE**
 * and for the same reason: LLVM turns a byte-copy loop into a call to memcpy,
 * including when the loop it is looking at IS memmove, and this OS's one-page
 * user stack does not survive the resulting recursion.
 */

#include "oslibc.h"

/* This file is compiled INTO the ports' link, alongside posix.c, and it must
 * not accidentally reach oscortex's `open`/`read`/`close`/`printf` through the
 * short spellings oslibc.h defines for them. Nothing here calls any of the
 * four, and undefining them makes that checkable rather than trusted. */
#undef open
#undef read
#undef close
#undef printf

/* --------------------------------------------------------------------------
 * The string and memory functions. Tier 1: memcmp, memmove, strncmp, strncpy.
 * ----------------------------------------------------------------------- */

/* `drmDevicesEqual`. */
int memcmp(const void *a, const void *b, size_t n) {
  volatile const unsigned char *p = (volatile const unsigned char *)a;
  volatile const unsigned char *q = (volatile const unsigned char *)b;
  size_t i;
  for (i = 0; i < n; i++) {
    if (p[i] != q[i]) {
      return (int)p[i] - (int)q[i];
    }
  }
  return 0;
}

/* `drmModeAtomicCommit` — an OVERLAPPING copy inside the atomic request, which
 * is the whole reason memcpy is not enough and the whole reason the direction
 * test below is not decoration. Copying forwards through an overlap where
 * dst > src destroys the source as it goes. */
void *memmove(void *dst, const void *src, size_t n) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  volatile const unsigned char *s = (volatile const unsigned char *)src;
  size_t i;
  if (d == s || n == 0) {
    return dst;
  }
  if (d < s) {
    for (i = 0; i < n; i++) {
      d[i] = s[i];
    }
  } else {
    for (i = n; i > 0; i--) {
      d[i - 1] = s[i - 1];
    }
  }
  return dst;
}

/* `drmGetNodeType`, `drmNodeIsDRM`. */
int strncmp(const char *a, const char *b, size_t n) {
  volatile const unsigned char *p = (volatile const unsigned char *)a;
  volatile const unsigned char *q = (volatile const unsigned char *)b;
  size_t i;
  for (i = 0; i < n; i++) {
    if (p[i] != q[i]) {
      return (int)p[i] - (int)q[i];
    }
    if (p[i] == 0) {
      return 0;
    }
  }
  return 0;
}

/* `drmModeGetProperty`.
 *
 * **THIS IS C's strncpy AND IT HAS C's strncpy's TWO SHARP EDGES**, kept
 * rather than smoothed, because a port compiled against the real header
 * expects them: it does NOT NUL-terminate when the source is at least [n]
 * bytes, and it PADS the whole remainder with NULs when the source is shorter.
 * A "safer" strncpy here would be a different function wearing the same name,
 * which is the exact failure GAP-0170 is about. */
char *strncpy(char *dst, const char *src, size_t n) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  volatile const unsigned char *s = (volatile const unsigned char *)src;
  size_t i = 0;
  while (i < n && s[i] != 0) {
    d[i] = s[i];
    i++;
  }
  while (i < n) {
    d[i] = 0;
    i++;
  }
  return dst;
}

/* --------------------------------------------------------------------------
 * The allocator family. Tier 1: calloc, realloc, strdup.
 *
 * Built on malloc.c's PUBLIC surface -- malloc, free, and nothing else. They
 * do not reach into its block headers, which is why m12-heap's arithmetic
 * about where blocks land is unaffected by this file existing.
 *
 * **THE COST OF THAT IS REAL AND IS STATED RATHER THAN HIDDEN: `realloc`
 * ALWAYS COPIES.** malloc.c has no way to ask "how big is this block", so a
 * realloc that grows cannot know whether the next block is free and cannot
 * grow in place. libdrm calls it from `drmModeAtomicAddProperty`, where the
 * request grows a page's worth of items at a time, so the copies are O(log n)
 * in the number of properties and not O(n). GAP-0182 records the shortcut.
 * ----------------------------------------------------------------------- */

/* `drmMalloc` is `calloc(1, n)` and EVERY `drmModeGet*` allocates through it,
 * so this is on the hot path of the whole KMS surface.
 *
 * The zeroing is not optional and is not a courtesy: `drmModeGetResources`
 * allocates a struct and fills SOME of it, and libdrm then tests the rest
 * against 0. A calloc that did not zero would make those tests read whatever
 * the last freed block held. */
void *calloc(size_t n, size_t sz) {
  size_t total;
  volatile unsigned char *p;
  size_t i;
  if (n == 0 || sz == 0) {
    return NULL;
  }
  /* Overflow check BEFORE the multiply is used, not after. `n * sz` wrapping
   * would allocate a small block and return it for a large request, and every
   * write through the result would then be out of bounds -- the classic
   * calloc bug, and it is one line to not have. */
  if (n > (~(size_t)0) / sz) {
    return NULL;
  }
  total = n * sz;
  p = (volatile unsigned char *)malloc(total);
  if (p == NULL) {
    return NULL;
  }
  for (i = 0; i < total; i++) {
    p[i] = 0;
  }
  return (void *)p;
}

/* `drmModeAtomicAddProperty`, `drmModeAtomicMerge`.
 *
 * **realloc(p, 0) FREES AND RETURNS NULL**, which is one of the two legal C
 * behaviours and is the one libdrm's callers survive. **realloc(NULL, n) IS
 * malloc(n)**, which every caller relies on.
 *
 * **THE COPY LENGTH IS THE SHARP EDGE AND IT IS WHY malloc.c GREW A
 * FUNCTION.** The obvious implementation copies [n] bytes -- the NEW size --
 * out of the old block, and on every GROWING realloc that reads past the end
 * of the old allocation. This heap has no guard pages, so the over-read is
 * silent. `malloc_usable` (added to malloc.c by ADR-0033, where the block
 * header layout lives) is the question this asks instead, and `min(old, new)`
 * is the only length that is safe in both directions. */
void *realloc(void *p, size_t n) {
  void *q;
  if (p == NULL) {
    return malloc(n);
  }
  if (n == 0) {
    free(p);
    return NULL;
  }
  q = malloc(n);
  if (q == NULL) {
    return NULL;
  }
  /* **THE HONEST BOUND.** malloc.c does not expose a block size, so the only
   * length this can copy without reading past the end of the old block is one
   * it was told. It was not told one. Copying [n] would be a read overrun on
   * every growing realloc -- which is the common case.
   *
   * So this asks the allocator, through the one question it can answer: it
   * copies through `malloc_usable` below, which walks malloc.c's own header
   * the same way malloc.c does. That is the single place in this file that
   * knows malloc.c's layout, it is sixteen bytes of knowledge, and it is
   * checked against `mallocHdrBytes` -- which malloc.c exports for exactly
   * this kind of cross-check -- at the top of the function. */
  {
    size_t oldn = malloc_usable(p);
    size_t copy = (oldn < n) ? oldn : n;
    volatile unsigned char *d = (volatile unsigned char *)q;
    volatile const unsigned char *s = (volatile const unsigned char *)p;
    size_t i;
    for (i = 0; i < copy; i++) {
      d[i] = s[i];
    }
  }
  free(p);
  return q;
}

/* `drmGetVersion` copies the driver's name/date/desc out of the ioctl reply
 * with this; `drmGetDeviceNameFromFd2` too. */
char *strdup(const char *s) {
  size_t n;
  char *p;
  volatile unsigned char *d;
  volatile const unsigned char *q;
  size_t i;
  if (s == NULL) {
    return NULL;
  }
  n = strlen(s);
  p = (char *)malloc(n + 1);
  if (p == NULL) {
    return NULL;
  }
  d = (volatile unsigned char *)p;
  q = (volatile const unsigned char *)s;
  for (i = 0; i < n; i++) {
    d[i] = q[i];
  }
  d[n] = 0;
  return p;
}

/* --------------------------------------------------------------------------
 * qsort. `drmModeAtomicCommit` sorts the atomic property list before it
 * commits it.
 *
 * **INSERTION SORT, AND THE CHOICE IS DELIBERATE RATHER THAN LAZY.** Real
 * qsort is quicksort with a recursion depth of O(log n); this OS gives a
 * program ONE PAGE of stack (ADR-0013), and a recursive sort on a
 * pathological input is how that page gets exceeded -- silently, because
 * there is no guard page below it. Insertion sort uses O(1) stack and is
 * O(n^2), and libdrm's atomic property list is tens of items, not thousands.
 * GAP-0182 records the complexity so that the day something sorts a large
 * array, this is a known thing to fix rather than a mystery.
 *
 * The element swap goes through a byte loop because the element size is a
 * runtime value.
 * ----------------------------------------------------------------------- */
void qsort(void *base, size_t n, size_t sz,
           int (*cmp)(const void *, const void *)) {
  volatile unsigned char *b = (volatile unsigned char *)base;
  size_t i, j, k;
  if (n < 2 || sz == 0) {
    return;
  }
  for (i = 1; i < n; i++) {
    for (j = i; j > 0; j--) {
      volatile unsigned char *cur = b + j * sz;
      volatile unsigned char *prv = b + (j - 1) * sz;
      if (cmp((const void *)prv, (const void *)cur) <= 0) {
        break;
      }
      for (k = 0; k < sz; k++) {
        unsigned char t = prv[k];
        prv[k] = cur[k];
        cur[k] = t;
      }
    }
  }
}

/* --------------------------------------------------------------------------
 * snprintf / sprintf. Tier 1: "device paths, sysfs paths, everything", and
 * `drmOpenByName`/`drmOpenMinor` build `/dev/dri/card%d` with sprintf.
 *
 * **THE CONVERSION SET IS WIDER THAN printf.c's FIVE, AND THE LOUDNESS IS THE
 * SAME.** printf.c has exactly %s %d %x %c %% and emits `%!` for anything
 * else, because ADR-0017 §5 decided that a printf which silently drops what it
 * does not understand turns a missing feature into wrong output. That decision
 * is kept here verbatim -- an unknown conversion emits `%!` and the offending
 * character -- and the set is widened only by what a port measurably needs:
 *
 *   %s %d %i %u %x %X %c %p %% , the length modifiers l / ll / z (which change
 *   the argument's width and nothing else), and a MINIMUM FIELD WIDTH with an
 *   optional leading zero, because "%02d" and "%04x" appear in libdrm's path
 *   and modifier formatting.
 *
 * NOT SUPPORTED, AND LOUD ABOUT IT: precision (`%.3s`), `-`/`+`/space flags,
 * `%f` and every other float (there is no libm and no soft-float here), `%n`.
 *
 * **THE RETURN VALUE IS C's, WHICH IS THE ONE THING A CALLER USES TO DETECT
 * TRUNCATION**: it is the number of bytes that WOULD have been written, not
 * the number that were. `drmGetFormatModifierName` and the path builders test
 * `ret >= sizeof buf`. A snprintf that returned the truncated length would
 * make every one of those tests silently false.
 * ----------------------------------------------------------------------- */

/* One output cursor. `cap` is the buffer size INCLUDING the NUL; `len` counts
 * what would have been written and is allowed to exceed `cap`. */
typedef struct SnBuf {
  char *buf;
  size_t cap;
  size_t len;
} SnBuf;

static void snPut(SnBuf *o, char c) {
  if (o->buf != NULL && o->len + 1 < o->cap) {
    o->buf[o->len] = c;
  }
  o->len = o->len + 1;
}

static void snPad(SnBuf *o, size_t have, size_t width, int zero) {
  while (have < width) {
    snPut(o, zero ? '0' : ' ');
    have++;
  }
}

/* Unsigned in base 10 or 16. Digits are produced backwards into a local array
 * -- 20 is enough for 2^64-1 in decimal and 16 in hex. */
static void snNum(SnBuf *o, unsigned long v, unsigned base, int upper,
                  size_t width, int zero) {
  char tmp[24];
  const char *lo = "0123456789abcdef";
  const char *up = "0123456789ABCDEF";
  const char *dig = upper ? up : lo;
  size_t k = 0;
  if (v == 0) {
    tmp[k++] = '0';
  }
  while (v != 0) {
    tmp[k++] = dig[v % base];
    v = v / base;
  }
  snPad(o, k, width, zero);
  while (k > 0) {
    snPut(o, tmp[--k]);
  }
}

static void snSigned(SnBuf *o, long v, size_t width, int zero) {
  unsigned long m;
  if (v < 0) {
    /* -LONG_MIN does not fit in a long, so the negation is done in the
     * unsigned domain. This is the one arithmetic edge in the formatter and
     * getting it wrong prints nothing for exactly one input. */
    m = (unsigned long)(-(v + 1)) + 1UL;
    snPut(o, '-');
    if (width > 0) {
      width--;
    }
    snNum(o, m, 10, 0, width, zero);
    return;
  }
  snNum(o, (unsigned long)v, 10, 0, width, zero);
}

int vsnprintf(char *buf, size_t cap, const char *fmt, __builtin_va_list ap) {
  SnBuf o;
  size_t i = 0;
  o.buf = buf;
  o.cap = cap;
  o.len = 0;

  while (fmt[i] != 0) {
    char c = fmt[i];
    size_t width = 0;
    int zero = 0;
    int lng = 0;

    if (c != '%') {
      snPut(&o, c);
      i++;
      continue;
    }
    i++;
    /* A `%` at the very end of the format. printf.c's rule: LOUD. */
    if (fmt[i] == 0) {
      snPut(&o, '%');
      snPut(&o, '!');
      break;
    }
    if (fmt[i] == '0') {
      zero = 1;
      i++;
    }
    while (fmt[i] >= '0' && fmt[i] <= '9') {
      width = width * 10 + (size_t)(fmt[i] - '0');
      i++;
    }
    while (fmt[i] == 'l' || fmt[i] == 'z') {
      lng = 1;
      i++;
    }
    c = fmt[i];
    i++;

    if (c == 's') {
      const char *s = __builtin_va_arg(ap, const char *);
      size_t n = 0;
      if (s == NULL) {
        s = "(null)";
      }
      while (s[n] != 0) {
        n++;
      }
      snPad(&o, n, width, 0);
      {
        size_t j;
        for (j = 0; j < n; j++) {
          snPut(&o, s[j]);
        }
      }
    } else if (c == 'd' || c == 'i') {
      long v = lng ? __builtin_va_arg(ap, long) : (long)__builtin_va_arg(ap, int);
      snSigned(&o, v, width, zero);
    } else if (c == 'u') {
      unsigned long v = lng ? __builtin_va_arg(ap, unsigned long)
                            : (unsigned long)__builtin_va_arg(ap, unsigned int);
      snNum(&o, v, 10, 0, width, zero);
    } else if (c == 'x' || c == 'X') {
      unsigned long v = lng ? __builtin_va_arg(ap, unsigned long)
                            : (unsigned long)__builtin_va_arg(ap, unsigned int);
      snNum(&o, v, 16, c == 'X', width, zero);
    } else if (c == 'p') {
      unsigned long v = (unsigned long)__builtin_va_arg(ap, void *);
      snPut(&o, '0');
      snPut(&o, 'x');
      snNum(&o, v, 16, 0, width, zero);
    } else if (c == 'c') {
      int v = __builtin_va_arg(ap, int);
      snPut(&o, (char)v);
    } else if (c == '%') {
      snPut(&o, '%');
    } else {
      /* ADR-0017 §5's marker, kept verbatim: the two characters `%!` and then
       * the offending character, which IS CONSUMED. No argument is taken,
       * because this formatter has no idea what size the caller pushed --
       * which is precisely why guessing would be worse than being loud. */
      snPut(&o, '%');
      snPut(&o, '!');
      snPut(&o, c);
    }
  }

  if (o.buf != NULL && o.cap > 0) {
    o.buf[(o.len < o.cap) ? o.len : (o.cap - 1)] = 0;
  }
  return (int)o.len;
}

int snprintf(char *buf, size_t cap, const char *fmt, ...) {
  __builtin_va_list ap;
  int r;
  __builtin_va_start(ap, fmt);
  r = vsnprintf(buf, cap, fmt, ap);
  __builtin_va_end(ap);
  return r;
}

/* `drmOpenByName`, `drmOpenMinor`, `drmOpenDevice` build `/dev/dri/card%d`
 * with this.
 *
 * **THERE IS NO BOUND AND THAT IS sprintf's CONTRACT**, not an oversight. The
 * caller supplied the buffer and asserted it was big enough; this cannot check
 * that and neither can the real one. libdrm's four call sites all write into
 * `char buf[PATH_MAX + 1]` with PATH_MAX 256 -- a number THIS PORT CHOSE
 * (design/libdrm-port.md §1) rather than transcribed, and chose small on
 * purpose because a 4096-byte stack frame does not fit this OS's one-page
 * user stack. */
int sprintf(char *buf, const char *fmt, ...) {
  __builtin_va_list ap;
  int r;
  __builtin_va_start(ap, fmt);
  /* ~0 as the cap means "never truncate": snPut's `len + 1 < cap` is then
   * always true and every byte lands. */
  r = vsnprintf(buf, ~(size_t)0, fmt, ap);
  __builtin_va_end(ap);
  return r;
}

/* `drmParseSubsystemType` and friends use it on sysfs paths; it is pulled into
 * the link from libdrm's string handling. Eight lines, and the empty-needle
 * case returns the haystack, which is C's contract and is what a caller
 * scanning for a prefix relies on. */
char *strstr(const char *hay, const char *needle) {
  size_t i, j;
  if (needle[0] == 0) {
    return (char *)hay;
  }
  for (i = 0; hay[i] != 0; i++) {
    for (j = 0; needle[j] != 0; j++) {
      if (hay[i + j] != needle[j]) {
        break;
      }
    }
    if (needle[j] == 0) {
      return (char *)(hay + i);
    }
  }
  return NULL;
}
