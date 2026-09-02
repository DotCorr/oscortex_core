/* Thin tool: argv, then DCDart. Not a Mac UI. Not a guest ELF. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "oschrome.h"

void oschrome_ffi_set_args(int argc, char **argv);
void oschrome_ffi_set_path(const char *p);
const char *oschrome_ffi_last_backend(void);
uint64_t oschromeFfiPage(void);
uint64_t oschromeFfiNone(void);

int main(int argc, char **argv) {
  const char *path;
  int no_init;
  int i;
  uint64_t pix;

  path = "oschrome.ppm";
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
    if (strcmp(argv[i], "--no-init") == 0) {
      no_init = 1;
      i = i + 1;
      continue;
    }
    if (strncmp(argv[i], "--type=", 7) == 0) {
      /* CEF helper — must reach oschrome_init. */
      oschrome_ffi_set_args(argc, argv);
      oschrome_init(argc, argv);
      return 3;
    }
    return 2;
  }

  oschrome_ffi_set_args(argc, argv);
  oschrome_ffi_set_path(path);
  if (no_init != 0) {
    pix = oschromeFfiNone();
  } else {
    pix = oschromeFfiPage();
  }

  fprintf(stdout, "BACKEND %s\n", oschrome_ffi_last_backend());
  fprintf(stdout, "PIXEL 0x%06X\n", (unsigned)(pix & 0xFFFFFFu));
  fflush(stdout);
  return 0;
}
