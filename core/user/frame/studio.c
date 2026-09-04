/* core/user/frame/studio.c
 *
 * STUDIO1 listing + STUDIO2 launch + STUDIO2b persist. A FRAME surface
 * that opens a planted catalog (APPS.TXT), writes the 8.3 names to COM1,
 * probes which of those names open on the volume, then starts the
 * selected name as a resident process (syscall 26). A derived digit key
 * or a click on a hit strip is the select. The selected row is
 * destroy-on-save persisted as four bytes in SEL.DAT (ADR-0119). A
 * later Studio start reads that file and exhibits the derived name.
 * The idle-line sibling is hidden `go NAME` (ADR-0099). Not an IDE,
 * not a builder, not opendir, not live-edit, not a guest Dart SDK.
 *
 * `proc spawn STUDIO.ELF` so the prompt returns (ADR-0053). Numbers
 * come from osframe.h. This file must not contain a catalog name as a
 * literal — the harness's truncated volume would still print it.
 */

#include "osframe.h"
#include "osxui_app.h"

typedef unsigned long u64;
typedef unsigned int u32;

#define CHUNK 512UL
#define NAME_MAX 15U
#define CAT_MAX 8U
#define WIN_W 320UL
#define WIN_H 220UL
#define SURF_X 48UL
#define SURF_Y 56UL
#define SURF_FILL 0x00203040UL
#define SURF_BAND0 0x00405060UL
#define SURF_BAND1 0x00304050UL
#define WIN_PAGES 69UL
#define YIELD_SPIN 8000UL
#define KEY_DIGIT1 0x02UL
#define SPAWN_FLOOR 0xFFFFFFFFFFFFFF00UL
#define FILE_ERR_FLOOR 0xFFFFFFFFFFFFFF00UL
#define O_WRITE 1UL
#define SEL_BYTES 4UL
#define SCAN_LCTRL 0x1DUL
#define CLIP_VA 0x10200000UL
#define EDIT_MAX 64UL
#define TEXT_MAX 2048UL
#define NOTE_NAME "NOTE.TXT"
#define NOTE_N 8UL
#define EDIT_TOP 112UL
#define EDIT_LINE_H 16UL
#define SCAN_ENTER 0x1CUL
#define SCAN_BKSP 0x0EUL
#define SCAN_LEFT 0x4BUL
#define SCAN_RIGHT 0x4DUL
#define SCAN_UP 0x48UL
#define SCAN_DOWN 0x50UL

static unsigned char buf[512];
static unsigned char acc[16];
static unsigned char catalog[CAT_MAX][16];
static unsigned catlen[CAT_MAX];
static char line[80];
static u64 desc[8] __attribute__((aligned(64))) = {0, 0, 0, 0, 0, 0, 0, 0};
static volatile u64 marker = 0x0057010100570101UL;
static u64 launched = 0;
static u32 sel_word = 0;

static const char msg_open[] = "STUDIO1 OPEN REFUSED ";
static const char msg_read[] = "STUDIO1 READ REFUSED ";
static const char msg_name[] = "STUDIO1 NAME ";
static const char msg_count[] = "STUDIO1 NAMES ";
static const char msg_list[] = "STUDIO1 LIST";
static const char msg_strip[] = "STUDIO1 STRIP";
static const char msg_ready[] = "STUDIO2 READY";
static const char msg_have[] = "STUDIO2 HAVE ";
static const char msg_launch[] = "STUDIO2 LAUNCH ";
static const char msg_ok[] = "STUDIO2 OK ";
static const char msg_refused[] = "STUDIO2 REFUSED ";
static const char msg_sel[] = "STUDIO2 SEL ";
static const char msg_save[] = "STUDIO2 SAVE";
static const char path_apps[] = "APPS.TXT";
static const char path_sel[] = "SEL.DAT";
static const char msg_csd[] = "STUDIO CSD";
static const char msg_view[] = "STUDIO VIEW ";
static const char msg_edit[] = "STUDIO EDIT ";
static const char cap_studio[] = "STUDIO";
static u64 view_row = 0;
static u64 view_off = 0;
static u64 clip_h;
static u64 studio_ctrl;
static char edit_buf[EDIT_MAX + 1];
static u64 edit_n;
static u64 edit_caret;
static u64 edit_on;
static const char msg_copy[] = "STUDIO COPY ";
static const char msg_paste[] = "STUDIO PASTE ";
static const char msg_openf[] = "STUDIO OPEN ";
static const char msg_savef[] = "STUDIO SAVE FILE ";
static const char msg_dirty[] = "STUDIO DIRTY";
static const char msg_scroll[] = "STUDIO SCROLL ";
static const char msg_errf[] = "STUDIO ERR";
static char text_buf[TEXT_MAX + 1];
static u64 text_n;
static u64 text_caret;
static u64 text_sel;
static u64 text_off;
static u64 text_dirty;
static u64 text_err;
static char file_name[16];
static unsigned file_nlen;
static u64 studio_h;
static u64 studio_va;
static u64 studio_names;

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

