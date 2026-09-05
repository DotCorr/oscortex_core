/* Always linked. Mailbox + weak tick so isr.S resolves without Skia. */
#include "osgfx_guest.h"

__attribute__((section(".osgfx_cmd"), used)) struct OsGfxGuestCmd osgfx_guest_cmd = {
    OSGFX_GUEST_MAGIC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};

__attribute__((weak)) void osgfx_guest_tick(void) {}
__attribute__((weak)) void osmedia_guest_tick(void) {}
__attribute__((weak)) int osgfx_pointer_raster(uint32_t *out, int w, int h) {
  (void)out;
  (void)w;
  (void)h;
  return 1;
}
__attribute__((weak)) unsigned osgfx_vk_spirv_ready(void) { return 0; }
__attribute__((weak)) unsigned osgfx_vk_venus_encode(void) { return 0; }
__attribute__((weak)) uint64_t osgfx_chrome_prep_rest(void) { return 0; }
__attribute__((weak)) uint64_t osgfx_chrome_prep(uint64_t win0, uint64_t win1) {
  (void)win0;
  (void)win1;
  return 0;
}
__attribute__((weak)) uint64_t osgfx_chrome_drag_step(uint64_t old_g, uint64_t new_g) {
  (void)old_g;
  (void)new_g;
  return 0;
}
__attribute__((weak)) uint64_t osgfx_chrome_vacate_geom(uint64_t old_g) {
  (void)old_g;
  return 0;
}
__attribute__((weak)) uint64_t osgfx_fb_copy_span(uint64_t dst, uint64_t src,
                                                 uint64_t bytes) {
  uint64_t i;
  if (dst == 0 || src == 0) {
    return 0;
  }
  i = 0;
  while (i < bytes) {
    ((unsigned char *)(uintptr_t)dst)[i] =
        ((const unsigned char *)(uintptr_t)src)[i];
    i = i + 1;
  }
  return bytes;
}
__attribute__((weak)) uint64_t osgfx_chrome_hit_present(const struct OsGfxGuestCmd *m) {
  (void)m;
  return 0;
}
__attribute__((weak)) uint64_t osgfx_chrome_hit_restore(void) { return 0; }
__attribute__((weak)) uint64_t osgfx_menu_blit(uint64_t pop) {
  (void)pop;
  return 0;
}
__attribute__((weak)) uint64_t osgfx_chrome_prep_present(uint64_t which, uint64_t xy,
                                                        uint64_t wh) {
  (void)which;
  (void)xy;
  (void)wh;
  return 0;
}
__attribute__((weak)) void osgfx_guest_ack(void) {}
