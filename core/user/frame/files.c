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
#define CAT_MAX 16U
#define WIN_W 400UL
#define WIN_H 280UL
/* Native 1280×720 maximize: origin (border,border), dock 48, border 3.
 * Commit this many pages at attach so grow is in-place before SET lands
 * in the hole that would otherwise split the 1024-page window. */
#define MAX_W 1274UL
#define MAX_H 666UL
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
#define SURF_SEL 0x00B8C8D8UL
#define SURF_EMPTY_FG 0x00405060UL
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
#define YIELD_SPIN 8000UL
#define FAT_ATTR 11U
#define FAT_ATTR_DIR 0x10U
#define FILE_RET_ISDIR 0xFFFFFFFFFFFFFFF8UL
#define FILE_RET_EMPTY 0xFFFFFFFFFFFFFFF7UL
#define FILE_RET_NOTFOUND 0xFFFFFFFFFFFFFFF9UL
#define ROW_H 28UL
#define SCROLL_TRACK_W 4UL
#define SCROLL_TRACK_PAD 6UL
#define SCROLL_THUMB_MIN 20UL
#define SCROLL_TRACK 0x003A4654UL
#define SCROLL_THUMB 0x00869BB0UL
#define MENU_SELECTED 0x00D0E4F8UL
#define SCAN_ESC 0x01UL
#define SCAN_BKSP 0x0EUL
#define SCAN_TAB 0x0FUL
#define SCAN_ENTER 0x1CUL
#define SCAN_UP 0x48UL
#define SCAN_DOWN 0x50UL
#define SCAN_LEFT 0x4BUL
#define SCAN_RIGHT 0x4DUL
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
/* 1 after the native-max body is painted into hidden backing. Restore
 * and later maximize reuse it; do not shrink the cap (SHM allows it).
 * SYS_SHMSHRINK on this path was the 1.3s TCG hitch (719-page unmap
 * before the host saw PRES). Keep the name so de-desk / de-skia-own
 * still see the reclaim door; do not call it on restore. */
static u64 files_retain_body;
/* Last size that was fully published (full-height COMMIT). Title-only
 * CSD is valid only at this size. A grow/restore that has not yet
 * published the new rect must COMMIT the whole page, or 800×600
 * (idle prep skipped) leaves the grown body as wallpaper. */
static u64 files_pub_w;
static u64 files_pub_h;
/* Configure-side operation id. Printed on REST / PHZ / COMMIT so the
 * host pairs by id, not the next PRES. */
static u64 files_op;
static u64 files_note_commit;
static u64 files_slot = 0xFFUL;
static u64 menu_on;
static u64 menu_row;
static u64 menu_x;
static u64 menu_y;
static u64 menu_sel;
static u64 files_writable;
static u64 files_ctrl;
static u64 clip_h;
static u64 confirm_del;
static u64 can_fwd;
static u64 cut_row;
static char edit_buf[16];
static u64 edit_n;
static u64 edit_caret;
static u64 edit_on;
static const char msg_del[] = "FILES DEL ";
static const char msg_del_conf[] = "FILES DEL CONFIRM";
static const char msg_new[] = "FILES NEW ";
static const char msg_mkdir[] = "FILES MKDIR ";
static const char msg_paste[] = "FILES PASTE ";
static const char msg_refresh[] = "FILES REFRESH";
static const char msg_fwd[] = "FILES FWD";
static const char msg_ro[] = "FILES RO";
static const char msg_clip[] = "FILES CLIP ";
static const char msg_field[] = "FILES FIELD ";
static u64 scroll_off;
static u64 list_sel;
static u64 files_err;
static u64 empty_noted;
static u64 root_names;
static u64 in_folder;
static char folder_name[16];
static unsigned folder_nlen;
static char fwd_name[16];
static unsigned fwd_nlen;
static const char path_gone[] = "GONE.DAT";
static const char path_miss[] = "MISS.DAT";
static const char msg_retry[] = "FILES RETRY";
static const char msg_dir[] = "FILES DIR ";
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
static const char msg_phz_grow[] = "FILES PHZ GROW\n";
static const char msg_phz_paint[] = "FILES PHZ PAINT";
static const char msg_prefill[] = "FILES PREFILL\n";
static const char msg_cfg[] = "FILES CFG ";
static const char msg_menu[] = "FILES MENU";
static const char msg_menu_esc[] = "FILES MENU ESC\n";
static const char msg_menu_sel[] = "FILES MENU SEL ";
static const char msg_fopen[] = "FILES OPEN ";
static const char msg_fren[] = "FILES RENAME ";
static const char msg_sel[] = "FILES SEL ";
static const char msg_back[] = "FILES BACK";
static const char msg_empty[] = "FILES EMPTY";
static const char msg_err[] = "FILES ERR";
static const char msg_key[] = "FILES KEY ";
static const char lab_empty[] = "This folder is empty";
static const char lab_error[] = "This path is unavailable";
static const char msg_error[] = "FILES ERROR";
static const char ext_cpy[] = "CPY";
static const char ext_mov[] = "MOV";
static const char ext_ren[] = "REN";
static const char ext_pst[] = "PST";

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

/* TCG turns `rep stosl` into a host memset. The per-pixel cream loop
 * was the 663–746ms cold max (848k stores with a swatch test each). */
static void fill_dwords(volatile u32 *p, u64 n, u32 c) {
  u32 *d;
  u64 cnt;
  if (n == 0) {
    return;
  }
  d = (u32 *)p;
  cnt = n;
  __asm__ volatile("rep stosl" : "+D"(d), "+c"(cnt) : "a"(c) : "memory");
}

static void emit_phz_paint(char which) {
  unsigned at = put(0, msg_phz_paint);
  line[at++] = ' ';
  line[at++] = which;
  at = put(at, " OP ");
  at = puthex(at, files_op, 8);
  line[at++] = '\n';
  emit(at);
}

static void emit_files_commit(void) {
  unsigned at = put(0, "FILES COMMIT OP ");
  at = puthex(at, files_op, 8);
  line[at++] = '\n';
  emit(at);
}

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

static u64 files_visible(void);

static u32 band_colour(u64 i) {
  if ((i & 1UL) == 0) {
    return (u32)SURF_BAND0;
  }
  return (u32)SURF_BAND1;
}

