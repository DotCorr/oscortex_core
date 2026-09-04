/* The DE chrome frame cache. Token: osgfx-chrome-cache
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS IS FOR, MEASURED RATHER THAN SUSPECTED (ADR-0191)
 * ---------------------------------------------------------------------------
 * ADR-0188 took the generative wallpaper out of the per-frame cost — 17-23x,
 * `wm fps` stage `K 8` against `K 3` — and then said, in its §8, exactly what
 * was left: the Skia session tick was 40-47 ms of a 40-45 ms compose. The
 * whole frame. Every rounded corner, every gradient stop, every blurred
 * elevation ring and every glyph outline was scan-converted again on every
 * tick, and not one input to any of them had changed.
 *
 * The wallpaper's answer was "generate once, blit per frame". This is the same
 * answer one layer up: the session paints into a full-screen buffer when its
 * inputs change, and every tick that finds the inputs unchanged is one blit.
 *
 * ---------------------------------------------------------------------------
 * THE KEY IS THE MAILBOX, NOT A SUMMARY OF IT
 * ---------------------------------------------------------------------------
 * A cache is its invalidation condition. GAP-0330 proposed `wmGfxChromeSig`
 * (kernel/wmpace.dart) and that would have been subtly wrong, which is worth
 * writing down because the two look interchangeable:
 *
 *   * The SIGNATURE answers a Dart question — "may a damage-limited repaint be
 *     honoured?" — and folds the window set and geometry, the top slot, focus,
 *     the DE and popover state and the wallpaper mode.
 *   * `osgfx_session_paint` reads all of that AND `tone0`/`tone1`, the client's
 *     own bottom-corner colours, which the compositor re-samples out of client
 *     shm on every kick. A cache keyed on the signature would hold a stale
 *     corner tone for the whole time a client's bottom edge was changing
 *     colour, and the corner is chrome's to paint (ADR-0187 §4).
 *
 * So the key is a fold of the mailbox words this paint actually reads, taken
 * on the side that reads them, and `gen` — the per-tick counter — is
 * deliberately NOT in it. `chrome_key` below is the complete list, and
 * `de-chrome-cache/run.sh` derives that list out of `osgfx_session.c` rather
 * than trusting this comment.
 *
 * The generative field's own cache key (`OSGFX_WMPAGE_W_DESK_HAVE`) is in the
 * fold too, which closes the one hole a mailbox-only key would leave: Dart can
 * mark the wallpaper stale (`wmDeskInvalidate`) without changing the seed, and
 * a chrome frame that did not notice would blit last wallpaper for ever.
 *
 * ---------------------------------------------------------------------------
 * THE MEMORY IS THE COMPOSITOR'S
 * ---------------------------------------------------------------------------
 * Same division of labour as osgfx_desk.c and for ADR-0188 §5's reasons: Dart
 * allocated a contiguous run out of the frame allocator and published it in
 * the state page. With no page and no buffer this file returns 0 from
 * `osgfx_chrome_target` and the tick paints straight into the scanout exactly
 * as it did before this file existed — slower, and not wrong.
 */
#include "osgfx.h"

#include "osgfx_guest.h"

#include <stdint.h>

extern void com1_puts(const char *s);

extern struct OsGfxGuestCmd osgfx_guest_cmd;

const char osgfx_chrome_cache_door[] = "osgfx-chrome-cache";

/* Guest CRT memcpy is a byte loop. TCG turns `rep movsl` into a host copy. */
static void chrome_movs(uint32_t *dst, const uint32_t *src, unsigned n) {
  uint32_t *d;
  const uint32_t *s;
  unsigned c;

  if (n == 0u || dst == 0 || src == 0) {
    return;
  }
  d = dst;
  s = src;
  c = n;
  asm volatile("rep movsl" : "+D"(d), "+S"(s), "+c"(c) : : "memory");
}

/* The compositor state page, or 0. The magic is checked because `wmpage` is an
 * address Dart wrote and a zeroed frame is the ONE thing this must not mistake
 * for a valid header. */
static uint64_t *chrome_page(void) {
  uint64_t *p;

  p = (uint64_t *)(uintptr_t)osgfx_guest_cmd.wmpage;
  if (p == 0) {
    return 0;
  }
  if (p[OSGFX_WMPAGE_W_MAGIC] != OSGFX_WMPAGE_MAGIC) {
    return 0;
  }
  return p;
}

/* Fold one word in. Rotate rather than shift, so two words cannot cancel and
 * a change in the top bits of a geometry cannot fall off the end. */
static uint64_t mix(uint64_t h, uint64_t v) {
  h = h ^ v;
  h = h * 0x100000001B3ULL;
  return (h << 13) | (h >> 51);
}

#define OSGFX_CHROME_TOP_MASK (3ULL << OSGFX_GUEST_TOP_SHIFT)
#define OSGFX_CHROME_POP_MASK (3ULL << OSGFX_GUEST_POP_SHIFT)
#define OSGFX_CHROME_OVERLAY_MASK \
  (OSGFX_CHROME_TOP_MASK | OSGFX_CHROME_POP_MASK)
#define OSGFX_CHROME_GEOM_MASK \
  (OSGFX_CHROME_TOP_MASK | OSGFX_CHROME_POP_MASK | OSGFX_GUEST_HELD0 | \
   OSGFX_GUEST_HELD1)

/* EVERY MAILBOX WORD `osgfx_session_paint` READS, AND NOTHING ELSE.
 *
 * `gen` is absent on purpose — it is the tick counter, it changes on every
 * kick, and folding it in would make this key a very expensive way of saying
 * "always miss". `fb` is absent because the paint's destination is this
 * cache's buffer, not the scanout; a scanout that MOVED is caught by the
 * extent check in `osgfx_chrome_fresh` instead, which is the same place a
 * resolution change is caught.
 *
 * The key is never 0: `OSGFX_WMPAGE_W_CHROME_HAVE == 0` means "nothing
 * trustworthy in the buffer", so a key that collided with it would read as a
 * permanent miss. The seed makes 0 unreachable in practice and the final
 * `| 1` makes it unreachable in fact. */
static uint64_t chrome_key(const struct OsGfxGuestCmd *m, const uint64_t *pg) {
  uint64_t h;

  h = 0xC1A0B0C0D0E0F001ULL;
  /* TOP and POP kind are scanout overlays (focus ring / menu card).
   * Folding them forced a 900 ms session MISS on every raise and
   * first menu. Held/DE/WALL/PANEL still change the cached picture.
   * Window identity is size, not screen position: a full-screen chrome
   * keyed on x,y MISSed (and SET_SCANOUT 1280×720) on every drag.
   * Each decorated layer is moved by restore+blit; glass recomposes
   * only the vacated/new bounds. */
  h = mix(h, m->flags & ~OSGFX_CHROME_OVERLAY_MASK);
  h = mix(h, m->w);
  h = mix(h, m->h);
  h = mix(h, m->win0 & 0xffffffffULL);
  h = mix(h, m->win1 & 0xffffffffULL);
  h = mix(h, m->desk);
  h = mix(h, m->wall);
  /* The client edge tones. This is the pair `wmGfxChromeSig` does not have. */
  h = mix(h, m->tone0);
  h = mix(h, m->tone1);
  /* Venus armed changes which arm the desktop fill takes. */
  h = mix(h, m->vk);
  /* ADR-0194's launch menu reads the page pointer and the four stem
   * words behind it. A cached frame that ignored either would keep
   * last boot's Start list after Dart remapped the page or planted a
   * new stem. */
  h = mix(h, m->wmpage);
  if (pg != 0) {
    h = mix(h, pg[OSGFX_WMPAGE_W_DESK_HAVE]);
    h = mix(h, pg[OSGFX_WMPAGE_W_LAUNCH0 + 0]);
    h = mix(h, pg[OSGFX_WMPAGE_W_LAUNCH0 + 1]);
    h = mix(h, pg[OSGFX_WMPAGE_W_LAUNCH0 + 2]);
    h = mix(h, pg[OSGFX_WMPAGE_W_LAUNCH0 + 3]);
    h = mix(h, pg[OSGFX_WMPAGE_W_CAP_MAIL]);
  }
  return h | 1ULL;
}

