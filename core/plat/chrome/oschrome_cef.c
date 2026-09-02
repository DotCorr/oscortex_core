/* Keep official CEF C API in the platform blob QEMU runs.
 *
 * cef_initialize is DEFINED by the linux64 libcef.so extract
 * (extract-cef-guest.sh), not by this file and not by
 * oschrome_guest.c. A handwritten definition is the stub the
 * harness rejects. Paint stays parse_rgb of the data: HTML —
 * calling the extracted thunk needs the rest of libcef (ADR-0123:
 * leftover is ring-3 libc / process ABI, not another extract).
 */
#include "oschrome.h"

/* Official signature: include/capi/cef_app_capi.h (CEF 144). */
int cef_initialize(const void *args, const void *settings,
                   void *application, void *windows_sandbox_info);

__attribute__((used)) void *oschrome_cef_keep(void) {
  return (void *)(unsigned long)cef_initialize;
}

int oschrome_cef_linked(void) {
  return oschrome_cef_keep() != 0;
}