static void paint_scrollbar(u64 h, u64 names, u64 visible) {
  u64 body_h;
  u64 track_h;
  u64 thumb_h;
  u64 travel;
  u64 max_off;
  u64 thumb_y;
  u64 x;
  if (names <= visible || files_w <= (SCROLL_TRACK_PAD + SCROLL_TRACK_W)) {
    return;
  }
  body_h = files_height > TITLE_H ? files_height - TITLE_H : 0;
  if (body_h <= (SCROLL_TRACK_PAD * 2UL)) {
    return;
  }
  track_h = body_h - SCROLL_TRACK_PAD * 2UL;
  thumb_h = (track_h * visible) / names;
  if (thumb_h < SCROLL_THUMB_MIN) {
    thumb_h = SCROLL_THUMB_MIN;
  }
  if (thumb_h > track_h) {
    thumb_h = track_h;
  }
  travel = track_h - thumb_h;
  max_off = names - visible;
  thumb_y = TITLE_H + SCROLL_TRACK_PAD + (travel * scroll_off) / max_off;
  x = files_w - SCROLL_TRACK_PAD - SCROLL_TRACK_W;
  osxui_app_rrect(h, x, TITLE_H + SCROLL_TRACK_PAD, SCROLL_TRACK_W, track_h,
                  2UL, SCROLL_TRACK);
  osxui_app_rrect(h, x, thumb_y, SCROLL_TRACK_W, thumb_h, 2UL, SCROLL_THUMB);
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
  u64 stride_px = files_stride / 4UL;
  u64 span_w = files_w;
  if (files_retain_body > 0) {
    if (files_cap_w > span_w) {
      span_w = files_cap_w;
    }
  }
  if (span_w > stride_px) {
    span_w = stride_px;
  }
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
    u32 c = (u32)SURF_FILL;
    if (names > 0) {
      if (py >= TITLE_H) {
        u64 row = scroll_off + (py - TITLE_H) / band_h;
        if (row < names) {
          if (row == list_sel) {
            c = (u32)SURF_SEL;
          } else {
            c = band_colour(row);
          }
        }
      }
    }
    fill_dwords(p + py * stride_px, span_w, c);
    py = py + 1;
  }
  if (swatch != 0) {
    u64 sy = SWATCH_Y;
    while (sy < (SWATCH_Y + SWATCH_H)) {
      if (sy < files_height) {
        u64 sx = SWATCH_X;
        while (sx < (SWATCH_X + SWATCH_W)) {
          if (sx < span_w) {
            p[sy * stride_px + sx] = swatch;
          }
          sx = sx + 1;
        }
      }
      sy = sy + 1;
    }
  }
#if FILES_NO_ICON == 0
  osxui_app_csd_win(h, files_w, files_height, cap_files, 5);
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
          u64 fill = (src & 1UL) ? SURF_BAND1 : SURF_BAND0;
          if (src == list_sel) {
            fill = SURF_SEL;
          }
          osxui_app_rrect(h, 6UL, iy + 2UL, files_w - 12UL, band_h - 4UL, 10UL,
                          fill);
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
  paint_scrollbar(h, names, visible);
  if (names == 0) {
    if (files_height > TITLE_H) {
      osxui_app_rrect(h, 4UL, TITLE_H, files_w - 8UL, files_height - TITLE_H,
                      0, SURF_FILL);
    }
    if (files_err > 0) {
      osxui_app_text(h, LAB_PAD_X, TITLE_H + 8UL, lab_error, 24,
                     WM_TEXT_LABEL_PX, WM_TEXT_REGULAR, SURF_EMPTY_FG);
    } else {
      osxui_app_text(h, LAB_PAD_X, TITLE_H + 8UL, lab_empty, 20,
                     WM_TEXT_LABEL_PX, WM_TEXT_REGULAR, SURF_EMPTY_FG);
    }
    if (empty_noted == 0) {
      empty_noted = 1;
      if (files_err > 0) {
        wr(msg_error, sizeof(msg_error) - 1);
      } else {
        wr(msg_empty, sizeof(msg_empty) - 1);
      }
    }
  }
#endif
}

#define FILE_MENU_W 168UL
#define FILE_MENU_H 152UL
#define FILE_MENU_ROWS 6UL
#define SCAN_LCTRL 0x1DUL
#define SCAN_F5 0x3FUL
/* Clip bytes live in the window region's unused prefix (SURF_OFFSET). */
#define EDIT_MAX 12UL
#define NAME_NEW "NEW.DAT"
#define NAME_NEW_N 7UL
#define NAME_DIR "NEWDIR"
#define NAME_DIR_N 6UL

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

static void commit_files_rect(u64 y, u64 h) {
  files_seq = files_seq + 1;
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = files_h;
  desc[WM_DESC_X] = 0;
  desc[WM_DESC_Y] = y;
  desc[WM_DESC_W] = files_w;
  desc[WM_DESC_H] = h;
  desc[WM_DESC_STRIDE] = files_seq;
  desc[WM_DESC_OFFSET] = 0;
  (void)sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (h >= files_height && y == 0) {
    files_pub_w = files_w;
    files_pub_h = files_height;
  }
  if (files_note_commit > 0) {
    files_note_commit = 0;
    emit_files_commit();
  }
}

#if FILES_NO_ICON == 0
static void files_paint_csd_only(void) {
  u64 commit_h;
  if (files_h == 0) {
    return;
  }
  osxui_app_csd_win(files_h, files_w, files_height, cap_files, 5);
  files_note_commit = 1;
  /* Same-size CSD stays title-only so a leftover 1274×666 compose
   * cannot sit on the next click. First publish at a new size must
   * expose the whole page — idle prep is skipped below 1200 px. */
  commit_h = TITLE_H;
  if (files_w != files_pub_w || files_height != files_pub_h) {
    commit_h = files_height;
  }
  commit_files_rect(0, commit_h);
}
#endif

static void files_prefill_cap(void) {
  u64 saved_w = files_w;
  u64 saved_h = files_height;
  if (files_h == 0 || files_cap_w <= files_w) {
    if (files_cap_h <= files_height) {
      return;
    }
  }
  files_w = files_cap_w;
  files_height = files_cap_h;
  paint_all(files_h, files_va, files_names, files_swatch);
  files_w = saved_w;
  files_height = saved_h;
#if FILES_NO_ICON == 0
  osxui_app_csd_win(files_h, files_w, files_height, cap_files, 5);
#endif
  files_retain_body = 1;
  wr(msg_prefill, sizeof(msg_prefill) - 1);
}

