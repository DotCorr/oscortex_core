/* core/user/frame/files.c
 *
 * FILES — a FRAME file manager. open(":ROOT") lists the FAT root as
 * 32-byte records (ADR-0100). Each listed 8.3 name is written to COM1.
 * The first name that is not this program is opened and its bytes are
 * printed (serial hex) and painted as a swatch. A baked GHOST.DAT open
 * is the missing-file probe: refusal is not a plant.
 *
 * ADR-0118 / ADR-0149: the first two listed .DAT names that are not
 * this program are copied and moved. Copy is open / read /
 * open(O_WRITE) / fdwrite / close. Move is rename (syscall 32) of the
 * source onto stem.MOV so the source name leaves. Dest 8.3 is the
 * source stem plus CPY or MOV — not a planted literal.
 *
 * ADR-0154: each listed name band gets a document icon through
 * osxui_icon_fb (osgfx_icon_rows in .rodata). Not a letter string.
 * FILES_NO_ICON=1 builds the anti-vacuity ELF without icons.
 *
 * ADR-0192: THE ROW CAPTIONS ARE REAL OUTLINES. Each 8.3 name is drawn by
 * `osxui_app_label_box` -> `wmOpPaint` -> `osgfx_text`, i.e. Roboto `glyf`
 * contours replayed into an SkPathBuilder and filled by SkCanvas::drawPath
 * with antialiasing on, at a proportional advance. They used to be
 * `osxui_label_fb`: an 8x16 BITMAP CELL per character, one fixed advance,
 * which is why the list read as paper stamps under a title bar that was
 * already live text. The document icon beside each row is still the .rodata
 * silhouette blit -- it is a shape, not a glyph, and nothing about it was a
 * font.
 *
 * `proc spawn FILES.ELF` so the prompt returns (ADR-0053). Numbers
 * come from osframe.h. Planted names must not appear as literals here.
 */

#include "osframe.h"
#include "osxui_app.h"

typedef unsigned long u64;
typedef unsigned int u32;

#define CHUNK 512UL
#define REC 32UL
#define NAME_MAX 12U
#define CAT_MAX 8U
#define WIN_W 400UL
#define WIN_H 280UL
#define SURF_X 48UL
#define SURF_Y 40UL
/* In lockstep with wmTitleH / SESS_TITLE_BAND. The compositor skips the
 * top 32 rows of the blit (caption lives there), so a row painted at y=0
 * is eaten by the title — FACTS.DAT became an 8-pixel sliver under a
 * gray slab. */
#define TITLE_H 32UL
#define SURF_FILL 0x00F4F6FAUL
#define SURF_BAND0 0x00E8EEF4UL
#define SURF_BAND1 0x00DEE6F0UL
/* First-three-bytes probe (ADR-0100). Lives in the title band the
 * compositor does not blit, so it cannot sit on a file row as a stray
 * grey slab (the owner screenshot at 320,16, then 372,252). Serial hex
 * is the public record. */
#define SWATCH_X 372UL
#define SWATCH_Y 8UL
#define SWATCH_W 16UL
#define SWATCH_H 16UL
#define ICON_PAD_X 2UL
#define LAB_PAD_X 20UL
#define LAB_FG 0x00202830UL
#define ICON_FG 0x00405060UL
#define SURF_OFFSET 1024UL
#define YIELD_SPIN 40000UL
#define ROW_H 28UL
#define MODE_WRITE 1UL
#define ERR_FLOOR 0xFFFFFFFFFFFFFF00UL

#ifndef FILES_NO_ICON
#define FILES_NO_ICON 0
#endif

#if FILES_NO_ICON == 0
/* osgfx_glyph.c — the document silhouette. A SHAPE out of .rodata, blitted
 * in-process; the caption next to it is not this and goes through
 * osxui_app_label_box (osxui_app.h). */
void osxui_icon_fb(u64 fb, u64 pitch, u64 wh, u64 xy, u64 rgb);
#endif

