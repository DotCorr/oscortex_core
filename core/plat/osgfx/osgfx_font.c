/* core/plat/osgfx/osgfx_font.c — face selection for the osgfx text ABI.
 *
 * The outlines live in the generated osgfx_font_data.c. This is only the
 * weight lookup, kept in C so the C++ side behind the osgfx.h fence does
 * not own the choice.
 */
#include "osgfx.h"
#include "osgfx_font.h"

const char osgfx_font_door[] = "osgfx-font-outline";

const OsgfxFace *osgfx_font_face(int weight) {
  if (osgfx_font_door[0] == 0) {
    return 0;
  }
  if (weight == OSGFX_TEXT_MEDIUM) {
    return &osgfx_face_medium;
  }
  return &osgfx_face_regular;
}
