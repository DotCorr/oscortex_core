/* core/user/frame/browse.c
 *
 * BROWSE — thin FRAME client that loads a data: page through
 * oschrome.h (ADR-0115). Chrome is wm. Paint is the WebView
 * readback into the shm the compositor told us. Not CEF
 * inside this file. Compiles against osframe.h (no private
 * SYS_*).
 *
 * Hidden `go BROWSE.ELF` starts it. BROWSE_NO_INIT compiles the
 * --no-init twin (NINIT.ELF): same ABI, pixel is not PAGE.
 */

#include "osframe.h"
#include "oschrome.h"
#include "osxui_app.h"

typedef unsigned long u64;
typedef unsigned int u32;

/* The picture. derive.py reads every one of these out of this file. */
#define WIN_W 128UL
#define WIN_H 128UL
#define SURF_X 80UL
#define SURF_Y 80UL
#define WIN_PAGES 17UL
#define PX 32UL
#define PY 32UL

#define YIELD_SPIN 8000UL

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}

static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }

static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }

__attribute__((noreturn)) static void die(u64 code) {
  sys1(SYS_EXIT, code);
  for (;;) {
  }
}

static u64 desc[8] __attribute__((aligned(64))) = {0, 0, 0, 0, 0, 0, 0, 0};

/* NON-ZERO so the RW PT_LOAD has a non-zero p_filesz (m11's segment shape). */
static volatile u64 marker = 0x00A01150000011A0UL;

static u64 shm_h;
static u64 pix_va;
static u64 scratch[8];

#ifdef BROWSE_NO_INIT
static const char msg_ready[] = "BROWSE NONE\n";
#elif defined(BROWSE_NO_ONPAINT)
static const char msg_ready[] = "BROWSE NOPAIN\n";
#else
static const char msg_ready[] = "BROWSE READY\n";
#endif
static const char msg_csd[] = "BROWSE CSD";
static const char cap_browse[] = "BROWSE";

static void commit_rect(u64 x, u64 y, u64 w, u64 h, u64 seq) {
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = shm_h;
  desc[WM_DESC_X] = x;
  desc[WM_DESC_Y] = y;
  desc[WM_DESC_W] = w;
  desc[WM_DESC_H] = h;
  desc[WM_DESC_STRIDE] = seq;
  desc[WM_DESC_OFFSET] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_RET_FLOOR) {
    die(0xB0000004UL | (frames << 32));
  }
  scratch[0] = frames;
}

static void blit_view(OsChrome *b, u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < WIN_H) {
    u64 px = 0;
    while (px < WIN_W) {
      u32 pix = 0;
      if (oschrome_pixel(b, (int)px, (int)py, &pix) != OSCHROME_OK) {
        die(0xB0000005UL);
      }
      p[py * WIN_W + px] = pix;
      px = px + 1;
    }
    py = py + 1;
  }
}

void _start(void) {
  char url[512];
  OsChrome *b;
#ifdef BROWSE_NO_INIT
  static char *av[] = {"browse", "--no-init", 0};
#elif defined(BROWSE_NO_ONPAINT)
  static char *av[] = {"browse", "--no-onpaint", 0};
#endif

  shm_h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (shm_h >= WM_RET_FLOOR) {
    die(0xB0000002UL);
  }

  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = shm_h;
  desc[WM_DESC_X] = SURF_X;
  desc[WM_DESC_Y] = SURF_Y;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  pix_va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (pix_va >= WM_RET_FLOOR) {
    die(0xB0000003UL | (pix_va << 32));
  }

#if defined(BROWSE_NO_INIT) || defined(BROWSE_NO_ONPAINT)
  if (oschrome_init(2, av) != OSCHROME_OK) {
    die(0xB0000010UL);
  }
#else
  if (oschrome_init(0, 0) != OSCHROME_OK) {
    die(0xB0000010UL);
  }
#endif
  if (oschrome_backend_chromium() == 0) {
    die(0xB0000011UL);
  }
  b = oschrome_create((int)WIN_W, (int)WIN_H);
  if (b == 0) {
    oschrome_shutdown();
    die(0xB0000012UL);
  }
  if (oschrome_default_data_url(url, (int)sizeof(url)) < 0) {
    oschrome_destroy(b);
    oschrome_shutdown();
    die(0xB0000013UL);
  }
  if (oschrome_load_url(b, url) != OSCHROME_OK) {
    oschrome_destroy(b);
    oschrome_shutdown();
    die(0xB0000014UL);
  }
  if (oschrome_pump(b, 0) != OSCHROME_OK) {
#if defined(BROWSE_NO_INIT) || defined(BROWSE_NO_ONPAINT)
    /* no-init / no-onpaint pump is OK even without a paint. */
#else
    oschrome_destroy(b);
    oschrome_shutdown();
    die(0xB0000015UL);
#endif
  }
  blit_view(b, pix_va);
  osxui_app_csd(shm_h, WIN_W, cap_browse, 6UL);
  wr(msg_csd, sizeof(msg_csd) - 1);
  commit_rect(0, 0, WIN_W, WIN_H, 1);
  wr(msg_ready, sizeof(msg_ready) - 1);

  if (marker != 0x00A01150000011A0UL) {
    die(0xB0000006UL);
  }

  for (;;) {
    (void)sys1(SYS_KBDEVENT, KBD_OP_POP);
    (void)sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    {
      volatile u64 spin = 0;
      while (spin < YIELD_SPIN) {
        spin = spin + 1;
      }
    }
    sys1(SYS_YIELD, 0);
  }
}