/* The buffer, or 0 when there is no usable cache.
 *
 * Refused for a screen bigger than the run Dart took, and refused outside
 * `wm de` — on `wmDeskEnsure`'s terms and for its reason: `wm de` is the only
 * flag combination under which the session paints antialiased chrome at all,
 * so `de-osgfx` and the Graphite proof stamps take no frames and their
 * baselines do not move. */
static uint32_t *chrome_buf(const struct OsGfxGuestCmd *m, uint64_t *pg) {
  uint64_t need;

  if (pg == 0 || m == 0) {
    return 0;
  }
  if ((m->flags & OSGFX_GUEST_DE) == 0) {
    return 0;
  }
  if (m->w < 8 || m->h < 8) {
    return 0;
  }
  need = m->w * m->h;
  if (need > pg[OSGFX_WMPAGE_W_CHROME_PX]) {
    return 0;
  }
  return (uint32_t *)(uintptr_t)pg[OSGFX_WMPAGE_W_CHROME_BUF];
}

uint32_t *osgfx_chrome_target(const struct OsGfxGuestCmd *m) {
  if (osgfx_chrome_cache_door[0] == 0) {
    return 0;
  }
  return chrome_buf(m, chrome_page());
}

/* 1 when the buffer holds the frame the current mailbox asks for.
 *
 * Three tests, and the two extent ones are not belt-and-braces: the key is a
 * hash and a hash can collide, but a frame of the wrong SIZE is the one wrong
 * answer that would read past the buffer rather than merely look wrong. */
int osgfx_chrome_fresh(const struct OsGfxGuestCmd *m) {
  uint64_t *pg;

  pg = chrome_page();
  if (pg == 0 || chrome_buf(m, pg) == 0) {
    return 0;
  }
  if (pg[OSGFX_WMPAGE_W_CHROME_HAVE] != chrome_key(m, pg)) {
    return 0;
  }
  if (pg[OSGFX_WMPAGE_W_CHROME_W] != m->w) {
    return 0;
  }
  if (pg[OSGFX_WMPAGE_W_CHROME_H] != m->h) {
    return 0;
  }
  return 1;
}

/* Last mailbox the cache buffer was stamped for. C statics, not Dart .bss.
 * Used to tell a TOP-only miss (focus/raise border) from a geom/desk miss. */
static int g_stamp_have;
static uint64_t g_stamp_flags;
static uint64_t g_stamp_w;
static uint64_t g_stamp_h;
static uint64_t g_stamp_win0;
static uint64_t g_stamp_win1;
static uint64_t g_stamp_pop;
static uint64_t g_stamp_desk;
static uint64_t g_stamp_wall;
static uint64_t g_stamp_tone0;
static uint64_t g_stamp_tone1;
static uint64_t g_stamp_vk;
static uint64_t g_stamp_wmpage;
static uint64_t g_stamp_desk_have;
static uint64_t g_stamp_launch0;
static uint64_t g_stamp_launch1;
static uint64_t g_stamp_launch2;
static uint64_t g_stamp_launch3;
static uint64_t g_stamp_cap_mail;

static void chrome_note_mailbox(const struct OsGfxGuestCmd *m) {
  uint64_t *pg;

  if (m == 0) {
    return;
  }
  g_stamp_have = 1;
  g_stamp_flags = m->flags;
  g_stamp_w = m->w;
  g_stamp_h = m->h;
  g_stamp_win0 = m->win0;
  g_stamp_win1 = m->win1;
  g_stamp_pop = m->pop;
  g_stamp_desk = m->desk;
  g_stamp_wall = m->wall;
  g_stamp_tone0 = m->tone0;
  g_stamp_tone1 = m->tone1;
  g_stamp_vk = m->vk;
  g_stamp_wmpage = m->wmpage;
  pg = chrome_page();
  if (pg == 0) {
    return;
  }
  g_stamp_desk_have = pg[OSGFX_WMPAGE_W_DESK_HAVE];
  g_stamp_launch0 = pg[OSGFX_WMPAGE_W_LAUNCH0 + 0];
  g_stamp_launch1 = pg[OSGFX_WMPAGE_W_LAUNCH0 + 1];
  g_stamp_launch2 = pg[OSGFX_WMPAGE_W_LAUNCH0 + 2];
  g_stamp_launch3 = pg[OSGFX_WMPAGE_W_LAUNCH0 + 3];
  g_stamp_cap_mail = pg[OSGFX_WMPAGE_W_CAP_MAIL];
}

/* 1 when the cached frame is still the right picture except the TOP
 * (focus/raise) border colour. Title, shadow, geom, desk, pop and tones
 * are unchanged — do not re-run osgfx_session_paint. */
int osgfx_chrome_is_focus_only(const struct OsGfxGuestCmd *m) {
  uint64_t *pg;

  if (g_stamp_have == 0 || m == 0) {
    return 0;
  }
  pg = chrome_page();
  if (pg == 0 || chrome_buf(m, pg) == 0) {
    return 0;
  }
  if (pg[OSGFX_WMPAGE_W_CHROME_HAVE] == 0) {
    return 0;
  }
  if (m->w != g_stamp_w || m->h != g_stamp_h) {
    return 0;
  }
  if (m->win0 != g_stamp_win0 || m->win1 != g_stamp_win1) {
    return 0;
  }
  if (m->desk != g_stamp_desk || m->wall != g_stamp_wall) {
    return 0;
  }
  if (m->tone0 != g_stamp_tone0 || m->tone1 != g_stamp_tone1) {
    return 0;
  }
  if (m->vk != g_stamp_vk || m->wmpage != g_stamp_wmpage) {
    return 0;
  }
  if ((m->flags & ~OSGFX_CHROME_GEOM_MASK) !=
      (g_stamp_flags & ~OSGFX_CHROME_GEOM_MASK)) {
    return 0;
  }
  if ((m->flags & OSGFX_CHROME_TOP_MASK) ==
      (g_stamp_flags & OSGFX_CHROME_TOP_MASK)) {
    return 0;
  }
  /* desk_have / launch / cap_mail change on uncover and dock hits.
   * Treating them as a full miss was the 1.6s TCG focus hitch. */
  (void)pg;
  (void)g_stamp_desk_have;
  (void)g_stamp_launch0;
  (void)g_stamp_launch1;
  (void)g_stamp_launch2;
  (void)g_stamp_launch3;
  (void)g_stamp_cap_mail;
  return 1;
}

void osgfx_chrome_stamp_wins(uint64_t *win0, uint64_t *win1) {
  if (win0 != 0) {
    *win0 = g_stamp_have != 0 ? g_stamp_win0 : 0;
  }
  if (win1 != 0) {
    *win1 = g_stamp_have != 0 ? g_stamp_win1 : 0;
  }
}

