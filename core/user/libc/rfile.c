/* core/user/libc/rfile.c — RFILE: a buffered, read-only file.
 *
 * WHY IT IS NOT CALLED `FILE`
 * ---------------------------------------------------------------------------
 * Because it does not do what a `FILE` does. C's `FILE` reads AND writes, has
 * three of itself already open when `main` starts, keeps an error indicator and
 * an end-of-file indicator that `ferror` and `feof` report separately, flushes,
 * can be re-pointed with `freopen`, and can be told to be unbuffered. This
 * struct reads. Naming it `FILE` would make ordinary C source compile against
 * it and then behave differently, which is exactly the failure ADR-0017 §5
 * built printf's loud `%!` marker to avoid: a missing feature that announces
 * itself is a smaller problem than a missing feature that pretends.
 *
 * WHAT IT DOES DO, AND IT IS REAL BUFFERING
 * ---------------------------------------------------------------------------
 * One RFILE_BUFSZ-byte buffer per open file. `rfread` copies out of it and
 * refills when it runs dry; `rfgets` scans it for a newline and refills across
 * one. The syscall count is what makes this worth having: reading a 20 KiB file
 * one line at a time costs 40 `read` syscalls here and would cost one per line
 * without it.
 *
 * NO malloc, AND THAT IS FORCED RATHER THAN CHOSEN
 * ---------------------------------------------------------------------------
 * `sbrk` is refused unless a PROCESS is live (core/kernel/user.dart), and
 * `run <name>` -- the command that loads a program off the very filesystem this
 * file exists to read -- does not create one. A buffered layer that needed
 * `malloc` would therefore be unusable by exactly the programs that need it, so
 * the RFILEs are a fixed array of RFILE_MAX in `.bss`, which the ELF loader
 * zeroes (ADR-0014). `rfopen` returns NULL when they are all taken and
 * `rf_last_error()` says 0 rather than a kernel refusal, because the kernel did
 * not refuse anything -- this library ran out.
 *
 * THE BUFFER IS DISCARDED ON A SEEK, NOT REPOSITIONED. Working out which part
 * of a 512-byte window a new offset lands in is four lines and one of them is
 * always wrong; refilling is one syscall. `m15-fileio`'s program seeks a great
 * deal on purpose and the syscall count it produces is derived by the harness,
 * so the cost of this decision is visible rather than assumed.
 */

#include "oslibc.h"

static RFILE rfiles[RFILE_MAX];
static unsigned long rfErr;

unsigned long rf_last_error(void) { return rfErr; }

/* Fills [f]'s buffer from the descriptor's current offset. Returns how many
 * bytes arrived, and sets eof when that is zero. A refusal is recorded in
 * rfErr and reported as zero bytes -- a buffered reader has nowhere to put a
 * refusal except the next call's return, and a caller that wants the raw value
 * asks for it. */
static unsigned long rfill(RFILE *f) {
  unsigned long got;
  f->base += f->n;
  f->n = 0;
  f->i = 0;
  if (f->eof) {
    return 0;
  }
  got = read(f->fd, f->buf, RFILE_BUFSZ);
  if (got >= FILE_ERR_FLOOR) {
    rfErr = got;
    f->eof = 1;
    return 0;
  }
  if (got == 0) {
    f->eof = 1;
    return 0;
  }
  f->n = got;
  return got;
}

RFILE *rfopen(const char *name) {
  unsigned long fd;
  int s;
  for (s = 0; s < RFILE_MAX; s++) {
    if (!rfiles[s].used) {
      break;
    }
  }
  if (s == RFILE_MAX) {
    rfErr = 0; /* the library ran out, not the kernel */
    return NULL;
  }
  fd = open(name);
  if (fd >= FILE_ERR_FLOOR) {
    rfErr = fd;
    return NULL;
  }
  rfErr = 0;
  rfiles[s].fd = fd;
  rfiles[s].base = 0;
  rfiles[s].n = 0;
  rfiles[s].i = 0;
  rfiles[s].eof = 0;
  rfiles[s].used = 1;
  return &rfiles[s];
}

size_t rfread(void *dst, size_t n, RFILE *f) {
  unsigned char *out = (unsigned char *)dst;
  size_t done = 0;
  if (f == NULL) {
    return 0;
  }
  while (done < n) {
    unsigned long avail = f->n - f->i;
    unsigned long take;
    if (avail == 0) {
      if (rfill(f) == 0) {
        break;
      }
      avail = f->n - f->i;
    }
    take = n - done;
    if (take > avail) {
      take = avail;
    }
    memcpy(out + done, f->buf + f->i, take);
    f->i += take;
    done += take;
  }
  return done;
}

char *rfgets(char *dst, size_t n, RFILE *f) {
  size_t k = 0;
  if (f == NULL) {
    return NULL;
  }
  if (n < 2) {
    return NULL;
  }
  while (k + 1 < n) {
    unsigned char c;
    if (f->i >= f->n) {
      if (rfill(f) == 0) {
        break;
      }
    }
    c = f->buf[f->i];
    f->i++;
    dst[k] = (char)c;
    k++;
    if (c == '\n') {
      break;
    }
  }
  if (k == 0) {
    return NULL;
  }
  dst[k] = '\0';
  return dst;
}

unsigned long rftell(RFILE *f) {
  if (f == NULL) {
    return 0;
  }
  return f->base + f->i;
}

unsigned long rfseek(RFILE *f, unsigned long off) {
  unsigned long r;
  if (f == NULL) {
    return FILE_EBADFD;
  }
  r = seek(f->fd, off);
  if (r >= FILE_ERR_FLOOR) {
    rfErr = r;
    return r;
  }
  f->base = r;
  f->n = 0;
  f->i = 0;
  f->eof = 0;
  return r;
}

int rfeof(RFILE *f) {
  if (f == NULL) {
    return 1;
  }
  if (f->i < f->n) {
    return 0;
  }
  return f->eof ? 1 : 0;
}

unsigned long rfclose(RFILE *f) {
  unsigned long r;
  if (f == NULL) {
    return FILE_EBADFD;
  }
  r = close(f->fd);
  if (r >= FILE_ERR_FLOOR) {
    rfErr = r;
  }
  f->used = 0;
  f->n = 0;
  f->i = 0;
  f->eof = 1;
  return r;
}