static unsigned put(unsigned at, const char *s) {
  while (*s) {
    line[at++] = *s++;
  }
  return at;
}

static unsigned puthex(unsigned at, u64 v, unsigned digits) {
  static const char D[] = "0123456789abcdef";
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

static void emit_name(const unsigned char *p, unsigned n) {
  unsigned i;
  unsigned at = put(0, msg_name);
  for (i = 0; i < n; i++) {
    line[at++] = (char)p[i];
  }
  emit(at);
}

static void store_name(const unsigned char *p, unsigned n, u64 slot) {
  unsigned i;
  if (slot >= CAT_MAX) {
    return;
  }
  if (n > NAME_MAX) {
    n = NAME_MAX;
  }
  for (i = 0; i < n; i++) {
    catalog[slot][i] = p[i];
  }
  catalog[slot][n] = 0;
  catlen[slot] = n;
}

static u32 band_colour(u64 i) {
  if ((i & 1UL) == 0) {
    return (u32)SURF_BAND0;
  }
  return (u32)SURF_BAND1;
}

static void studio_clip_offer(void) {
  volatile unsigned char *p;
  u64 i;
  u64 r;
  unsigned n;
  u64 take;
  if (clip_h == 0) {
    return;
  }
  take = text_n;
  if (take < 1) {
    take = edit_n;
  }
  if (take < 1) {
    return;
  }
  if (take > EDIT_MAX) {
    take = EDIT_MAX;
  }
  p = (volatile unsigned char *)CLIP_VA;
  i = 0;
  while (i < take) {
    if (text_n > 0) {
      p[i] = (unsigned char)text_buf[i];
    } else {
      p[i] = (unsigned char)edit_buf[i];
    }
    i = i + 1;
  }
  r = osxui_app_clip(WM_OP_OFFER, clip_h, take);
  n = put(0, msg_copy);
  if (r >= FILE_ERR_FLOOR) {
    n = put(n, "ERR");
  } else {
    n = puthex(n, take, 2);
  }
  emit(n);
}

static void studio_clip_take(void) {
  u64 r;
  volatile unsigned char *p;
  u64 i;
  unsigned n;
  if (clip_h == 0) {
    return;
  }
  r = osxui_app_clip(WM_OP_TAKE, clip_h, 0);
  if (r >= FILE_ERR_FLOOR) {
    return;
  }
  if (r > EDIT_MAX) {
    r = EDIT_MAX;
  }
  p = (volatile unsigned char *)CLIP_VA;
  i = 0;
  while (i < r) {
    edit_buf[i] = (char)p[i];
    if (i < TEXT_MAX) {
      text_buf[i] = (char)p[i];
    }
    i = i + 1;
  }
  edit_n = r;
  edit_caret = r;
  edit_buf[r] = 0;
  text_n = r;
  text_caret = r;
  text_buf[r] = 0;
  text_dirty = 1;
  wr(msg_dirty, sizeof(msg_dirty) - 1);
  n = put(0, msg_paste);
  i = 0;
  while (i < r && n < 70) {
    line[n++] = edit_buf[i];
    i = i + 1;
  }
  emit(n);
}

static void paint_strip(u64 va, u64 names);

static u64 studio_line_start(u64 line) {
  u64 i = 0;
  u64 n = 0;
  while (i < text_n) {
    if (n == line) {
      return i;
    }
    if (text_buf[i] == '\n') {
      n = n + 1;
    }
    i = i + 1;
  }
  if (n == line) {
    return text_n;
  }
  return text_n;
}

static u64 studio_line_count(void) {
  u64 i = 0;
  u64 n = 1;
  while (i < text_n) {
    if (text_buf[i] == '\n') {
      n = n + 1;
    }
    i = i + 1;
  }
  return n;
}

static void studio_mark_dirty(void) {
  if (text_dirty < 1) {
    text_dirty = 1;
    wr(msg_dirty, sizeof(msg_dirty) - 1);
  }
}

static void studio_open_named(const char *name, unsigned nlen) {
  u64 fd;
  u64 got;
  u64 total;
  unsigned n;
  unsigned i;
  if (nlen < 1U) {
    return;
  }
  fd = sys2(SYS_OPEN, (u64)name, (u64)nlen);
  n = put(0, msg_openf);
  i = 0;
  while (i < nlen && n < 70) {
    line[n++] = name[i];
    i = i + 1;
  }
  if (fd >= FILE_ERR_FLOOR) {
    text_err = 1;
    wr(msg_errf, sizeof(msg_errf) - 1);
    emit(n);
    return;
  }
  total = 0;
  for (;;) {
    got = sys3(SYS_READ, fd, (u64)buf, 32);
    if (got >= FILE_ERR_FLOOR) {
      sys2(SYS_CLOSE, fd, 0);
      text_err = 1;
      wr(msg_errf, sizeof(msg_errf) - 1);
      emit(n);
      return;
    }
    if (got == 0) {
      break;
    }
    i = 0;
    while (i < (unsigned)got && total < TEXT_MAX) {
      text_buf[total] = (char)buf[i];
      total = total + 1;
      i = i + 1;
    }
    if (total >= TEXT_MAX) {
      break;
    }
  }
  sys2(SYS_CLOSE, fd, 0);
  text_n = total;
  text_caret = total;
  text_sel = total;
  text_off = 0;
  text_dirty = 0;
  text_err = 0;
  text_buf[total] = 0;
  if (total < EDIT_MAX) {
    i = 0;
    while (i < (unsigned)total) {
      edit_buf[i] = text_buf[i];
      i = i + 1;
    }
    edit_n = total;
    edit_caret = total;
    edit_buf[total] = 0;
  }
  i = 0;
  while (i < nlen && i < 12U) {
    file_name[i] = name[i];
    i = i + 1;
  }
  file_name[nlen] = 0;
  file_nlen = nlen;
  emit(n);
}

static void studio_save_named(const char *name, unsigned nlen) {
  u64 fd;
  u64 w;
  u64 off;
  unsigned n;
  unsigned i;
  if (nlen < 1U) {
    return;
  }
  fd = sys3(SYS_OPEN, (u64)name, (u64)nlen, O_WRITE);
  n = put(0, msg_savef);
  i = 0;
  while (i < nlen && n < 70) {
    line[n++] = name[i];
    i = i + 1;
  }
  if (fd >= FILE_ERR_FLOOR) {
    text_err = 1;
    wr(msg_errf, sizeof(msg_errf) - 1);
    emit(n);
    return;
  }
  off = 0;
  while (off < text_n) {
    u64 chunk = text_n - off;
    if (chunk > 32) {
      chunk = 32;
    }
    w = sys3(SYS_FDWRITE, fd, (u64)&text_buf[off], chunk);
    if (w >= FILE_ERR_FLOOR) {
      sys2(SYS_CLOSE, fd, 0);
      text_err = 1;
      wr(msg_errf, sizeof(msg_errf) - 1);
      emit(n);
      return;
    }
    off = off + w;
    if (w < chunk) {
      break;
    }
  }
  sys2(SYS_CLOSE, fd, 0);
  text_dirty = 0;
  text_err = 0;
  emit(n);
  wr(msg_save, sizeof(msg_save) - 1);
}

static void paint_edit(u64 h) {
  u64 body = WIN_H - EDIT_TOP;
  u64 vis;
  u64 line_i;
  u64 y;
  osxui_app_rrect(h, 8UL, EDIT_TOP, WIN_W - 16UL, body - 8UL, 6UL, 0x00F4F6FAUL);
  vis = (body - 12UL) / EDIT_LINE_H;
  if (vis < 1UL) {
    vis = 1UL;
  }
  line_i = 0;
  while (line_i < vis) {
    u64 src = text_off + line_i;
    u64 a = studio_line_start(src);
    u64 b = studio_line_start(src + 1);
    unsigned nlab;
    y = EDIT_TOP + 4UL + line_i * EDIT_LINE_H;
    if (a < text_n && text_buf[a] == '\n') {
      a = a + 1;
    }
    if (b > a && b <= text_n && text_buf[b - 1] == '\n') {
      b = b - 1;
    }
    if (b < a) {
      b = a;
    }
    nlab = (unsigned)(b - a);
    if (nlab > 28U) {
      nlab = 28U;
    }
    if (nlab > 0U) {
      osxui_app_text(h, 14UL, y, &text_buf[a], nlab, WM_TEXT_LABEL_PX,
                     WM_TEXT_REGULAR, 0x00202830UL);
    } else if (src == 0 && text_n == 0) {
      osxui_app_text(h, 14UL, y, "type / paste / save", 19, WM_TEXT_LABEL_PX,
                     WM_TEXT_REGULAR, 0x00506070UL);
    }
    line_i = line_i + 1;
  }
  if (text_dirty > 0) {
    osxui_app_rrect(h, WIN_W - 18UL, EDIT_TOP + 4UL, 6UL, 6UL, 3UL, 0x00C04040UL);
  }
  (void)edit_n;
}

static void studio_repaint(u64 names) {
  if (studio_h == 0) {
    return;
  }
  paint_strip(studio_va, names);
  osxui_app_csd(studio_h, WIN_W, cap_studio, 6UL);
  paint_edit(studio_h);
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = studio_h;
  desc[WM_DESC_X] = 0;
  desc[WM_DESC_Y] = 0;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 2;
  desc[WM_DESC_OFFSET] = 0;
  (void)sys1(SYS_WMSURFACE, (u64)&desc[0]);
}

static void paint_strip(u64 va, u64 names) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  u64 body = WIN_H - OSXUI_CSD_H;
  u64 band_h = body;
  if (names > 1) {
    band_h = body / names;
  }
  if (band_h == 0) {
    band_h = 1;
  }
  while (py < WIN_H) {
    u64 px = 0;
    u32 c = (u32)SURF_FILL;
    if (py >= OSXUI_CSD_H) {
      if (names > 0) {
        u64 row = (py - OSXUI_CSD_H) / band_h;
        if (row >= names) {
          row = names - 1;
        }
        if (row == view_row) {
          c = 0x00507080UL;
        } else {
          c = band_colour(row);
        }
      }
    }
    while (px < WIN_W) {
      p[py * WIN_W + px] = c;
      px = px + 1;
    }
    py = py + 1;
  }
}

