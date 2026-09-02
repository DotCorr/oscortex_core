/* Host scene: desktop + label strip + one button through osxui.h.
 * Click is a hit-test that selects the derived colour. --square paints
 * the button AABB with fill_rect so the rrect corner probe can fail
 * on purpose.
 */
#include "osgfx.h"
#include "osxui.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void paint_scene(OsGfx *g, int armed, int square, const char *label) {
  OsxuiRect btn;
  OsxuiRect panel;
  uint32_t rgb;
  int n;

  osgfx_clear(g, OSGFX_DESK);
  panel.x = OSXUI_PANEL_X;
  panel.y = OSXUI_PANEL_Y;
  panel.w = OSXUI_PANEL_W;
  panel.h = OSXUI_PANEL_H;
  osxui_panel(g, &panel, OSXUI_PANEL);
  if (label != 0 && label[0] != 0) {
    n = 0;
    while (label[n] != 0 && n < 8) {
      n = n + 1;
    }
    osxui_label(g, OSXUI_PANEL_X + OSXUI_LABEL_PAD_X,
                OSXUI_PANEL_Y + OSXUI_LABEL_PAD_Y, label, n, OSXUI_LABEL_FG);
  }
  btn.x = OSXUI_BTN_X;
  btn.y = OSXUI_BTN_Y;
  btn.w = OSXUI_BTN_W;
  btn.h = OSXUI_BTN_H;
  rgb = OSXUI_BTN_IDLE;
  if (armed) {
    rgb = OSXUI_BTN_HIT;
  }
  if (square) {
    osgfx_fill_rect(g, btn.x, btn.y, btn.w, btn.h, rgb);
  } else {
    osxui_button(g, &btn, OSXUI_BTN_R, rgb);
  }
}

static uint64_t parse_hex_label(const char *s) {
  uint64_t v;
  int i;

  v = 0;
  if (s == 0) {
    return 0;
  }
  i = 0;
  while (s[i] != 0 && i < 8) {
    char c = s[i];
    unsigned nib;
    if (c >= '0' && c <= '9') {
      nib = (unsigned)(c - '0');
    } else if (c >= 'A' && c <= 'F') {
      nib = (unsigned)(c - 'A' + 10);
    } else if (c >= 'a' && c <= 'f') {
      nib = (unsigned)(c - 'a' + 10);
    } else {
      return v;
    }
    v = (v << 4) | (uint64_t)nib;
    i = i + 1;
  }
  return v;
}

static void paint_panel(OsGfx *g, const char *label) {
  OsxuiRect panel;
  OsxuiRect row;
  int n;

  osgfx_clear(g, OSGFX_DESK);
  panel.x = OSXUI_REFL_X;
  panel.y = OSXUI_REFL_Y;
  panel.w = OSXUI_REFL_W;
  panel.h = OSXUI_REFL_H;
  osxui_panel(g, &panel, OSXUI_REFL_BG);
  row.x = OSXUI_REFL_X + 4;
  row.y = OSXUI_REFL_Y + 4;
  row.w = OSXUI_REFL_W - 8;
  row.h = 18;
  osxui_panel(g, &row, OSXUI_REFL);
  if (label != 0 && label[0] != 0) {
    n = 0;
    while (label[n] != 0 && n < OSXUI_REFL_N) {
      n = n + 1;
    }
    osxui_hex(g, OSXUI_REFL_X + OSXUI_REFL_PAD_X,
              OSXUI_REFL_Y + OSXUI_REFL_PAD_Y, parse_hex_label(label), n,
              OSXUI_REFL_FG);
  }
}

static int write_scan_ppm(const char *path, const uint32_t *px, int w, int h) {
  FILE *f;
  int y;
  int x;
  uint32_t c;
  unsigned char rgb[3];

  if (path == 0 || px == 0) {
    return 5;
  }
  f = fopen(path, "wb");
  if (f == 0) {
    return 5;
  }
  if (fprintf(f, "P6\n%d %d\n255\n", w, h) < 0) {
    fclose(f);
    return 5;
  }
  y = 0;
  while (y < h) {
    x = 0;
    while (x < w) {
      c = px[(unsigned)y * (unsigned)w + (unsigned)x];
      rgb[0] = (unsigned char)((c >> 16) & 0xff);
      rgb[1] = (unsigned char)((c >> 8) & 0xff);
      rgb[2] = (unsigned char)(c & 0xff);
      if (fwrite(rgb, 1, 3, f) != 3) {
        fclose(f);
        return 5;
      }
      x = x + 1;
    }
    y = y + 1;
  }
  fclose(f);
  return 0;
}