static unsigned char buf[512];
static unsigned char recs[CAT_MAX][32];
static char dotted[CAT_MAX][16];
static unsigned dotlen[CAT_MAX];
static unsigned char plant[64];
static u64 plant_n;
#if FILES_NO_ICON == 0
/* The advance the OS laid down for row 0's caption, in pixels. `8 * nlab`
 * would be the bitmap cell; anything else is the face's own `hmtx`. */
static u64 lab_adv;
#endif
static char dest_copy[16];
static char dest_move[16];
static char dest_ren[16];
static u64 desc[8] __attribute__((aligned(64))) = {0, 0, 0, 0, 0, 0, 0, 0};
static volatile u64 marker = 0x00F10000000000F1UL;
static char line[96];
static u64 files_h;
static u64 files_va;
static u64 files_names;
static u32 files_swatch;
static u64 files_seq;
static u64 files_w = WIN_W;
static u64 files_height = WIN_H;
static u64 files_stride = WIN_W * 4UL;
static u64 files_cap_w = WIN_W;
static u64 files_cap_h = WIN_H;
static u64 menu_on;
static u64 menu_row;
static u64 menu_x;
static u64 menu_y;
static u64 scroll_off;
#if FILES_NO_ICON == 0
static u64 csd_noted;
#endif
static const char msg_scroll[] = "FILES SCROLL ";

static const char path_root[] = ":ROOT";
static const char path_ghost[] = "GHOST.DAT";
static const unsigned char self83[11] = {
    'F', 'I', 'L', 'E', 'S', ' ', ' ', ' ', 'E', 'L', 'F'};

static const char msg_open[] = "FILES OPEN REFUSED ";
static const char msg_read[] = "FILES READ REFUSED ";
static const char msg_name[] = "FILES NAME ";
static const char msg_count[] = "FILES NAMES ";
static const char msg_cat[] = "FILES CAT ";
static const char msg_none[] = "FILES CAT NONE";
static const char msg_miss[] = "FILES MISS ";
static const char msg_ready[] = "FILES READY";
static const char msg_list[] = "FILES LIST";
static const char msg_strip[] = "FILES STRIP";
#if FILES_NO_ICON == 0
static const char msg_icon[] = "FILES ICON";
static const char msg_row[] = "FILES ROW OUTLINE ADV ";
static const char msg_row_cell[] = " CELL ";
#endif
static const char msg_copy[] = "FILES COPY ";
static const char msg_move[] = "FILES MOVE ";
static const char msg_copy_none[] = "FILES COPY NONE";
static const char msg_move_none[] = "FILES MOVE NONE";
#if FILES_NO_ICON == 0
static const char msg_csd[] = "FILES CSD";
static const char cap_files[] = "FILES";
#endif
static const char msg_menu[] = "FILES MENU";
static const char msg_fopen[] = "FILES OPEN ";
static const char msg_fren[] = "FILES RENAME ";
static const char ext_cpy[] = "CPY";
static const char ext_mov[] = "MOV";
static const char ext_ren[] = "REN";

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

static inline u64 sys2(u64 n, u64 a, u64 b) { return sys3(n, a, b, 0); }
static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }

static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }

__attribute__((noreturn)) static void die(u64 code) {
  sys1(SYS_EXIT, code);
  for (;;) {
  }
}

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

static unsigned putdec(unsigned at, u64 v) {
  char tmp[16];
  unsigned n = 0;
  if (v == 0) {
    line[at++] = '0';
    return at;
  }
  while (v) {
    tmp[n++] = (char)('0' + (v % 10));
    v /= 10;
  }
  while (n) {
    line[at++] = tmp[--n];
  }
  return at;
}

static void emit(unsigned n) { sys2(SYS_WRITE, (u64)line, n); }

static void cat_file(const char *name, unsigned nlen);

static unsigned fmt83(const unsigned char *rec, char *out) {
  unsigned n = 0;
  unsigned i;
  unsigned ext = 0;
  for (i = 0; i < 8; i++) {
    if (rec[i] == (unsigned char)' ') {
      break;
    }
    out[n++] = (char)rec[i];
  }
  for (i = 8; i < 11; i++) {
    if (rec[i] != (unsigned char)' ') {
      ext = 1;
    }
  }
  if (ext > 0) {
    out[n++] = '.';
    for (i = 8; i < 11; i++) {
      if (rec[i] == (unsigned char)' ') {
        break;
      }
      out[n++] = (char)rec[i];
    }
  }
  out[n] = 0;
  return n;
}

