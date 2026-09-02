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
  /* Flags carry ON, DE, WALL_IMG, the top slot, the popover kind and the two
   * held bits. All of them change the picture. */
  h = mix(h, m->flags);
  h = mix(h, m->w);
  h = mix(h, m->h);
  h = mix(h, m->win0);
  h = mix(h, m->win1);
  h = mix(h, m->pop);
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

/* Packed the same way wmPackGeom writes win0/win1: x<<48|y<<32|w<<16|h. */
static void chrome_unpack_geom(uint64_t g, int *x, int *y, int *w, int *h) {
  *x = (int)((g >> 48) & 0xffffu);
  *y = (int)((g >> 32) & 0xffffu);
  *w = (int)((g >> 16) & 0xffffu);
  *h = (int)(g & 0xffffu);
}

/* Client-body span on scanout row [yy], or x1<=x0 if this row is chrome.
 * Title band and bottom-corner insets stay cache-owned (wmBlitRow). */
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
    *x0 = wx + OSGFX_RADIUS;
    *x1 = wx + ww - OSGFX_RADIUS;
  }
}

static void chrome_copy_span(uint32_t *drow, const uint32_t *srow, int x0,
                             int x1, int w) {
  int xx;

  if (x0 < 0) {
    x0 = 0;
  }
  if (x1 > w) {
    x1 = w;
  }
  xx = x0;
  while (xx < x1) {
    drow[xx] = srow[xx];
    xx = xx + 1;
  }
}

/* WHAT A TICK PAYS. Row copies with rectangular holes for live FRAME
 * bodies. The chrome cache holds wallpaper in those holes; a full-screen
 * present is what emptied FILES/SET after the first pointer kick. Restore
 * still owes the re-blit (ADR-0190 kick gate unmoved). */
static void chrome_blit(uint32_t *fb, int pitch, const uint32_t *src, int w,
                        int h, uint64_t win0, uint64_t win1, int csd) {
  int yy;
  uint32_t *drow;
  const uint32_t *srow;
  int a0;
  int a1;
  int b0;
  int b1;
  int cut0;
  int cut1;

  yy = 0;
  while (yy < h) {
    drow = (uint32_t *)((uint8_t *)fb + (unsigned)yy * (unsigned)pitch);
    srow = src + (unsigned)yy * (unsigned)w;
    chrome_body_span(win0, yy, &a0, &a1, csd);
    chrome_body_span(win1, yy, &b0, &b1, csd);
    cut0 = a0;
    cut1 = a1;
    if (b1 > b0) {
      if (cut1 <= cut0) {
        cut0 = b0;
        cut1 = b1;
      } else {
        if (b0 < cut0) {
          cut0 = b0;
        }
        if (b1 > cut1) {
          cut1 = b1;
        }
      }
    }
    if (cut1 <= cut0) {
      chrome_copy_span(drow, srow, 0, w, w);
    } else {
      chrome_copy_span(drow, srow, 0, cut0, w);
      chrome_copy_span(drow, srow, cut1, w, w);
    }
    yy = yy + 1;
  }
}

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
  chrome_blit((uint32_t *)(uintptr_t)m->fb, (int)m->pitch, buf, (int)m->w,
              (int)m->h, m->win0, m->win1,
              (m->flags & OSGFX_GUEST_PANEL) != 0);
  pg[OSGFX_WMPAGE_W_CHROME_BLITS] = pg[OSGFX_WMPAGE_W_CHROME_BLITS] + 1;
  return (int)(m->w * m->h);
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
  if (pg[OSGFX_WMPAGE_W_CHROME_LOG] != 0) {
    com1_puts("OSGFX CHROME REGEN\n");
  }
  (void)osgfx_chrome_present(m);
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