/* FILES list row: colour band + optional document icon. */
static void paint_icon_row(OsGfx *g, int with_icon) {
  OsxuiRect band;

  osgfx_clear(g, OSGFX_DESK);
  band.x = 40;
  band.y = 48;
  band.w = 160;
  band.h = 32;
  osxui_panel(g, &band, 0x00C08030u);
  if (with_icon) {
    osxui_icon(g, band.x + OSXUI_ICON_PAD_X, band.y, OSXUI_ICON_FG);
  }
}

static int chrome_start_scene(const char *path) {
  uint32_t *scan;
  unsigned n;
  unsigned i;
  int y0;
  OsxuiRect start;
  uint64_t fwh;
  uint64_t xy;
  uint64_t sz;
  uint64_t rrgb;

  n = (unsigned)OSGFX_W * (unsigned)OSGFX_H;
  scan = (uint32_t *)calloc(n, sizeof(uint32_t));
  if (scan == 0) {
    return 3;
  }
  i = 0;
  while (i < n) {
    scan[i] = (uint32_t)OSGFX_DESK;
    i = i + 1;
  }
  y0 = OSGFX_H - OSGFX_CHROME_H;
  i = 0;
  while (i < (unsigned)OSGFX_CHROME_H) {
    unsigned xx = 0;
    while (xx < (unsigned)OSGFX_W) {
      scan[((unsigned)y0 + i) * (unsigned)OSGFX_W + xx] =
          (uint32_t)OSGFX_CHROME;
      xx = xx + 1;
    }
    i = i + 1;
  }
  start.x = 0;
  start.y = y0;
  start.w = OSXUI_START_W;
  start.h = OSXUI_START_H;
  fwh = ((uint64_t)OSGFX_W << 32) | (uint64_t)OSGFX_H;
  xy = ((uint64_t)start.x << 32) | (uint64_t)start.y;
  sz = ((uint64_t)start.w << 32) | (uint64_t)start.h;
  rrgb = ((uint64_t)OSXUI_START_R << 32) | (uint64_t)OSXUI_START;
  osxui_button_fb((uint64_t)(uintptr_t)scan, (uint64_t)OSGFX_W * 4u, fwh, xy,
                  sz, rrgb);
  fprintf(stdout, "CHROME_START 0x%06X\n", OSXUI_START & 0x00FFFFFFu);
  fflush(stdout);
  i = (unsigned)write_scan_ppm(path, scan, OSGFX_W, OSGFX_H);
  free(scan);
  return (int)i;
}