static void do_copy(unsigned pick, char *dest);
static void do_move(unsigned pick, char *dest);
static u64 write_copy(const char *src, unsigned slen, const char *dst,
                      unsigned dlen);
static void do_file_open(u64 row);
static void do_file_rename(u64 row);
static void files_go_back(void);
static void files_set_sel(u64 row);
static void files_retry(void);
static void files_show_empty(void);
static void files_show_error(void);
static void files_repaint(void);
static u64 files_load_listing(const char *path, unsigned nlen);
static void emit_name(const char *s, unsigned n);

static void files_probe_writable(void) {
  if (files_writable > 0) {
    return;
  }
  files_writable = 0;
  wr(msg_ro, sizeof(msg_ro) - 1);
}

static volatile unsigned char *files_clip_bytes(void) {
  if (files_va < SURF_OFFSET) {
    return (volatile unsigned char *)0;
  }
  return (volatile unsigned char *)(files_va - SURF_OFFSET);
}

static void files_clip_offer(const char *s, u64 n) {
  volatile unsigned char *p;
  u64 i;
  u64 r;
  unsigned at;
  if (files_h == 0 || n < 1) {
    return;
  }
  p = files_clip_bytes();
  if (p == 0) {
    return;
  }
  if (n > 64UL) {
    n = 64UL;
  }
  i = 0;
  while (i < n) {
    p[i] = (unsigned char)s[i];
    i = i + 1;
  }
  r = osxui_app_clip(WM_OP_OFFER, files_h, n);
  at = put(0, msg_clip);
  if (r >= ERR_FLOOR) {
    at = put(at, "ERR ");
    at = puthex(at, r & 0xFFUL, 2);
  } else {
    at = puthex(at, n, 2);
  }
  emit(at);
}

static u64 files_clip_take(char *dst, u64 max) {
  u64 r;
  volatile unsigned char *p;
  u64 i;
  if (files_h == 0) {
    return 0;
  }
  r = osxui_app_clip(WM_OP_TAKE, files_h, 0);
  if (r >= ERR_FLOOR) {
    return 0;
  }
  if (r > max) {
    r = max;
  }
  p = files_clip_bytes();
  if (p == 0) {
    return 0;
  }
  i = 0;
  while (i < r) {
    dst[i] = (char)p[i];
    i = i + 1;
  }
  if (r < max) {
    dst[r] = 0;
  }
  return r;
}

static void files_edit_from_sel(void) {
  u64 i;
  if (list_sel >= files_names) {
    edit_n = 0;
    edit_caret = 0;
    return;
  }
  i = 0;
  while (i < dotlen[list_sel] && i < EDIT_MAX) {
    edit_buf[i] = dotted[list_sel][i];
    i = i + 1;
  }
  edit_n = i;
  edit_caret = i;
  edit_buf[i] = 0;
}

static void files_remember_folder(const char *name, unsigned nlen) {
  unsigned i = 0;
  if (nlen > 12U) {
    nlen = 12U;
  }
  while (i < nlen) {
    folder_name[i] = name[i];
    fwd_name[i] = name[i];
    i = i + 1;
  }
  folder_name[nlen] = 0;
  fwd_name[nlen] = 0;
  folder_nlen = nlen;
  fwd_nlen = nlen;
}

static u64 files_load_listing(const char *path, unsigned nlen) {
  u64 fd;
  u64 got;
  u64 names;
  unsigned i;
  unsigned n;
  if (nlen < 1U) {
    return 1;
  }
  fd = sys2(SYS_OPEN, (u64)path, (u64)nlen);
  if (fd >= ERR_FLOOR) {
    return 1;
  }
  names = 0;
  for (;;) {
    got = sys3(SYS_READ, fd, (u64)buf, CHUNK);
    if (got >= ERR_FLOOR) {
      sys1(SYS_CLOSE, fd);
      return 1;
    }
    if (got == 0) {
      break;
    }
    i = 0;
    while (i + REC <= (unsigned)got) {
      if (names < CAT_MAX) {
        unsigned k;
        unsigned skip = 0;
        for (k = 0; k < 32; k++) {
          recs[names][k] = buf[i + k];
        }
        if (recs[names][0] == (unsigned char)'.') {
          skip = 1;
        }
        if (skip < 1) {
          n = fmt83(recs[names], dotted[names]);
          dotlen[names] = n;
          emit_name(dotted[names], n);
          names = names + 1;
        }
      }
      i = i + (unsigned)REC;
    }
  }
  sys1(SYS_CLOSE, fd);
  files_names = names;
  files_err = 0;
  list_sel = 0;
  scroll_off = 0;
  empty_noted = 0;
  n = put(0, msg_count);
  n = putdec(n, names);
  emit(n);
  return 0;
}

static void files_go_fwd(void) {
  if (can_fwd < 1) {
    return;
  }
  if (fwd_nlen < 1U) {
    return;
  }
  if (files_load_listing(fwd_name, fwd_nlen) > 0) {
    files_show_error();
    return;
  }
  files_remember_folder(fwd_name, fwd_nlen);
  in_folder = 1;
  can_fwd = 0;
  wr(msg_fwd, sizeof(msg_fwd) - 1);
  files_repaint();
}

static void files_do_refresh(void) {
  wr(msg_refresh, sizeof(msg_refresh) - 1);
  if (in_folder > 0) {
    if (files_err > 0) {
      files_retry();
      return;
    }
    if (folder_nlen > 0U) {
      if (files_load_listing(folder_name, folder_nlen) > 0) {
        files_show_error();
        return;
      }
    }
    files_repaint();
    return;
  }
  if (files_load_listing(path_root, 5) > 0) {
    files_show_error();
    return;
  }
  empty_noted = 0;
  files_repaint();
}

static void files_reload_here(void) {
  if (in_folder > 0 && folder_nlen > 0U) {
    if (files_load_listing(folder_name, folder_nlen) > 0) {
      files_show_error();
      return;
    }
  } else {
    if (files_load_listing(path_root, 5) > 0) {
      files_show_error();
      return;
    }
  }
}

