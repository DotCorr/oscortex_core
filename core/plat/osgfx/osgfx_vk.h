/* Kernel Vulkan ICD door. Handles + getProc for MakeVulkan.
 * Armed only when Venus capset 4 is offered. Not a stub context.
 * DRAW applies a Graphite-queued solid rrect (chrome path).
 * CreateShaderModule stores Graphite SPIR-V (osgfx-vk-spirv).
 */
#ifndef OSGFX_VK_H
#define OSGFX_VK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Token the harness greps. Not a success claim. */
extern const char osgfx_vk_door[];
/* First SPIR-V door token — CreateShaderModule keeps module bytes. */
extern const char osgfx_vk_spirv_door[];
/* Host-precompiled SPIR-V door — not guest AnalyticRRect SkSL. */
extern const char osgfx_vk_host_spirv_door[];
/* Venus SPIR-V encode door — CONTEXT_INIT + blob to host lavapipe. */
extern const char osgfx_vk_venus_spirv_door[]; /* "osgfx-venus-spirv" */

int osgfx_vk_open(void);
void *osgfx_vk_instance(void);
void *osgfx_vk_phys(void);
void *osgfx_vk_device(void);
void *osgfx_vk_queue(void);
unsigned osgfx_vk_qindex(void);
void *osgfx_vk_get_proc(const char *name);

/* Queue one solid rrect for the next vkCmdDraw against the live FB.
 * Graphite records drawRRect; DRAW fills it. Not CPU SkCanvas::drawRect. */
void osgfx_vk_queue_rrect(int x, int y, int w, int h, int radius, uint32_t rgb);
void osgfx_vk_clear_rrect(void);
/* How many DRAW ops applied a queued rrect. */
unsigned osgfx_vk_rrect_draws(void);

/* Bytes / modules retained from CreateShaderModule (Graphite SPIR-V). */
size_t osgfx_vk_spirv_bytes(void);
unsigned osgfx_vk_spirv_modules(void);

/* Plant host-precompiled SPIR-V through CreateShaderModule — AnalyticRRect
 * freestanding SkSL #GPs before this door; curve paint uses this instead. */
unsigned osgfx_vk_plant_host_spirv(void);

/* Encode retained SPIR-V through Venus CONTEXT_INIT + blob (host lavapipe
 * substrate). Returns 1 when the wire submit landed. Not full FS coverage. */
unsigned osgfx_vk_venus_encode(void);
unsigned osgfx_vk_venus_encode_ok(void);
/* Non-zero when a module is retained for Venus encode. */
unsigned osgfx_vk_spirv_ready(void);

#ifdef __cplusplus
}
#endif

#endif
