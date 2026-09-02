/* Metal fallback behind osgfx.h. Public symbols live in osgfx_graphite.mm. */
#ifndef OSGFX_METAL_H
#define OSGFX_METAL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OsGfxMetal OsGfxMetal;

OsGfxMetal *osgfx_metal_create(int w, int h);
void osgfx_metal_destroy(OsGfxMetal *g);
void osgfx_metal_clear(OsGfxMetal *g, uint32_t rgb);
void osgfx_metal_fill_rect(OsGfxMetal *g, int x, int y, int w, int h, uint32_t rgb);
void osgfx_metal_fill_rrect(OsGfxMetal *g, int x, int y, int w, int h, int radius,
                            uint32_t rgb);
void osgfx_metal_fill_rrect_vgrad(OsGfxMetal *g, int x, int y, int w, int h,
                                  int radius, uint32_t top, uint32_t bot);
void osgfx_metal_shadow(OsGfxMetal *g, int x, int y, int w, int h, int radius,
                        int blur, uint32_t rgb);
int osgfx_metal_flush(OsGfxMetal *g);
int osgfx_metal_readback(OsGfxMetal *g, uint32_t *out, int max_pixels);
int osgfx_metal_ppm_write(OsGfxMetal *g, const char *path);
int osgfx_metal_present_layer(OsGfxMetal *g, void *metal_layer);

#ifdef __cplusplus
}
#endif

#endif