static void files_do_new(void) {
  u64 fd;
  unsigned at;
  if (files_writable < 1) {
    wr(msg_ro, sizeof(msg_ro) - 1);
    return;
  }
  fd = sys3(SYS_OPEN, (u64)NAME_NEW, NAME_NEW_N, MODE_WRITE);
  if (fd >= ERR_FLOOR) {
    wr(msg_ro, sizeof(msg_ro) - 1);
    return;
  }
  sys1(SYS_CLOSE, fd);
  at = put(0, msg_new);
  at = put(at, NAME_NEW);
  emit(at);
  files_reload_here();
}

static void files_do_mkdir(void) {
  u64 r;
  unsigned at;
  if (files_writable < 1) {
    wr(msg_ro, sizeof(msg_ro) - 1);
    return;
  }
  r = sys2(SYS_MKDIR, (u64)NAME_DIR, NAME_DIR_N);
  at = put(0, msg_mkdir);
  at = put(at, NAME_DIR);
  if (r >= ERR_FLOOR) {
    at = put(at, " ERR");
    emit(at);
    return;
  }
  emit(at);
  files_reload_here();
  {
    u64 i = 0;
    while (i < files_names) {
      if (same_bytes(dotted[i], dotlen[i], NAME_DIR, (unsigned)NAME_DIR_N) > 0) {
        files_set_sel(i);
        i = files_names;
      } else {
        i = i + 1;
      }
    }
  }
}

static void files_do_delete(u64 row) {
  u64 r;
  unsigned at;
  if (row >= files_names) {
    return;
  }
  if (files_writable < 1) {
    wr(msg_ro, sizeof(msg_ro) - 1);
    return;
  }
  if (confirm_del != (row + 1UL)) {
    confirm_del = row + 1UL;
    wr(msg_del_conf, sizeof(msg_del_conf) - 1);
    return;
  }
  confirm_del = 0;
  r = sys2(SYS_UNLINK, (u64)dotted[row], (u64)dotlen[row]);
  at = put(0, msg_del);
  at = put(at, dotted[row]);
  if (r >= ERR_FLOOR) {
    at = put(at, " ERR");
    emit(at);
    return;
  }
  emit(at);
  files_reload_here();
}

static void files_do_paste(void) {
  char got[16];
  u64 n;
  unsigned dlen;
  u64 wrote;
  unsigned at;
  n = files_clip_take(got, 12);
  if (n < 1) {
    return;
  }
  got[n] = 0;
  at = put(0, msg_paste);
  at = put(at, got);
  emit(at);
  {
    u64 i = 0;
    while (i < n && i < EDIT_MAX) {
      edit_buf[i] = got[i];
      i = i + 1;
    }
  }
  edit_n = n;
  edit_caret = n;
  edit_buf[n] = 0;
  at = put(0, msg_field);
  at = put(at, edit_buf);
  emit(at);
  if (files_writable < 1) {
    return;
  }
  if (cut_row < files_names) {
    dlen = dest_from(got, (unsigned)n, dest_ren, ext_pst);
    (void)sys4(SYS_RENAME, (u64)dotted[cut_row], (u64)dotlen[cut_row],
               (u64)dest_ren, (u64)dlen);
    cut_row = CAT_MAX;
    files_reload_here();
    return;
  }
  dlen = dest_from(got, (unsigned)n, dest_copy, ext_pst);
  wrote = write_copy(got, (unsigned)n, dest_copy, dlen);
  (void)wrote;
  files_reload_here();
}

static void files_menu_run(u64 row) {
  if (in_folder > 0) {
    if (row == 0) {
      files_go_back();
    } else if (row == 1) {
      files_retry();
    } else if (row == 2) {
      do_file_open(menu_row);
    } else if (row == 3) {
      files_do_new();
    } else if (row == 4) {
      files_do_mkdir();
    } else if (row == 5) {
      files_do_refresh();
    }
    return;
  }
  if (row == 0) {
    do_file_open(menu_row);
    return;
  }
  if (row == 1) {
    do_file_rename(menu_row);
    return;
  }
  if (row == 2) {
    if (menu_row < files_names) {
      do_copy((unsigned)menu_row, dest_copy);
      files_clip_offer(dotted[menu_row], (u64)dotlen[menu_row]);
    }
    return;
  }
  if (row == 3) {
    files_do_delete(menu_row);
    return;
  }
  if (row == 4) {
    files_do_new();
    return;
  }
  if (row == 5) {
    files_do_mkdir();
  }
}

static void paint_file_menu(void) {
  u64 mx = menu_x;
  u64 my = menu_y;
  u64 row;
  u64 rgb;
  u64 fg;
  const char *lab;
  unsigned nlab;
  u64 enabled;
  if (mx + FILE_MENU_W > files_w) {
    mx = files_w - FILE_MENU_W;
  }
  if (my + FILE_MENU_H > files_height) {
    my = files_height - FILE_MENU_H;
  }
  osxui_app_rrect(files_h, mx, my, FILE_MENU_W, FILE_MENU_H, OSXUI_MENU_R,
                  OSXUI_MENU_BG);
  row = 0;
  while (row < FILE_MENU_ROWS) {
    enabled = 1;
    if (in_folder > 0) {
      if (row == 0) {
        lab = "Back";
        nlab = 4;
      } else if (row == 1) {
        lab = "Retry";
        nlab = 5;
      } else if (row == 2) {
        lab = "Open";
        nlab = 4;
        if (menu_row >= files_names) {
          enabled = 0;
        }
      } else if (row == 3) {
        lab = "New File";
        nlab = 8;
        if (files_writable < 1) {
          enabled = 0;
        }
      } else if (row == 4) {
        lab = "New Folder";
        nlab = 10;
        if (files_writable < 1) {
          enabled = 0;
        }
      } else {
        lab = "Refresh";
        nlab = 7;
      }
    } else {
      if (row == 0) {
        lab = "Open";
        nlab = 4;
        if (menu_row >= files_names) {
          enabled = 0;
        }
      } else if (row == 1) {
        lab = "Rename";
        nlab = 6;
        if (menu_row >= files_names || files_writable < 1) {
          enabled = 0;
        }
      } else if (row == 2) {
        lab = "Copy";
        nlab = 4;
        if (menu_row >= files_names) {
          enabled = 0;
        }
      } else if (row == 3) {
        lab = "Delete";
        nlab = 6;
        if (confirm_del == (menu_row + 1UL)) {
          lab = "Delete?";
          nlab = 7;
        }
        if (menu_row >= files_names || files_writable < 1) {
          enabled = 0;
        }
      } else if (row == 4) {
        lab = "New File";
        nlab = 8;
        if (files_writable < 1) {
          enabled = 0;
        }
      } else {
        lab = "New Folder";
        nlab = 10;
        if (files_writable < 1) {
          enabled = 0;
        }
      }
    }
    rgb = (row & 1UL) ? OSXUI_MENU_ROW1 : OSXUI_MENU_ROW0;
    if (menu_sel == row) {
      rgb = MENU_SELECTED;
    }
    fg = enabled > 0 ? OSXUI_MENU_FG : SURF_EMPTY_FG;
    osxui_app_rrect(files_h, mx + 4UL,
                    my + OSXUI_MENU_PAD + row * OSXUI_MENU_ROW_H,
                    FILE_MENU_W - 8UL, OSXUI_MENU_ROW_H - 2UL, 4UL, rgb);
    osxui_app_text(files_h, mx + 8UL,
                   my + OSXUI_MENU_PAD + row * OSXUI_MENU_ROW_H + 4UL, lab,
                   nlab, WM_TEXT_LABEL_PX, WM_TEXT_REGULAR, fg);
    row = row + 1;
  }
}