static unsigned is_self(const unsigned char *rec) {
  unsigned i;
  for (i = 0; i < 11; i++) {
    if (rec[i] != self83[i]) {
      return 0;
    }
  }
  return 1;
}

static unsigned is_dat(const unsigned char *rec) {
  if (rec[8] != (unsigned char)'D') {
    return 0;
  }
  if (rec[9] != (unsigned char)'A') {
    return 0;
  }
  if (rec[10] != (unsigned char)'T') {
    return 0;
  }
  return 1;
}

static unsigned same_bytes(const char *a, unsigned na, const char *b,
                           unsigned nb) {
  unsigned i;
  if (na != nb) {
    return 0;
  }
  for (i = 0; i < na; i++) {
    if (a[i] != b[i]) {
      return 0;
    }
  }
  return 1;
}

static unsigned dest_from(const char *src, unsigned nlen, char *out,
                          const char *ext3) {
  unsigned n = 0;
  unsigned i = 0;
  while (i < nlen) {
    if (src[i] == '.') {
      break;
    }
    if (n >= 8) {
      break;
    }
    out[n] = src[i];
    n = n + 1;
    i = i + 1;
  }
  out[n] = '.';
  n = n + 1;
  out[n] = ext3[0];
  n = n + 1;
  out[n] = ext3[1];
  n = n + 1;
  out[n] = ext3[2];
  n = n + 1;
  out[n] = 0;
  return n;
}

static u32 band_colour(u64 i) {
  if ((i & 1UL) == 0) {
    return (u32)SURF_BAND0;
  }
  return (u32)SURF_BAND1;
}

static void paint_all(u64 h, u64 va, u64 names, u32 swatch) {
  volatile u32 *p = (volatile u32 *)va;
#if FILES_NO_ICON
  (void)h;
#endif
  u64 py = 0;
  u64 body_h = files_height;
  u64 band_h = ROW_H;
  u64 visible;
  u64 max_off;
  if (body_h > TITLE_H) {
    body_h = files_height - TITLE_H;
  }
  visible = body_h / band_h;
  if (visible < 1UL) {
    visible = 1UL;
  }
  max_off = 0;
  if (names > visible) {
    max_off = names - visible;
  }
  if (scroll_off > max_off) {
    scroll_off = max_off;
  }
  while (py < files_height) {
    u64 px = 0;
    u32 c = (u32)SURF_FILL;
    if (names > 0) {
      if (py >= TITLE_H) {
        u64 row = scroll_off + (py - TITLE_H) / band_h;
        if (row < names) {
          c = band_colour(row);
        }
      }
    }
    while (px < files_w) {
      u64 hit = 0;
      if (swatch != 0) {
        if (px >= SWATCH_X) {
          if (px < (SWATCH_X + SWATCH_W)) {
            if (py >= SWATCH_Y) {
              if (py < (SWATCH_Y + SWATCH_H)) {
                hit = 1;
              }
            }
          }
        }
      }
      if (hit > 0) {
        p[py * (files_stride / 4UL) + px] = swatch;
      } else {
        p[py * (files_stride / 4UL) + px] = c;
      }
      px = px + 1;
    }
    py = py + 1;
  }
#if FILES_NO_ICON == 0
  osxui_app_csd(h, files_w, cap_files, 5);
  if (csd_noted == 0) {
    csd_noted = 1;
    wr(msg_csd, sizeof(msg_csd) - 1);
  }
  if (names > 0) {
    u64 row = 0;
    u64 wh = (files_w << 32) | files_height;
    u64 pitch = files_stride;
    while (row < visible) {
      u64 src = scroll_off + row;
      u64 iy;
      u64 xy;
      unsigned nlab;
      if (src >= names) {
        break;
      }
      iy = TITLE_H + row * band_h;
      if (iy + band_h > files_height) {
        break;
      }
      xy = (ICON_PAD_X << 32) | iy;
      osxui_icon_fb(va, pitch, wh, xy, ICON_FG);
      nlab = dotlen[src];
      if (nlab > 11U) {
        nlab = 11U;
      }
      if (nlab > 0U) {
        if (band_h > 8UL) {
          osxui_app_rrect(h, 6UL, iy + 2UL, files_w - 12UL, band_h - 4UL, 10UL,
                          (src & 1UL) ? SURF_BAND1 : SURF_BAND0);
        }
        u64 adv = osxui_app_label_box(h, LAB_PAD_X, iy, 0, band_h,
                                      dotted[src], nlab, WM_TEXT_LABEL_PX,
                                      WM_TEXT_REGULAR, LAB_FG);
        if (row == 0) {
          lab_adv = adv;
        }
      }
      row = row + 1;
    }
  }
#endif
}

