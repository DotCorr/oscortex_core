#include "osgfx.h"
#include "osgfx_scene.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  const char *path;
  int square;
  int compose;
  int i;
  OsGfx *g;
  int rc;

  path = "osgfx.ppm";
  square = 0;
  compose = 0;
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
    if (strcmp(argv[i], "--square") == 0) {
      square = 1;
      i = i + 1;
      continue;
    }
    if (strcmp(argv[i], "--compose") == 0) {
      compose = 1;
      i = i + 1;
      continue;
    }
    return 2;
  }

  g = osgfx_create(OSGFX_W, OSGFX_H);
  if (g == 0) {
    fprintf(stderr, "osgfx-headless: no GPU device\n");
    return 3;
  }
  fprintf(stdout, "BACKEND %s\n", osgfx_backend_name(g));
  fflush(stdout);
  if (compose) {
    if (square) {
      osgfx_scene_compose_square(g);
    } else {
      osgfx_scene_compose(g);
    }
  } else if (square) {
    osgfx_scene_two_square(g);
  } else {
    osgfx_scene_two(g);
  }
  rc = osgfx_flush(g);
  if (rc != OSGFX_OK) {
    osgfx_destroy(g);
    return 4;
  }
  rc = osgfx_ppm_write(g, path);
  osgfx_destroy(g);
  if (rc != OSGFX_OK) {
    return 5;
  }
  return 0;
}