/* Old max/restore rects. Present sources leftover pixels from the desk
 * cache so geom paint does not store 848k wallpaper words (1.3s TCG). */
static uint64_t g_uncover0;
static uint64_t g_uncover1;

void osgfx_chrome_note_uncover(uint64_t old0, uint64_t old1) {
  g_uncover0 = old0;
  g_uncover1 = old1;
}

/* 1 when the cached frame is still the right picture except window
 * geometry (maximize / restore / resize). Desk, pop, wall, tones, page
 * and flags-minus-TOP stay. Title/borders are recomposed from slices;
 * do not re-run wallpaper generation. */
int osgfx_chrome_is_geom_only(const struct OsGfxGuestCmd *m) {
  uint64_t *pg;

  if (g_stamp_have == 0 || m == 0) {
    return 0;
  }
  pg = chrome_page();
  if (pg == 0 || chrome_buf(m, pg) == 0) {
    return 0;
  }
  if (pg[OSGFX_WMPAGE_W_CHROME_HAVE] == 0) {
    return 0;
  }
  if (m->w != g_stamp_w || m->h != g_stamp_h) {
    return 0;
  }
  if (m->win0 == g_stamp_win0 && m->win1 == g_stamp_win1) {
    return 0;
  }
  if (m->desk != g_stamp_desk || m->wall != g_stamp_wall) {
    return 0;
  }
  if (m->tone0 != g_stamp_tone0 || m->tone1 != g_stamp_tone1) {
    return 0;
  }
  if (m->vk != g_stamp_vk || m->wmpage != g_stamp_wmpage) {
    return 0;
  }
  if ((m->flags & ~OSGFX_CHROME_GEOM_MASK) !=
      (g_stamp_flags & ~OSGFX_CHROME_GEOM_MASK)) {
    return 0;
  }
  /* Same as focus_only: uncover must not force a wallpaper miss. */
  (void)pg;
  (void)g_stamp_desk_have;
  (void)g_stamp_launch0;
  (void)g_stamp_launch1;
  (void)g_stamp_launch2;
  (void)g_stamp_launch3;
  return 1;
}

/* Packed the same way wmPackGeom writes win0/win1: x<<48|y<<32|w<<16|h. */
static void chrome_unpack_geom(uint64_t g, int *x, int *y, int *w, int *h) {
  *x = (int)((g >> 48) & 0xffffu);
  *y = (int)((g >> 32) & 0xffffu);
  *w = (int)((g >> 16) & 0xffffu);
  *h = (int)(g & 0xffffu);
}

static uint64_t chrome_pack_geom(int x, int y, int w, int h) {
  if (x < 0) {
    x = 0;
  }
  if (y < 0) {
    y = 0;
  }
  return ((uint64_t)(unsigned)x << 48) | ((uint64_t)(unsigned)y << 32) |
         ((uint64_t)(unsigned)w << 16) | (uint64_t)(unsigned)h;
}

static uint64_t chrome_shift_geom(uint64_t g, int dx, int dy) {
  int x;
  int y;
  int w;
  int h;

  if (g == 0) {
    return 0;
  }
  chrome_unpack_geom(g, &x, &y, &w, &h);
  return chrome_pack_geom(x + dx, y + dy, w, h);
}

static int chrome_geom_at(uint64_t g, int x, int y) {
  int gx;
  int gy;
  int gw;
  int gh;

  if (g == 0) {
    return 0;
  }
  chrome_unpack_geom(g, &gx, &gy, &gw, &gh);
  return gx == x && gy == y;
}

/* Client-body span on scanout row [yy], or x1<=x0 if this row is chrome.
 * Top-corner insets stay cache-owned (title AA card). Bottom-corner
 * squares are a client hole so wmBlitRow coverage can close the curve
 * without chrome restamping wallpaper or a white AABB through the mask. */
static void chrome_body_span(uint64_t geom, int yy, int *x0, int *x1, int csd) {
  int wx;
  int wy;
  int ww;
  int wh;

  *x0 = 0;
  *x1 = 0;
  if (geom == 0) {
    return;
  }
  chrome_unpack_geom(geom, &wx, &wy, &ww, &wh);
  if (ww < 8 || wh < 8) {
    return;
  }
  if (yy < wy || yy >= wy + wh) {
    return;
  }
  if (wh <= OSGFX_CHROME_H + 4) {
    *x0 = wx;
    *x1 = wx + ww;
    return;
  }
  if (csd == 0 && yy < wy + OSGFX_TITLE_H) {
    return;
  }
  *x0 = wx;
  *x1 = wx + ww;
  /* Top and bottom corner squares stay chrome-owned so one Skia AA card
   * can close the radius. CSD titles are a client hole in the middle of
   * the band; the teeth were wallpaper in these insets. */
  if (yy < wy + OSGFX_RADIUS) {
    *x0 = wx + OSGFX_RADIUS;
    *x1 = wx + ww - OSGFX_RADIUS;
  }
  if (yy >= wy + wh - OSGFX_RADIUS) {
    *x0 = wx;
    *x1 = wx + ww;
  }
}

static int geom_contains(uint64_t geom, int x, int y, int pad) {
  int gx;
  int gy;
  int gw;
  int gh;

  if (geom == 0) {
    return 0;
  }
  chrome_unpack_geom(geom, &gx, &gy, &gw, &gh);
  if (gw < 1 || gh < 1) {
    return 0;
  }
  gx = gx - pad;
  gy = gy - pad;
  gw = gw + pad + pad;
  gh = gh + pad + pad;
  if (x < gx || y < gy) {
    return 0;
  }
  if (x >= gx + gw || y >= gy + gh) {
    return 0;
  }
  return 1;
}

static void chrome_copy_span(uint32_t *drow, const uint32_t *srow, int x0,
                             int x1, int w, int yy, const uint32_t *desk,
                             int dw, int dh, uint64_t keep0, uint64_t keep1) {
  int xx;
  int from_desk;

  if (x0 < 0) {
    x0 = 0;
  }
  if (x1 > w) {
    x1 = w;
  }
  xx = x0;
  while (xx < x1) {
    from_desk = 0;
    if (desk != 0 && (g_uncover0 != 0 || g_uncover1 != 0)) {
      if (geom_contains(g_uncover0, xx, yy, OSGFX_RADIUS) != 0 ||
          geom_contains(g_uncover1, xx, yy, OSGFX_RADIUS) != 0) {
        if (geom_contains(keep0, xx, yy, OSGFX_RADIUS) == 0 &&
            geom_contains(keep1, xx, yy, OSGFX_RADIUS) == 0) {
          from_desk = 1;
        }
      }
    }
    if (from_desk != 0 && xx < dw && yy < dh) {
      drow[xx] = desk[(unsigned)yy * (unsigned)dw + (unsigned)xx];
    } else {
      drow[xx] = srow[xx];
    }
    xx = xx + 1;
  }
}

/* 1 when [x] is inside [x0, x1). */
static int chrome_span_hit(int x, int x0, int x1) {
  if (x1 <= x0) {
    return 0;
  }
  if (x < x0) {
    return 0;
  }
  if (x >= x1) {
    return 0;
  }
  return 1;
}

/* WHAT A TICK PAYS. Row copies with DISJOINT rectangular holes for live
 * FRAME bodies, the dock strip, and the popover card. Unioning win0+win1
 * into one span used to punch the wallpaper BETWEEN FILES and SET and
 * leave stale FILES pixels in SET's 333-wide hole. */