static void view_open(u64 row, u64 names) {
  u64 fd;
  u64 got;
  unsigned n;
  unsigned i;

  if (row >= names) {
    return;
  }
  view_row = row;
  fd = sys2(SYS_OPEN, (u64)&catalog[row][0], (u64)catlen[row]);
  n = put(0, msg_view);
  for (i = 0; i < catlen[row]; i++) {
    line[n++] = (char)catalog[row][i];
  }
  if (fd >= FILE_ERR_FLOOR) {
    emit(n);
    return;
  }
  got = sys3(SYS_READ, fd, (u64)buf, 32);
  sys2(SYS_CLOSE, fd, 0);
  n = put(n, " ");
  n = puthex(n, got & 0xFFFFFFFFUL, 4);
  emit(n);
}

static void try_strip(u64 names) {
  u64 h;
  u64 va;
  u64 frames;

  clip_h = sys1(SYS_SHMCREATE, 1);
  if (clip_h >= WM_RET_FLOOR) {
    clip_h = 0;
  }
  h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (h >= WM_RET_FLOOR) {
    return;
  }

  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = h;
  desc[WM_DESC_X] = SURF_X;
  desc[WM_DESC_Y] = SURF_Y;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_RET_FLOOR) {
    return;
  }

  paint_strip(va, names);
  osxui_app_csd(h, WIN_W, cap_studio, 6UL);
  paint_edit(h);
  wr(msg_csd, sizeof(msg_csd) - 1);
  studio_h = h;
  studio_va = va;
  studio_names = names;
  edit_on = 1;
  edit_n = 0;
  edit_caret = 0;
  edit_buf[0] = 0;
  text_n = 0;
  text_caret = 0;
  text_off = 0;
  text_dirty = 0;
  text_err = 0;
  text_buf[0] = 0;
  file_name[0] = 'N';
  file_name[1] = 'O';
  file_name[2] = 'T';
  file_name[3] = 'E';
  file_name[4] = '.';
  file_name[5] = 'T';
  file_name[6] = 'X';
  file_name[7] = 'T';
  file_name[8] = 0;
  file_nlen = NOTE_N;

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
}

