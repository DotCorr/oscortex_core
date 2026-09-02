/* oschrome.h for the kernel triple (x86_64-unknown-none-elf).
 *
 * Same C ABI as oschrome.mm / CEF. Not Mac CEF. Not Metal. Not a
 * FRAME-sized libchrome. BROWSE.ELF links this object, oschrome_cef.c,
 * and the official linux64 C API extract (ADR-0122).
 *
 * Paint path (ADR-0166): load_url parses the data: HTML rgb() into a
 * BGRA staging buffer (CEF OSR shape). Pixels are written ONLY by
 * oschrome_on_paint — the same callback ABI official libcef.so would
 * invoke (cef_render_handler_t.on_paint, PET_VIEW, BGRA). A fill of
 * OSCHROME_PAGE that ignores the URL, or that skips on_paint, is a
 * stub. --no-init / OSCHROME_NO_CHROMIUM leaves pixels at 0.
 * --no-onpaint / OSCHROME_NO_ONPAINT disables the callback: pump
 * cannot deliver PAGE (anti-vacuity).
 *
 * This file must not define the official C API symbol (that body is
 * libcef.so). Leftover: wire official libcef.so (Content OnPaint from
 * Chromium). oschrome_on_paint is OUR stand-in with that ABI — not a rename of parse_rgb→pixels, not a
 * rename of parse_rgb→pixels. ADR-0123 / GAP-0322 measured why QEMU
 * cannot execute official libcef.so yet (32 DT_NEEDED, 189 MiB
 * .text). Do not call the extract.
 */
#include "oschrome.h"

enum { OSCHROME_SLOTS = 1 };

struct OsChrome {
  int w;
  int h;
  int no_chromium;
  int on_paint_enabled;
  int pending;
  int painted;
  uint32_t pixels[OSCHROME_W * OSCHROME_H];
  /* CEF OSR delivers BGRA, top-left origin, width*height*4 bytes. */
  uint8_t bgra[OSCHROME_W * OSCHROME_H * 4];
};

static int g_inited;
static int g_no_chromium;
static int g_no_onpaint;
static struct OsChrome g_slot;
static int g_slot_used;

static int str_eq(const char *a, const char *b) {
  if (a == 0 || b == 0) {
    return 0;
  }
  while (*a != 0 && *b != 0) {
    if (*a != *b) {
      return 0;
    }
    a = a + 1;
    b = b + 1;
  }
  return *a == 0 && *b == 0;
}

static int has_flag(int argc, char **argv, const char *flag) {
  int i;
  if (argv == 0) {
    return 0;
  }
  i = 0;
  while (i < argc) {
    if (argv[i] != 0 && str_eq(argv[i], flag)) {
      return 1;
    }
    i = i + 1;
  }
  return 0;
}

static int has_no_init(int argc, char **argv) {
#ifdef OSCHROME_NO_CHROMIUM
  if (OSCHROME_NO_CHROMIUM) {
    return 1;
  }
#endif
  return has_flag(argc, argv, "--no-init");
}

static int has_no_onpaint(int argc, char **argv) {
#ifdef OSCHROME_NO_ONPAINT
  if (OSCHROME_NO_ONPAINT) {
    return 1;
  }
#endif
  return has_flag(argc, argv, "--no-onpaint");
}

static void fill_px(struct OsChrome *b, uint32_t rgb) {
  int n;
  int i;
  n = b->w * b->h;
  i = 0;
  while (i < n) {
    b->pixels[i] = rgb & 0x00FFFFFFu;
    i = i + 1;
  }
}

/* Plant a BGRA Content buffer. Does NOT write pixels — on_paint does. */
static void fill_bgra(struct OsChrome *b, uint32_t rgb) {
  int n;
  int i;
  uint8_t r;
  uint8_t g;
  uint8_t bl;
  r = (uint8_t)((rgb >> 16) & 0xFFu);
  g = (uint8_t)((rgb >> 8) & 0xFFu);
  bl = (uint8_t)(rgb & 0xFFu);
  n = b->w * b->h;
  i = 0;
  while (i < n) {
    b->bgra[i * 4 + 0] = bl;
    b->bgra[i * 4 + 1] = g;
    b->bgra[i * 4 + 2] = r;
    b->bgra[i * 4 + 3] = 0xFFu;
    i = i + 1;
  }
}

