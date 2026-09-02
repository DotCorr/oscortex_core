/* core/tests/conformance/m14-fat/prog.c
 *
 * A PROGRAM THAT CHECKS THE FILESYSTEM DELIVERED IT INTACT.
 *
 * This is the only test program in this repo that says anything about how it
 * got into memory, and it exists because M14's whole claim is about that. The
 * volume `make-image.py` writes is deliberately fragmented -- this program's
 * clusters are the ODD ones and the other program's are the EVEN ones, so the
 * two are interleaved 1KiB slab by 1KiB slab. A loader that read forward from
 * the first cluster instead of following the FAT would therefore assemble a
 * program out of alternating pieces of two different executables.
 *
 * So the program HASHES ITSELF. `__ro_start` and `__ro_end` bracket the R+X
 * segment's file bytes (prog.ld), FNV-1a over that range is printed, and
 * derive.py computes the same hash over the same bytes of the ELF on the host.
 * FNV-1a is used rather than a sum BECAUSE IT IS POSITION-SENSITIVE: a sum is
 * invariant under a permutation of clusters, which is exactly the corruption
 * this is meant to catch, and would have passed.
 *
 * NO `malloc`, NO `sbrk`, AND THAT IS NOT AN OVERSIGHT. `sbrk` is refused
 * unless a PROCESS is live (core/kernel/user.dart), and `run` -- the command
 * this milestone is about -- loads a program without creating one. m13-libc
 * owns the allocator's testing and runs its programs through `proc run`. This
 * one uses the rest of the library: `printf`, `strlen`, `strcmp`, `memcpy`,
 * `write` and `exit`.
 *
 * TWO BUILDS FROM ONE SOURCE. `-DPROG_ID=0` is PROGA.ELF and `-DPROG_ID=1` is
 * PROGB.ELF. They differ in a .rodata string, so their hashes differ, their
 * messages differ and their exit statuses differ -- which is what makes "PROGB
 * ran, and it was not PROGA" a thing the transcript can show.
 */

#include "oslibc.h"

extern char __ro_start[];
extern char __ro_end[];

#ifndef PROG_ID
#define PROG_ID 0
#endif

#if PROG_ID == 0
static const char id[] = "A";
static const char tag[] = "PROGA.ELF took the odd clusters";
#else
static const char id[] = "B";
static const char tag[] = "PROGB.ELF took the even clusters";
#endif

/* FNV-1a, 32 bits. Position-sensitive by construction: every byte is mixed in
 * after the previous one has been multiplied through, so swapping two 1KiB
 * blocks changes the result. */
static unsigned long fnv1a(const unsigned char *p, unsigned long n)
{
    unsigned long h = 0x811C9DC5UL;
    unsigned long i;
    for (i = 0; i < n; i++) {
        h ^= (unsigned long)p[i];
        h = (h * 16777619UL) & 0xFFFFFFFFUL;
    }
    return h;
}

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  call progMain\n"
    "1:\n"
    "  pause\n"
    "  jmp 1b\n"
    ".size _start, . - _start\n");

void progMain(void);

void progMain(void)
{
    const unsigned char *lo = (const unsigned char *)__ro_start;
    const unsigned char *hi = (const unsigned char *)__ro_end;
    unsigned long n = (unsigned long)(hi - lo);
    unsigned long h = fnv1a(lo, n);
    char line[96];

    printf("M14 PROG %s BYTES %x FNV %x\n", id, (int)n, (int)h);
    printf("M14 PROG %s TAG %s\n", id, tag);

    /* The kernel's own pointer validator, on a stack buffer this time -- there
     * is no heap here. `elfOwns` walks the live page tables before believing
     * the pointer, so the line appearing at all is the kernel confirming the
     * mapping from its side. */
    memcpy(line, "M14 PROG ", 9);
    line[9] = id[0];
    memcpy(line + 10, " WROTE THROUGH A STACK POINTER\n", 31);
    write(line, 41);

    /* strcmp, so that one more library function is exercised by something that
     * would notice if it stopped working. */
    if (strcmp(id, "A") == 0 && strlen(tag) != 31) {
        printf("M14 PROG %s STRLEN WRONG\n", id);
        exit(0xFFUL);
    }

    exit((h ^ (PROG_ID * 0x5AUL)) & 0xFFUL);
}
