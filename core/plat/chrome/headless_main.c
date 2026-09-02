#include "oschrome.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  const char *path;
  int no_init;
  int i;
  OsChrome *b;
  char url[512];
  int rc;
  uint32_t pix;

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
      break;
    }
    return 2;
  }

  if (no_init) {
    setenv("OSCHROME_NO_CHROMIUM", "1", 1);
  }

  rc = oschrome_init(argc, argv);
  if (rc != OSCHROME_OK) {
    fprintf(stderr, "oschrome-headless: init failed\n");
    return 3;
  }

  b = oschrome_create(OSCHROME_W, OSCHROME_H);
  if (b == 0) {
    fprintf(stderr, "oschrome-headless: create failed\n");
    oschrome_shutdown();
    return 4;
  }

  fprintf(stdout, "BACKEND %s\n", oschrome_backend_name(b));
  fflush(stdout);

  if (oschrome_default_data_url(url, (int)sizeof(url)) < 0) {
    oschrome_destroy(b);
    oschrome_shutdown();
    return 5;
  }

  rc = oschrome_load_url(b, url);
  if (rc != OSCHROME_OK) {
    oschrome_destroy(b);
    oschrome_shutdown();
    return 6;
  }

  rc = oschrome_pump(b, 30000);
  if (rc != OSCHROME_OK && !no_init) {
    fprintf(stderr, "oschrome-headless: no paint\n");
    oschrome_destroy(b);
    oschrome_shutdown();
    return 7;
  }

  if (oschrome_pixel(b, OSCHROME_PX, OSCHROME_PY, &pix) == OSCHROME_OK) {
    fprintf(stdout, "PIXEL 0x%06X\n", (unsigned)(pix & 0xFFFFFFu));
    fflush(stdout);
  }

  rc = oschrome_ppm_write(b, path);
  oschrome_destroy(b);
  oschrome_shutdown();
  if (rc != OSCHROME_OK) {
    return 8;
  }
  return 0;
}