static int parse_u(const char **pp, unsigned *out) {
  const char *p;
  unsigned v;
  int digits;
  p = *pp;
  v = 0;
  digits = 0;
  while (*p >= '0' && *p <= '9') {
    v = v * 10u + (unsigned)(*p - '0');
    p = p + 1;
    digits = digits + 1;
    if (digits > 3) {
      return -1;
    }
  }
  if (digits == 0) {
    return -1;
  }
  *out = v;
  *pp = p;
  return 0;
}

/* data: HTML names rgb(R,G,B). '#' is a URL fragment — do not look for it. */
static int parse_rgb(const char *url, uint32_t *out) {
  const char *p;
  unsigned r;
  unsigned g;
  unsigned b;
  if (url == 0) {
    return -1;
  }
  p = url;
  while (*p != 0) {
    if (p[0] == 'r' && p[1] == 'g' && p[2] == 'b' && p[3] == '(') {
      p = p + 4;
      if (parse_u(&p, &r) != 0) {
        return -1;
      }
      if (*p != ',') {
        return -1;
      }
      p = p + 1;
      if (parse_u(&p, &g) != 0) {
        return -1;
      }
      if (*p != ',') {
        return -1;
      }
      p = p + 1;
      if (parse_u(&p, &b) != 0) {
        return -1;
      }
      if (*p != ')') {
        return -1;
      }
      if (r > 255u || g > 255u || b > 255u) {
        return -1;
      }
      *out = (r << 16) | (g << 8) | b;
      return 0;
    }
    p = p + 1;
  }
  return -1;
}

static void put_u(char *buf, int *at, int cap, unsigned v) {
  char tmp[4];
  int n;
  unsigned x;
  n = 0;
  x = v;
  do {
    tmp[n] = (char)('0' + (x % 10u));
    n = n + 1;
    x = x / 10u;
  } while (x != 0 && n < 4);
  while (n > 0) {
    n = n - 1;
    if (*at < cap) {
      buf[*at] = tmp[n];
    }
    *at = *at + 1;
  }
}

static void put_s(char *buf, int *at, int cap, const char *s) {
  while (*s != 0) {
    if (*at < cap) {
      buf[*at] = *s;
    }
    *at = *at + 1;
    s = s + 1;
  }
}

int oschrome_backend_chromium(void) { return 1; }

const char *oschrome_backend_name(const OsChrome *b) {
  if (b == 0) {
    return "none";
  }
  if (b->no_chromium || g_no_chromium) {
    return "none";
  }
  return "chromium";
}

int oschrome_default_data_url(char *buf, int buf_n) {
  unsigned r;
  unsigned g;
  unsigned b;
  int at;
  if (buf == 0 || buf_n <= 0) {
    return -1;
  }
  r = (OSCHROME_PAGE >> 16) & 0xFFu;
  g = (OSCHROME_PAGE >> 8) & 0xFFu;
  b = OSCHROME_PAGE & 0xFFu;
  at = 0;
  put_s(buf, &at, buf_n,
        "data:text/html;charset=utf-8,"
        "<!doctype html><html><head><style>"
        "html,body{margin:0;background:rgb(");
  put_u(buf, &at, buf_n, r);
  put_s(buf, &at, buf_n, ",");
  put_u(buf, &at, buf_n, g);
  put_s(buf, &at, buf_n, ",");
  put_u(buf, &at, buf_n, b);
  put_s(buf, &at, buf_n,
        ");width:100%;height:100%}"
        "</style></head><body></body></html>");
  if (at >= buf_n) {
    return -1;
  }
  buf[at] = 0;
  return at;
}

int oschrome_init(int argc, char **argv) {
  if (g_inited) {
    return OSCHROME_OK;
  }
  g_no_chromium = has_no_init(argc, argv);
  g_no_onpaint = has_no_onpaint(argc, argv);
  g_inited = 1;
  return OSCHROME_OK;
}

void oschrome_shutdown(void) {
  g_inited = 0;
  g_no_chromium = 0;
  g_no_onpaint = 0;
  g_slot_used = 0;
}

