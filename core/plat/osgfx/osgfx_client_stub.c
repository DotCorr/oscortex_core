/* Stubs for OSGFX_SKIA=0 anti-vacuity links. wmOpPaint is Skia-only. */
#include <stdint.h>

void com1_puts(const char *s) {
  (void)s;
}

uint64_t osgfx_client_paint(uint64_t px, uint64_t pitch, uint64_t w, uint64_t h,
                            uint64_t scr_x, uint64_t scr_y, uint64_t desc,
                            uint64_t pid) {
  (void)px;
  (void)pitch;
  (void)w;
  (void)h;
  (void)scr_x;
  (void)scr_y;
  (void)desc;
  (void)pid;
  return 0xFFFFFFFFFFFFFFFDULL; /* WM_RET_OFF */
}
