/* core/user/frame/desk.c
 *
 * DESK — the desktop shell FRAME app (ADR-0183, finished by ADR-0192).
 *
 * THE DOCK IS THIS PROGRAM'S PIXELS (ADR-0197). It asks the compositor how
 * big the screen is (`WM_OP_SCREEN`), attaches a strip that is exactly the
 * full width of it and flush against the bottom edge (so `wmIsPanel` still
 * withdraws the fallback bar), and paints TWO floating glass islands —
 * clock/status/menu on the left, app icons on the right — through
 * `osxui_app_glass` / `osxui_app_island` / `osxui_app_icon_btn`. Unused
 * panel pixels stay 0 so wallpaper shows between the islands. Icon presses
 * `spawn` FILES / SET / BROWSE / PLAY / STUDIO / TAP. Same Skia path as
 * chrome (ADR-0187).
 *
 * WHAT CHANGED AND WHY IT MATTERED. This file used to freeze `SURF_Y 549` and
 * `WIN_W 794` — the 800x600 bottom slot — so on a 1280x720 scanout its strip
 * hung in the MIDDLE of the desk while `osgfx_session.c` painted a second,
 * correct one along the bottom. Two taskbars, GAP-0329. It also had no way to
 * reach a rounded rect or a proportional glyph from inside a 64KiB
 * freestanding ELF, so its pills were hand-written solid spans and its
 * captions were 8x16 bitmap cells.
 *
 * The slot pills come from the compositor's live window table
 * (`WM_SCREEN_TASKS`), so the bar shows the surfaces that actually exist and
 * marks the focused one — the shell is not told about windows by a constant.
 */

#include "osframe.h"
#include "osxui_app.h"

typedef unsigned long u64;
typedef unsigned int u32;

/* Band height. IN LOCKSTEP with OSGFX_CHROME_H (core/plat/osgfx/osgfx.h) and
 * wmChromeH (core/kernel/wmchrome.dart): the compositor's panel rule
 * (`wmIsPanel`) refuses a surface taller than the band, and its fallback strip
 * occupies exactly this many rows. de-desk asserts the three agree. */
#define BAR_H 48UL

/* Split glass dock (ADR-0197). Two islands on a full-width panel so
 * wmIsPanel still withdraws the fallback strip. Unused panel pixels
 * stay 0; the compositor skips them so wallpaper shows between
 * islands. Not 800x600 — widths come from WM_OP_SCREEN. */
#define ISLAND_Y 4UL
#define ISLAND_H 40UL
#define LEFT_X 16UL
#define LEFT_W 268UL
#define HAM_OFF 228UL
#define HAM_W 36UL
#define ICON_S 32UL
#define ICON_GAP 8UL
#define ICON_PAD 16UL
#define ICON_N 6UL
#define RIGHT_W (ICON_PAD + ICON_N * ICON_S + (ICON_N - 1UL) * ICON_GAP + ICON_PAD)
/* Frost island cache (ADR-0198). Regen only when the wallpaper key moves. */
#define FROST_L_W LEFT_W
#define FROST_R_W RIGHT_W
#define FROST_ISLE_H ISLAND_H
#define ICO_SET 0x008090A0UL
#define ICO_FILES 0x00F0C040UL
#define ICO_WEB 0x004080E0UL
#define ICO_MUSIC 0x006080E0UL
#define ICO_PAPER 0x00F0F0F0UL
#define ICO_TOOLS 0x003080C0UL

/* The pixels one poll of the window table costs when nothing changed: none.
 * A repaint only happens when the table or the scanout rect moves. */
#define YIELD_SPIN 8000UL
#define MENU_W 174UL
#define MENU_H 93UL
#define LAUNCH_W 280UL
#define LAUNCH_SEARCH_H 36UL
#define LAUNCH_ROW_H 24UL
#define LAUNCH_PAD 16UL
#define SWITCH_CARD_W 56UL
#define SWITCH_CARD_H 72UL
#define SWITCH_H 88UL
#define SWITCH_PAD 12UL
#define OVERLAY_MAX_W 280UL
#define OVERLAY_MAX_H 244UL
#define MENU_PAGES 17UL

/* osxui_button_fb's in-ELF retest (ADR-0192 §5). Linked for real now:
 * osxui.c + osxui_fb.c, not the weak no-op in osgfx_glyph.c. */
void osxui_button_fb(u64 fb, u64 pitch, u64 fwh, u64 xy, u64 sz, u64 rrgb);

#define PROBE_RGB 0x00FF00FFUL
#define PROBE_S 16UL

static u64 desc[8] __attribute__((aligned(64))) = {0, 0, 0, 0, 0, 0, 0, 0};
static u64 commit_desc[8] __attribute__((aligned(64))) = {0, 0, 0, 0, 0, 0, 0, 0};
static volatile u64 marker = 0x00D50000000000D5UL;
static u64 shm_h;
static u64 pix_va;
static u64 bar_w;
static u64 bar_x;
static u64 bar_y;
static u64 scr_w;
static u64 scr_h;
static u64 last_tasks;
static u64 last_tasks_hi;
static u64 last_screen;
static u64 last_pop;
static u64 last_launch_sel;
static u64 last_pref;
static u64 seq;
static u64 menu_h;
static u64 menu_va;
static u64 menu_on;
static u64 menu_seq;
static u64 overlay_w;
static u64 overlay_h;
static u64 right_x;
static u64 frost_key;
static u64 frost_regen;
static u32 frost_left[FROST_L_W * FROST_ISLE_H];
static u32 frost_right[FROST_R_W * FROST_ISLE_H];
static u64 launched_mask;

