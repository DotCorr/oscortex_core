#ifndef OSGFX_SESSION_H
#define OSGFX_SESSION_H

#include "osgfx.h"
#include "osgfx_guest.h"

#ifdef __cplusplus
extern "C" {
#endif

void osgfx_fill_desk_generative(uint32_t *fb, int pitch, int x, int y, int w, int h,
                                uint32_t seed, uint32_t frame);
void osgfx_session_paint(OsGfx *g, const struct OsGfxGuestCmd *cmd, int graphite_ready);
void osgfx_session_paint_windows(OsGfx *g, const struct OsGfxGuestCmd *cmd);
void osgfx_session_patch_focus(OsGfx *g, const struct OsGfxGuestCmd *cmd);

#ifdef __cplusplus
}
#endif

#endif