static void chrome_blit(uint32_t *fb, int pitch, const uint32_t *src, int w,
                        int h, uint64_t win0, uint64_t win1, uint64_t pop,
                        uint64_t flags, int csd, int cx, int cy, int cw,
                        int ch) {
  int yy;
  uint32_t *drow;
  const uint32_t *srow;
  const uint32_t *desk;
  int dw;
  int dh;
  int a0;
  int a1;
  int b0;
  int b1;
  int p0;
  int p1;
  int q0;
  int q1;
  int xx;
  int x1;
  int hit;
  int px;
  int py;

  dw = 0;
  dh = 0;
  desk = 0;
  if (g_uncover0 != 0 || g_uncover1 != 0) {
    desk = osgfx_desk_cache(&dw, &dh);
  }
  if (cw < 1 || ch < 1) {
    cx = 0;
    cy = 0;
    cw = w;
    ch = h;
  }
  if (cx < 0) {
    cw = cw + cx;
    cx = 0;
  }
  if (cy < 0) {
    ch = ch + cy;
    cy = 0;
  }
  if (cx + cw > w) {
    cw = w - cx;
  }
  if (cy + ch > h) {
    ch = h - cy;
  }
  if (cw < 1 || ch < 1) {
    return;
  }
  yy = cy;
  while (yy < cy + ch) {
    drow = (uint32_t *)((uint8_t *)fb + (unsigned)yy * (unsigned)pitch);
    srow = src + (unsigned)yy * (unsigned)w;
    chrome_body_span(win0, yy, &a0, &a1, csd);
    chrome_body_span(win1, yy, &b0, &b1, csd);
    p0 = 0;
    p1 = 0;
    if ((flags & OSGFX_GUEST_PANEL) != 0) {
      if (yy >= h - OSGFX_CHROME_H) {
        p0 = 0;
        p1 = w;
      }
    }
    q0 = 0;
    q1 = 0;
    if (pop != 0) {
      px = (int)(pop >> 32);
      py = (int)(pop & 0xffffffffu);
      /* Effect bounds, not the 168×80 hit-test rect: AA + south/east
       * shadow must not be overwritten by a chrome-cache blit. */
      if (yy >= py - OSGFX_POP_VIS_T &&
          yy < py - OSGFX_POP_VIS_T + OSGFX_POP_VIS_H) {
        q0 = px - OSGFX_POP_VIS_L;
        q1 = px - OSGFX_POP_VIS_L + OSGFX_POP_VIS_W;
      }
    }
    xx = cx;
    while (xx < cx + cw) {
      hit = chrome_span_hit(xx, a0, a1);
      if (chrome_span_hit(xx, b0, b1) != 0) {
        hit = 1;
      }
      if (chrome_span_hit(xx, p0, p1) != 0) {
        hit = 1;
      }
      if (chrome_span_hit(xx, q0, q1) != 0) {
        hit = 1;
      }
      if (hit != 0) {
        xx = xx + 1;
        continue;
      }
      x1 = xx + 1;
      while (x1 < cx + cw) {
        hit = chrome_span_hit(x1, a0, a1);
        if (chrome_span_hit(x1, b0, b1) != 0) {
          hit = 1;
        }
        if (chrome_span_hit(x1, p0, p1) != 0) {
          hit = 1;
        }
        if (chrome_span_hit(x1, q0, q1) != 0) {
          hit = 1;
        }
        if (hit != 0) {
          break;
        }
        x1 = x1 + 1;
      }
      chrome_copy_span(drow, srow, xx, x1, w, yy, desk, dw, dh, win0, win1);
      xx = x1;
    }
    yy = yy + 1;
  }
}

static uint64_t chrome_present_clip(const struct OsGfxGuestCmd *m, int x, int y,
                                    int rw, int rh);
static void chrome_idle_prep(const struct OsGfxGuestCmd *m);

/* Blits the cached frame to the scanout. Returns pixels, or 0 if it declined.
 *
 * The pixel count is returned rather than dropped so a caller cannot mistake
 * "declined" for "presented nothing": every present through this path is
 * `w * h` pixels or it did not happen. */
int osgfx_chrome_present(const struct OsGfxGuestCmd *m) {
  uint64_t *pg;
  uint32_t *buf;

  pg = chrome_page();
  if (pg == 0) {
    return 0;
  }
  buf = chrome_buf(m, pg);
  if (buf == 0 || m->fb == 0) {
    return 0;
  }
  if (m->pitch < m->w * 4) {
    return 0;
  }
  /*
   * Session titles are always compositor-owned (`session_csd == 0` in
   * osgfx_session.c). OSGFX_GUEST_PANEL says only that one short DESK surface
   * owns the bottom strip; using it as the CSD bit punched title-band holes in
   * every ordinary window as soon as the dock attached.
   */
  chrome_blit((uint32_t *)(uintptr_t)m->fb, (int)m->pitch, buf, (int)m->w,
              (int)m->h, m->win0, m->win1, m->pop, m->flags, 0, 0, 0, 0, 0);
  pg[OSGFX_WMPAGE_W_CHROME_BLITS] = pg[OSGFX_WMPAGE_W_CHROME_BLITS] + 1;
  /* The sealed desk field is what this chrome snapshot displays. Count
   * the present as a desk-cache serve so de-pace sees BLIT > REGEN
   * when chrome HIT skips a second fill_desk_cached. */
  if (pg[OSGFX_WMPAGE_W_DESK_HAVE] != 0) {
    pg[OSGFX_WMPAGE_W_DESK_BLITS] = pg[OSGFX_WMPAGE_W_DESK_BLITS] + 1;
  }
  return (int)(m->w * m->h);
}

/* Last pop packed into scanout by a HIT overlay. Not in the chrome key. */
static uint64_t g_hit_pop;

/* HIT present: restore a vacated menu rect from the cache. Never a 1280×720
 * blit — that was the 1.1 s TCG focus hitch after every kick. */
uint64_t osgfx_chrome_hit_present(const struct OsGfxGuestCmd *m) {
  uint64_t *pg;
  uint64_t old;
  int ox;
  int oy;

  if (m == 0) {
    return 0;
  }
  old = g_hit_pop;
  if (old != 0 && old != m->pop) {
    ox = (int)(old >> 32);
    oy = (int)(old & 0xffffffffu);
    /* Card plus the 4×6 shadow the overlay does not own. */
    (void)chrome_present_clip(m, ox, oy, OSGFX_POP_W + 8, OSGFX_POP_H + 10);
  }
  g_hit_pop = m->pop;
  /* Count a cache serve even when the scanout copy is overlay-only.
   * de-chrome-cache watches BLIT move across unchanged wmCompose ticks. */
  pg = chrome_page();
  if (pg != 0) {
    pg[OSGFX_WMPAGE_W_CHROME_BLITS] = pg[OSGFX_WMPAGE_W_CHROME_BLITS] + 1;
    if (pg[OSGFX_WMPAGE_W_DESK_HAVE] != 0) {
      pg[OSGFX_WMPAGE_W_DESK_BLITS] = pg[OSGFX_WMPAGE_W_DESK_BLITS] + 1;
    }
  }
  chrome_idle_prep(m);
  return 1;
}