static char start_lab[] = "Start";
static char clock_lab[] = "3:30 PM";
static char date_lab[] = "Oct 30";
static char stat_lab[] = "1 C";
static char slot_stem[9];
#define SLOT_X0 (LEFT_X + LEFT_W + 8UL)
#define SLOT_W 56UL
#define SLOT_H 28UL
#define SLOT_PITCH 64UL
#define SLOT_Y (ISLAND_Y + 6UL)
#define SLOT_FILL 0x00E4ECF4UL
#define SLOT_FOCUS 0x00B8C8D8UL
#define SLOT_FOCUS_A1 0x00A0C8F0UL
#define SLOT_FOCUS_A2 0x00C8B0E0UL
#define SLOT_FOCUS_A3 0x00C0D890UL
static char name_set[] = "SET.ELF";
static char name_files[] = "FILES.ELF";
static char name_web[] = "BROWSE.ELF";
static char name_music[] = "PLAY.ELF";
static char name_paper[] = "STUDIO.ELF";
static char name_tools[] = "TAP.ELF";

static const char msg_ready[] = "DESK READY";
static const char msg_strip[] = "DESK STRIP";
static const char msg_dock[] = "DESK DOCK";
static const char msg_menu[] = "DESK MENU";
static const char msg_launch[] = "DESK LAUNCH ";

static inline u64 sys4(u64 n, u64 a, u64 b, u64 c, u64 d) {
  u64 r;
  __asm__ volatile("int $0x80"
                   : "=a"(r)
                   : "a"(n), "D"(a), "S"(b), "d"(c), "c"(d)
                   : "memory");
  return r;
}

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  return sys4(n, a, b, c, 0);
}

static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }

static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }

/* ONE LINE IS ONE WRITE. Each `write` prints its own `USER WRITE <text>` line
 * on COM1 (user.dart), so a caption assembled out of six calls arrives as six
 * lines and no harness can grep the sentence it was meant to form. Everything
 * below stages into `line` and emits once, which is what files.c does. */
static char line[96];

static u64 put(u64 at, const char *s) {
  while (*s != 0) {
    if (at >= sizeof(line)) {
      return at;
    }
    line[at] = *s;
    at = at + 1;
    s = s + 1;
  }
  return at;
}

static u64 put_hex(u64 at, u64 v, u64 nib) {
  static const char D[] = "0123456789ABCDEF";
  u64 i = 0;
  if (nib > 16UL) {
    nib = 16UL;
  }
  while (i < nib) {
    if (at >= sizeof(line)) {
      return at;
    }
    line[at] = D[(v >> ((nib - 1UL - i) * 4UL)) & 0xFUL];
    at = at + 1;
    i = i + 1;
  }
  return at;
}

static void emit(u64 at) { wr(line, at); }

__attribute__((noreturn)) static void die(u64 code) {
  sys1(SYS_EXIT, code);
  for (;;) {
  }
}

/* ---------------------------------------------------------------------------
 * osxui_button_fb, RETESTED IN THE ELF RATHER THAN ASSUMED (ADR-0192 §5).
 *
 * The header of this file used to say the call "HUNG in-ELF", and the pills
 * below were hand-written solid spans because of it. It does not hang, and the
 * `sqrtf` recursion ADR-0187 fixed was never the cause either: there is not a
 * single float on the path, which is `osxui_button` -> `osxui_scan_button` ->
 * an integer `rrect_hit` span walk.
 *
 * WHAT ACTUALLY HAPPENED. clang vectorises that span walk, and the vector
 * constants it hoists are spilled with `movdqa %xmm0,-0xc0(%rbp)`. A FRAME
 * app's `_start` used to be a plain C function, so `%rbp` came out 8 mod 16
 * (see OSFRAME_START in osframe.h) and that store raised #GP(0) the first time
 * it ran:
 *
 *   FAULT 0D ERR 0000000000000000 OP 660F
 *   USER FAULT VEC 0D ... RIP 0000000010002C62 CPL 3
 *   PROC KILL SLOT 00
 *
 * The process was reaped, the strip never appeared, and from outside a killed
 * process and a wedged one look the same. GAP-0339. With the entry shim in
 * place it returns, and the read-back below says whether it painted.
 *
 * THESE PIXELS ARE NOT THE TASKBAR. They are a 16x16 magenta probe in the
 * strip's top-left corner, read back, and then covered by `paint_bar`'s band
 * on the very next call. The pills are Skia (`wmOpPaint`); this is one
 * measurement of a CPU span walker whose reputation needed correcting.
 * ------------------------------------------------------------------------- */
static void probe_button_fb(void) {
  volatile u32 *p = (volatile u32 *)pix_va;
  u64 got;
  u64 at;

  wr("DESK BTNFB ENTER\n", 17);
  osxui_button_fb(pix_va, bar_w * 4UL, (bar_w << 32) | BAR_H, 0,
                  (PROBE_S << 32) | PROBE_S, (4UL << 32) | PROBE_RGB);
  wr("DESK BTNFB RETURN\n", 18);
  got = (u64)p[(PROBE_S / 2UL) * bar_w + (PROBE_S / 2UL)];
  if ((got & 0x00FFFFFFUL) == PROBE_RGB) {
    at = put(0, "DESK BTNFB PIXELS ");
  } else {
    at = put(0, "DESK BTNFB NOPIXELS ");
  }
  at = put_hex(at, got & 0x00FFFFFFUL, 6);
  emit(at);
}

