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
#define CAT_MAX 4U
#define WIN_W 200UL
#define WIN_H 140UL
#define SURF_X 48UL
#define SURF_Y 56UL
#define SURF_FILL 0x00203040UL
#define SURF_BAND0 0x00405060UL
#define SURF_BAND1 0x00304050UL
#define WIN_PAGES 32UL
#define YIELD_SPIN 8000UL
#define KEY_DIGIT1 0x02UL
#define SPAWN_FLOOR 0xFFFFFFFFFFFFFF00UL
#define FILE_ERR_FLOOR 0xFFFFFFFFFFFFFF00UL
#define O_WRITE 1UL
#define SEL_BYTES 4UL

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
static const char cap_studio[] = "STUDIO";

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

static void paint_strip(u64 va, u64 names) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  u64 band_h = WIN_H;
  if (names > 1) {
    band_h = WIN_H / names;
  }
  if (band_h == 0) {
    band_h = 1;
  }
  while (py < WIN_H) {
    u64 px = 0;
    u32 c = (u32)SURF_FILL;
    if (names > 0) {
      u64 row = py / band_h;
      if (row >= names) {
        row = names - 1;
      }
      c = band_colour(row);
    }
    while (px < WIN_W) {
      p[py * WIN_W + px] = c;
      px = px + 1;
    }
    py = py + 1;
  }
}

static void try_strip(u64 names) {
  u64 h;
  u64 va;
  u64 frames;

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
  wr(msg_csd, sizeof(msg_csd) - 1);

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

  ev = sys1(SYS_KBDEVENT, KBD_OP_POP);
  if (ev != KBD_EMPTY) {
    if ((ev & KBD_BIT_BREAK) == 0) {
      if ((ev & KBD_BIT_EXT) == 0) {
        sc = ev & 0xFFUL;
        if (sc >= KEY_DIGIT1) {
          row = sc - KEY_DIGIT1;
          if (row < names) {
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
      band_h = WIN_H;
      if (names > 1) {
        band_h = WIN_H / names;
      }
      if (band_h == 0) {
        band_h = 1;
      }
      row = y / band_h;
      launch_row(row, names);
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
