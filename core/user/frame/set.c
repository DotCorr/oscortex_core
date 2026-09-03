/* core/user/frame/set.c
 *
 * Settings — glass sidebar + content pane (ADR-0198). Appearance
 * (theme / mode / accent) and Devices pages. Compiles against
 * osframe.h (no private SYS_*). de-set builds SET.ELF.
 *
 * Facts from planted FACTS.DAT. A press inside the accent toggle
 * flips a local setting, writes CHROME.DAT, and commits damage.
 * A press outside does not. Truncated FACTS.DAT is SET BAD.
 *
 * Number 11 stays reserved. No 0x10200000-class literal.
 */

#include "osframe.h"
#include "osxui_app.h"

typedef unsigned long u64;
typedef unsigned int u32;

/* derive.py reads every one of these out of this file. */
#define WIN_W 440UL
#define WIN_H 280UL
#define SURF_X 180UL
#define SURF_Y 48UL
#define SURF_FILL 0x00F0F4F8UL
#define SIDE_W 120UL
#define SIDE_FILL 0x00E8EEF4UL
#define SIDE_SEL 0x00D8E4F0UL
#define SW_X 140UL
#define SW_Y 248UL
#define SW_W 40UL
#define SW_H 28UL
#define SW_GAP 8UL
#define CTL_X 140UL
#define CTL_Y 200UL
#define CTL_W 140UL
#define CTL_H 40UL
/* Glass accent: idle slate vs selected blue — not orange/green probes. */
#define CTL_OFF 0x00C8D0D8UL
#define CTL_ON 0x004080E0UL
#define LAB_FG 0x00202830UL
#define ACCENT_SEL 0x004080E0UL
#define THEME_CARD 0x00FFFFFFUL
#define FLIP_SCAN 0x1FUL
#define WIN_PAGES 121UL
#define FACTS_NEED 26UL
#define CHUNK 512UL

#define YIELD_SPIN 8000UL
#define O_WRITE 1UL
#define PREF_BYTES 1UL
#define FILE_ERR_FLOOR 0xFFFFFFFFFFFFFF00UL

#define PAGE_APPEAR 0UL
#define PAGE_DEVICES 1UL

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}

static inline u64 sys2(u64 n, u64 a, u64 b) { return sys3(n, a, b, 0); }
static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }

static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }

__attribute__((noreturn)) static void die(u64 code) {
  sys1(SYS_EXIT, code);
  for (;;) {
  }
}

static u64 desc[8] __attribute__((aligned(64))) = {0, 0, 0, 0, 0, 0, 0, 0};

static volatile u64 marker = 0x005E70000000005EUL;

static u64 shm_h;
static u64 pix_va;
static u64 set_w = WIN_W;
static u64 set_h = WIN_H;
static volatile u64 armed = 0;
static u64 scratch[8];
static unsigned char buf[512];
static char line[48];
static u64 page = PAGE_APPEAR;

static u32 fact_desk;
static u32 fact_chrome;
static u32 fact_title;
static u64 fact_w;
static u64 fact_h;
static u64 fact_chrome_on;

static const char path_facts[] = "FACTS.DAT";
static const char path_pref[] = "CHROME.DAT";
static const char msg_ready[] = "SET READY\n";
static const char msg_miss[] = "SET MISS\n";
static const char msg_bad[] = "SET BAD\n";
static const char msg_row[] = "SET LABEL OUTLINE ADV ";
static const char msg_row_cell[] = " CELL ";
static const char lab_set[] = "Settings";
static const char lab_app[] = "Appearance";
static const char lab_dev[] = "Devices";
static const char msg_csd[] = "SET CSD\n";
static u64 csd_noted;
static u64 set_slot = 0xFFUL;
static const char lab_on[] = "ON";
static const char lab_off[] = "OFF";
static unsigned char pref_on = 1;

static u64 lab_adv;

static unsigned put(unsigned at, const char *s) {
  while (*s) {
    line[at++] = *s++;
  }
  return at;
}

static unsigned puthex(unsigned at, u64 v, unsigned digits) {
  static const char D[] = "0123456789ABCDEF";
  unsigned i = digits;
  while (i--) {
    line[at++] = D[(v >> (i * 4)) & 0xF];
  }
  return at;
}

static void emit(unsigned n) { sys3(SYS_WRITE, (u64)line, n, 0); }

