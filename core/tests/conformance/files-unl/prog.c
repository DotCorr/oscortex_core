/* core/tests/conformance/files-unl/prog.c
 *
 * APP4 / ADR-0147 — unlink and rename on the FAT root.
 *
 * Creates KILL.DAT (two clusters), lists :ROOT, unlinks it, lists again
 * (gone), unlinks a missing name (FILE_ENOTFOUND), renames A.TMP over
 * A.TXT (atomic-save idiom). Every printed token is checked by run.sh.
 */

#include "oslibc.h"

#define CHUNK 512UL
#define REC 32UL
#define KILL_BYTES 2048UL /* two 1024-byte clusters — anti-vacuity for reuse */
#define ROOT_PATH ":ROOT"
#define KILL_NAME "KILL.DAT"
#define MISS_NAME "NOSUCH.ZZ"
#define TMP_NAME "A.TMP"
#define TXT_NAME "A.TXT"

static unsigned char chunk[CHUNK];
static unsigned char rootbuf[REC * 16];

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  xorl %ebp, %ebp\n"
    "  call main\n"
    "  movq %rax, %rdi\n"
    "  call exit\n"
    "  ud2\n"
    ".size _start, . - _start\n");

static int nameInRoot(const char *dotted) {
  unsigned long fd = open(ROOT_PATH);
  unsigned long n, at;
  char name[13];
  unsigned j, k;
  if (fd >= FILE_ERR_FLOOR) {
    return -1;
  }
  for (;;) {
    n = read(fd, rootbuf, sizeof(rootbuf));
    if (n >= FILE_ERR_FLOOR) {
      close(fd);
      return -1;
    }
    if (n == 0) {
      break;
    }
    at = 0;
    while (at + REC <= n) {
      if (rootbuf[at] != 0x00 && rootbuf[at] != 0xE5) {
        j = 0;
        for (k = 0; k < 8; k++) {
          if (rootbuf[at + k] != ' ') {
            name[j++] = (char)rootbuf[at + k];
          }
        }
        if (rootbuf[at + 8] != ' ' || rootbuf[at + 9] != ' ' ||
            rootbuf[at + 10] != ' ') {
          name[j++] = '.';
          for (k = 8; k < 11; k++) {
            if (rootbuf[at + k] != ' ') {
              name[j++] = (char)rootbuf[at + k];
            }
          }
        }
        name[j] = 0;
        if (strcmp(name, dotted) == 0) {
          close(fd);
          return 1;
        }
      }
      at += REC;
    }
  }
  close(fd);
  return 0;
}

static unsigned long writeAll(const char *name, unsigned long bytes, unsigned char seed) {
  unsigned long fd = create(name);
  unsigned long off = 0;
  unsigned long w;
  if (fd >= FILE_ERR_FLOOR) {
    return fd;
  }
  while (off < bytes) {
    unsigned long n = bytes - off;
    unsigned long i;
    if (n > CHUNK) {
      n = CHUNK;
    }
    for (i = 0; i < n; i++) {
      chunk[i] = (unsigned char)((seed + off + i) & 0xFFUL);
    }
    w = fdwrite(fd, chunk, n);
    if (w >= FILE_ERR_FLOOR || w != n) {
      close(fd);
      return w >= FILE_ERR_FLOOR ? w : FILE_EIO;
    }
    off += n;
  }
  close(fd);
  return 0;
}

static unsigned long hashFile(const char *name, unsigned long *got) {
  unsigned long fd = open(name);
  unsigned long h = 2166136261UL;
  unsigned long n, total = 0;
  unsigned long i;
  if (fd >= FILE_ERR_FLOOR) {
    *got = fd;
    return 0;
  }
  for (;;) {
    n = read(fd, chunk, CHUNK);
    if (n >= FILE_ERR_FLOOR) {
      close(fd);
      *got = n;
      return 0;
    }
    if (n == 0) {
      break;
    }
    for (i = 0; i < n; i++) {
      h ^= (unsigned long)chunk[i];
      h = (h * 16777619UL) & 0xFFFFFFFFUL;
    }
    total += n;
  }
  close(fd);
  *got = total;
  return h;
}

int main(void) {
  unsigned long r, got, h;
  int listed;

  r = writeAll(KILL_NAME, KILL_BYTES, 0x41);
  printf("UNL MAKE %x\n", (int)(r & 0xFFFFUL));
  if (r != 0) {
    return 1;
  }

  listed = nameInRoot(KILL_NAME);
  printf("UNL BEFORE %d\n", listed);
  if (listed != 1) {
    return 2;
  }

  r = unlink(KILL_NAME);
  printf("UNL OK %x\n", (int)(r & 0xFFFFUL));
  if (r != 0) {
    return 3;
  }

  listed = nameInRoot(KILL_NAME);
  printf("UNL AFTER %d\n", listed);
  if (listed != 0) {
    return 4;
  }

  r = unlink(MISS_NAME);
  printf("UNL MISS %x\n", (int)(r & 0xFFFFUL));
  if (r != FILE_ENOTFOUND) {
    return 5;
  }

  r = writeAll(TXT_NAME, 40, 0x10);
  if (r != 0) {
    printf("UNL TXT %x\n", (int)(r & 0xFFFFUL));
    return 6;
  }
  r = writeAll(TMP_NAME, 40, 0x90);
  if (r != 0) {
    printf("UNL TMP %x\n", (int)(r & 0xFFFFUL));
    return 7;
  }
  r = rename(TMP_NAME, TXT_NAME);
  printf("UNL REN %x\n", (int)(r & 0xFFFFUL));
  if (r != 0) {
    return 8;
  }

  listed = nameInRoot(TMP_NAME);
  printf("UNL TMPGONE %d\n", listed);
  if (listed != 0) {
    return 9;
  }
  listed = nameInRoot(TXT_NAME);
  printf("UNL TXTKEEP %d\n", listed);
  if (listed != 1) {
    return 10;
  }

  h = hashFile(TXT_NAME, &got);
  printf("UNL HASH %d %x\n", (int)got, (int)h);
  if (got != 40) {
    return 11;
  }
  /* seed 0x90 at offset 0 => first byte 0x90; FNV of 40 bytes of (0x90+i) */
  {
    unsigned long expect = 2166136261UL;
    unsigned long i;
    for (i = 0; i < 40; i++) {
      expect ^= (0x90UL + i) & 0xFFUL;
      expect = (expect * 16777619UL) & 0xFFFFFFFFUL;
    }
    if (h != expect) {
      printf("UNL BADHASH %x want %x\n", (int)h, (int)expect);
      return 12;
    }
  }

  printf("UNL PASS\n");
  return 0;
}
