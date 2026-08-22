/* core/user/libc/malloc.c — a first-fit free list over `sbrk`, with splitting
 * and with coalescing.
 *
 * IT IS CALLED A FREE LIST BECAUSE IT IS ONE. ADR-0016 §4 was careful to call
 * the kernel's `sbrk` a bump pointer rather than an allocator, because the break
 * only ever moves up and nothing is ever reused; the honest counterpart to that
 * care is to say exactly what THIS is:
 *
 *   * `free` puts a block back on a list and a later `malloc` of a size that
 *     fits RETURNS THE SAME ADDRESS. The test program does not assert that -- it
 *     MEASURES it and prints REUSE 1 or REUSE 0, and the negative-control build
 *     of the same source, whose `free` returns immediately, prints REUSE 0. The
 *     harness requires both, and requires its own reuse check to FAIL against
 *     the control. Reuse is a measurement with a build that lacks it standing
 *     next to it, not a claim.
 *   * Adjacent free blocks are MERGED. The list is kept in address order for no
 *     other reason. The test program frees two neighbours and then asks for more
 *     than either alone could hold, and gets the lower address back.
 *   * A block that is much larger than the request is SPLIT, and the tail goes
 *     back on the list. Without splitting the first `sbrk` of a whole page would
 *     be handed out entire to a 5-byte request.
 *
 * WHAT IT IS NOT, so that nothing is inferred:
 *   * There is no `realloc` and no `calloc`.
 *   * There are no size classes, no bins and no best-fit: the scan is linear
 *     from the head and takes the FIRST block that fits, so a long-lived list
 *     of small blocks costs a long walk. This is O(free blocks) per malloc.
 *   * Memory is NEVER given back to the kernel. `sbrk` cannot shrink
 *     (GAP-0107 item 1), so a freed block stays in this process's address space
 *     until it exits. `free` returns memory to the PROGRAM, not to the machine.
 *   * It is not thread-safe or reentrant, because this OS has neither threads
 *     nor signals.
 *   * There is no guard, no canary and no double-free detection. Freeing a
 *     pointer twice corrupts the list, and nothing here will tell you.
 *
 * THE HEADER IS 16 BYTES AND IS NOT A HIDDEN NUMBER. `mallocHdrBytes`,
 * `mallocAlign` and `mallocMinSplit` are `volatile const` words in .rodata, and
 * m13-libc/derive.py reads all three OUT OF THE ELF to compute where each block
 * must land. The harness's arithmetic about this allocator therefore comes from
 * the binary that ran, not from a constant typed a second time in Python.
 */

#include "oslibc.h"

/* Every allocation is preceded by one of these. `next` is meaningful only while
 * the block is on the free list; a live block's `next` is stale and is never
 * read. That is why the header is 16 bytes and not 8: 16 is also the alignment
 * this ABI wants for anything that might hold a `movaps`-able type, and a
 * 16-byte header keeps every payload 16-aligned for free. */
typedef struct Blk {
  size_t size; /* usable payload bytes; always a multiple of ALIGN */
  struct Blk *next;
} Blk;

#define HDR ((size_t)sizeof(Blk))
#define ALIGN ((size_t)16)
#define MIN_SPLIT ALIGN

/* Read out of the ELF by derive.py. `volatile` so clang cannot fold them away
 * and leave derive.py reading a symbol the linker dropped.
 *
 * THEY ARE THE MACROS THEMSELVES, NOT COPIES OF THEM. An earlier version of
 * this file wrote `= 16` three times. That was noticed while writing m13's
 * mutation set rather than by running one: changing ALIGN to 8 would have
 * changed this allocator's behaviour while leaving derive.py reading a 16 that
 * no code obeyed, and the harness would have caught it only by luck of the
 * arithmetic. Spelling them as the macros makes the exported words unable to
 * disagree with the code, which is why that mutation is not in the set -- it is
 * no longer expressible. */
volatile const unsigned long mallocHdrBytes = (unsigned long)sizeof(Blk);
volatile const unsigned long mallocAlign = (unsigned long)ALIGN;
volatile const unsigned long mallocMinSplit = (unsigned long)MIN_SPLIT;
volatile const unsigned long printfMax = PRINTF_MAX;
volatile const unsigned long libcWriteMax = WRITE_MAX;

/* 1 normally; 0 in the negative-control build. A `volatile const` word rather
 * than an `#ifdef` so that both builds are the same size, have the same segment
 * geometry and get the same heap base -- m12-heap/build-progs.sh's argument,
 * which applies here for the same reason: two builds that differ in layout
 * cannot be compared address for address. */
