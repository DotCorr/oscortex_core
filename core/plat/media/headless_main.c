#include "osmedia.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int write_black_ppm(const char *path) {
  FILE *f;
  int n;
  unsigned char z;
  if (path == 0) {
    return -1;
  }
  f = fopen(path, "wb");
  if (f == 0) {
    return -1;
  }
  if (fprintf(f, "P6\n%d %d\n255\n", OSMEDIA_W, OSMEDIA_H) < 0) {
    fclose(f);
    return -1;
  }
  z = 0;
  n = OSMEDIA_W * OSMEDIA_H * 3;
  while (n > 0) {
    if (fwrite(&z, 1, 1, f) != 1) {
      fclose(f);
      return -1;
    }
    n = n - 1;
  }
  if (fclose(f) != 0) {
    return -1;
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *out;
  const char *clip;
  int no_init;
  int missing;
  int i;
  OsMedia *m;
  int rc;
  uint32_t pix;

  out = "osmedia.ppm";
  clip = 0;
  no_init = 0;
  missing = 0;
  i = 1;
  while (i < argc) {
    if (strcmp(argv[i], "-o") == 0) {
      if (i + 1 >= argc) {
        return 2;
      }
      out = argv[i + 1];
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
    if (strcmp(argv[i], "--missing") == 0) {
      missing = 1;
      i = i + 1;
      continue;
    }
    return 2;
  }

  if (no_init) {
    setenv("OSMEDIA_NO_FFMPEG", "1", 1);
  }

  rc = osmedia_init();
  if (rc != OSMEDIA_OK) {
    fprintf(stderr, "osmedia-headless: init failed\n");
    return 3;
  }

  fprintf(stdout, "VERSION %s\n", osmedia_version());
  fflush(stdout);

  if (missing) {
    clip = "/no/such/osmedia/clip.mp4";
  }
  if (clip == 0) {
    fprintf(stderr, "osmedia-headless: need -i clip or --missing\n");
    osmedia_shutdown();
    return 2;
  }

  m = osmedia_open(clip);
  if (m == 0) {
    fprintf(stdout, "BACKEND none\n");
    fprintf(stdout, "PIXEL 0x000000\n");
    fflush(stdout);
    osmedia_shutdown();
    if (write_black_ppm(out) != 0) {
      return 8;
    }
    return 0;
  }

  fprintf(stdout, "BACKEND %s\n", osmedia_backend_name(m));
  fflush(stdout);

  rc = osmedia_decode_frame(m);
  if (rc != OSMEDIA_OK && !no_init && !missing) {
    fprintf(stderr, "osmedia-headless: no frame\n");
    osmedia_close(m);
    osmedia_shutdown();
    return 7;
  }

  pix = 0;
  if (osmedia_pixel(m, OSMEDIA_PX, OSMEDIA_PY, &pix) == OSMEDIA_OK) {
    fprintf(stdout, "PIXEL 0x%06X\n", (unsigned)(pix & 0xFFFFFFu));
    fflush(stdout);
  }

  rc = osmedia_ppm_write(m, out);
  osmedia_close(m);
  osmedia_shutdown();
  if (rc != OSMEDIA_OK) {
    return 8;
  }
  return 0;
}