#define FILE_MENU_W 96UL
#define FILE_MENU_H 56UL

static u64 row_at_y(u64 y, u64 names) {
  u64 body_h = files_height;
  u64 band_h = ROW_H;
  u64 row;
  u64 visible;
  if (body_h > TITLE_H) {
    body_h = files_height - TITLE_H;
  }
  visible = body_h / band_h;
  if (visible < 1UL) {
    visible = 1UL;
  }
  if (y < TITLE_H) {
    return CAT_MAX;
  }
  row = scroll_off + (y - TITLE_H) / band_h;
  if (row >= names) {
    return CAT_MAX;
  }
  if (row >= (scroll_off + visible)) {
    return CAT_MAX;
  }
  return row;
}

static void commit_files(void) {
  files_seq = files_seq + 1;
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = files_h;
  desc[WM_DESC_X] = 0;
  desc[WM_DESC_Y] = 0;
  desc[WM_DESC_W] = files_w;
  desc[WM_DESC_H] = files_height;
  desc[WM_DESC_STRIDE] = files_seq;
  desc[WM_DESC_OFFSET] = 0;
  (void)sys1(SYS_WMSURFACE, (u64)&desc[0]);
}

static void paint_file_menu(void) {
  u64 mx = menu_x;
  u64 my = menu_y;
  if (mx + FILE_MENU_W > files_w) {
    mx = files_w - FILE_MENU_W;
  }
  if (my + FILE_MENU_H > files_height) {
    my = files_height - FILE_MENU_H;
  }
  osxui_app_rrect(files_h, mx, my, FILE_MENU_W, FILE_MENU_H, OSXUI_MENU_R,
                  OSXUI_MENU_BG);
  osxui_app_rrect(files_h, mx + 4UL, my + OSXUI_MENU_PAD, FILE_MENU_W - 8UL,
                  OSXUI_MENU_ROW_H - 2UL, 4UL, OSXUI_MENU_ROW0);
  osxui_app_text(files_h, mx + 8UL, my + OSXUI_MENU_PAD + 4UL, "Open", 4,
                 WM_TEXT_LABEL_PX, WM_TEXT_REGULAR, OSXUI_MENU_FG);
  osxui_app_rrect(files_h, mx + 4UL, my + OSXUI_MENU_PAD + OSXUI_MENU_ROW_H,
                  FILE_MENU_W - 8UL, OSXUI_MENU_ROW_H - 2UL, 4UL,
                  OSXUI_MENU_ROW1);
  osxui_app_text(files_h, mx + 8UL, my + OSXUI_MENU_PAD + OSXUI_MENU_ROW_H + 4UL,
                 "Rename", 6, WM_TEXT_LABEL_PX, WM_TEXT_REGULAR, OSXUI_MENU_FG);
}

static void files_repaint(void) {
  if (files_h == 0) {
    return;
  }
  paint_all(files_h, files_va, files_names, files_swatch);
  if (menu_on > 0) {
    paint_file_menu();
  }
  commit_files();
}

static void do_file_open(u64 row) {
  unsigned at;
  if (row >= files_names) {
    return;
  }
  cat_file(dotted[row], dotlen[row]);
  at = put(0, msg_fopen);
  at = put(at, dotted[row]);
  emit(at);
}