static void emit_sel_name(u64 row) {
  unsigned n;
  unsigned i;

  n = put(0, msg_sel);
  for (i = 0; i < catlen[row]; i++) {
    line[n++] = (char)catalog[row][i];
  }
  emit(n);
}

static void exhibit_sel(u64 names) {
  u64 fd;
  u64 got;
  u64 row;

  fd = sys2(SYS_OPEN, (u64)path_sel, 7);
  if (fd >= FILE_ERR_FLOOR) {
    return;
  }
  got = sys3(SYS_READ, fd, (u64)buf, SEL_BYTES);
  sys2(SYS_CLOSE, fd, 0);
  if (got != SEL_BYTES) {
    return;
  }
  row = (u64)buf[0] | ((u64)buf[1] << 8) | ((u64)buf[2] << 16) |
        ((u64)buf[3] << 24);
  if (row >= names) {
    return;
  }
  if (catlen[row] < 1) {
    return;
  }
  emit_sel_name(row);
}

static void persist_row(u64 row) {
  u64 fd;
  u64 n;

  sel_word = (u32)row;
  fd = sys3(SYS_OPEN, (u64)path_sel, 7, O_WRITE);
  if (fd >= FILE_ERR_FLOOR) {
    return;
  }
  n = sys3(SYS_FDWRITE, fd, (u64)&sel_word, SEL_BYTES);
  sys2(SYS_CLOSE, fd, 0);
  if (n == SEL_BYTES) {
    wr(msg_save, sizeof(msg_save) - 1);
  }
}