static u32 load_u32(const unsigned char *p) {
  return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

static u64 load_u16(const unsigned char *p) {
  return (u64)p[0] | ((u64)p[1] << 8);
}

static u32 xor4(u32 a, u32 b, u32 c, u32 d) { return a ^ b ^ c ^ d; }

static u32 chrome_swatch(u64 on) {
  if (on > 0) {
    return fact_title;
  }
  return fact_chrome;
}

static u32 pixel_of(u64 px, u64 py, u64 on) {
  u64 sw1x = SW_X + SW_W + SW_GAP;
  u64 sw2x = sw1x + SW_W + SW_GAP;
  if (py >= OSXUI_CSD_H) {
    if (px < SIDE_W) {
      return (u32)SIDE_FILL;
    }
  }
  if (page == PAGE_APPEAR) {
    if (py >= SW_Y) {
      if (py < (SW_Y + SW_H)) {
        if (px >= SW_X) {
          if (px < (SW_X + SW_W)) {
            return fact_desk;
          }
        }
        if (px >= sw1x) {
          if (px < (sw1x + SW_W)) {
            return chrome_swatch(on);
          }
        }
        if (px >= sw2x) {
          if (px < (sw2x + SW_W)) {
            return fact_title;
          }
        }
      }
    }
    if (px >= CTL_X) {
      if (px < (CTL_X + CTL_W)) {
        if (py >= CTL_Y) {
          if (py < (CTL_Y + CTL_H)) {
            if (on > 0) {
              return (u32)CTL_ON;
            }
            return (u32)CTL_OFF;
          }
        }
      }
    }
  }
  return (u32)SURF_FILL;
}

static void fill_cpu(u64 va, u64 x, u64 y, u64 w, u64 h, u32 rgb) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = y;
  while (py < (y + h)) {
    u64 px = x;
    while (px < (x + w)) {
      if (px < set_w) {
        if (py < set_h) {
          p[py * set_w + px] = rgb;
        }
      }
      px = px + 1;
    }
    py = py + 1;
  }
}

static void paint_appear_chrome(u64 on) {
  u64 tx;
  u64 i;
  const char *state;
  unsigned nstate;

  osxui_app_text(shm_h, SIDE_W + 16UL, OSXUI_CSD_H + 12UL, lab_app, 10UL,
                 WM_TEXT_TITLE_PX, WM_TEXT_MEDIUM, LAB_FG);
  i = 0;
  while (i < 6UL) {
    tx = SIDE_W + 12UL + (i % 3UL) * 96UL;
    fill_cpu(pix_va, tx, OSXUI_CSD_H + 52UL + (i / 3UL) * 48UL, 88UL, 40UL,
             THEME_CARD);
    fill_cpu(pix_va, tx + 10UL, OSXUI_CSD_H + 68UL + (i / 3UL) * 48UL, 8UL, 8UL,
             0x00E07070UL);
    fill_cpu(pix_va, tx + 24UL, OSXUI_CSD_H + 68UL + (i / 3UL) * 48UL, 8UL, 8UL,
             0x00E0C040UL);
    fill_cpu(pix_va, tx + 38UL, OSXUI_CSD_H + 68UL + (i / 3UL) * 48UL, 8UL, 8UL,
             ACCENT_SEL);
    i = i + 1;
  }
  fill_cpu(pix_va, SIDE_W + 16UL, CTL_Y - 18UL, 52UL, 22UL, SIDE_SEL);
  fill_cpu(pix_va, CTL_X, CTL_Y + 28UL, 18UL, 18UL, 0x00E05050UL);
  fill_cpu(pix_va, CTL_X + 28UL, CTL_Y + 28UL, 18UL, 18UL, 0x00E0C040UL);
  fill_cpu(pix_va, CTL_X + 56UL, CTL_Y + 28UL, 18UL, 18UL, 0x0040C060UL);
  if (on > 0) {
    fill_cpu(pix_va, CTL_X + 84UL, CTL_Y + 28UL, 18UL, 18UL, ACCENT_SEL);
    fill_cpu(pix_va, CTL_X + 88UL, CTL_Y + 32UL, 10UL, 10UL, 0x00F8FCFFUL);
  } else {
    fill_cpu(pix_va, CTL_X + 84UL, CTL_Y + 28UL, 18UL, 18UL, 0x00A0B0C0UL);
  }
  fill_cpu(pix_va, CTL_X + 112UL, CTL_Y + 28UL, 18UL, 18UL, 0x008060C0UL);
  state = lab_off;
  nstate = 3U;
  if (on > 0) {
    state = lab_on;
    nstate = 2U;
  }
  osxui_app_label_box(shm_h, CTL_X, CTL_Y, CTL_W, CTL_H, state, (u64)nstate,
                      WM_TEXT_LABEL_PX, WM_TEXT_MEDIUM, LAB_FG);
}

