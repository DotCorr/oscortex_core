/* Thin tool: argv, then DCDart. Not a Mac UI. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

void osgfx_ffi_set_path(const char *p);
uint64_t osgfxFfiPaint(void);

int main(int argc, char **argv) {
  const char *path;
  int i;
  uint64_t rc;

  path = "osgfx.ppm";
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
    return 2;
  }
  osgfx_ffi_set_path(path);
  rc = osgfxFfiPaint();
  if (rc != 0) {
    fprintf(stderr, "osgfx-ffi: DCDart paint returned %llu\n",
            (unsigned long long)rc);
    return 1;
  }
  return 0;
}