static void exhibit_have(u64 names) {
  u64 i;
  u64 fd;
  unsigned n;
  unsigned j;

  for (i = 0; i < names; i++) {
    if (catlen[i] < 1) {
      continue;
    }
    fd = sys2(SYS_OPEN, (u64)&catalog[i][0], (u64)catlen[i]);
    if (fd >= SPAWN_FLOOR) {
      continue;
    }
    sys2(SYS_CLOSE, fd, 0);
    n = put(0, msg_have);
    for (j = 0; j < catlen[i]; j++) {
      line[n++] = (char)catalog[i][j];
    }
    emit(n);
  }
}

static void launch_row(u64 row, u64 names) {
  unsigned n;
  u64 st;
  unsigned i;

  if (launched > 0) {
    return;
  }
  if (row >= names) {
    return;
  }
  n = catlen[row];
  if (n < 1) {
    return;
  }

  n = put(0, msg_launch);
  for (i = 0; i < catlen[row]; i++) {
    line[n++] = (char)catalog[row][i];
  }
  emit(n);

  persist_row(row);

  st = sys2(SYS_SPAWN, (u64)&catalog[row][0], (u64)catlen[row]);
  if (st >= SPAWN_FLOOR) {
    n = put(0, msg_refused);
    n = puthex(n, st & 0xFFFFFFFFUL, 8);
    emit(n);
    return;
  }
  launched = 1;
  n = put(0, msg_ok);
  n = puthex(n, st, 2);
  emit(n);
}