static void do_file_rename(u64 row) {
  unsigned dlen;
  u64 r;
  unsigned at;
  unsigned i;
  if (row >= files_names) {
    return;
  }
  dlen = dest_from(dotted[row], dotlen[row], dest_ren, ext_ren);
  if (same_bytes(dotted[row], dotlen[row], dest_ren, dlen) > 0) {
    return;
  }
  r = sys4(SYS_RENAME, (u64)dotted[row], (u64)dotlen[row], (u64)dest_ren,
           (u64)dlen);
  if (r >= ERR_FLOOR) {
    return;
  }
  /* FILES reflects the committed name. Not an in-place field. */
  i = 0;
  while (i < dlen) {
    dotted[row][i] = dest_ren[i];
    i = i + 1;
  }
  dotted[row][dlen] = 0;
  dotlen[row] = dlen;
  at = put(0, msg_fren);
  at = put(at, dest_ren);
  emit(at);
}

static void files_on_event(u64 ev) {
  u64 typ = ev & 0xFFUL;
  u64 rx = (ev >> 16) & 0xFFFFUL;
  u64 ry = (ev >> 32) & 0xFFFFUL;
  if (typ == WMEVENT_TYPE_CONFIGURE) {
    u64 nw = (ev >> 40) & 0xFFFUL;
    u64 nh = (ev >> 52) & 0xFFFUL;
    if (nw > 0 && nh > 0) {
      if (nw > files_cap_w || nh > files_cap_h) {
        u64 stride = nw * 4UL;
        u64 pages = (SURF_OFFSET + stride * nh + 4095UL) / 4096UL;
        u64 grown = sys2(SYS_SHMGROW, files_h, pages);
        if (grown >= WM_RET_FLOOR) {
          return;
        }
        desc[WM_DESC_OP] = WM_OP_BACKING;
        desc[WM_DESC_HANDLE] = files_h;
        desc[WM_DESC_STRIDE] = stride;
        if (sys1(SYS_WMSURFACE, (u64)&desc[0]) >= WM_RET_FLOOR) {
          return;
        }
        files_stride = stride;
        files_cap_w = nw;
        files_cap_h = nh;
      }
      if (nw != files_w || nh != files_height) {
        files_w = nw;
        files_height = nh;
        files_repaint();
      }
    }
    return;
  }
  if (typ == WMEVENT_TYPE_SCROLL) {
    u64 delta = (ev >> 48) & 0xFFUL;
    u64 body_h =
        files_height > TITLE_H ? (files_height - TITLE_H) : files_height;
    u64 visible = body_h / ROW_H;
    u64 max_off = 0;
    unsigned at;
    if (visible < 1UL) {
      visible = 1UL;
    }
    if (files_names > visible) {
      max_off = files_names - visible;
    }
    if (delta == 0xFFUL) {
      if (scroll_off < max_off) {
        scroll_off = scroll_off + 1UL;
      }
    } else {
      if (scroll_off > 0) {
        scroll_off = scroll_off - 1UL;
      }
    }
    at = put(0, msg_scroll);
    at = puthex(at, scroll_off, 2);
    emit(at);
    files_repaint();
    return;
  }
  if (typ == WMEVENT_TYPE_CONTEXT) {
    menu_row = row_at_y(ry, files_names);
    menu_x = rx;
    menu_y = ry;
    menu_on = 1;
    wr(msg_menu, sizeof(msg_menu) - 1);
    files_repaint();
    return;
  }
  if (typ == WMEVENT_TYPE_PRESS) {
    if (menu_on > 0) {
      u64 mx = menu_x;
      u64 my = menu_y;
      if (mx + FILE_MENU_W > files_w) {
        mx = files_w - FILE_MENU_W;
      }
      if (my + FILE_MENU_H > files_height) {
        my = files_height - FILE_MENU_H;
      }
      if (rx >= mx && rx < (mx + FILE_MENU_W) && ry >= my &&
          ry < (my + FILE_MENU_H)) {
        u64 row = (ry - my - OSXUI_MENU_PAD) / OSXUI_MENU_ROW_H;
        menu_on = 0;
        if (row == 0) {
          do_file_open(menu_row);
        }
        if (row == 1) {
          do_file_rename(menu_row);
        }
        files_repaint();
        return;
      }
      menu_on = 0;
      files_repaint();
    }
  }
}

