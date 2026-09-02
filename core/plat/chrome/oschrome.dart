// core/plat/chrome/oschrome.dart — DCDart calls the platform WebView.
//
// Same shape as osgfx.dart / examples/ffi-extern: `@extern` names are C
// symbols. Handles are u64 (GAP-0025: Pointer is not an @extern type).
// The default data: URL is built on the C side (GAP-0035: no String).
// Prelude spelling is ADR-0043: through core/build/dcdart only.
import '../../build/dcdart/core/runtime/dc-core-bare/prelude.dart';

@extern
external u64 oschrome_ffi_init(u64 noInit);

@extern
external u64 oschrome_ffi_create(u64 w, u64 h);

@extern
external void oschrome_ffi_destroy(u64 b);

@extern
external u64 oschrome_ffi_load_url(u64 b);

@extern
external u64 oschrome_ffi_pump(u64 b, u64 timeoutMs);

@extern
external u64 oschrome_ffi_readback(u64 b);

@extern
external u64 oschrome_ffi_pixel(u64 b, u64 x, u64 y);

@extern
external u64 oschrome_ffi_ppm(u64 b);

@extern
external void oschrome_ffi_shutdown();

@extern
external u64 oschrome_ffi_backend_chromium();

@extern
external u64 oschrome_ffi_backend_is_chromium(u64 b);

/// Equal to oschrome.h — harness greps both.
/// OSCHROME_W = 128, OSCHROME_H = 128, OSCHROME_PX = 32, OSCHROME_PY = 32.

/// Chromium path. Harness cmod-chrome1 derives PAGE at (32, 32).
@bare
u64 oschromeFfiPage() {
  final ini = oschrome_ffi_init(u64(0));
  if (ini != u64(0)) {
    return u64(0);
  }
  final b = oschrome_ffi_create(u64(128), u64(128));
  if (b == u64(0)) {
    oschrome_ffi_shutdown();
    return u64(0);
  }
  final ld = oschrome_ffi_load_url(b);
  if (ld != u64(0)) {
    oschrome_ffi_destroy(b);
    oschrome_ffi_shutdown();
    return u64(0);
  }
  final pm = oschrome_ffi_pump(b, u64(30000));
  if (pm != u64(0)) {
    oschrome_ffi_destroy(b);
    oschrome_ffi_shutdown();
    return u64(0);
  }
  final rb = oschrome_ffi_readback(b);
  if (rb == u64(0)) {
    oschrome_ffi_destroy(b);
    oschrome_ffi_shutdown();
    return u64(0);
  }
  final pix = oschrome_ffi_pixel(b, u64(32), u64(32));
  final wr = oschrome_ffi_ppm(b);
  final cr = oschrome_ffi_backend_chromium();
  final named = oschrome_ffi_backend_is_chromium(b);
  oschrome_ffi_destroy(b);
  oschrome_ffi_shutdown();
  if (wr != u64(0)) {
    return u64(0);
  }
  if (cr == u64(0)) {
    return u64(0);
  }
  if (named == u64(0)) {
    return u64(0);
  }
  return pix;
}

/// Negative: no CefInitialize. Pixel is not PAGE.
@bare
u64 oschromeFfiNone() {
  final ini = oschrome_ffi_init(u64(1));
  if (ini != u64(0)) {
    return u64(0);
  }
  final b = oschrome_ffi_create(u64(128), u64(128));
  if (b == u64(0)) {
    oschrome_ffi_shutdown();
    return u64(0);
  }
  final ld = oschrome_ffi_load_url(b);
  if (ld != u64(0)) {
    oschrome_ffi_destroy(b);
    oschrome_ffi_shutdown();
    return u64(0);
  }
  final pm = oschrome_ffi_pump(b, u64(30000));
  final rb = oschrome_ffi_readback(b);
  final pix = oschrome_ffi_pixel(b, u64(32), u64(32));
  final wr = oschrome_ffi_ppm(b);
  final cr = oschrome_ffi_backend_chromium();
  oschrome_ffi_destroy(b);
  oschrome_ffi_shutdown();
  if (wr != u64(0)) {
    return u64(0);
  }
  if (cr == u64(0)) {
    return u64(0);
  }
  if (pm != u64(0)) {
    return pix;
  }
  if (rb == u64(0)) {
    return pix;
  }
  return pix;
}
