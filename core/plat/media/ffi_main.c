/* Thin tool: argv, then DCDart. Not a Mac UI. Not a guest ELF. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "osmedia.h"

void osmedia_ffi_set_clip(const char *p);
void osmedia_ffi_set_path(const char *p);
const char *osmedia_ffi_last_backend(void);
uint64_t osmediaFfiFrame(void);
uint64_t osmediaFfiNone(void);

int main(int argc, char **argv) {
  const char *path;
  const char *clip;
  int no_init;
  int i;
  uint64_t pix;

  path = "osmedia.ppm";
  clip = "osmedia-clip.mp4";
  no_init = 0;
  i = 1;
  while (i < argc) {
    if (strcmp(argv[i], "-o") == 0) {
      if (i + 1 >= argc) {
        return 2;
      }
      path = argv[i + 1];
      i = i + 2;
      continue;
    }
    if (strcmp(argv[i], "-i") == 0) {
      if (i + 1 >= argc) {
        return 2;
      }
      clip = argv[i + 1];
      i = i + 2;
      continue;
    }
    if (strcmp(argv[i], "--no-init") == 0) {
      no_init = 1;
      i = i + 1;
      continue;
    }
    return 2;
  }

  osmedia_ffi_set_clip(clip);
  osmedia_ffi_set_path(path);
  if (no_init != 0) {
    pix = osmediaFfiNone();
  } else {
    pix = osmediaFfiFrame();
  }

  fprintf(stdout, "BACKEND %s\n", osmedia_ffi_last_backend());
  fprintf(stdout, "VERSION %s\n", osmedia_version());
  fprintf(stdout, "PIXEL 0x%06X\n", (unsigned)(pix & 0xFFFFFFu));
  fflush(stdout);
  return 0;
}