static void paint_devices_chrome(void) {
  osxui_app_text(shm_h, SIDE_W + 16UL, OSXUI_CSD_H + 12UL, lab_dev, 7UL,
                 WM_TEXT_TITLE_PX, WM_TEXT_MEDIUM, LAB_FG);
  fill_cpu(pix_va, SIDE_W + 12UL, OSXUI_CSD_H + 48UL, 140UL, 56UL, THEME_CARD);
  fill_cpu(pix_va, SIDE_W + 164UL, OSXUI_CSD_H + 48UL, 140UL, 56UL, THEME_CARD);
  fill_cpu(pix_va, SIDE_W + 12UL, OSXUI_CSD_H + 116UL, 140UL, 56UL, THEME_CARD);
  fill_cpu(pix_va, SIDE_W + 164UL, OSXUI_CSD_H + 116UL, 140UL, 56UL, THEME_CARD);
}

static void paint_sidebar(void) {
  if (set_h > OSXUI_CSD_H) {
    fill_cpu(pix_va, 0, OSXUI_CSD_H, SIDE_W, set_h - OSXUI_CSD_H, SIDE_FILL);
  }
  if (page == PAGE_APPEAR) {
    fill_cpu(pix_va, 8UL, OSXUI_CSD_H + 68UL, SIDE_W - 16UL, 24UL, SIDE_SEL);
  }
  osxui_app_text(shm_h, 16UL, OSXUI_CSD_H + 72UL, lab_app, 10UL,
                 WM_TEXT_LABEL_PX, WM_TEXT_MEDIUM, LAB_FG);
  if (page == PAGE_DEVICES) {
    fill_cpu(pix_va, 8UL, OSXUI_CSD_H + 100UL, SIDE_W - 16UL, 24UL, SIDE_SEL);
  }
  osxui_app_text(shm_h, 16UL, OSXUI_CSD_H + 104UL, lab_dev, 7UL,
                 WM_TEXT_LABEL_PX, WM_TEXT_MEDIUM, LAB_FG);
}

static void paint_labels(u64 va, u64 on) {
  (void)va;
  paint_sidebar();
  if (page == PAGE_APPEAR) {
    paint_appear_chrome(on);
  } else {
    paint_devices_chrome();
  }
  osxui_app_csd(shm_h, set_w, lab_set, 8UL);
  if (csd_noted == 0) {
    csd_noted = 1;
    wr(msg_csd, sizeof(msg_csd) - 1);
  }
  lab_adv = osxui_app_text_width(lab_app, 10UL, WM_TEXT_TITLE_PX, WM_TEXT_MEDIUM);
}

static void paint_all(u64 va, u64 on) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < set_h) {
    u64 px = 0;
    while (px < set_w) {
      p[py * set_w + px] = pixel_of(px, py, on);
      px = px + 1;
    }
    py = py + 1;
  }
  paint_labels(va, on);
}

static void paint_toggle(u64 va, u64 on) {
  volatile u32 *p = (volatile u32 *)va;
  u32 c = (u32)((on > 0) ? CTL_ON : CTL_OFF);
  u32 sc = chrome_swatch(on);
  u64 sw1x = SW_X + SW_W + SW_GAP;
  u64 py = CTL_Y;
  while (py < (CTL_Y + CTL_H)) {
    u64 px = CTL_X;
    while (px < (CTL_X + CTL_W)) {
      p[py * set_w + px] = c;
      px = px + 1;
    }
    py = py + 1;
  }
  py = SW_Y;
  while (py < (SW_Y + SW_H)) {
    u64 px = sw1x;
    while (px < (sw1x + SW_W)) {
      p[py * set_w + px] = sc;
      px = px + 1;
    }
    py = py + 1;
  }
  paint_labels(va, on);
}

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
    die(0x5E000004UL | (frames << 32));
  }
  scratch[0] = frames;
}

