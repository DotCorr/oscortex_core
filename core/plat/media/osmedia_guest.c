/* IRQ0 tick: decode the mailbox clip through osmedia.h onto serial. */
#include "osmedia_guest.h"
#include "osmedia.h"

#include <stddef.h>
#include <stdint.h>

__attribute__((section(".osmedia_cmd"), used)) struct OsMediaGuestCmd
    osmedia_guest_cmd = {OSMEDIA_GUEST_MAGIC, 0, 0, 0, 0, {0, 0, 0}, {0}};

#ifndef OSMEDIA_NO_FFMPEG_LINK
static uint8_t decode_stack[512 * 1024];
#endif

static void outb(uint16_t port, uint8_t v) {
  __asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(port));
}

static uint8_t inb(uint16_t port) {
  uint8_t v;
  __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
  return v;
}

static void sputc(char c) {
  int spins;
  spins = 0;
  while ((inb(0x3FD) & 0x20) == 0) {
    spins = spins + 1;
    if (spins > 100000) {
      break;
    }
  }
  outb(0x3F8, (uint8_t)c);
}

static void sputs(const char *s) {
  while (*s) {
    sputc(*s);
    s = s + 1;
  }
}

static void sputhex(uint32_t v, int digits) {
  static const char *hex = "0123456789ABCDEF";
  int i;
  for (i = digits - 1; i >= 0; i--) {
    sputc(hex[(v >> (i * 4)) & 0xF]);
  }
}

#ifndef OSMEDIA_NO_FFMPEG_LINK
static void line_pix(uint32_t pix, const char *backend) {
  sputs("OSMEDIA PIX ");
  sputhex(pix, 8);
  sputc('\n');
  sputs("OSMEDIA BACKEND ");
  sputs(backend);
  sputc('\n');
}
#endif

static void line_miss(void) {
  sputs("OSMEDIA MISS\n");
  sputs("OSMEDIA BACKEND none\n");
}

#ifndef OSMEDIA_NO_FFMPEG_LINK
void osmedia_trace(const char *s) {
  sputs(s);
  sputc('\n');
}

/* Dart @bare — sit-in scanout blit (ADR-0131). Not an @extern. */
void fbBlitArgb(uint64_t src, uint64_t w, uint64_t h, uint64_t dx,
                uint64_t dy);

/* Dart @bare — wmsurface commit of the decoder tile (ADR-0135). */
void wmMediaFill(uint64_t src, uint64_t w, uint64_t h);

#ifndef OSMEDIA_NO_WIN
static uint32_t win_rgb[OSMEDIA_W * OSMEDIA_H];
static int win_have;
static int win_tries;
#endif

#ifndef OSMEDIA_NO_MOVIE
static OsMedia *movie_m;
static int movie_hold;
#endif

#ifndef OSMEDIA_NO_BLIT
static void commit_rgb(uint32_t *rgb, int n) {
  if (n <= 0) {
    return;
  }
  fbBlitArgb((uint64_t)(uintptr_t)rgb, (uint64_t)OSMEDIA_W,
             (uint64_t)OSMEDIA_H, (uint64_t)OSMEDIA_BLIT_X,
             (uint64_t)OSMEDIA_BLIT_Y);
#ifndef OSMEDIA_NO_WIN
  {
    int i;
    for (i = 0; i < n && i < (OSMEDIA_W * OSMEDIA_H); i++) {
      win_rgb[i] = rgb[i];
    }
    win_have = 1;
    win_tries = 8;
    wmMediaFill((uint64_t)(uintptr_t)win_rgb, (uint64_t)OSMEDIA_W,
                (uint64_t)OSMEDIA_H);
  }
#endif
}
#endif