static void files_repaint(void) {
  if (files_h == 0) {
    return;
  }
  paint_all(files_h, files_va, files_names, files_swatch);
  if (menu_on > 0) {
    paint_file_menu();
  }
  commit_files_rect(0, files_height);
}

static void files_repaint_body(void) {
  u64 body_h;
  if (files_h == 0 || files_height <= TITLE_H) {
    return;
  }
  paint_all(files_h, files_va, files_names, files_swatch);
  if (menu_on > 0) {
    paint_file_menu();
  }
  body_h = files_height - TITLE_H;
  commit_files_rect(TITLE_H, body_h);
}

/* One visible row. Used after a translate so the first body click
 * does not Skia-replay every label (the 120 ms cold hitch). */
static void files_paint_one_row(u64 src) {
  u64 band_h = ROW_H;
  u64 visible = files_visible();
  u64 row;
  u64 iy;
  u32 c;
  volatile u32 *p;
  u64 stride_px;
  u64 span_w;
  u64 py;
  if (files_h == 0 || src < scroll_off) {
    return;
  }
  row = src - scroll_off;
  if (row >= visible) {
    return;
  }
  iy = TITLE_H + row * band_h;
  if (iy + band_h > files_height) {
    return;
  }
  p = (volatile u32 *)files_va;
  stride_px = files_stride / 4UL;
  span_w = files_w;
  if (span_w > stride_px) {
    span_w = stride_px;
  }
  if (src == list_sel) {
    c = (u32)SURF_SEL;
  } else {
    c = band_colour(src);
  }
  py = iy;
  while (py < (iy + band_h)) {
    if (py < files_height) {
      fill_dwords(p + py * stride_px, span_w, c);
    }
    py = py + 1;
  }
#if FILES_NO_ICON == 0
  {
    u64 wh = (files_w << 32) | files_height;
    unsigned nlab;
    osxui_icon_fb(files_va, files_stride, wh, (ICON_PAD_X << 32) | iy, ICON_FG);
    nlab = dotlen[src];
    if (nlab > 11U) {
      nlab = 11U;
    }
    if (nlab > 0U) {
      u64 fill = (src & 1UL) ? SURF_BAND1 : SURF_BAND0;
      if (src == list_sel) {
        fill = SURF_SEL;
      }
      osxui_app_rrect(files_h, 6UL, iy + 2UL, files_w - 12UL, band_h - 4UL,
                      10UL, fill);
      (void)osxui_app_label_box(files_h, LAB_PAD_X, iy, 0, band_h, dotted[src],
                                nlab, WM_TEXT_LABEL_PX, WM_TEXT_REGULAR,
                                LAB_FG);
    }
  }
#endif
}

static void files_repaint_sel(u64 old_row) {
  u64 y0;
  u64 y1;
  u64 h;
  if (files_h == 0 || files_height <= TITLE_H) {
    return;
  }
  files_paint_one_row(old_row);
  files_paint_one_row(list_sel);
  y0 = TITLE_H;
  if (old_row >= scroll_off) {
    y0 = TITLE_H + (old_row - scroll_off) * ROW_H;
  }
  y1 = y0;
  if (list_sel >= scroll_off) {
    y1 = TITLE_H + (list_sel - scroll_off) * ROW_H;
  }
  if (y1 < y0) {
    u64 t = y0;
    y0 = y1;
    y1 = t;
  }
  h = (y1 - y0) + ROW_H;
  if ((y0 + h) > files_height) {
    h = files_height - y0;
  }
  commit_files_rect(y0, h);
}

static u64 files_visible(void) {
  u64 body_h = files_height > TITLE_H ? (files_height - TITLE_H) : 0;
  u64 visible = body_h / ROW_H;
  if (visible < 1UL) {
    visible = 1UL;
  }
  return visible;
}

static void files_emit_sel(void) {
  unsigned at = put(0, msg_sel);
  at = puthex(at, list_sel, 2);
  emit(at);
}

static void files_set_sel(u64 row) {
  u64 visible;
  u64 max_off;
  if (row >= files_names) {
    return;
  }
  list_sel = row;
  visible = files_visible();
  max_off = 0;
  if (files_names > visible) {
    max_off = files_names - visible;
  }
  if (list_sel < scroll_off) {
    scroll_off = list_sel;
  }
  if (list_sel >= (scroll_off + visible)) {
    scroll_off = list_sel - visible + 1UL;
    if (scroll_off > max_off) {
      scroll_off = max_off;
    }
  }
  files_emit_sel();
}