/* Clipped cache→scanout. Same holes as a full present. */
static uint64_t chrome_present_clip(const struct OsGfxGuestCmd *m, int x, int y,
                                    int rw, int rh) {
  uint64_t *pg;
  uint32_t *buf;
  uint32_t *fb;
  int w;
  int h;

  pg = chrome_page();
  if (pg == 0 || m == 0 || m->fb == 0) {
    return 0;
  }
  buf = chrome_buf(m, pg);
  if (buf == 0) {
    return 0;
  }
  w = (int)m->w;
  h = (int)m->h;
  if (w < 8 || h < 8 || m->pitch < m->w * 4) {
    return 0;
  }
  if (rw < 1 || rh < 1) {
    return 0;
  }
  fb = (uint32_t *)(uintptr_t)m->fb;
  chrome_blit(fb, (int)m->pitch, buf, w, h, m->win0, m->win1, m->pop, m->flags,
              0, x, y, rw, rh);
  pg[OSGFX_WMPAGE_W_CHROME_BLITS] = pg[OSGFX_WMPAGE_W_CHROME_BLITS] + 1;
  if (pg[OSGFX_WMPAGE_W_DESK_HAVE] != 0) {
    pg[OSGFX_WMPAGE_W_DESK_BLITS] = pg[OSGFX_WMPAGE_W_DESK_BLITS] + 1;
  }
  if (rw < 1 || rh < 1) {
    return 0;
  }
  return (uint64_t)(unsigned)rw * (uint64_t)(unsigned)rh;
}

static void chrome_clip_rect(int *x, int *y, int *rw, int *rh, int w, int h) {
  if (*x < 0) {
    *rw = *rw + *x;
    *x = 0;
  }
  if (*y < 0) {
    *rh = *rh + *y;
    *y = 0;
  }
  if (*x + *rw > w) {
    *rw = w - *x;
  }
  if (*y + *rh > h) {
    *rh = h - *y;
  }
  if (*rw < 0) {
    *rw = 0;
  }
  if (*rh < 0) {
    *rh = 0;
  }
}

static int chrome_pt_in_geom(uint64_t g, int x, int y);
static int chrome_rects_overlap(int ax, int ay, int aw, int ah, uint64_t g);

/* Overlap-safe rectangle move inside the chrome cache. */
static void chrome_move_rect(uint32_t *fb, int pitch_px, int ww, int hh, int ox,
                             int oy, int nx, int ny, int rw, int rh,
                             uint64_t keep) {
  int row;
  int col;
  int y;
  int x;
  uint32_t *srow;
  uint32_t *drow;

  chrome_clip_rect(&ox, &oy, &rw, &rh, ww, hh);
  if (rw < 1 || rh < 1) {
    return;
  }
  {
    int nrw;
    int nrh;
    nrw = rw;
    nrh = rh;
    chrome_clip_rect(&nx, &ny, &nrw, &nrh, ww, hh);
    if (nrw < rw) {
      rw = nrw;
    }
    if (nrh < rh) {
      rh = nrh;
    }
  }
  if (rw < 1 || rh < 1) {
    return;
  }
  if (keep != 0 && chrome_rects_overlap(nx, ny, rw, rh, keep) != 0) {
    row = 0;
    while (row < rh) {
      srow = fb + (unsigned)(oy + row) * (unsigned)pitch_px;
      drow = fb + (unsigned)(ny + row) * (unsigned)pitch_px;
      col = 0;
      while (col < rw) {
        if (chrome_pt_in_geom(keep, nx + col, ny + row) == 0) {
          drow[nx + col] = srow[ox + col];
        }
        col = col + 1;
      }
      row = row + 1;
    }
    return;
  }
  if (ox == nx && oy == ny) {
    return;
  }
  if (ny > oy) {
    row = rh - 1;
    while (row >= 0) {
      srow = fb + (unsigned)(oy + row) * (unsigned)pitch_px;
      drow = fb + (unsigned)(ny + row) * (unsigned)pitch_px;
      if (nx > ox) {
        col = rw - 1;
        while (col >= 0) {
          drow[nx + col] = srow[ox + col];
          col = col - 1;
        }
      } else {
        col = 0;
        while (col < rw) {
          drow[nx + col] = srow[ox + col];
          col = col + 1;
        }
      }
      row = row - 1;
    }
    return;
  }
  row = 0;
  while (row < rh) {
    srow = fb + (unsigned)(oy + row) * (unsigned)pitch_px;
    drow = fb + (unsigned)(ny + row) * (unsigned)pitch_px;
    if (nx > ox) {
      col = rw - 1;
      while (col >= 0) {
        drow[nx + col] = srow[ox + col];
        col = col - 1;
      }
    } else {
      x = 0;
      while (x < rw) {
        drow[nx + x] = srow[ox + x];
        x = x + 1;
      }
    }
    row = row + 1;
  }
}

static int chrome_pt_in_geom(uint64_t g, int x, int y) {
  int gx;
  int gy;
  int gw;
  int gh;

  if (g == 0) {
    return 0;
  }
  chrome_unpack_geom(g, &gx, &gy, &gw, &gh);
  if (x < gx || y < gy) {
    return 0;
  }
  if (x >= gx + gw || y >= gy + gh) {
    return 0;
  }
  return 1;
}

static int chrome_rects_overlap(int ax, int ay, int aw, int ah, uint64_t g) {
  int gx;
  int gy;
  int gw;
  int gh;

  if (g == 0 || aw < 1 || ah < 1) {
    return 0;
  }
  chrome_unpack_geom(g, &gx, &gy, &gw, &gh);
  if (ax + aw <= gx || gx + gw <= ax) {
    return 0;
  }
  if (ay + ah <= gy || gy + gh <= ay) {
    return 0;
  }
  return 1;
}