#ifndef LIBC_FREE_ENABLED
#define LIBC_FREE_ENABLED 1
#endif
volatile const unsigned long libcFreeEnabled = LIBC_FREE_ENABLED;

/* Address-ordered singly-linked list of free blocks. */
static Blk *freeHead;
static unsigned long fromKernel;

unsigned long malloc_bytes_from_kernel(void) { return fromKernel; }

unsigned long malloc_free_blocks(void) {
  unsigned long n = 0;
  Blk *b = freeHead;
  while (b) {
    n++;
    b = b->next;
  }
  return n;
}

static size_t roundUp(size_t n, size_t a) { return (n + a - 1) & ~(a - 1); }

/* Inserts [b] into the address-ordered free list and merges it with whichever
 * of its neighbours it physically abuts.
 *
 * The merge test is `end of one == start of the other`, computed in bytes, and
 * it is exact rather than approximate on purpose: two free blocks with even one
 * byte between them must NOT be merged, or the block that came out would claim
 * a byte it does not own. There is no such gap in practice -- every block comes
 * from a split or from an `sbrk`, and both produce abutting blocks -- but the
 * check that says so costs one comparison. */
static void insertFree(Blk *b) {
  Blk **link = &freeHead;
  while (*link && *link < b) {
    link = &(*link)->next;
  }
  b->next = *link;
  *link = b;

  /* forward merge */
  if (b->next && (char *)b + HDR + b->size == (char *)b->next) {
    b->size += HDR + b->next->size;
    b->next = b->next->next;
  }
  /* backward merge: find the predecessor by walking from the head. The list is
   * short and this is a first allocator, not a fast one. */
  if (freeHead != b) {
    Blk *p = freeHead;
    while (p && p->next != b) {
      p = p->next;
    }
    if (p && (char *)p + HDR + p->size == (char *)b) {
      p->size += HDR + b->size;
      p->next = b->next;
    }
  }
}

/* Asks the kernel for enough address space to hold a block with [need] bytes of
 * payload, and puts the whole thing on the free list.
 *
 * The new chunk always sits immediately above whatever the last one ended at --
 * `sbrk` is monotone and page-granular (ADR-0016 §4) -- so `insertFree` merges
 * it with the top free block when there is one. That is what stops a program
 * that allocates in a loop from accumulating one unusable page-sized fragment
 * per grow. */
static int grow(size_t need) {
  size_t want = roundUp(HDR + need, 4096);
  void *p = sbrk(want);
  if (!p) {
    return 0;
  }
  fromKernel += want;
  Blk *b = (Blk *)p;
  b->size = want - HDR;
  b->next = NULL;
  insertFree(b);
  return 1;
}

static void *takeFrom(Blk **link, size_t need) {
  Blk *b = *link;
  if (b->size >= need + HDR + MIN_SPLIT) {
    Blk *tail = (Blk *)((char *)b + HDR + need);
    tail->size = b->size - need - HDR;
    tail->next = b->next;
    b->size = need;
    *link = tail;
  } else {
    *link = b->next;
  }
  return (char *)b + HDR;
}

void *malloc(size_t n) {
  if (n == 0) {
    return NULL;
  }
  /* The overflow guard comes BEFORE the round-up, which is the addition that
   * would wrap -- heapSbrk's ordering (ADR-0016 §5), for the same reason: the
   * arithmetic that overflows must not be reached by an argument chosen by
   * somebody else. */
  if (n > (size_t)-1 - HDR - ALIGN) {
    return NULL;
  }
  size_t need = roundUp(n, ALIGN);

  Blk **link = &freeHead;
  while (*link) {
    if ((*link)->size >= need) {
      return takeFrom(link, need);
    }
    link = &(*link)->next;
  }

  if (!grow(need)) {
    return NULL;
  }

  link = &freeHead;
  while (*link) {
    if ((*link)->size >= need) {
      return takeFrom(link, need);
    }
    link = &(*link)->next;
  }
  return NULL;
}

void free(void *p) {
  if (!p) {
    return;
  }
  /* THE NEGATIVE CONTROL. In the control build this returns here and every
   * reuse the test program asserts stops happening. It is a load from .rodata
   * on every free in the normal build too, which is the price of the two builds
   * being the same shape. */
  if (!libcFreeEnabled) {
    return;
  }
  insertFree((Blk *)((char *)p - HDR));
}