static void pump(u64 names) {
  u64 ev;
  u64 sc;
  u64 row;
  u64 y;
  u64 band_h;
  u64 body;
  unsigned n;

  ev = sys1(SYS_KBDEVENT, KBD_OP_POP);
  if (ev != KBD_EMPTY) {
    if ((ev & KBD_BIT_BREAK) != 0) {
      if ((ev & 0xFFUL) == SCAN_LCTRL) {
        studio_ctrl = 0;
      }
    } else {
      sc = ev & 0xFFUL;
      if (sc == SCAN_LCTRL) {
        studio_ctrl = 1;
      } else if (studio_ctrl > 0) {
        studio_ctrl = 0;
        if (sc == 0x2EUL) {
          studio_clip_offer();
        } else if (sc == 0x2FUL) {
          studio_clip_take();
          studio_repaint(names);
        } else if (sc == 0x2DUL) {
          edit_n = 0;
          edit_caret = 0;
          edit_buf[0] = 0;
          text_n = 0;
          text_caret = 0;
          text_buf[0] = 0;
          studio_mark_dirty();
          studio_clip_offer();
          studio_repaint(names);
        } else if (sc == 0x1FUL) {
          if (file_nlen > 0U) {
            studio_save_named(file_name, file_nlen);
          } else {
            studio_save_named(NOTE_NAME, NOTE_N);
          }
          studio_repaint(names);
        } else if (sc == 0x18UL) {
          if (view_row < names && catlen[view_row] > 0) {
            studio_open_named((const char *)&catalog[view_row][0],
                              catlen[view_row]);
          } else {
            studio_open_named(NOTE_NAME, NOTE_N);
          }
          studio_repaint(names);
        }
      } else if (sc == SCAN_UP) {
        if (text_n > 0) {
          if (text_off > 0) {
            text_off = text_off - 1;
            n = put(0, msg_scroll);
            n = puthex(n, text_off, 2);
            emit(n);
            studio_repaint(names);
          } else if (view_row > 0) {
            view_open(view_row - 1, names);
          }
        } else if (view_row > 0) {
          view_open(view_row - 1, names);
        }
      } else if (sc == SCAN_DOWN) {
        if (text_n > 0) {
          if ((text_off + 1) < studio_line_count()) {
            text_off = text_off + 1;
            n = put(0, msg_scroll);
            n = puthex(n, text_off, 2);
            emit(n);
            studio_repaint(names);
          } else if ((view_row + 1) < names) {
            view_open(view_row + 1, names);
          }
        } else if ((view_row + 1) < names) {
          view_open(view_row + 1, names);
        }
      } else if (sc == SCAN_ENTER) {
        if (edit_on > 0 && text_n < TEXT_MAX) {
          text_buf[text_n] = '\n';
          text_n = text_n + 1;
          text_caret = text_n;
          text_buf[text_n] = 0;
          studio_mark_dirty();
          studio_repaint(names);
        } else {
          launch_row(view_row, names);
        }
      } else if (sc == 0x12UL) {
        persist_row(view_row);
        edit_on = 1;
        n = put(0, msg_edit);
        n = puthex(n, view_row, 2);
        emit(n);
      } else if (edit_on > 0) {
        if (sc == SCAN_BKSP) {
          if (text_caret > 0) {
            text_caret = text_caret - 1;
            text_n = text_caret;
            text_buf[text_n] = 0;
            studio_mark_dirty();
          }
          if (edit_caret > 0) {
            edit_caret = edit_caret - 1;
            edit_n = edit_caret;
            edit_buf[edit_n] = 0;
          }
          studio_repaint(names);
        } else if ((ev & KBD_BIT_EXT) == 0) {
          if (sc >= KEY_DIGIT1 && sc <= 0x0BUL && edit_n < 1) {
            row = sc - KEY_DIGIT1;
            if (row < names) {
              view_open(row, names);
              launch_row(row, names);
            }
          } else if (edit_n < EDIT_MAX) {
            char ch = 0;
            if (sc == 0x39UL) {
              ch = ' ';
            } else if (sc == 0x1EUL) {
              ch = 'a';
            } else if (sc == 0x30UL) {
              ch = 'b';
            } else if (sc == 0x2EUL) {
              ch = 'c';
            } else if (sc == 0x20UL) {
              ch = 'd';
            } else if (sc == 0x12UL) {
              ch = 'e';
            } else if (sc == 0x21UL) {
              ch = 'f';
            } else if (sc == 0x2FUL) {
              ch = 'v';
            } else if (sc == 0x17UL) {
              ch = 'i';
            } else if (sc == 0x18UL) {
              ch = 'o';
            } else if (sc == 0x19UL) {
              ch = 'p';
            } else if (sc == 0x1FUL) {
              ch = 's';
            } else if (sc == 0x14UL) {
              ch = 't';
            }
            if (ch != 0) {
              edit_buf[edit_n] = ch;
              edit_n = edit_n + 1;
              edit_caret = edit_n;
              edit_buf[edit_n] = 0;
              if (text_n < TEXT_MAX) {
                text_buf[text_n] = ch;
                text_n = text_n + 1;
                text_caret = text_n;
                text_buf[text_n] = 0;
              }
              studio_mark_dirty();
              n = put(0, msg_edit);
              n = puthex(n, edit_n, 2);
              emit(n);
              studio_repaint(names);
            }
          }
        }
      } else if ((ev & KBD_BIT_EXT) == 0) {
        if (sc >= KEY_DIGIT1) {
          row = sc - KEY_DIGIT1;
          if (row < names) {
            view_open(row, names);
            launch_row(row, names);
          }
        }
      }
    }
  }

  ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
  if (ev != WMEVENT_EMPTY) {
    if ((ev & 0xFFUL) == WMEVENT_TYPE_PRESS) {
      y = (ev >> 32) & 0xFFFFUL;
      body = WIN_H - OSXUI_CSD_H;
      band_h = body;
      if (names > 1) {
        band_h = body / names;
      }
      if (band_h == 0) {
        band_h = 1;
      }
      if (y >= OSXUI_CSD_H) {
        row = (y - OSXUI_CSD_H) / band_h;
        view_open(row, names);
      }
    } else if ((ev & 0xFFUL) == WMEVENT_TYPE_SCROLL) {
      u64 delta = (ev >> 48) & 0xFFUL;
      if ((delta & 0x80UL) != 0) {
        if (text_off > 0) {
          text_off = text_off - 1;
        }
      } else {
        if ((text_off + 1) < studio_line_count()) {
          text_off = text_off + 1;
        }
      }
      view_off = text_off;
      n = put(0, msg_scroll);
      n = puthex(n, text_off, 2);
      emit(n);
      studio_repaint(names);
    }
  }
}