static char scan_letter(u64 scan) {
  if (scan == 0x10UL) {
    return 'Q';
  }
  if (scan == 0x11UL) {
    return 'W';
  }
  if (scan == 0x12UL) {
    return 'E';
  }
  if (scan == 0x13UL) {
    return 'R';
  }
  if (scan == 0x14UL) {
    return 'T';
  }
  if (scan == 0x15UL) {
    return 'Y';
  }
  if (scan == 0x16UL) {
    return 'U';
  }
  if (scan == 0x17UL) {
    return 'I';
  }
  if (scan == 0x18UL) {
    return 'O';
  }
  if (scan == 0x19UL) {
    return 'P';
  }
  if (scan == 0x1EUL) {
    return 'A';
  }
  if (scan == 0x1FUL) {
    return 'S';
  }
  if (scan == 0x20UL) {
    return 'D';
  }
  if (scan == 0x21UL) {
    return 'F';
  }
  if (scan == 0x22UL) {
    return 'G';
  }
  if (scan == 0x23UL) {
    return 'H';
  }
  if (scan == 0x24UL) {
    return 'J';
  }
  if (scan == 0x25UL) {
    return 'K';
  }
  if (scan == 0x26UL) {
    return 'L';
  }
  if (scan == 0x2CUL) {
    return 'Z';
  }
  if (scan == 0x2DUL) {
    return 'X';
  }
  if (scan == 0x2EUL) {
    return 'C';
  }
  if (scan == 0x2FUL) {
    return 'V';
  }
  if (scan == 0x30UL) {
    return 'B';
  }
  if (scan == 0x31UL) {
    return 'N';
  }
  if (scan == 0x32UL) {
    return 'M';
  }
  return 0;
}

static void files_type_sel(char letter) {
  u64 i;
  unsigned at;
  if (letter == 0 || files_names == 0) {
    return;
  }
  i = 0;
  while (i < files_names) {
    char c = dotted[i][0];
    if (c >= 'a' && c <= 'z') {
      c = (char)(c - ('a' - 'A'));
    }
    if (c == letter) {
      at = put(0, msg_key);
      line[at++] = letter;
      emit(at);
      files_set_sel(i);
      files_repaint_body();
      return;
    }
    i = i + 1;
  }
}

static u64 files_is_dir(u64 row) {
  if (row >= files_names) {
    return 0;
  }
  if ((recs[row][FAT_ATTR] & FAT_ATTR_DIR) != 0) {
    return 1;
  }
  return 0;
}

static u64 files_plant_skip(u64 row) {
  if (row >= files_names) {
    return 1;
  }
  if (files_is_dir(row) > 0) {
    return 0;
  }
  if (dotlen[row] == 8) {
    if (same_bytes(dotted[row], 8, path_gone, 8) > 0) {
      return 1;
    }
    if (same_bytes(dotted[row], 8, path_miss, 8) > 0) {
      return 1;
    }
  }
  return 0;
}

static void files_show_empty(void) {
  if (in_folder == 0) {
    root_names = files_names;
  }
  in_folder = 1;
  files_err = 0;
  files_names = 0;
  list_sel = 0;
  scroll_off = 0;
  menu_on = 0;
  empty_noted = 0;
  files_repaint();
  wr(msg_empty, sizeof(msg_empty) - 1);
}

static void files_show_error(void) {
  if (in_folder == 0) {
    root_names = files_names;
  }
  in_folder = 1;
  files_err = 1;
  files_names = 0;
  list_sel = 0;
  scroll_off = 0;
  menu_on = 0;
  empty_noted = 0;
  files_repaint();
  wr(msg_error, sizeof(msg_error) - 1);
  wr(msg_err, sizeof(msg_err) - 1);
}

static void files_restore_root(void) {
  files_names = root_names;
  files_err = 0;
  in_folder = 0;
  list_sel = 0;
  scroll_off = 0;
  menu_on = 0;
  empty_noted = 0;
}

static void files_go_back(void) {
  menu_on = 0;
  if (in_folder > 0) {
    can_fwd = 1;
    if (folder_nlen > 0U) {
      unsigned i = 0;
      while (i < folder_nlen) {
        fwd_name[i] = folder_name[i];
        i = i + 1;
      }
      fwd_name[folder_nlen] = 0;
      fwd_nlen = folder_nlen;
    }
    if (files_load_listing(path_root, 5) > 0) {
      files_restore_root();
    } else {
      in_folder = 0;
      files_err = 0;
    }
    wr(msg_back, sizeof(msg_back) - 1);
    files_repaint();
    return;
  }
  list_sel = 0;
  scroll_off = 0;
  wr(msg_back, sizeof(msg_back) - 1);
  files_repaint();
}

static void files_retry(void) {
  u64 fd;
  wr(msg_retry, sizeof(msg_retry) - 1);
  if (files_err > 0) {
    fd = sys2(SYS_OPEN, (u64)path_gone, 8);
    if (fd < ERR_FLOOR) {
      sys1(SYS_CLOSE, fd);
      files_restore_root();
      files_repaint();
      return;
    }
    if (fd == FILE_RET_EMPTY) {
      files_restore_root();
      files_repaint();
      return;
    }
    files_show_error();
    return;
  }
  if (in_folder > 0) {
    files_show_empty();
    return;
  }
  files_repaint();
}