static void set_apply_configure(u64 ev) {
  u64 slot = (ev >> 8) & 0xFFUL;
  u64 nw = (ev >> 40) & 0xFFFUL;
  u64 nh = (ev >> 52) & 0xFFFUL;
  if (set_slot == 0xFFUL) {
    set_slot = slot;
  }
  if (slot != set_slot) {
    return;
  }
  if (nw < 1 || nh < 1) {
    return;
  }
  if (nw > WIN_W) {
    nw = WIN_W;
  }
  if (nh > WIN_H) {
    nh = WIN_H;
  }
  if (nw == set_w && nh == set_h) {
    return;
  }
  set_w = nw;
  set_h = nh;
  paint_all(pix_va, armed);
  commit_rect(0, 0, set_w, set_h, 5);
}

static void emit_toggle(u64 on) {
  unsigned n = put(0, "SET TOGGLE ");
  if (on > 0) {
    n = put(n, "ON ");
  } else {
    n = put(n, "OFF ");
  }
  n = puthex(n, chrome_swatch(on) & 0xFFFFFFUL, 8);
  n = put(n, "\n");
  emit(n);
}

static void write_pref(void) {
  u64 fd = sys3(SYS_OPEN, (u64)path_pref, 10, O_WRITE);
  if (fd >= FILE_ERR_FLOOR) {
    return;
  }
  sys3(SYS_FDWRITE, fd, (u64)&pref_on, PREF_BYTES);
  sys1(SYS_CLOSE, fd);
}

static void flip(void) {
  if (armed != 0) {
    return;
  }
  armed = 1;
  write_pref();
  paint_toggle(pix_va, 1);
  commit_rect(0, 0, set_w, set_h, 2);
  emit_toggle(1);
}

static u64 press_in_ctl(u64 ev) {
  u64 typ = ev & 0xFFUL;
  u64 rx = (ev >> 16) & 0xFFFFUL;
  u64 ry = (ev >> 32) & 0xFFFFUL;
  if (typ != WMEVENT_TYPE_PRESS) {
    return 0;
  }
  if (page != PAGE_APPEAR) {
    return 0;
  }
  if (rx < CTL_X) {
    return 0;
  }
  if (rx >= (CTL_X + CTL_W)) {
    return 0;
  }
  if (ry < CTL_Y) {
    return 0;
  }
  if (ry >= (CTL_Y + CTL_H)) {
    return 0;
  }
  return 1;
}

static u64 press_in_side(u64 ev) {
  u64 typ = ev & 0xFFUL;
  u64 rx = (ev >> 16) & 0xFFFFUL;
  if (typ != WMEVENT_TYPE_PRESS) {
    return 0;
  }
  if (rx < SIDE_W) {
    return 1;
  }
  return 0;
}

static void handle_nav(u64 ev) {
  u64 rx = (ev >> 16) & 0xFFFFUL;
  u64 ry = (ev >> 32) & 0xFFFFUL;
  if (rx >= SIDE_W) {
    return;
  }
  if (ry >= OSXUI_CSD_H + 68UL) {
    if (ry < OSXUI_CSD_H + 92UL) {
      page = PAGE_APPEAR;
      paint_all(pix_va, armed);
      commit_rect(0, 0, set_w, set_h, 3);
      return;
    }
  }
  if (ry >= OSXUI_CSD_H + 100UL) {
    if (ry < OSXUI_CSD_H + 124UL) {
      page = PAGE_DEVICES;
      paint_all(pix_va, armed);
      commit_rect(0, 0, set_w, set_h, 4);
    }
  }
}

