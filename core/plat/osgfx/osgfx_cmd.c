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