static void play_inner(void) {
  OsMedia *m;
  uint32_t pix;
  int rc;
#ifndef OSMEDIA_NO_BLIT
  uint32_t rgb[OSMEDIA_W * OSMEDIA_H];
  int n;
#endif

  sputs("OSMEDIA INIT\n");
  if (osmedia_init() != OSMEDIA_OK) {
    line_miss();
    return;
  }
  sputs("OSMEDIA OPEN\n");
  m = osmedia_open_mem(osmedia_guest_cmd.clip,
                       (int)osmedia_guest_cmd.clip_len);
  if (m == 0) {
    osmedia_shutdown();
    line_miss();
    return;
  }
  sputs("OSMEDIA DEC\n");
  rc = osmedia_decode_frame(m);
  pix = 0;
  if (rc == OSMEDIA_OK) {
    if (osmedia_pixel(m, OSMEDIA_PX, OSMEDIA_PY, &pix) != OSMEDIA_OK) {
      pix = 0;
    }
  }
  sputs("OSMEDIA RC ");
  sputhex((uint32_t)(rc < 0 ? 0 : rc), 8);
  sputc('\n');
  osmedia_guest_cmd.pixel = pix;
  osmedia_guest_cmd.status = (rc == OSMEDIA_OK) ? 1 : 0;
  if (rc == OSMEDIA_OK && pix != 0) {
    line_pix(pix, osmedia_backend_name(m));
#ifndef OSMEDIA_NO_BLIT
    n = osmedia_readback(m, rgb, OSMEDIA_W * OSMEDIA_H);
    commit_rgb(rgb, n);
#endif
#ifndef OSMEDIA_NO_MOVIE
    movie_m = m;
    movie_hold = 32;
    return;
#endif
  } else {
    line_miss();
  }
  osmedia_close(m);
  osmedia_shutdown();
}

#ifndef OSMEDIA_NO_MOVIE
static void movie_inner(void) {
  OsMedia *m;
  uint32_t pix;
  int rc;
#ifndef OSMEDIA_NO_BLIT
  uint32_t rgb[OSMEDIA_W * OSMEDIA_H];
  int n;
#endif

  m = movie_m;
  movie_m = 0;
  movie_hold = 0;
  if (m == 0) {
    return;
  }
  rc = osmedia_decode_frame(m);
  pix = 0;
  if (rc == OSMEDIA_OK) {
    if (osmedia_pixel(m, OSMEDIA_PX, OSMEDIA_PY, &pix) != OSMEDIA_OK) {
      pix = 0;
    }
  }
  if (rc == OSMEDIA_OK && pix != 0) {
    sputs("OSMEDIA MOV ");
    sputhex(pix, 8);
    sputc('\n');
#ifndef OSMEDIA_NO_BLIT
    n = osmedia_readback(m, rgb, OSMEDIA_W * OSMEDIA_H);
    commit_rgb(rgb, n);
#endif
  }
  osmedia_close(m);
  osmedia_shutdown();
}
#endif

static void call_on_stack(void (*fn)(void), void *top) {
  top = (void *)(((uintptr_t)top) & ~(uintptr_t)15);
  __asm__ volatile(
      "movq %%rsp, %%rbx\n\t"
      "movq %[top], %%rsp\n\t"
      "call *%[fn]\n\t"
      "movq %%rbx, %%rsp\n\t"
      :
      : [fn] "r"(fn), [top] "r"(top)
      : "rbx", "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11",
        "memory", "cc");
}
#endif

void osmedia_guest_tick(void) {
  uint64_t flags;
  flags = osmedia_guest_cmd.flags;
  if (flags == 0) {
#ifndef OSMEDIA_NO_WIN
    if (win_have != 0) {
      if (win_tries > 0) {
        wmMediaFill((uint64_t)(uintptr_t)win_rgb, (uint64_t)OSMEDIA_W,
                    (uint64_t)OSMEDIA_H);
        win_tries = win_tries - 1;
      }
    }
#endif
#ifndef OSMEDIA_NO_MOVIE
    if (movie_m != 0) {
      if (movie_hold > 0) {
        movie_hold = movie_hold - 1;
      } else {
        call_on_stack(movie_inner, decode_stack + sizeof(decode_stack) - 128);
      }
    }
#endif
    return;
  }
  osmedia_guest_cmd.flags = 0;
  sputs("OSMEDIA TICK ");
  sputhex((uint32_t)flags, 8);
  sputs(" LEN ");
  sputhex((uint32_t)osmedia_guest_cmd.clip_len, 8);
  sputc('\n');
  if (flags == OSMEDIA_GUEST_MISS) {
    line_miss();
    return;
  }
  if (flags != OSMEDIA_GUEST_PLAY) {
    return;
  }
#ifdef OSMEDIA_NO_FFMPEG_LINK
  line_miss();
#else
  if (osmedia_guest_cmd.clip_len == 0 ||
      osmedia_guest_cmd.clip_len > OSMEDIA_GUEST_CLIP_MAX) {
    line_miss();
    return;
  }
  sputs("OSMEDIA GO\n");
  call_on_stack(play_inner, decode_stack + sizeof(decode_stack) - 128);
#endif
}

#ifndef OSMEDIA_NO_FFMPEG_LINK
char *getenv(const char *name) {
  (void)name;
  return 0;
}
#endif