static void try_strip(u64 names, u32 swatch) {
  u64 h;
  u64 va;
  u64 frames;
  u64 pages;

  files_cap_w = WIN_W;
  files_cap_h = WIN_H;
  files_w = WIN_W;
  files_height = WIN_H;
  files_stride = WIN_W * 4UL;
  pages = (SURF_OFFSET + files_stride * files_cap_h + 4095UL) / 4096UL;

  h = sys1(SYS_SHMCREATE, pages);
  if (h >= WM_RET_FLOOR) {
    return;
  }

  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = h;
  desc[WM_DESC_X] = SURF_X;
  desc[WM_DESC_Y] = SURF_Y;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = files_stride;
  desc[WM_DESC_OFFSET] = WM_SURFACE_RESIZABLE | SURF_OFFSET;
  va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_RET_FLOOR) {
    return;
  }
  va = va + SURF_OFFSET;

  files_h = h;
  files_va = va;
  files_names = names;
  files_swatch = swatch;
  files_seq = 1;
  paint_all(h, va, names, swatch);

  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = h;
  desc[WM_DESC_X] = 0;
  desc[WM_DESC_Y] = 0;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 1;
  desc[WM_DESC_OFFSET] = 0;
  frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_RET_FLOOR) {
    return;
  }
  wr(msg_strip, sizeof(msg_strip) - 1);
#if FILES_NO_ICON == 0
  if (names > 0) {
    wr(msg_icon, sizeof(msg_icon) - 1);
  }
  /* WHAT THE ROWS ACTUALLY ARE, out of the running OS. The number after ADV is
   * what the rasteriser laid down for row 0; CELL is what an 8x16 grid would
   * have laid down for the same string. They differ, and that difference IS
   * ADR-0192's claim — a harness reads this line rather than the source. */
  if (names > 0) {
    unsigned at = put(0, msg_row);
    at = putdec(at, lab_adv);
    at = put(at, msg_row_cell);
    at = putdec(at, (u64)dotlen[0] * 8UL);
    emit(at);
  }
#endif
}

static void emit_name(const char *s, unsigned n) {
  unsigned at = put(0, msg_name);
  unsigned i;
  for (i = 0; i < n; i++) {
    line[at++] = s[i];
  }
  emit(at);
}

static void cat_file(const char *name, unsigned nlen) {
  u64 fd;
  u64 got;
  unsigned at;
  unsigned i;

  fd = sys2(SYS_OPEN, (u64)name, (u64)nlen);
  if (fd >= 0xFFFFFFFFFFFFFF00UL) {
    wr(msg_none, sizeof(msg_none) - 1);
    return;
  }
  plant_n = 0;
  for (;;) {
    got = sys3(SYS_READ, fd, (u64)buf, CHUNK);
    if (got >= 0xFFFFFFFFFFFFFF00UL) {
      sys1(SYS_CLOSE, fd);
      wr(msg_none, sizeof(msg_none) - 1);
      return;
    }
    if (got == 0) {
      break;
    }
    for (i = 0; i < (unsigned)got; i++) {
      if (plant_n < 64) {
        plant[plant_n] = buf[i];
        plant_n = plant_n + 1;
      }
    }
  }
  sys1(SYS_CLOSE, fd);

  at = put(0, msg_cat);
  for (i = 0; i < (unsigned)plant_n; i++) {
    at = puthex(at, plant[i], 2);
  }
  emit(at);
}

static void miss_ghost(void) {
  u64 fd;
  unsigned at;
  fd = sys2(SYS_OPEN, (u64)path_ghost, 9);
  if (fd < ERR_FLOOR) {
    sys1(SYS_CLOSE, fd);
    return;
  }
  at = put(0, msg_miss);
  at = put(at, path_ghost);
  emit(at);
}