void _start(void) {
  u64 fd;
  u64 got;
  u64 total;
  u64 names;
  unsigned accn;
  unsigned i;
  unsigned n;

  if (marker != 0x0057010100570101UL) {
    die(0x57000006UL);
  }

  fd = sys2(SYS_OPEN, (u64)path_apps, 8);
  if (fd >= 0xFFFFFFFFFFFFFF00UL) {
    n = put(0, msg_open);
    n = puthex(n, fd & 0xFFFFFFFFUL, 8);
    emit(n);
    die(0x57000001UL);
  }

  total = 0;
  names = 0;
  accn = 0;
  for (;;) {
    got = sys3(SYS_READ, fd, (u64)buf, CHUNK);
    if (got >= 0xFFFFFFFFFFFFFF00UL) {
      n = put(0, msg_read);
      n = puthex(n, got & 0xFFFFFFFFUL, 8);
      emit(n);
      die(0x57000002UL);
    }
    if (got == 0) {
      break;
    }
    for (i = 0; i < (unsigned)got; i++) {
      unsigned char c = buf[i];
      if (c == (unsigned char)'\n' || c == (unsigned char)'\r') {
        if (accn > 0) {
          emit_name(acc, accn);
          store_name(acc, accn, names);
          names = names + 1;
          accn = 0;
        }
      } else if (accn < NAME_MAX) {
        acc[accn] = c;
        accn = accn + 1;
      }
    }
    total = total + got;
  }
  if (accn > 0) {
    emit_name(acc, accn);
    store_name(acc, accn, names);
    names = names + 1;
  }
  sys2(SYS_CLOSE, fd, 0);

  n = put(0, msg_count);
  n = putdec(n, names);
  n = put(n, " LEN ");
  n = puthex(n, total, 8);
  emit(n);

  exhibit_have(names);
  exhibit_sel(names);
  try_strip(names);
  studio_open_named(NOTE_NAME, NOTE_N);
  if (names > 0) {
    view_open(0, names);
  }
  wr(msg_list, sizeof(msg_list) - 1);
  wr(msg_ready, sizeof(msg_ready) - 1);

  for (;;) {
    pump(names);
    {
      volatile u64 spin = 0;
      while (spin < YIELD_SPIN) {
        spin = spin + 1;
      }
    }
    sys1(SYS_YIELD, 0);
  }
}