static u64 load_facts(void) {
  u64 fd;
  u64 got;
  u32 sum;
  u32 want;

  fd = sys2(SYS_OPEN, (u64)path_facts, 9);
  if (fd >= 0xFFFFFFFFFFFFFF00UL) {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  got = sys3(SYS_READ, fd, (u64)buf, CHUNK);
  sys2(SYS_CLOSE, fd, 0);
  if (got >= 0xFFFFFFFFFFFFFF00UL) {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  if (got < FACTS_NEED) {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  if (buf[0] != (unsigned char)'S') {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  if (buf[1] != (unsigned char)'E') {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  if (buf[2] != (unsigned char)'T') {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  if (buf[3] != (unsigned char)'1') {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }

  fact_w = load_u16(buf + 4);
  fact_h = load_u16(buf + 6);
  fact_chrome_on = (u64)buf[8];
  fact_desk = load_u32(buf + 10);
  fact_chrome = load_u32(buf + 14);
  fact_title = load_u32(buf + 18);
  want = load_u32(buf + 22);
  sum = xor4((u32)fact_w | ((u32)fact_h << 16), fact_desk, fact_chrome,
             fact_title);
  sum = sum ^ (u32)fact_chrome_on;
  if (sum != want) {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  if (fact_w == 0) {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  if (fact_h == 0) {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  if (fact_desk == fact_chrome) {
    wr(msg_bad, sizeof(msg_bad) - 1);
    return 0;
  }
  return 1;
}

static void emit_facts(void) {
  unsigned n;

  n = put(0, "SET FB ");
  n = puthex(n, fact_w, 4);
  n = put(n, "x");
  n = puthex(n, fact_h, 4);
  n = put(n, "\n");
  emit(n);

  n = put(0, "SET CHROME ");
  if (fact_chrome_on > 0) {
    n = put(n, "ON\n");
  } else {
    n = put(n, "OFF\n");
  }
  emit(n);

  n = put(0, "SET DESK ");
  n = puthex(n, fact_desk & 0xFFFFFFUL, 8);
  n = put(n, "\n");
  emit(n);

  n = put(0, "SET BAR ");
  n = puthex(n, fact_chrome & 0xFFFFFFUL, 8);
  n = put(n, "\n");
  emit(n);

  n = put(0, "SET TITLE ");
  n = puthex(n, fact_title & 0xFFFFFFUL, 8);
  n = put(n, "\n");
  emit(n);
}

static void idle(void) {
  for (;;) {
    sys1(SYS_YIELD, 0);
  }
}

void _start(void) {
  if (marker != 0x005E70000000005EUL) {
    die(0x5E000006UL);
  }

  if (load_facts() == 0) {
    idle();
  }

  emit_facts();

  shm_h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (shm_h >= WM_RET_FLOOR) {
    die(0x5E000002UL);
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
    die(0x5E000003UL | (pix_va << 32));
  }

  /* Identity probe before the first fill: a wrong-stride paint used to
   * fault and never reach SET CSD. */
  if (csd_noted == 0) {
    csd_noted = 1;
    wr(msg_csd, sizeof(msg_csd) - 1);
  }
  {
    u64 n = 0;
    while (n < 8UL) {
      u64 ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
      if (ev == WMEVENT_EMPTY) {
        break;
      }
      if ((ev & 0xFFUL) == WMEVENT_TYPE_CONFIGURE) {
        set_apply_configure(ev);
      }
      n = n + 1UL;
    }
  }
  paint_all(pix_va, 0);
  commit_rect(0, 0, set_w, set_h, 1);
  wr(msg_ready, sizeof(msg_ready) - 1);
  {
    unsigned at = put(0, msg_row);
    at = puthex(at, lab_adv, 4);
    at = put(at, msg_row_cell);
    at = puthex(at, 24UL, 4);
    line[at++] = '\n';
    emit(at);
  }
  emit_toggle(0);

  for (;;) {
    u64 k = sys1(SYS_KBDEVENT, KBD_OP_POP);
    if (k != KBD_EMPTY) {
      if ((k & KBD_BIT_BREAK) == 0) {
        if ((k & 0xFFUL) == FLIP_SCAN) {
          flip();
        }
      }
    }
    u64 ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    if (ev != WMEVENT_EMPTY) {
      if ((ev & 0xFFUL) == WMEVENT_TYPE_CONFIGURE) {
        set_apply_configure(ev);
      } else if (press_in_ctl(ev) > 0) {
        flip();
      } else if (press_in_side(ev) > 0) {
        handle_nav(ev);
      } else {
        if ((ev & 0xFFUL) == WMEVENT_TYPE_PRESS) {
          wr(msg_miss, sizeof(msg_miss) - 1);
        }
      }
    }
    {
      volatile u64 spin = 0;
      while (spin < YIELD_SPIN) {
        spin = spin + 1;
      }
    }
    sys1(SYS_YIELD, 0);
  }
}