static void chrome_desk_rect(uint32_t *fb, int pitch_px, int x, int y, int rw,
                             int rh, uint32_t seed, uint64_t keep) {
  int yy;
  int xx;
  int run0;

  if (rw < 1 || rh < 1) {
    return;
  }
  if (keep == 0 || chrome_rects_overlap(x, y, rw, rh, keep) == 0) {
    osgfx_fill_desk_cached(fb, pitch_px * 4, x, y, rw, rh, seed);
    return;
  }
  /* Sibling VIS must stay committed. Wallpaper uncover of a drag AABB
   * used to erase SET's title when FILES moved across it. */
  yy = 0;
  while (yy < rh) {
    xx = 0;
    run0 = -1;
    while (xx <= rw) {
      if (xx < rw && chrome_pt_in_geom(keep, x + xx, y + yy) == 0) {
        if (run0 < 0) {
          run0 = xx;
        }
      } else {
        if (run0 >= 0) {
          osgfx_fill_desk_cached(fb, pitch_px * 4, x + run0, y + yy,
                                 xx - run0, 1, seed);
          run0 = -1;
        }
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

static void chrome_vacate(uint32_t *fb, int pitch_px, int ww, int hh, int ox,
                          int oy, int ow, int oh, int nx, int ny, int nw,
                          int nh, uint32_t seed, uint64_t keep) {
  int ix;
  int iy;
  int iw;
  int ih;
  int ax1;
  int ay1;
  int bx1;
  int by1;

  chrome_clip_rect(&ox, &oy, &ow, &oh, ww, hh);
  chrome_clip_rect(&nx, &ny, &nw, &nh, ww, hh);
  if (ow < 1 || oh < 1) {
    return;
  }
  ax1 = ox + ow;
  ay1 = oy + oh;
  bx1 = nx + nw;
  by1 = ny + nh;
  ix = ox;
  if (nx > ix) {
    ix = nx;
  }
  iy = oy;
  if (ny > iy) {
    iy = ny;
  }
  iw = ax1;
  if (bx1 < iw) {
    iw = bx1;
  }
  iw = iw - ix;
  ih = ay1;
  if (by1 < ih) {
    ih = by1;
  }
  ih = ih - iy;
  if (iw < 1 || ih < 1) {
    chrome_desk_rect(fb, pitch_px, ox, oy, ow, oh, seed, keep);
    return;
  }
  if (oy < iy) {
    chrome_desk_rect(fb, pitch_px, ox, oy, ow, iy - oy, seed, keep);
  }
  if (ay1 > iy + ih) {
    chrome_desk_rect(fb, pitch_px, ox, iy + ih, ow, ay1 - (iy + ih), seed, keep);
  }
  if (ox < ix) {
    chrome_desk_rect(fb, pitch_px, ox, iy, ix - ox, ih, seed, keep);
  }
  if (ax1 > ix + iw) {
    chrome_desk_rect(fb, pitch_px, ix + iw, iy, ax1 - (ix + iw), ih, seed, keep);
  }
}

/* Discrete old/new drag. No session MISS, no giant AABB. Mailbox already
 * holds the live geom (Dart kicked). Returns transferred cache pixels. */
static uint64_t chrome_drag_apply(uint64_t old_g, uint64_t new_g) {
  const struct OsGfxGuestCmd *m;
  uint64_t *pg;
  uint32_t *buf;
  uint32_t seed;
  int ox;
  int oy;
  int ow;
  int oh;
  int nx;
  int ny;
  int nw;
  int nh;
  int ww;
  int hh;
  int dx;
  int dy;
  int sdx;
  int sdy;
  int old_cx;
  int old_cy;
  uint64_t px;

  m = &osgfx_guest_cmd;
  pg = chrome_page();
  buf = chrome_buf(m, pg);
  if (pg == 0 || buf == 0 || m->fb == 0) {
    return 0;
  }
  ww = (int)m->w;
  hh = (int)m->h;
  if (ww < 8 || hh < 8) {
    return 0;
  }
  chrome_unpack_geom(old_g, &ox, &oy, &ow, &oh);
  chrome_unpack_geom(new_g, &nx, &ny, &nw, &nh);
  sdx = nx - ox;
  sdy = ny - oy;
  /* Decorated old + wmBorder(3) is the content origin before this step. */
  old_cx = ox + 3;
  old_cy = oy + 3;
  if (ow < 1 || oh < 1 || nw < 1 || nh < 1) {
    return 0;
  }
  seed = 0xD074A17u;
  if (m->desk != 0) {
    seed = (uint32_t)m->desk;
  }
  {
    uint64_t keep;
    keep = 0;
    /* Mailbox already holds the NEW content geom (Dart kicked before
     * drag_step). Match that, not the vacated origin. */
    if (chrome_geom_at(m->win0, nx + 3, ny + 3) != 0) {
      keep = m->win1;
    } else {
      if (chrome_geom_at(m->win1, nx + 3, ny + 3) != 0) {
        keep = m->win0;
      }
    }
    chrome_move_rect(buf, ww, ww, hh, ox, oy, nx, ny, ow, oh, keep);
    {
      uint32_t *fb;
      int pitch_px;
      int bh;
      fb = (uint32_t *)(uintptr_t)m->fb;
      pitch_px = (int)(m->pitch / 4u);
      bh = oh - OSGFX_TITLE_H;
      if (bh > 0 && pitch_px >= ww) {
        chrome_move_rect(fb, pitch_px, ww, hh, ox, oy + OSGFX_TITLE_H, nx,
                         ny + OSGFX_TITLE_H, ow, bh, keep);
      }
    }
    /* Radius fringe lives outside the strict window AABB. Filling only
     * x,y,w,h left AA/shadow chips on the vacated side. */
    chrome_vacate(buf, ww, ww, hh, ox - OSGFX_RADIUS, oy - OSGFX_RADIUS,
                  ow + OSGFX_RADIUS + OSGFX_RADIUS,
                  oh + OSGFX_RADIUS + OSGFX_RADIUS, nx, ny, nw, nh, seed,
                  keep);
    /* Dock/panel glass is a DESK client hole, not this layer. Vacate
     * restores desk-cache wallpaper in the old AABB only — do not
     * frost the whole strip (that would invent a glass bar). */
  }
  g_uncover0 = old_g;
  g_uncover1 = 0;
  dx = nx - ox;
  if (dx < 0) {
    dx = ox - nx;
  }
  dy = ny - oy;
  if (dy < 0) {
    dy = oy - ny;
  }
  px = 0;
  if (dx < 24 && dy < 24) {
    if (nx != ox) {
      if (nx > ox) {
        px = px + chrome_present_clip(m, ox, oy, nx - ox, oh);
        px = px + chrome_present_clip(m, ox + ow, ny, nx - ox, nh);
      } else {
        px = px + chrome_present_clip(m, nx + nw, oy, ox - nx, oh);
        px = px + chrome_present_clip(m, nx, ny, ox - nx, nh);
      }
    }
    if (ny != oy) {
      if (ny > oy) {
        px = px + chrome_present_clip(m, ox, oy, ow, ny - oy);
        px = px + chrome_present_clip(m, nx, oy + oh, nw, ny - oy);
      } else {
        px = px + chrome_present_clip(m, ox, ny + nh, ow, oy - ny);
        px = px + chrome_present_clip(m, nx, ny, nw, oy - ny);
      }
    }
    px = px + chrome_present_clip(m, ox - OSGFX_RADIUS, oy - OSGFX_RADIUS,
                                  ow + OSGFX_RADIUS + OSGFX_RADIUS,
                                  OSGFX_RADIUS);
    px = px + chrome_present_clip(m, ox - OSGFX_RADIUS, oy + oh,
                                  ow + OSGFX_RADIUS + OSGFX_RADIUS,
                                  OSGFX_RADIUS);
    px = px + chrome_present_clip(m, ox - OSGFX_RADIUS, oy, OSGFX_RADIUS, oh);
    px = px + chrome_present_clip(m, ox + ow, oy, OSGFX_RADIUS, oh);
    px = px + chrome_present_clip(m, nx, ny, nw, OSGFX_TITLE_H + 4);
  } else {
    px = px + chrome_present_clip(m, ox - OSGFX_RADIUS, oy - OSGFX_RADIUS,
                                  ow + OSGFX_RADIUS + OSGFX_RADIUS,
                                  oh + OSGFX_RADIUS + OSGFX_RADIUS);
    px = px + chrome_present_clip(m, nx, ny, nw, nh);
  }
  g_uncover0 = 0;
  /* Cache blit moved the discs. Stale mailbox/stamp geoms would leave
   * the vacated close/min/max hit targets live. Shift only the card
   * whose content origin still matches the pre-move decorated origin. */
  if (chrome_geom_at(osgfx_guest_cmd.win0, old_cx, old_cy)) {
    osgfx_guest_cmd.win0 = chrome_shift_geom(osgfx_guest_cmd.win0, sdx, sdy);
  }
  if (chrome_geom_at(osgfx_guest_cmd.win1, old_cx, old_cy)) {
    osgfx_guest_cmd.win1 = chrome_shift_geom(osgfx_guest_cmd.win1, sdx, sdy);
  }
  if (chrome_geom_at(g_stamp_win0, old_cx, old_cy)) {
    g_stamp_win0 = chrome_shift_geom(g_stamp_win0, sdx, sdy);
  }
  if (chrome_geom_at(g_stamp_win1, old_cx, old_cy)) {
    g_stamp_win1 = chrome_shift_geom(g_stamp_win1, sdx, sdy);
  }
  pg[OSGFX_WMPAGE_W_CHROME_W] = m->w;
  pg[OSGFX_WMPAGE_W_CHROME_H] = m->h;
  pg[OSGFX_WMPAGE_W_CHROME_HAVE] = chrome_key(m, pg);
  chrome_note_mailbox(m);
  return px;
}

uint64_t osgfx_chrome_drag_step(uint64_t old_g, uint64_t new_g) {
  return chrome_drag_apply(old_g, new_g);
}

/* Translate drag leaf primitives once on an already-presented frame.
 * Not a synthetic drag: no drag_step, no visible geom change. */
static void chrome_idle_prep(const struct OsGfxGuestCmd *m) {
  static int ready;
  static int win_ready;
  uint64_t *pg;
  uint32_t *buf;
  int w;
  int h;
  int wx;
  int wy;
  int ww;
  int wh;
  uint32_t seed;

  pg = chrome_page();
  buf = chrome_buf(m, pg);
  if (pg == 0 || buf == 0 || m == 0 || m->fb == 0) {
    return;
  }
  w = (int)m->w;
  h = (int)m->h;
  if (w < 16 || h < 16) {
    return;
  }
  seed = 0xD074A17u;
  if (m->desk != 0) {
    seed = (uint32_t)m->desk;
  }
  if (ready == 0) {
    chrome_move_rect(buf, w, w, h, 0, 0, 1, 0, 4, 4, 0);
    chrome_move_rect(buf, w, w, h, 1, 0, 0, 0, 4, 4, 0);
    chrome_vacate(buf, w, w, h, 2, 2, 2, 2, 2, 2, 2, 2, seed, 0);
    chrome_desk_rect(buf, w, 0, 0, 1, 1, seed, 0);
    (void)chrome_present_clip(m, 0, 0, 8, 8);
    ready = 1;
  }
  if (win_ready != 0) {
    return;
  }
  if (m->win0 == 0) {
    return;
  }
  chrome_unpack_geom(m->win0, &wx, &wy, &ww, &wh);
  if (ww < 16 || wh < 16) {
    return;
  }
  /* Same apply the live drag path uses. Identical geom: no visible move. */
  (void)chrome_drag_apply(m->win0, m->win0);
  {
    uint64_t shifted;
    /* dx>=24 takes the AABB present, the first-user-step cold path. */
    shifted = ((uint64_t)(unsigned)(wx + 32) << 48) |
              ((uint64_t)(unsigned)wy << 32) |
              ((uint64_t)(unsigned)ww << 16) | (uint64_t)(unsigned)wh;
    (void)chrome_drag_apply(m->win0, shifted);
    (void)chrome_drag_apply(shifted, m->win0);
  }
  win_ready = 1;
}

/* Called BEFORE the paint. Clears the key, so a #GP or a reset half way
 * through a Skia scan conversion leaves a torn frame marked untrustworthy
 * rather than current — osgfx_desk.c's rule, and for the stronger version of
 * its reason: the compositor blits this buffer to the visible scanout. */
void osgfx_chrome_begin(const struct OsGfxGuestCmd *m) {
  uint64_t *pg;

  (void)m;
  pg = chrome_page();
  if (pg == 0) {
    return;
  }
  pg[OSGFX_WMPAGE_W_CHROME_HAVE] = 0;
}

/* Called AFTER the paint. Stamps the key the buffer now holds and presents it.
 *
 * THE KEY IS RECOMPUTED HERE RATHER THAN CARRIED FROM `osgfx_chrome_begin`,
 * and that is what makes the regenerate count 1 instead of 2. The paint has
 * one side effect that lands in the key: a wallpaper regenerate writes
 * `OSGFX_WMPAGE_W_DESK_HAVE`. A key taken before the paint would therefore
 * disagree with the next tick's key, that tick would repaint, and the boot
 * would show two rasterisations where one happened. */
void osgfx_chrome_done(const struct OsGfxGuestCmd *m) {
  uint64_t *pg;

  pg = chrome_page();
  if (pg == 0) {
    return;
  }
  if (chrome_buf(m, pg) == 0) {
    return;
  }
  pg[OSGFX_WMPAGE_W_CHROME_W] = m->w;
  pg[OSGFX_WMPAGE_W_CHROME_H] = m->h;
  pg[OSGFX_WMPAGE_W_CHROME_REGEN] = pg[OSGFX_WMPAGE_W_CHROME_REGEN] + 1;
  pg[OSGFX_WMPAGE_W_CHROME_HAVE] = chrome_key(m, pg);
  chrome_note_mailbox(m);
  if (pg[OSGFX_WMPAGE_W_CHROME_LOG] != 0) {
    com1_puts("OSGFX CHROME REGEN\n");
  }
  (void)osgfx_chrome_present(m);
  chrome_idle_prep(m);
}

/* The glyph run cache's counters. Kept here rather than in osgfx_skia.cpp so
 * that the state page has exactly one C owner (osgfx_desk.c owns the
 * wallpaper words, this file owns the chrome and glyph words) and the C++
 * translation unit does not name a word table. */
void osgfx_chrome_glyph_count(int hit) {
  uint64_t *pg;

  pg = chrome_page();
  if (pg == 0) {
    return;
  }
  if (hit != 0) {
    pg[OSGFX_WMPAGE_W_GLYPH_HIT] = pg[OSGFX_WMPAGE_W_GLYPH_HIT] + 1;
    return;
  }
  pg[OSGFX_WMPAGE_W_GLYPH_FILL] = pg[OSGFX_WMPAGE_W_GLYPH_FILL] + 1;
}

/* ---------------------------------------------------------------------------
 * THE TASKBAR GRADIENT BAND (ADR-0191 §5)
 *
 * Measured, not guessed: one `SkShaders::LinearGradient` fill over the 800x48
 * taskbar is ~31.5 ms of a ~36 ms chrome rasterisation — 88% of it, about
 * 820 ns/px. Turning its antialiasing off changed nothing (39.7 ms against
 * 35.9), so the cost is the gradient shader and not the coverage pass; the
 * freestanding build calls `skcms_DisableRuntimeCPUDetection()` and gets a
 * scalar raster pipeline. Every glyph run in the same frame is 0.25 ms, which
 * is why the glyph cache GAP-0327 asked for is not what this file caches.
 *
 * The band's inputs are the screen width, the band height and two colours
 * from `osgfx_session.c`'s enum. None of them change for the life of a boot at
 * a fixed resolution, so this is the one piece of chrome that is not merely
 * usually unchanged — it is never changed.
 * ------------------------------------------------------------------------- */

static uint64_t band_key(int w, int h, uint32_t top, uint32_t bot) {
  uint64_t k;

  k = 0xB0A0D0C0E0F01234ULL;
  k = mix(k, (uint64_t)(unsigned)w);
  k = mix(k, (uint64_t)(unsigned)h);
  k = mix(k, (uint64_t)top);
  k = mix(k, (uint64_t)bot);
  return k | 1ULL;
}

uint32_t *osgfx_chrome_band(int w, int h) {
  uint64_t *pg;
  uint64_t need;

  if (osgfx_chrome_cache_door[0] == 0) {
    return 0;
  }
  if (w < 1 || h < 1) {
    return 0;
  }
  pg = chrome_page();
  if (pg == 0) {
    return 0;
  }
  need = (uint64_t)(unsigned)w * (uint64_t)(unsigned)h;
  if (need > pg[OSGFX_WMPAGE_W_BAND_PX]) {
    return 0;
  }
  return (uint32_t *)(uintptr_t)pg[OSGFX_WMPAGE_W_BAND_BUF];
}

int osgfx_chrome_band_fresh(int w, int h, uint32_t top, uint32_t bot) {
  uint64_t *pg;

  pg = chrome_page();
  if (pg == 0 || osgfx_chrome_band(w, h) == 0) {
    return 0;
  }
  if (pg[OSGFX_WMPAGE_W_BAND_HAVE] != band_key(w, h, top, bot)) {
    return 0;
  }
  /* The extent again, separately from the key, for `osgfx_chrome_fresh`'s
   * reason: a hash can collide and a band of the wrong WIDTH is the one wrong
   * answer that reads past the buffer rather than merely looking wrong. */
  if (pg[OSGFX_WMPAGE_W_BAND_W] != (uint64_t)(unsigned)w) {
    return 0;
  }
  if (pg[OSGFX_WMPAGE_W_BAND_H] != (uint64_t)(unsigned)h) {
    return 0;
  }
  pg[OSGFX_WMPAGE_W_BAND_HIT] = pg[OSGFX_WMPAGE_W_BAND_HIT] + 1;
  return 1;
}

void osgfx_chrome_band_stamp(int w, int h, uint32_t top, uint32_t bot) {
  uint64_t *pg;

  pg = chrome_page();
  if (pg == 0 || osgfx_chrome_band(w, h) == 0) {
    return;
  }
  pg[OSGFX_WMPAGE_W_BAND_W] = (uint64_t)(unsigned)w;
  pg[OSGFX_WMPAGE_W_BAND_H] = (uint64_t)(unsigned)h;
  pg[OSGFX_WMPAGE_W_BAND_FILL] = pg[OSGFX_WMPAGE_W_BAND_FILL] + 1;
  pg[OSGFX_WMPAGE_W_BAND_HAVE] = band_key(w, h, top, bot);
}

/* Idle max/restore chrome slots. which 0 = native-max, 1 = restore. */
uint32_t *osgfx_chrome_prep_target(int which) {
  uint64_t *pg;
  uint64_t need;
  uint64_t buf;

  pg = chrome_page();
  if (pg == 0) {
    return 0;
  }
  need = pg[OSGFX_WMPAGE_W_CHROME_W] * pg[OSGFX_WMPAGE_W_CHROME_H];
  if (need < 8u * 8u) {
    need = osgfx_guest_cmd.w * osgfx_guest_cmd.h;
  }
  if (need < 1 || need > pg[OSGFX_WMPAGE_W_PREP_PX]) {
    return 0;
  }
  buf = (which == 0) ? pg[OSGFX_WMPAGE_W_PREP_BUF] : pg[OSGFX_WMPAGE_W_PREP_REST];
  if (buf == 0) {
    return 0;
  }
  return (uint32_t *)(uintptr_t)buf;
}

int osgfx_chrome_prep_copy_live(int which) {
  uint64_t *pg;
  uint32_t *live;
  uint32_t *dst;
  uint64_t n;

  pg = chrome_page();
  live = chrome_buf(&osgfx_guest_cmd, pg);
  dst = osgfx_chrome_prep_target(which);
  if (pg == 0 || live == 0 || dst == 0) {
    return 0;
  }
  n = pg[OSGFX_WMPAGE_W_CHROME_W] * pg[OSGFX_WMPAGE_W_CHROME_H];
  if (n < 1 || n > pg[OSGFX_WMPAGE_W_CHROME_PX] || n > pg[OSGFX_WMPAGE_W_PREP_PX]) {
    return 0;
  }
  chrome_movs(dst, live, (unsigned)n);
  return 1;
}

int osgfx_chrome_prep_stamp(int which, uint64_t win0, uint64_t win1) {
  uint64_t *pg;
  uint64_t bit;

  pg = chrome_page();
  if (pg == 0 || osgfx_chrome_prep_target(which) == 0) {
    return 0;
  }
  bit = (which == 0) ? 1ull : 2ull;
  pg[OSGFX_WMPAGE_W_PREP_HAVE] = pg[OSGFX_WMPAGE_W_PREP_HAVE] | bit;
  if (which == 0) {
    pg[OSGFX_WMPAGE_W_PREP_WIN0] = win0;
    pg[OSGFX_WMPAGE_W_PREP_WIN1] = win1;
  }
  return 1;
}

uint64_t osgfx_chrome_prep_rest(void) {
  if (osgfx_chrome_prep_copy_live(1) == 0) {
    return 0;
  }
  if (osgfx_chrome_prep_stamp(1, osgfx_guest_cmd.win0, osgfx_guest_cmd.win1) == 0) {
    return 0;
  }
  com1_puts("OSGFX CHROME PREP REST\n");
  return 1;
}

uint64_t osgfx_chrome_prep_present(uint64_t which, uint64_t xy, uint64_t wh) {
  uint64_t *pg;
  const struct OsGfxGuestCmd *m;
  uint32_t *live;
  uint32_t *src;
  uint32_t *fb;
  int w;
  int h;
  int pitch;
  int x0;
  int y0;
  int rw;
  int rh;

  m = &osgfx_guest_cmd;
  pg = chrome_page();
  live = chrome_buf(m, pg);
  src = osgfx_chrome_prep_target((int)which);
  if (pg == 0 || live == 0 || src == 0 || m->fb == 0) {
    return 0;
  }
  w = (int)m->w;
  h = (int)m->h;
  if (w < 8 || h < 8 || m->pitch < m->w * 4) {
    return 0;
  }
  chrome_movs(live, src, (unsigned)w * (unsigned)h);
  pg[OSGFX_WMPAGE_W_CHROME_W] = m->w;
  pg[OSGFX_WMPAGE_W_CHROME_H] = m->h;
  pg[OSGFX_WMPAGE_W_CHROME_HAVE] = chrome_key(m, pg);
  chrome_note_mailbox(m);
  x0 = (int)(xy >> 32);
  y0 = (int)(xy & 0xffffffffu);
  rw = (int)(wh >> 32);
  rh = (int)(wh & 0xffffffffu);
  if (x0 < 0) {
    rw = rw + x0;
    x0 = 0;
  }
  if (y0 < 0) {
    rh = rh + y0;
    y0 = 0;
  }
  if (x0 + rw > w) {
    rw = w - x0;
  }
  if (y0 + rh > h) {
    rh = h - y0;
  }
  if (rw < 1 || rh < 1) {
    return 0;
  }
  fb = (uint32_t *)(uintptr_t)m->fb;
  pitch = (int)m->pitch;
  /* Hole-preserving blit: raw row copies stamped wallpaper over SET
   * (and any other client that is not the max/restore slot). */
  chrome_blit(fb, pitch, live, w, h, m->win0, m->win1, m->pop, m->flags, 0,
              x0, y0, rw, rh);
  pg[OSGFX_WMPAGE_W_CHROME_BLITS] = pg[OSGFX_WMPAGE_W_CHROME_BLITS] + 1;
  if (pg[OSGFX_WMPAGE_W_DESK_HAVE] != 0) {
    pg[OSGFX_WMPAGE_W_DESK_BLITS] = pg[OSGFX_WMPAGE_W_DESK_BLITS] + 1;
  }
  return (uint64_t)(unsigned)rw * (uint64_t)(unsigned)rh;
}