static u64 write_copy(const char *src, unsigned slen, const char *dst,
                      unsigned dlen) {
  u64 in;
  u64 out;
  u64 got;
  u64 w;
  u64 total;

  if (same_bytes(src, slen, dst, dlen) > 0) {
    return ERR_FLOOR;
  }
  in = sys2(SYS_OPEN, (u64)src, (u64)slen);
  if (in >= ERR_FLOOR) {
    return in;
  }
  out = sys3(SYS_OPEN, (u64)dst, (u64)dlen, MODE_WRITE);
  if (out >= ERR_FLOOR) {
    sys1(SYS_CLOSE, in);
    return out;
  }
  total = 0;
  for (;;) {
    got = sys3(SYS_READ, in, (u64)buf, CHUNK);
    if (got >= ERR_FLOOR) {
      sys1(SYS_CLOSE, in);
      sys1(SYS_CLOSE, out);
      return got;
    }
    if (got == 0) {
      break;
    }
    w = sys3(SYS_FDWRITE, out, (u64)buf, got);
    if (w >= ERR_FLOOR) {
      sys1(SYS_CLOSE, in);
      sys1(SYS_CLOSE, out);
      return w;
    }
    if (w < got) {
      sys1(SYS_CLOSE, in);
      sys1(SYS_CLOSE, out);
      return ERR_FLOOR;
    }
    total = total + w;
  }
  sys1(SYS_CLOSE, in);
  sys1(SYS_CLOSE, out);
  return total;
}

static unsigned read_plant(const char *name, unsigned nlen) {
  u64 fd;
  u64 got;
  unsigned i;

  fd = sys2(SYS_OPEN, (u64)name, (u64)nlen);
  if (fd >= ERR_FLOOR) {
    return 0;
  }
  plant_n = 0;
  for (;;) {
    got = sys3(SYS_READ, fd, (u64)buf, CHUNK);
    if (got >= ERR_FLOOR) {
      sys1(SYS_CLOSE, fd);
      plant_n = 0;
      return 0;
    }
    if (got == 0) {
      break;
    }
    for (i = 0; i < (unsigned)got; i++) {
      if (plant_n < 64) {
        plant[plant_n] = buf[i];
        plant_n = plant_n + 1;
      }
    }
  }
  sys1(SYS_CLOSE, fd);
  return 1;
}

static void emit_op(const char *msg, const char *name, unsigned nlen) {
  unsigned at = put(0, msg);
  unsigned i;
  for (i = 0; i < nlen; i++) {
    line[at++] = name[i];
  }
  line[at++] = ' ';
  for (i = 0; i < (unsigned)plant_n; i++) {
    at = puthex(at, plant[i], 2);
  }
  emit(at);
}

static unsigned cstr_n(const char *s) {
  unsigned n = 0;
  while (s[n]) {
    n = n + 1;
  }
  return n;
}

static void do_copy(unsigned pick, char *dest) {
  unsigned dlen;
  u64 wrote;

  if (pick >= CAT_MAX) {
    wr(msg_copy_none, cstr_n(msg_copy_none));
    return;
  }
  dlen = dest_from(dotted[pick], dotlen[pick], dest, ext_cpy);
  wrote = write_copy(dotted[pick], dotlen[pick], dest, dlen);
  if (wrote >= ERR_FLOOR) {
    wr(msg_copy_none, cstr_n(msg_copy_none));
    return;
  }
  if (read_plant(dest, dlen) < 1) {
    wr(msg_copy_none, cstr_n(msg_copy_none));
    return;
  }
  emit_op(msg_copy, dest, dlen);
}

/* Move is rename onto stem.MOV (ADR-0149). Source name must leave. */
static void do_move(unsigned pick, char *dest) {
  unsigned dlen;
  u64 r;
  u64 miss;

  if (pick >= CAT_MAX) {
    wr(msg_move_none, cstr_n(msg_move_none));
    return;
  }
  dlen = dest_from(dotted[pick], dotlen[pick], dest, ext_mov);
  if (same_bytes(dotted[pick], dotlen[pick], dest, dlen) > 0) {
    wr(msg_move_none, cstr_n(msg_move_none));
    return;
  }
  r = sys4(SYS_RENAME, (u64)dotted[pick], (u64)dotlen[pick], (u64)dest,
           (u64)dlen);
  if (r >= ERR_FLOOR) {
    wr(msg_move_none, cstr_n(msg_move_none));
    return;
  }
  if (read_plant(dest, dlen) < 1) {
    wr(msg_move_none, cstr_n(msg_move_none));
    return;
  }
  miss = sys2(SYS_OPEN, (u64)dotted[pick], (u64)dotlen[pick]);
  if (miss < ERR_FLOOR) {
    sys1(SYS_CLOSE, miss);
    wr(msg_move_none, cstr_n(msg_move_none));
    return;
  }
  emit_op(msg_move, dest, dlen);
}

