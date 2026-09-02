/* core/user/gpu/osgpu.c — explicit GPU stub a later syscall wraps.
 *
 * Games include osgpu.h and call these. UI / osgfx / wm do not.
 * Today's device path is hidden `osgpug` in virtgpu3d.dart (G10
 * virgl CLEAR + TRANSFER_FROM_HOST_3D). Ring-3 has no number yet;
 * without that wrap this file returns OSGPU_NONE (no 3D from here).
 * Do not invent SYS_OSGPU in this file. 11 stays fdwait.
 */

#include "osgpu.h"

int osgpu_create(struct osgpu_ctx *ctx) {
  if (ctx == 0) {
    return OSGPU_BAD;
  }
  ctx->magic = OSGPU_MAGIC;
  ctx->handle = 0;
  ctx->pixel = 0;
  return OSGPU_NONE;
}

int osgpu_submit(struct osgpu_ctx *ctx, int kind) {
  if (ctx == 0) {
    return OSGPU_BAD;
  }
  if (ctx->magic != OSGPU_MAGIC) {
    return OSGPU_BAD;
  }
  if (kind != OSGPU_KIND_CLEAR) {
    if (kind != OSGPU_KIND_TRIANGLE) {
      return OSGPU_BAD;
    }
  }
  return OSGPU_NONE;
}

int osgpu_readback(struct osgpu_ctx *ctx, unsigned int *pixel) {
  if (ctx == 0) {
    return OSGPU_BAD;
  }
  if (pixel == 0) {
    return OSGPU_BAD;
  }
  if (ctx->magic != OSGPU_MAGIC) {
    return OSGPU_BAD;
  }
  *pixel = ctx->pixel;
  return OSGPU_NONE;
}