/* ---------------------------------------------------------------------------
 * The strip. Every call below is one osgfx.h draw, reached through the SDK.
 * ------------------------------------------------------------------------- */
static void clear_bar(void) {
  volatile u32 *p = (volatile u32 *)pix_va;
  u64 n = bar_w * BAR_H;
  u64 i = 0;
  while (i < n) {
    p[i] = 0;
    i = i + 1;
  }
}

static void layout_right(void) {
  right_x = bar_w - 16UL - RIGHT_W;
  if (right_x < (LEFT_X + LEFT_W + 8UL)) {
    right_x = LEFT_X + LEFT_W + 8UL;
  }
}

static void paint_icon_glyph(u64 ix, u64 iy, u64 which) {
  u64 s = ICON_S;
  u64 pad = 6UL;
  u64 cx = ix + s / 2UL;
  u64 cy = iy + s / 2UL;

  osxui_app_icon_tile(shm_h, ix, iy, s);
  if (which == 0UL) {
    /* Settings gear: ring + hub. */
    osxui_app_rrect(shm_h, ix + pad, iy + pad, s - pad * 2UL, s - pad * 2UL, 8UL,
                    ICO_SET);
    osxui_app_rrect(shm_h, cx - 4UL, cy - 4UL, 8UL, 8UL, 4UL, 0x00F4F6FAUL);
    osxui_app_rrect(shm_h, cx - 2UL, iy + 4UL, 4UL, 5UL, 1UL, ICO_SET);
    osxui_app_rrect(shm_h, cx - 2UL, iy + s - 9UL, 4UL, 5UL, 1UL, ICO_SET);
    osxui_app_rrect(shm_h, ix + 4UL, cy - 2UL, 5UL, 4UL, 1UL, ICO_SET);
    osxui_app_rrect(shm_h, ix + s - 9UL, cy - 2UL, 5UL, 4UL, 1UL, ICO_SET);
    return;
  }
  if (which == 1UL) {
    /* Files folder. */
    osxui_app_rrect(shm_h, ix + 5UL, iy + 10UL, s - 10UL, s - 14UL, 3UL,
                    ICO_FILES);
    osxui_app_rrect(shm_h, ix + 5UL, iy + 8UL, 12UL, 6UL, 2UL, 0x00E0A030UL);
    return;
  }
  if (which == 2UL) {
    /* Web globe: disc + meridians. */
    osxui_app_rrect(shm_h, ix + pad, iy + pad, s - pad * 2UL, s - pad * 2UL, 10UL,
                    ICO_WEB);
    osxui_app_rrect(shm_h, cx - 2UL, iy + pad, 4UL, s - pad * 2UL, 2UL,
                    0x00F0F8FFUL);
    osxui_app_rrect(shm_h, ix + pad, cy - 2UL, s - pad * 2UL, 4UL, 2UL,
                    0x00F0F8FFUL);
    return;
  }
  if (which == 3UL) {
    /* Music note. */
    osxui_app_rrect(shm_h, cx - 2UL, iy + 6UL, 4UL, 14UL, 2UL, ICO_MUSIC);
    osxui_app_rrect(shm_h, cx + 2UL, iy + 6UL, 8UL, 4UL, 2UL, ICO_MUSIC);
    osxui_app_rrect(shm_h, ix + 8UL, iy + 18UL, 10UL, 8UL, 4UL, ICO_MUSIC);
    return;
  }
  if (which == 4UL) {
    /* Studio / paper X. */
    osxui_app_rrect(shm_h, ix + 8UL, iy + 6UL, 16UL, 20UL, 3UL, ICO_PAPER);
    osxui_app_rrect(shm_h, ix + 11UL, iy + 10UL, 10UL, 3UL, 1UL, 0x0040A060UL);
    osxui_app_rrect(shm_h, ix + 14UL, iy + 10UL, 3UL, 12UL, 1UL, 0x0040A060UL);
    return;
  }
  /* Tools: crossed wrench bars. */
  osxui_app_rrect(shm_h, ix + 8UL, iy + 8UL, 16UL, 5UL, 2UL, ICO_TOOLS);
  osxui_app_rrect(shm_h, ix + 14UL, iy + 8UL, 5UL, 16UL, 2UL, ICO_TOOLS);
  osxui_app_rrect(shm_h, ix + 8UL, iy + 19UL, 16UL, 5UL, 2UL, ICO_TOOLS);
}

