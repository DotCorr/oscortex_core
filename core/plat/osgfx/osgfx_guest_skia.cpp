/* Guest osgfx: Skia CPU raster writes the scanout. Not Metal. Not Graphite.
 * Not a Dart fill_rect. canvas->drawRRect is the paint.
 */
#include "osgfx.h"
#include "osgfx_guest.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkSurface.h"

extern "C" {
extern struct OsGfxGuestCmd osgfx_guest_cmd;
void osgfx_guest_tick(void);
}

static uint64_t last_gen;
static int ran_ctors;

extern "C" void (*__init_array_start[])(void);
extern "C" void (*__init_array_end[])(void);

static void run_ctors(void) {
  void (**p)(void);
  if (ran_ctors != 0) {
    return;
  }
  ran_ctors = 1;
  p = __init_array_start;
  while (p < __init_array_end) {
    if (*p != 0) {
      (*p)();
    }
    p = p + 1;
  }
}

static SkColor sk_rgb(uint32_t rgb) {
  return SkColorSetARGB(255, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
}

static void draw_rrect(SkCanvas *c, int x, int y, int w, int h, int radius,
                       uint32_t rgb) {
  SkRect rect = SkRect::MakeXYWH((SkScalar)x, (SkScalar)y, (SkScalar)w,
                                 (SkScalar)h);
  SkRRect rr = SkRRect::MakeRectXY(rect, (SkScalar)radius, (SkScalar)radius);
  SkPaint paint;
  paint.setAntiAlias(true);
  paint.setStyle(SkPaint::kFill_Style);
  paint.setColor(sk_rgb(rgb));
  c->drawRRect(rr, paint);
}

static void draw_rect(SkCanvas *c, int x, int y, int w, int h, uint32_t rgb) {
  SkPaint paint;
  paint.setAntiAlias(false);
  paint.setStyle(SkPaint::kFill_Style);
  paint.setColor(sk_rgb(rgb));
  c->drawRect(SkRect::MakeXYWH((SkScalar)x, (SkScalar)y, (SkScalar)w,
                               (SkScalar)h),
              paint);
}

static void unpack_geom(uint64_t g, int *x, int *y, int *w, int *h) {
  *x = (int)((g >> 48) & 0xffff);
  *y = (int)((g >> 32) & 0xffff);
  *w = (int)((g >> 16) & 0xffff);
  *h = (int)(g & 0xffff);
}

static void paint_window(SkCanvas *c, uint64_t geom, uint32_t border) {
  int x, y, w, h, b, r;
  if (geom == 0) {
    return;
  }
  unpack_geom(geom, &x, &y, &w, &h);
  if (w < 8) {
    return;
  }
  if (h < 8) {
    return;
  }
  b = OSGFX_BORDER;
  r = OSGFX_RADIUS;
  draw_rrect(c, x + 6, y + 10, w, h, r, 0x000C2030);
  draw_rrect(c, x - b, y - b, w + b + b, h + b + b, r, border);
  draw_rrect(c, x, y, w, OSGFX_TITLE_H + 8, r, OSGFX_TITLE);
}

extern "C" void osgfx_guest_tick(void) {
  struct OsGfxGuestCmd *m;
  SkImageInfo info;
  sk_sp<SkSurface> surf;
  SkCanvas *canvas;
  int ww, hh;
  uint32_t *fb;

  run_ctors();
  m = &osgfx_guest_cmd;
  if (m->magic != OSGFX_GUEST_MAGIC) {
    return;
  }
  if ((m->flags & OSGFX_GUEST_ON) == 0) {
    return;
  }
  if (m->gen == last_gen) {
    return;
  }
  if (m->fb == 0) {
    return;
  }
  if (m->w < 8) {
    return;
  }
  if (m->h < 8) {
    return;
  }
  if (m->pitch < m->w * 4) {
    return;
  }
  ww = (int)m->w;
  hh = (int)m->h;
  fb = (uint32_t *)(uintptr_t)m->fb;
  info = SkImageInfo::Make(ww, hh, kBGRA_8888_SkColorType,
                           kUnpremul_SkAlphaType);
  surf = SkSurface::MakeRasterDirect(info, fb, (size_t)m->pitch);
  if (!surf) {
    return;
  }
  canvas = surf->getCanvas();
  paint_window(canvas, m->win0, OSGFX_UNFOCUS);
  paint_window(canvas, m->win1, OSGFX_FOCUS);
  draw_rect(canvas, 0, hh - OSGFX_CHROME_H, ww, OSGFX_CHROME_H, OSGFX_CHROME);
  if (m->pop != 0) {
    int px = (int)(m->pop >> 32);
    int py = (int)(m->pop & 0xffffffffu);
    draw_rrect(canvas, px + 4, py + 6, OSGFX_POP_W, OSGFX_POP_H, OSGFX_RADIUS,
               0x000C2030);
    draw_rrect(canvas, px, py, OSGFX_POP_W, OSGFX_POP_H, OSGFX_RADIUS,
               OSGFX_POP);
  }
  surf->flushAndSubmit();
  last_gen = m->gen;
}
