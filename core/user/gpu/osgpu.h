/* OSGPU 1
 * core/user/gpu/osgpu.h — explicit GPU for apps that need one.
 *
 * TWO USES. Do not mix them.
 *   Implicit — UI / osgfx / wm decide GPU vs CPU Skia. Apps do not
 *   pick. That is the compositor path. A FRAME client never calls
 *   this header.
 *   Explicit — this file. Games call osgpu_create / osgpu_submit /
 *   osgpu_readback. C, like osframe. DCDart does not become C++.
 *   C++ stays behind the fence if the impl is Vulkan/virgl.
 *
 * WHAT THIS IS
 * ---------------------------------------------------------------------------
 * A host-side header a freestanding program includes. create a
 * context, submit a CLEAR or a triangle, optional readback of one
 * pixel the device wrote. Today's kernel path is hidden `osgpug`
 * calling G10 virgl (virtgpu3d). A later syscall wraps these
 * functions; this file does not invent one. 11 stays fdwait.
 *
 * WHAT THIS IS NOT
 * ---------------------------------------------------------------------------
 * It is not osgfx.h. It is not a paint fallback. It is not a
 * compositor pick. UI never requires the app to call osgpu.
 * No swapchain. No shader ABI. Those are leftover.
 *
 * The first line's tag `OSGPU 1` is the magic/version. OSGPU_MAGIC
 * is 'GPU1'.
 */

#ifndef OSGPU_H
#define OSGPU_H

#define OSGPU_MAGIC 0x47505531UL
#define OSGPU_VERSION 1

#define OSGPU_OK 0
#define OSGPU_NONE 1
#define OSGPU_BAD 2

#define OSGPU_KIND_CLEAR 1
#define OSGPU_KIND_TRIANGLE 2

/* A later syscall can wrap these. Not taken. 11 is fdwait. */
#define OSGPU_OP_CREATE 1UL
#define OSGPU_OP_SUBMIT 2UL
#define OSGPU_OP_READBACK 3UL

struct osgpu_ctx {
  unsigned long magic;
  unsigned long handle;
  unsigned int pixel;
};

int osgpu_create(struct osgpu_ctx *ctx);
int osgpu_submit(struct osgpu_ctx *ctx, int kind);
int osgpu_readback(struct osgpu_ctx *ctx, unsigned int *pixel);

#endif /* OSGPU_H */