static void frost_copy_out(u64 x, u64 y, u64 w, u64 h, u32 *cache) {
  volatile u32 *p = (volatile u32 *)pix_va;
  u64 yy = 0;
  while (yy < h) {
    volatile u32 *src = p + (y + yy) * bar_w + x;
    u32 *dst = cache + yy * w;
    u64 xx = 0;
    while (xx < w) {
      /* Preserve premultiplied alpha; dropping A turns transparent corners
       * into opaque black when this cached island is presented again. */
      dst[xx] = src[xx];
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

static void frost_copy_in(u64 x, u64 y, u64 w, u64 h, const u32 *cache) {
  volatile u32 *p = (volatile u32 *)pix_va;
  u64 yy = 0;
  while (yy < h) {
    volatile u32 *dst = p + (y + yy) * bar_w + x;
    const u32 *src = cache + yy * w;
    u64 xx = 0;
    while (xx < w) {
      dst[xx] = src[xx];
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

static void paint_frost_islands(u64 wall_key) {
  /* Elevation is outside the cached frost rectangles, so repaint it after
   * clear_bar on both cache hits and misses. This avoids square/orphan dock
   * ends while keeping the expensive wallpaper blur cached. */
  osxui_app_island_shadow(shm_h, LEFT_X, ISLAND_Y, LEFT_W, ISLAND_H);
  osxui_app_island_shadow(shm_h, right_x, ISLAND_Y, RIGHT_W, ISLAND_H);
  if (wall_key != 0UL && wall_key == frost_key) {
    frost_copy_in(LEFT_X, ISLAND_Y, FROST_L_W, FROST_ISLE_H, frost_left);
    frost_copy_in(right_x, ISLAND_Y, FROST_R_W, FROST_ISLE_H, frost_right);
    return;
  }
  osxui_app_island(shm_h, LEFT_X, ISLAND_Y, LEFT_W, ISLAND_H);
  osxui_app_island(shm_h, right_x, ISLAND_Y, RIGHT_W, ISLAND_H);
  frost_copy_out(LEFT_X, ISLAND_Y, FROST_L_W, FROST_ISLE_H, frost_left);
  frost_copy_out(right_x, ISLAND_Y, FROST_R_W, FROST_ISLE_H, frost_right);
  frost_key = wall_key;
  frost_regen = frost_regen + 1UL;
  {
    u64 at = put(0, "DESK FROST REGEN ");
    at = put_hex(at, frost_regen, 8);
    emit(at);
  }
}

static u64 slot_focus_rgb(void);

static void paint_slots(u64 tasks, u64 tasks_hi) {
  u64 i;
  u64 n;
  u64 sx;
  u64 rgb;
  char *lab;
  i = 0;
  n = 0;
  while (i < 8UL) {
    u64 bank = tasks;
    u64 idx = i;
    u64 st;
    if (i >= 4UL) {
      bank = tasks_hi;
      idx = i - 4UL;
    }
    st = osxui_app_task(bank, idx);
    if ((st & WM_TASK_LIVE) != 0) {
      if ((st & WM_TASK_PANEL) == 0) {
        sx = SLOT_X0 + n * SLOT_PITCH;
        rgb = SLOT_FILL;
        if ((st & WM_TASK_FOCUS) != 0) {
          rgb = slot_focus_rgb();
        }
        osxui_app_rrect(shm_h, sx, SLOT_Y, SLOT_W, SLOT_H, 8UL, rgb);
        {
          u64 packed = osxui_app_name(i);
          u64 k = 0;
          u64 nn = 0;
          while (k < 8UL) {
            slot_stem[k] = (char)((packed >> (k * 8UL)) & 0xFFUL);
            k = k + 1UL;
          }
          slot_stem[8] = 0;
          while (nn < 8UL) {
            if (slot_stem[nn] == 0) {
              break;
            }
            nn = nn + 1UL;
          }
          if (nn == 0UL) {
            slot_stem[0] = 'W';
            slot_stem[1] = '0' + (char)n;
            slot_stem[2] = 0;
            nn = 2UL;
          }
          lab = slot_stem;
          osxui_app_text(shm_h, sx + 6UL, SLOT_Y + 6UL, lab, nn,
                         WM_TEXT_LABEL_PX, WM_TEXT_REGULAR, OSXUI_GLASS_FG);
        }
        n = n + 1;
      }
    }
    i = i + 1;
  }
  if (n > 0) {
    u64 at = put(0, "DESK TASK ");
    at = put_hex(at, n, 1);
    emit(at);
  }
}

static void paint_bar(u64 tasks, u64 tasks_hi) {
  u64 i;
  u64 ix;
  u64 hy;
  volatile u32 *p;
  clear_bar();
  layout_right();
  /* Frost islands: sample wallpaper once per wallpaper key, then blit. */
  paint_frost_islands(osxui_app_desk_key());
  osxui_app_clock(shm_h, LEFT_X + 4UL, ISLAND_Y + 4UL, clock_lab, 7);
  osxui_app_text(shm_h, LEFT_X + 10UL, ISLAND_Y + 20UL, date_lab, 6,
                 WM_TEXT_LABEL_PX, WM_TEXT_REGULAR, OSXUI_GLASS_FG_MUTED);
  osxui_app_text(shm_h, LEFT_X + 100UL, ISLAND_Y + 12UL, stat_lab, 3,
                 WM_TEXT_LABEL_PX, WM_TEXT_REGULAR, OSXUI_GLASS_FG_MUTED);
  paint_slots(tasks, tasks_hi);
  hy = ISLAND_Y + 12UL;
  osxui_app_rrect(shm_h, LEFT_X + HAM_OFF + 8UL, hy, 20UL, 2UL, 1UL,
                  OSXUI_GLASS_FG);
  osxui_app_rrect(shm_h, LEFT_X + HAM_OFF + 8UL, hy + 6UL, 20UL, 2UL, 1UL,
                  OSXUI_GLASS_FG);
  osxui_app_rrect(shm_h, LEFT_X + HAM_OFF + 8UL, hy + 12UL, 20UL, 2UL, 1UL,
                  OSXUI_GLASS_FG);
  i = 0;
  while (i < ICON_N) {
    ix = right_x + ICON_PAD + i * (ICON_S + ICON_GAP);
    paint_icon_glyph(ix, ISLAND_Y + 4UL, i);
    i = i + 1;
  }
  p = (volatile u32 *)pix_va;
  {
    u64 at = put(0, "DESK ISLE ");
    at = put_hex(at, (u64)(p[(ISLAND_Y + 16UL) * bar_w + (LEFT_X + 180UL)] &
                           0x00FFFFFFUL),
                 6);
    emit(at);
  }
  {
    u32 a = p[(ISLAND_Y + 12UL) * bar_w + (LEFT_X + 40UL)] & 0x00FFFFFFUL;
    u32 b = p[(ISLAND_Y + 28UL) * bar_w + (LEFT_X + 200UL)] & 0x00FFFFFFUL;
    u64 at = put(0, "DESK FROST ");
    at = put_hex(at, (u64)a, 6);
    at = put(at, " ");
    at = put_hex(at, (u64)b, 6);
    if (a != b) {
      at = put(at, " VARY");
    } else {
      at = put(at, " FLAT");
    }
    emit(at);
  }
}

static char *launch_name(u64 i) {
  if (i == 0UL) {
    return name_set;
  }
  if (i == 1UL) {
    return name_files;
  }
  if (i == 2UL) {
    return name_web;
  }
  if (i == 3UL) {
    return name_music;
  }
  if (i == 4UL) {
    return name_paper;
  }
  return name_tools;
}

static u64 launch_nlen(u64 i) {
  if (i == 2UL) {
    return 10UL;
  }
  if (i == 4UL) {
    return 10UL;
  }
  if (i == 1UL) {
    return 9UL;
  }
  if (i == 3UL) {
    return 8UL;
  }
  if (i == 5UL) {
    return 7UL;
  }
  return 7UL;
}

static void launch_icon(u64 i) {
  char *nm;
  u64 nlen;
  u64 st;
  u64 at;
  if (i >= ICON_N) {
    return;
  }
  /* Dock is spawn, not raise. A live stem used to return here and
   * block the next FILES.ELF after the first client. */
  nm = launch_name(i);
  nlen = launch_nlen(i);
  at = put(0, msg_launch);
  at = put(at, nm);
  emit(at);
  st = sys3(SYS_SPAWN, (u64)nm, nlen, 0);
  if (st < WM_RET_FLOOR) {
    launched_mask = launched_mask | (1UL << i);
  }
}

static void handle_press(u64 ev) {
  u64 rx;
  u64 ry;
  u64 i;
  u64 ix;
  u64 span;
  u64 at;
  if ((ev & 0xFFUL) != WMEVENT_TYPE_PRESS) {
    return;
  }
  rx = (ev >> 16) & 0xFFFFUL;
  ry = (ev >> 32) & 0xFFFFUL;
  at = put(0, "DESK PRESS ");
  at = put_hex(at, rx, 4);
  at = put(at, " ");
  at = put_hex(at, ry, 4);
  emit(at);
  if (ry < ISLAND_Y) {
    return;
  }
  if (ry >= (ISLAND_Y + ISLAND_H)) {
    return;
  }
  if (rx < right_x) {
    return;
  }
  i = 0;
  while (i < ICON_N) {
    ix = right_x + ICON_PAD + i * (ICON_S + ICON_GAP);
    span = ICON_S + ICON_GAP;
    if (i + 1UL >= ICON_N) {
      span = ICON_S + ICON_PAD;
    }
    if (rx >= ix) {
      if (rx < (ix + span)) {
        launch_icon(i);
        return;
      }
    }
    i = i + 1;
  }
}

static void commit_all(void) {
  u64 frames;
  seq = seq + 1;
  commit_desc[WM_DESC_OP] = WM_OP_COMMIT;
  commit_desc[WM_DESC_HANDLE] = shm_h;
  commit_desc[WM_DESC_X] = 0;
  commit_desc[WM_DESC_Y] = 0;
  commit_desc[WM_DESC_W] = bar_w;
  commit_desc[WM_DESC_H] = BAR_H;
  commit_desc[WM_DESC_STRIDE] = seq;
  commit_desc[WM_DESC_OFFSET] = 0;
  {
    u64 at = put(0, "DESK COMMIT ");
    at = put_hex(at, bar_w, 4);
    at = put(at, " H ");
    at = put_hex(at, BAR_H, 4);
    at = put(at, " HND ");
    at = put_hex(at, shm_h, 4);
    emit(at);
  }
  frames = sys1(SYS_WMSURFACE, (u64)&commit_desc[0]);
  if (frames >= WM_RET_FLOOR) {
    u64 at = put(0, "DESK COMMIT FAIL ");
    at = put_hex(at, frames, 16);
    emit(at);
  }
}

static void attach_menu(void) {
  menu_h = sys1(SYS_SHMCREATE, MENU_PAGES);
  if (menu_h >= WM_RET_FLOOR) {
    menu_h = 0;
    return;
  }
  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = menu_h;
  desc[WM_DESC_X] = 8;
  desc[WM_DESC_Y] = 8;
  desc[WM_DESC_W] = OVERLAY_MAX_W;
  desc[WM_DESC_H] = OVERLAY_MAX_H;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  menu_va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  overlay_w = OVERLAY_MAX_W;
  overlay_h = OVERLAY_MAX_H;
  if (menu_va >= WM_RET_FLOOR) {
    menu_h = 0;
    menu_va = 0;
  }
}

static u64 stem_into(char *dst, u64 packed) {
  u64 n = 0;
  u64 i = 0;
  while (i < 8UL) {
    char c = (char)((packed >> (i * 8UL)) & 0xFFUL);
    if (c != 0 && c != ' ') {
      dst[n] = c;
      n = n + 1;
    }
    i = i + 1;
  }
  return n;
}

static void commit_menu(void) {
  menu_seq = menu_seq + 1;
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = menu_h;
  desc[WM_DESC_X] = 0;
  desc[WM_DESC_Y] = 0;
  desc[WM_DESC_W] = overlay_w;
  desc[WM_DESC_H] = overlay_h;
  desc[WM_DESC_STRIDE] = menu_seq;
  desc[WM_DESC_OFFSET] = 0;
  (void)sys1(SYS_WMSURFACE, (u64)&desc[0]);
}

static u64 desk_fold(u64 ch) {
  if (ch >= 0x61UL) {
    if (ch <= 0x7AUL) {
      return ch - 0x20UL;
    }
  }
  return ch;
}

static u64 launch_q_match(u64 packed, u64 q, u64 qlen) {
  u64 i;
  if (qlen < 1UL) {
    return 1;
  }
  i = 0;
  while (i < qlen) {
    u64 want = desk_fold((q >> (i * 8UL)) & 0xFFUL);
    u64 have = desk_fold((packed >> (i * 8UL)) & 0xFFUL);
    if (want != have) {
      return 0;
    }
    i = i + 1;
  }
  return 1;
}

static u64 slot_focus_rgb(void) {
  u64 pref = osxui_app_pref();
  u64 accent = (pref >> 8) & 0xFFUL;
  if (accent == 1UL) {
    return SLOT_FOCUS_A1;
  }
  if (accent == 2UL) {
    return SLOT_FOCUS_A2;
  }
  if (accent == 3UL) {
    return SLOT_FOCUS_A3;
  }
  return SLOT_FOCUS;
}

static void paint_desk_menu(u64 kind) {
  char stem[8];
  char qbuf[9];
  u64 i;
  u64 vis;
  u64 q;
  u64 qlen;
  u64 sel;
  u64 packed;
  u64 n;
  u64 ry;
  u64 rgb;
  u64 cx;
  u64 slot;
  osxui_app_menu_card(menu_h, overlay_w, overlay_h);
  if (kind == 1UL) {
    osxui_app_menu_row(menu_h, MENU_W, 0, OSXUI_MENU_ROW0, "Regen", 5);
    osxui_app_menu_row(menu_h, MENU_W, 1, OSXUI_MENU_ROW1, "Image", 5);
    return;
  }
  if (kind == 2UL) {
    packed = osxui_app_launch_sel();
    sel = packed & 0xFFUL;
    qlen = (packed >> 16) & 0xFFUL;
    q = osxui_app_launch_q();
    i = 0;
    while (i < 8UL) {
      qbuf[i] = (char)((q >> (i * 8UL)) & 0xFFUL);
      i = i + 1;
    }
    qbuf[8] = 0;
    osxui_app_rrect(menu_h, 8UL, 8UL, LAUNCH_W - 16UL, LAUNCH_SEARCH_H - 8UL, 8UL,
                    0x00FFFFFFUL);
    if (qlen > 0UL) {
      if (qlen > 8UL) {
        qlen = 8UL;
      }
      osxui_app_text(menu_h, 16UL, 12UL, qbuf, qlen, WM_TEXT_TITLE_PX,
                     WM_TEXT_MEDIUM, OSXUI_MENU_FG);
    } else {
      osxui_app_text(menu_h, 16UL, 12UL, "Search apps", 11, WM_TEXT_LABEL_PX,
                     WM_TEXT_REGULAR, OSXUI_GLASS_FG_MUTED);
    }
    vis = 0;
    i = 0;
    while (i < ICON_N) {
      n = stem_into(stem, osxui_app_launch(i));
      if (n > 0) {
        if (launch_q_match(osxui_app_launch(i), q, qlen) > 0) {
          ry = LAUNCH_SEARCH_H + vis * LAUNCH_ROW_H;
          rgb = OSXUI_MENU_ROW0;
          if ((vis & 1UL) != 0UL) {
            rgb = OSXUI_MENU_ROW1;
          }
          if (vis == sel) {
            rgb = 0x00D0E4F8UL;
          }
          osxui_app_rrect(menu_h, 8UL, ry, LAUNCH_W - 16UL, LAUNCH_ROW_H - 4UL,
                          6UL, rgb);
          osxui_app_text(menu_h, 16UL, ry + 2UL, stem, n, WM_TEXT_LABEL_PX,
                         WM_TEXT_REGULAR, OSXUI_MENU_FG);
          vis = vis + 1;
        }
      }
      i = i + 1;
    }
    {
      u64 at = put(0, "DESK LAUNCH FILT ");
      at = put_hex(at, vis, 2);
      at = put(at, " Q ");
      at = put_hex(at, qlen, 1);
      emit(at);
    }
    return;
  }
  if (kind == 6UL) {
    packed = osxui_app_launch_sel();
    (void)packed;
    sel = (osxui_app_pop() >> 56) & 0xFFUL;
    vis = 0;
    i = 0;
    while (i < 8UL) {
      slot = osxui_app_switch_at(i);
      if (slot >= 8UL) {
        break;
      }
      n = stem_into(stem, osxui_app_name(slot));
      cx = SWITCH_PAD + vis * (SWITCH_CARD_W + 8UL);
      if ((cx + SWITCH_CARD_W) > overlay_w) {
        break;
      }
      rgb = OSXUI_MENU_ROW0;
      if (vis == sel) {
        rgb = 0x00D0E4F8UL;
      }
      osxui_app_rrect(menu_h, cx, 24UL, SWITCH_CARD_W, SWITCH_CARD_H, 10UL,
                      rgb);
      if (n > 0) {
        osxui_app_text(menu_h, cx + 6UL, 48UL, stem, n, WM_TEXT_LABEL_PX,
                       WM_TEXT_REGULAR, OSXUI_MENU_FG);
      }
      vis = vis + 1;
      i = i + 1;
    }
    {
      u64 at = put(0, "DESK SWITCH ");
      at = put_hex(at, vis, 1);
      at = put(at, " S ");
      at = put_hex(at, sel, 1);
      emit(at);
    }
    return;
  }
  if (kind == 4UL) {
    osxui_app_menu_row(menu_h, MENU_W, 0, OSXUI_MENU_ROW0, "Close", 5);
    osxui_app_menu_row(menu_h, MENU_W, 1, OSXUI_MENU_ROW1, "Raise", 5);
    return;
  }
  if (kind == 5UL) {
    osxui_app_menu_row(menu_h, MENU_W, 0, OSXUI_MENU_ROW0, "Raise", 5);
    osxui_app_menu_row(menu_h, MENU_W, 1, OSXUI_MENU_ROW1, "Close", 5);
  }
}

static u64 launch_box_h(void) {
  u64 packed = osxui_app_launch_sel();
  u64 n = (packed >> 8) & 0xFFUL;
  if (n < 1UL) {
    n = 1UL;
  }
  if (n > 8UL) {
    n = 8UL;
  }
  return LAUNCH_SEARCH_H + n * LAUNCH_ROW_H + LAUNCH_PAD;
}

static u64 switch_box_w(void) {
  u64 n = 0;
  u64 i = 0;
  while (i < 8UL) {
    if (osxui_app_switch_at(i) < 8UL) {
      n = n + 1UL;
    } else {
      break;
    }
    i = i + 1UL;
  }
  if (n < 1UL) {
    n = 1UL;
  }
  return n * (SWITCH_CARD_W + 8UL) + SWITCH_PAD;
}

static void overlay_size_for(u64 kind) {
  if (kind == 2UL) {
    overlay_w = LAUNCH_W;
    overlay_h = launch_box_h();
    return;
  }
  if (kind == 6UL) {
    overlay_w = switch_box_w();
    overlay_h = SWITCH_H;
    return;
  }
  overlay_w = MENU_W;
  overlay_h = MENU_H;
}

static void sync_menu(u64 pop) {
  u64 kind = OSXUI_POP_KIND(pop);
  u64 px = OSXUI_POP_X(pop);
  u64 py = OSXUI_POP_Y(pop);
  if (menu_h == 0) {
    return;
  }
  if (kind == 0) {
    if (menu_on != 0) {
      /* Park off the visible desk. Restore uses the last exact geom. */
      osxui_app_place(menu_h, 8, 8, overlay_w, overlay_h);
      {
        u64 at = put(0, msg_menu);
        at = put(at, " 0");
        emit(at);
      }
    }
    menu_on = 0;
    return;
  }
  overlay_size_for(kind);
  osxui_app_place(menu_h, px, py, overlay_w, overlay_h);
  paint_desk_menu(kind);
  commit_menu();
  if (menu_on != kind) {
    u64 at = put(0, msg_menu);
    at = put(at, " ");
    at = put_hex(at, kind, 1);
    emit(at);
  }
  menu_on = kind;
}

/* THE ENTRY IS A SHIM, NOT A C FUNCTION (GAP-0339). See OSFRAME_START in
 * osframe.h: entered by `iretq` with a 16-aligned RSP, a C `_start` leaves
 * every frame pointer below it 8 mod 16, and the first `movdqa` to a stack
 * slot anywhere in the call tree raises #GP(0). That is what killed this
 * program the moment it called `osxui_button_fb`. */
OSFRAME_START(desk_main);

void desk_main(u64 sp);

void desk_main(u64 sp) {
  /* The System V initial stack argsBuild handed ring 3: argc, then argv. This
   * program takes no arguments and only names it so the shim's contract is
   * visible at the C side rather than only in the asm. */
  (void)sp;
  if (marker == 0) {
    die(0xD5000001UL);
  }
  wr("DESK BOOT\n", 10);

  /* 1. ASK. The strip's geometry is a fact about the machine, not a constant
   *    in this file. GAP-0329's first step. */
  last_screen = osxui_app_screen();
  scr_w = last_screen >> 32;
  scr_h = last_screen & 0xFFFFFFFFUL;
  {
    u64 at = put(0, "DESK SCREEN ");
    at = put_hex(at, scr_w, 4);
    at = put(at, " H ");
    at = put_hex(at, scr_h, 4);
    emit(at);
  }
  if (scr_w < 320UL) {
    wr("DESK SCREEN FAIL\n", 17);
    die(0xD5000005UL);
  }
  if (scr_h <= BAR_H) {
    wr("DESK SCREEN FAIL\n", 17);
    die(0xD5000005UL);
  }
  bar_w = scr_w;
  bar_x = 0;
  bar_y = scr_h - BAR_H;

  /* 2. SIZE the region from that width. 800x48x32bpp is 38 pages and
   *    1280x48 is 60; the compositor's ceiling is shmMaxPages. */
  {
    const u64 bytes = bar_w * BAR_H * 4UL;
    const u64 pages = (bytes + 4095UL) / 4096UL;
    u64 at = put(0, "DESK PAGES ");
    at = put_hex(at, pages, 4);
    emit(at);
    shm_h = sys1(SYS_SHMCREATE, pages);
  }
  if (shm_h >= WM_RET_FLOOR) {
    wr("DESK SHM FAIL\n", 14);
    die(0xD5000002UL);
  }
  wr("DESK SHM OK\n", 12);

  /* 3. ATTACH flush. `wmIsPanel` is what lets x be 0 and the bottom edge be
   *    the bottom edge: a panel IS the screen edge and has no room for the
   *    three-pixel border an ordinary window is held off by. */
  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = shm_h;
  desc[WM_DESC_X] = bar_x;
  desc[WM_DESC_Y] = bar_y;
  desc[WM_DESC_W] = bar_w;
  desc[WM_DESC_H] = BAR_H;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  pix_va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (pix_va >= WM_RET_FLOOR) {
    u64 at = put(0, "DESK ATT FAIL ");
    at = put_hex(at, pix_va, 16);
    emit(at);
    die(0xD5000003UL);
  }
  {
    u64 at = put(0, "DESK ATT OK X ");
    at = put_hex(at, bar_x, 4);
    at = put(at, " Y ");
    at = put_hex(at, bar_y, 4);
    at = put(at, " W ");
    at = put_hex(at, bar_w, 4);
    at = put(at, " H ");
    at = put_hex(at, BAR_H, 4);
    emit(at);
  }

  /* 4. The osxui_button_fb retest, before the real paint covers its pixels. */
  probe_button_fb();

  /* 5. What a label actually measures, out of the running OS. Five glyphs on
   *    an 8x16 grid would be exactly 0x28; a proportional Roboto Medium
   *    "Start" at 14px is neither that nor 0. */
  {
    const u64 m =
        osxui_app_measure(start_lab, 5, WM_TEXT_LABEL_PX, WM_TEXT_MEDIUM);
    u64 at = put(0, "DESK TEXT ADV ");
    at = put_hex(at, OSXUI_APP_ADV(m), 4);
    at = put(at, " CELL ");
    at = put_hex(at, 40UL, 4);
    at = put(at, " CAP ");
    at = put_hex(at, OSXUI_APP_CAP(m), 4);
    at = put(at, " ASC ");
    at = put_hex(at, OSXUI_APP_ASC(m), 4);
    emit(at);
    if (OSXUI_APP_ADV(m) == 0UL) {
      wr("DESK TEXT NO OUTLINE\n", 21);
    } else if (OSXUI_APP_ADV(m) == 40UL) {
      wr("DESK TEXT FIXEDCELL\n", 20);
    } else {
      wr("DESK TEXT OUTLINE PROPORTIONAL\n", 31);
    }
  }

  last_tasks = osxui_app_tasks();
  last_tasks_hi = osxui_app_tasks_hi();
  paint_bar(last_tasks, last_tasks_hi);
  wr("DESK PAINT\n", 11);
  {
    const u64 m2 =
        osxui_app_measure(clock_lab, 7, WM_TEXT_LABEL_PX, WM_TEXT_MEDIUM);
    if (OSXUI_APP_ADV(m2) != 0UL) {
      if (OSXUI_APP_ADV(m2) != 56UL) {
        wr("DESK TEXT OUTLINE PROPORTIONAL\n", 31);
      }
    }
  }
  commit_all();
  attach_menu();
  last_pop = 0;
  last_launch_sel = 0;
  last_pref = osxui_app_pref();
  wr(msg_ready, 10);
  wr(msg_strip, 10);
  wr(msg_dock, 9);

  /* 6. Stay resident and keep the bar honest. A window opening, closing or
   *    taking focus changes the table; a repaint and a commit follow. Nothing
   *    is repainted when nothing moved, so an idle desk costs one syscall per
   *    poll. */
  for (;;) {
    volatile u64 spin = 0;
    u64 tasks;
    u64 pop;
    while (spin < YIELD_SPIN) {
      spin = spin + 1;
    }
    sys1(SYS_YIELD, 0);
    pop = osxui_app_pop();
    {
      u64 lsel = osxui_app_launch_sel();
      u64 pref = osxui_app_pref();
      if (pop != last_pop || lsel != last_launch_sel) {
        last_pop = pop;
        last_launch_sel = lsel;
        sync_menu(pop);
      }
      if (pref != last_pref) {
        last_pref = pref;
        paint_bar(last_tasks, last_tasks_hi);
        commit_all();
        wr("DESK PREF\n", 10);
      }
    }
    {
      u64 ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
      while (ev != WMEVENT_EMPTY) {
        handle_press(ev);
        ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
      }
    }
    tasks = osxui_app_tasks();
    {
      u64 tasks_hi = osxui_app_tasks_hi();
      if (tasks != last_tasks) {
        last_tasks = tasks;
        last_tasks_hi = tasks_hi;
        paint_bar(tasks, tasks_hi);
        commit_all();
        wr("DESK RESTRIP\n", 13);
      } else if (tasks_hi != last_tasks_hi) {
        last_tasks_hi = tasks_hi;
        paint_bar(tasks, tasks_hi);
        commit_all();
        wr("DESK RESTRIP\n", 13);
      }
    }
  }
}
