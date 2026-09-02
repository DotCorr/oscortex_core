/* Mailbox at kernel_data_start+128 (.osmedia_cmd). Dart fills CLIP.MP4.
 * IRQ0 osmedia_guest_tick decodes through osmedia.h. No new @extern. */
#ifndef OSMEDIA_GUEST_H
#define OSMEDIA_GUEST_H

#include <stdint.h>

#define OSMEDIA_GUEST_MAGIC 0x4F534D45445F7631ULL /* OSMED_v1 */
#define OSMEDIA_GUEST_PLAY 1ULL
#define OSMEDIA_GUEST_MISS 2ULL
#define OSMEDIA_GUEST_OFF 128ULL
#define OSMEDIA_GUEST_CLIP_OFF 64ULL
#define OSMEDIA_GUEST_CLIP_MAX 32768ULL

struct OsMediaGuestCmd {
  uint64_t magic;
  uint64_t flags;
  uint64_t clip_len;
  uint64_t pixel;
  uint64_t status;
  uint64_t reserved[3];
  uint8_t clip[32768];
};

void osmedia_guest_tick(void);

#endif