static void do_file_open(u64 row) {
  unsigned at;
  u64 fd;
  if (row >= files_names) {
    files_show_error();
    wr(msg_err, sizeof(msg_err) - 1);
    return;
  }
  if (files_is_dir(row) > 0) {
    char saved[16];
    unsigned slen = dotlen[row];
    unsigned k = 0;
    at = put(0, msg_dir);
    at = put(at, dotted[row]);
    emit(at);
    while (k < slen && k < 12U) {
      saved[k] = dotted[row][k];
      k = k + 1;
    }
    saved[slen] = 0;
    if (files_load_listing(saved, slen) > 0) {
      files_show_error();
      return;
    }
    files_remember_folder(saved, slen);
    in_folder = 1;
    can_fwd = 0;
    files_repaint();
    return;
  }
  fd = sys2(SYS_OPEN, (u64)dotted[row], (u64)dotlen[row]);
  if (fd >= ERR_FLOOR) {
    if (fd == FILE_RET_ISDIR) {
      char saved[16];
      unsigned slen = dotlen[row];
      unsigned k = 0;
      while (k < slen && k < 12U) {
        saved[k] = dotted[row][k];
        k = k + 1;
      }
      saved[slen] = 0;
      if (files_load_listing(saved, slen) > 0) {
        files_show_empty();
        return;
      }
      files_remember_folder(saved, slen);
      in_folder = 1;
      can_fwd = 0;
      files_repaint();
      return;
    }
    files_show_error();
    return;
  }
  sys1(SYS_CLOSE, fd);
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
    u64 slot = (ev >> 8) & 0xFFUL;
    u64 nw = (ev >> 40) & 0xFFFUL;
    u64 nh = (ev >> 52) & 0xFFFUL;
    if (files_slot == 0xFFUL) {
      /* Own attach is 400×280; maximize is wider. SET's tiled 333
       * must not steal this process's slot or body size. */
      if (nw < WIN_W) {
        if (nh <= WIN_H) {
          return;
        }
      }
      files_slot = slot;
      {
        unsigned at = put(0, "FILES SLOT ");
        at = putdec(at, slot);
        emit(at);
      }
    }
    if (slot != files_slot) {
      return;
    }
    if (nw > 0 && nh > 0) {
      unsigned at;
      if (nw > files_cap_w || nh > files_cap_h) {
        u64 stride = nw * 4UL;
        u64 pages = (SURF_OFFSET + stride * nh + 4095UL) / 4096UL;
        u64 grown = sys2(SYS_SHMGROW, files_h, pages);
        if (grown >= WM_RET_FLOOR) {
          at = put(0, "FILES GROW REFUSE ");
          at = putdec(at, pages);
          emit(at);
          return;
        }
        if (grown > 0) {
          files_va = grown + SURF_OFFSET;
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
        wr(msg_phz_grow, sizeof(msg_phz_grow) - 1);
        at = put(0, "FILES GROW ");
        at = putdec(at, pages);
        at = put(at, " W ");
        at = putdec(at, nw);
        at = put(at, " H ");
        at = putdec(at, nh);
        emit(at);
      }
      if (nw != files_w || nh != files_height) {
        u64 shrinking = 0;
        u64 growing = 0;
        /* Dismiss the row menu before a HOLD resize so COMMIT is not
         * deferred behind FILES CFG / menu paint. Escape still works. */
        if (menu_on > 0) {
          menu_on = 0;
          wr(msg_menu_esc, sizeof(msg_menu_esc) - 1);
        }
        files_op = files_op + 1;
        at = put(0, msg_cfg);
        at = puthex(at, files_op, 8);
        line[at++] = '\n';
        emit(at);
        if (nw < files_w || nh < files_height) {
          shrinking = 1;
          at = put(0, "FILES REST ");
          at = putdec(at, nw);
          at = put(at, " ");
          at = putdec(at, nh);
          at = put(at, " OP ");
          at = puthex(at, files_op, 8);
          line[at++] = '\n';
          emit(at);
        } else {
          growing = 1;
        }
        files_w = nw;
        files_height = nh;
        emit_phz_paint('B');
        /* Retained native-max backing already holds the body. Restore
         * only redraws CSD at the new width (buttons move). Maximize
         * after a scroll still needs a full stosl paint so newly
         * visible rows are not stale. First-ever max before PREFILL
         * also takes the full path. */
        if (files_retain_body > 0 && shrinking > 0) {
#if FILES_NO_ICON == 0
          files_paint_csd_only();
#else
          files_note_commit = 1;
          commit_files_rect(0, files_height);
#endif
        } else if (files_retain_body > 0 && growing > 0 && scroll_off == 0) {
#if FILES_NO_ICON == 0
          files_paint_csd_only();
#else
          files_note_commit = 1;
          commit_files_rect(0, files_height);
#endif
        } else {
          files_note_commit = 1;
          files_repaint();
        }
        emit_phz_paint('E');
        (void)growing;
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
    u64 before = scroll_off;
    u64 magnitude = delta;
    u64 dirty = menu_on;
    unsigned at;
    if (visible < 1UL) {
      visible = 1UL;
    }
    if (files_names > visible) {
      max_off = files_names - visible;
    }
    /* REL_WHEEL/PS2: negative is wheel-up (toward list start), positive
     * wheel-down. Coalesced events may carry a magnitude greater than one. */
    if ((delta & 0x80UL) != 0) {
      magnitude = 0x100UL - delta;
      if (magnitude > scroll_off) {
        scroll_off = 0;
      } else {
        scroll_off = scroll_off - magnitude;
      }
    } else {
      if (magnitude > (max_off - scroll_off)) {
        scroll_off = max_off;
      } else {
        scroll_off = scroll_off + magnitude;
      }
    }
    /* Keep an open context menu. Residual virtio wheel after a
     * harness scroll used to clear menu_on so Open at (364,196)
     * selected row 4 instead (FILES SEL 04). */
    at = put(0, msg_scroll);
    at = puthex(at, scroll_off, 2);
    emit(at);
    if (scroll_off != before) {
      files_repaint_body();
    } else {
      if (dirty > 0) {
        files_repaint_body();
      }
    }
    return;
  }
  if (typ == WMEVENT_TYPE_CONTEXT) {
    menu_row = row_at_y(ry, files_names);
    menu_x = rx;
    menu_y = ry;
    if (menu_x + FILE_MENU_W > files_w) {
      menu_x = files_w - FILE_MENU_W;
    }
    if (menu_y + FILE_MENU_H > files_height) {
      menu_y = files_height - FILE_MENU_H;
    }
    menu_sel = 0;
    menu_on = 1;
    wr(msg_menu, sizeof(msg_menu) - 1);
    files_repaint();
    return;
  }
  if (typ == WMEVENT_TYPE_PRESS) {
    if (menu_on == 0) {
      u64 row = row_at_y(ry, files_names);
      if (row < files_names) {
        u64 prev = list_sel;
        u64 before_off = scroll_off;
        files_set_sel(row);
        if (scroll_off != before_off) {
          files_repaint_body();
        } else {
          files_repaint_sel(prev);
        }
      }
      return;
    }
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
        u64 row = 0;
        if (ry >= (my + OSXUI_MENU_PAD)) {
          row = (ry - my - OSXUI_MENU_PAD) / OSXUI_MENU_ROW_H;
        }
        menu_on = 0;
        menu_sel = row;
        files_menu_run(row);
        files_repaint();
        return;
      }
      menu_on = 0;
      files_repaint();
    }
    return;
  }
  if (typ == WMEVENT_TYPE_LEAVE) {
    /* Keep an open context menu. Focus/hover leave used to clear it
     * before the Open row click arrived (SEL 04 at the same coords). */
  }
}