OSFRAME_START(files_main);

void files_main(u64 sp);

void files_main(u64 sp) {
  u64 fd;
  u64 got;
  u64 names;
  (void)sp;
  unsigned i;
  unsigned n;
  unsigned pick;
  unsigned copy_i;
  unsigned move_i;
  u32 swatch;

  if (marker != 0x00F10000000000F1UL) {
    die(0xF1000006UL);
  }

  fd = sys2(SYS_OPEN, (u64)path_root, 5);
  if (fd >= 0xFFFFFFFFFFFFFF00UL) {
    n = put(0, msg_open);
    n = puthex(n, fd & 0xFFFFFFFFUL, 8);
    emit(n);
    try_strip(0, 0);
    wr(msg_ready, sizeof(msg_ready) - 1);
    for (;;) {
      {
        volatile u64 spin = 0;
        while (spin < YIELD_SPIN) {
          spin = spin + 1;
        }
      }
      sys1(SYS_YIELD, 0);
    }
  }

  names = 0;
  for (;;) {
    got = sys3(SYS_READ, fd, (u64)buf, CHUNK);
    if (got >= 0xFFFFFFFFFFFFFF00UL) {
      n = put(0, msg_read);
      n = puthex(n, got & 0xFFFFFFFFUL, 8);
      emit(n);
      die(0xF1000002UL);
    }
    if (got == 0) {
      break;
    }
    i = 0;
    while (i + REC <= (unsigned)got) {
      if (names < CAT_MAX) {
        unsigned k;
        for (k = 0; k < 32; k++) {
          recs[names][k] = buf[i + k];
        }
        n = fmt83(recs[names], dotted[names]);
        dotlen[names] = n;
        emit_name(dotted[names], n);
        names = names + 1;
      }
      i = i + (unsigned)REC;
    }
  }
  sys1(SYS_CLOSE, fd);

  n = put(0, msg_count);
  n = putdec(n, names);
  emit(n);
  wr(msg_list, sizeof(msg_list) - 1);

  pick = CAT_MAX;
  for (i = 0; i < (unsigned)names; i++) {
    if (is_self(recs[i]) < 1) {
      pick = i;
      i = (unsigned)names;
    }
  }
  plant_n = 0;
  if (pick < CAT_MAX) {
    cat_file(dotted[pick], dotlen[pick]);
  } else {
    wr(msg_none, sizeof(msg_none) - 1);
  }

  copy_i = CAT_MAX;
  move_i = CAT_MAX;
  for (i = 0; i < (unsigned)names; i++) {
    if (is_self(recs[i]) < 1) {
      if (is_dat(recs[i]) > 0) {
        if (copy_i >= CAT_MAX) {
          copy_i = i;
        } else {
          if (move_i >= CAT_MAX) {
            move_i = i;
          }
        }
      }
    }
  }
  do_copy(copy_i, dest_copy);
  do_move(move_i, dest_move);

  miss_ghost();

  swatch = 0;
  if (plant_n >= 3) {
    swatch = ((u32)plant[0] << 16) | ((u32)plant[1] << 8) | (u32)plant[2];
    swatch = swatch & 0x00FFFFFFUL;
    if (swatch == 0) {
      swatch = 0x00010101UL;
    }
  }
  try_strip(names, swatch);
  wr(msg_ready, sizeof(msg_ready) - 1);

  for (;;) {
    u64 ev;
    u64 got;
    got = 0;
    ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    while (ev != 0) {
      files_on_event(ev);
      got = 1;
      ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    }
    if (got == 0 && menu_on == 0) {
      volatile u64 spin = 0;
      while (spin < YIELD_SPIN) {
        spin = spin + 1;
      }
    }
    sys1(SYS_YIELD, 0);
  }
}
