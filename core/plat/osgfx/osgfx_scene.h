#ifndef OSGFX_SCENE_H
#define OSGFX_SCENE_H

#include "osgfx.h"

void osgfx_scene_two(OsGfx *g);
void osgfx_scene_two_square(OsGfx *g);

/* Session chrome: desktop, two windows, title, 3px focus/unfocus,
 * taskbar, popover. Rrects + shadow. Same colours/sizes as wm*. */
void osgfx_scene_compose(OsGfx *g);
void osgfx_scene_compose_square(OsGfx *g);

void osgfx_scene_osxui3(OsGfx *g, int menu_open, int menu_hit, int ctl_on,
                        int win_x, int win_y, int pop_x, int pop_y);

#endif