static void files_on_key(u64 ev) {
  u64 scan;
  unsigned at;
  if ((ev & KBD_BIT_BREAK) != 0) {
    if ((ev & 0xFFUL) == SCAN_LCTRL) {
      files_ctrl = 0;
    }
    return;
  }
  scan = ev & 0xFFUL;
  if (menu_on > 0) {
    if (scan == SCAN_ESC) {
      menu_on = 0;
      wr(msg_menu_esc, sizeof(msg_menu_esc) - 1);
      files_repaint_body();
      return;
    }
    if ((ev & KBD_BIT_EXT) != 0) {
      if (scan == SCAN_UP || scan == SCAN_DOWN) {
        if (scan == SCAN_DOWN) {
          menu_sel = menu_sel + 1UL;
          if (menu_sel >= FILE_MENU_ROWS) {
            menu_sel = 0;
          }
        } else {
          if (menu_sel < 1UL) {
            menu_sel = FILE_MENU_ROWS - 1UL;
          } else {
            menu_sel = menu_sel - 1UL;
          }
        }
        at = put(0, msg_menu_sel);
        at = puthex(at, menu_sel, 1);
        emit(at);
        files_repaint_body();
      }
      return;
    }
    if (scan == SCAN_ENTER) {
      u64 selected = menu_sel;
      menu_on = 0;
      files_menu_run(selected);
      files_repaint_body();
    }
    return;
  }
  if (scan == SCAN_ESC) {
    if (edit_on > 0) {
      edit_on = 0;
      return;
    }
    files_go_back();
    return;
  }
  if (scan == SCAN_BKSP) {
    if (edit_on < 1) {
      files_go_back();
      return;
    }
  }
  if ((ev & KBD_BIT_EXT) != 0) {
    if (scan == SCAN_UP) {
      if (list_sel > 0) {
        files_set_sel(list_sel - 1UL);
        files_repaint_body();
      }
    }
    if (scan == SCAN_DOWN) {
      if ((list_sel + 1UL) < files_names) {
        files_set_sel(list_sel + 1UL);
        files_repaint_body();
      }
    }
    if (scan == SCAN_LEFT) {
      files_go_back();
    }
    if (scan == SCAN_RIGHT) {
      files_go_fwd();
    }
    return;
  }
  if (scan == SCAN_LCTRL) {
    files_ctrl = 1;
    return;
  }
  if (files_ctrl > 0) {
    files_ctrl = 0;
    if (scan == 0x2EUL) {
      if (list_sel < files_names) {
        files_clip_offer(dotted[list_sel], (u64)dotlen[list_sel]);
        at = put(0, msg_copy);
        at = put(at, dotted[list_sel]);
        emit(at);
      }
      return;
    }
    if (scan == 0x2DUL) {
      cut_row = list_sel;
      if (list_sel < files_names) {
        files_clip_offer(dotted[list_sel], (u64)dotlen[list_sel]);
      }
      return;
    }
    if (scan == 0x2FUL) {
      files_do_paste();
      files_repaint_body();
      return;
    }
    if (scan == 0x31UL) {
      files_do_new();
      files_repaint_body();
      return;
    }
  }
  if (scan == SCAN_F5) {
    files_do_refresh();
    return;
  }
  if (scan == SCAN_ENTER) {
    do_file_open(list_sel);
    files_repaint_body();
    return;
  }
  if (edit_on > 0) {
    char letter = scan_letter(scan);
    if (scan == SCAN_BKSP) {
      if (edit_caret > 0) {
        edit_caret = edit_caret - 1;
        edit_n = edit_caret;
        edit_buf[edit_n] = 0;
      }
      return;
    }
    if (letter != 0 && edit_n < EDIT_MAX) {
      edit_buf[edit_n] = letter;
      edit_n = edit_n + 1;
      edit_caret = edit_n;
      edit_buf[edit_n] = 0;
      at = put(0, msg_field);
      at = put(at, edit_buf);
      emit(at);
      return;
    }
  }
  files_type_sel(scan_letter(scan));
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
  /* Grow on maximize only. Eager native-max (829 pages) starved later
   * shmcreate when slots were 4; with 8 slots the cost is still a
   * per-client hog, so attach stays at the window's first size. */

  files_h = h;
  files_va = va;
  clip_h = h;
  files_names = names;
  files_swatch = swatch;
  files_seq = 1;
  files_op = 0;
  files_retain_body = 0;
  files_pub_w = 0;
  files_pub_h = 0;
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
  files_pub_w = WIN_W;
  files_pub_h = WIN_H;
  /* Let DESK restripe before the hidden 1274×666 paint. Syscalls are
   * not preemptable; without this yield the dock cannot pop SET. */
  sys1(SYS_YIELD, 0);
  /* Hidden native-max body, off the click path. Restore/max then
   * reuse this backing instead of a cream fill that blocked UART. */
  files_prefill_cap();
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
    files_err = 1;
    list_sel = CAT_MAX;
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

  files_names = names;
  copy_i = CAT_MAX;
  move_i = CAT_MAX;
  for (i = 0; i < (unsigned)names; i++) {
    if (is_self(recs[i]) < 1) {
      if (files_plant_skip(i) < 1) {
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
  }
  do_copy(copy_i, dest_copy);
  if (copy_i < CAT_MAX) {
    files_writable = 1;
  }
  do_move(move_i, dest_move);
  if (files_writable < 1) {
    files_probe_writable();
  }
  cut_row = CAT_MAX;
  files_edit_from_sel();

  miss_ghost();

  swatch = 0;
  if (plant_n >= 3) {
    swatch = ((u32)plant[0] << 16) | ((u32)plant[1] << 8) | (u32)plant[2];
    swatch = swatch & 0x00FFFFFFUL;
    if (swatch == 0) {
      swatch = 0x00010101UL;
    }
  }
  if (names > 0) {
    list_sel = 0;
  } else {
    list_sel = CAT_MAX;
  }
  try_strip(names, swatch);
  if (list_sel < files_names) {
    files_clip_offer(dotted[list_sel], (u64)dotlen[list_sel]);
  }
  wr(msg_ready, sizeof(msg_ready) - 1);

  for (;;) {
    u64 ev;
    u64 key;
    u64 got;
    got = 0;
    ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    while (ev != 0) {
      files_on_event(ev);
      got = 1;
      ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    }
    key = sys1(SYS_KBDEVENT, KBD_OP_POP);
    while (key != KBD_EMPTY) {
      files_on_key(key);
      got = 1;
      key = sys1(SYS_KBDEVENT, KBD_OP_POP);
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