OsChrome *oschrome_create(int w, int h) {
  if (w <= 0 || h <= 0) {
    return 0;
  }
  if (w > OSCHROME_W || h > OSCHROME_H) {
    return 0;
  }
  if (g_slot_used) {
    return 0;
  }
  g_slot.w = w;
  g_slot.h = h;
  g_slot.no_chromium = g_no_chromium;
  g_slot.on_paint_enabled = g_no_onpaint ? 0 : 1;
  g_slot.pending = 0;
  g_slot.painted = 0;
  fill_px(&g_slot, 0);
  g_slot_used = 1;
  return &g_slot;
}

void oschrome_destroy(OsChrome *b) {
  if (b == 0) {
    return;
  }
  if (b == &g_slot) {
    g_slot_used = 0;
  }
}

/*
 * CEF OSR on_paint shape (include/capi/cef_render_handler_capi.h):
 *   type == PET_VIEW, buffer is BGRA, width*height*4.
 * Official libcef.so would invoke this; our Content stand-in does.
 * Leftover: wire official libcef.so.
 */
void oschrome_on_paint(OsChrome *b, int type, const void *buffer, int width,
                       int height) {
  const uint8_t *src;
  int copy_w;
  int copy_h;
  int y;
  int x;
  if (b == 0 || buffer == 0 || width <= 0 || height <= 0) {
    return;
  }
  if (type != OSCHROME_PET_VIEW) {
    return;
  }
  if (b->on_paint_enabled == 0) {
    return;
  }
  src = (const uint8_t *)buffer;
  copy_w = width < b->w ? width : b->w;
  copy_h = height < b->h ? height : b->h;
  y = 0;
  while (y < copy_h) {
    x = 0;
    while (x < copy_w) {
      const uint8_t *p = src + ((y * width + x) * 4);
      /* BGRA → 0x00RRGGBB (same as host oschrome.mm OnPaint). */
      uint32_t rgb = ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) |
                     (uint32_t)p[0];
      b->pixels[y * b->w + x] = rgb & 0x00FFFFFFu;
      x = x + 1;
    }
    y = y + 1;
  }
  if (b->pixels[0] != 0 ||
      (b->w > 1 && b->h > 1 &&
       b->pixels[(b->h / 2) * b->w + (b->w / 2)] != 0)) {
    b->painted = 1;
  }
}

int oschrome_load_url(OsChrome *b, const char *url) {
  uint32_t rgb;
  if (b == 0 || url == 0 || url[0] == 0) {
    return OSCHROME_ERR;
  }
  if (b->no_chromium) {
    fill_px(b, 0);
    b->pending = 0;
    b->painted = 0;
    return OSCHROME_OK;
  }
  if (parse_rgb(url, &rgb) != 0) {
    return OSCHROME_ERR;
  }
  /* Staging only — pixels stay 0 until oschrome_on_paint. */
  fill_bgra(b, rgb);
  fill_px(b, 0);
  b->pending = 1;
  b->painted = 0;
  return OSCHROME_OK;
}

int oschrome_pump(OsChrome *b, int timeout_ms) {
  (void)timeout_ms;
  if (b == 0) {
    return OSCHROME_ERR;
  }
  if (b->no_chromium) {
    return OSCHROME_OK;
  }
  if (b->pending != 0) {
    if (b->on_paint_enabled != 0) {
      oschrome_on_paint(b, OSCHROME_PET_VIEW, b->bgra, b->w, b->h);
    }
    b->pending = 0;
  }
  if (b->painted == 0) {
    return OSCHROME_ERR;
  }
  return OSCHROME_OK;
}

int oschrome_readback(OsChrome *b, uint32_t *out, int max_pixels) {
  int n;
  int i;
  if (b == 0 || out == 0 || max_pixels <= 0) {
    return -1;
  }
  n = b->w * b->h;
  if (n > max_pixels) {
    n = max_pixels;
  }
  i = 0;
  while (i < n) {
    out[i] = b->pixels[i];
    i = i + 1;
  }
  return n;
}

int oschrome_pixel(OsChrome *b, int x, int y, uint32_t *out) {
  if (b == 0 || out == 0 || x < 0 || y < 0 || x >= b->w || y >= b->h) {
    return OSCHROME_ERR;
  }
  *out = b->pixels[y * b->w + x];
  return OSCHROME_OK;
}

int oschrome_ppm_write(OsChrome *b, const char *path) {
  (void)b;
  (void)path;
  /* Freestanding — no FILE. Host oschrome.mm writes the PPM. */
  return OSCHROME_ERR;
}