int main(int argc, char **argv) {
  const char *path;
  const char *label;
  int square;
  int want_click;
  int want_miss;
  int want_start;
  int want_panel;
  int want_icon;
  int want_no_icon;
  int i;
  int cx;
  int cy;
  int armed;
  int hit;
  OsGfx *g;
  OsxuiRect btn;
  int rc;
  uint32_t rgb;

  path = "osxui.ppm";
  square = 0;
  want_click = 0;
  want_miss = 0;
  want_start = 0;
  want_panel = 0;
  want_icon = 0;
  want_no_icon = 0;
  label = 0;
  i = 1;
  while (i < argc) {
    if (strcmp(argv[i], "-o") == 0) {
      if (i + 1 >= argc) {
        return 2;
      }
      path = argv[i + 1];
      i = i + 2;
      continue;
    }
    if (strcmp(argv[i], "--square") == 0) {
      square = 1;
      i = i + 1;
      continue;
    }
    if (strcmp(argv[i], "--click") == 0) {
      want_click = 1;
      i = i + 1;
      continue;
    }
    if (strcmp(argv[i], "--miss") == 0) {
      want_miss = 1;
      i = i + 1;
      continue;
    }
    if (strcmp(argv[i], "--chrome-start") == 0) {
      want_start = 1;
      i = i + 1;
      continue;
    }
    if (strcmp(argv[i], "--panel") == 0) {
      want_panel = 1;
      i = i + 1;
      continue;
    }
    if (strcmp(argv[i], "--icon") == 0) {
      want_icon = 1;
      i = i + 1;
      continue;
    }
    if (strcmp(argv[i], "--no-icon") == 0) {
      want_no_icon = 1;
      i = i + 1;
      continue;
    }
    if (strcmp(argv[i], "--label") == 0) {
      if (i + 1 >= argc) {
        return 2;
      }
      label = argv[i + 1];
      i = i + 2;
      continue;
    }
    return 2;
  }

  if (want_start) {
    return chrome_start_scene(path);
  }

  if (want_icon || want_no_icon) {
    g = osgfx_create(OSGFX_W, OSGFX_H);
    if (g == 0) {
      fprintf(stderr, "osxui-headless: no raster\n");
      return 3;
    }
    fprintf(stdout, "BACKEND %s\n", osgfx_backend_name(g));
    fprintf(stdout, "ICON 0x%06X\n", OSXUI_ICON_FG & 0x00FFFFFFu);
    fflush(stdout);
    paint_icon_row(g, want_icon && !want_no_icon);
    rc = osgfx_flush(g);
    if (rc != OSGFX_OK) {
      osgfx_destroy(g);
      return 4;
    }
    rc = osgfx_ppm_write(g, path);
    osgfx_destroy(g);
    if (rc != OSGFX_OK) {
      return 5;
    }
    return 0;
  }

  if (want_panel) {
    g = osgfx_create(OSGFX_W, OSGFX_H);
    if (g == 0) {
      fprintf(stderr, "osxui-headless: no raster\n");
      return 3;
    }
    fprintf(stdout, "BACKEND %s\n", osgfx_backend_name(g));
    fprintf(stdout, "PANEL 0x%06X\n", OSXUI_REFL & 0x00FFFFFFu);
    if (label != 0) {
      fprintf(stdout, "LABEL %s\n", label);
    }
    fflush(stdout);
    paint_panel(g, label);
    rc = osgfx_flush(g);
    if (rc != OSGFX_OK) {
      osgfx_destroy(g);
      return 4;
    }
    rc = osgfx_ppm_write(g, path);
    osgfx_destroy(g);
    if (rc != OSGFX_OK) {
      return 5;
    }
    return 0;
  }

  btn.x = OSXUI_BTN_X;
  btn.y = OSXUI_BTN_Y;
  btn.w = OSXUI_BTN_W;
  btn.h = OSXUI_BTN_H;
  if (want_miss) {
    cx = 10;
    cy = 10;
  } else {
    cx = OSXUI_BTN_X + OSXUI_BTN_W / 2;
    cy = OSXUI_BTN_Y + OSXUI_BTN_H / 2;
  }
  hit = osxui_hit(&btn, cx, cy);
  armed = 0;
  if (want_click && hit) {
    armed = 1;
  }
  if (want_miss && hit) {
    return 6;
  }

  g = osgfx_create(OSGFX_W, OSGFX_H);
  if (g == 0) {
    fprintf(stderr, "osxui-headless: no raster\n");
    return 3;
  }
  fprintf(stdout, "BACKEND %s\n", osgfx_backend_name(g));
  fprintf(stdout, "HIT %d\n", hit);
  rgb = armed ? (uint32_t)OSXUI_BTN_HIT : (uint32_t)OSXUI_BTN_IDLE;
  fprintf(stdout, "COLOUR 0x%06X\n", rgb & 0x00FFFFFFu);
  fflush(stdout);

  if (label != 0) {
    fprintf(stdout, "LABEL %s\n", label);
  }
  paint_scene(g, armed, square, label);
  rc = osgfx_flush(g);
  if (rc != OSGFX_OK) {
    osgfx_destroy(g);
    return 4;
  }
  rc = osgfx_ppm_write(g, path);
  osgfx_destroy(g);
  if (rc != OSGFX_OK) {
    return 5;
  }
  return 0;
}
