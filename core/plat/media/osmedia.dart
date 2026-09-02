// core/plat/media/osmedia.dart — DCDart calls the platform FFmpeg module.
//
// Same shape as osgfx.dart / oschrome.dart: `@extern` names are C
// symbols. Handles are u64 (GAP-0025: Pointer is not an @extern type).
// The clip path is set on the C side (GAP-0035: no String).
// Prelude spelling is ADR-0043: through core/build/dcdart only.
import '../../build/dcdart/core/runtime/dc-core-bare/prelude.dart';

@extern
external u64 osmedia_ffi_init(u64 noInit);

@extern
external u64 osmedia_ffi_open();

@extern
external void osmedia_ffi_close(u64 m);

@extern
external u64 osmedia_ffi_decode_frame(u64 m);

@extern
external u64 osmedia_ffi_readback(u64 m);

@extern
external u64 osmedia_ffi_pixel(u64 m, u64 x, u64 y);

@extern
external u64 osmedia_ffi_ppm(u64 m);

@extern
external void osmedia_ffi_shutdown();

@extern
external u64 osmedia_ffi_backend_ffmpeg();

@extern
external u64 osmedia_ffi_backend_is_ffmpeg(u64 m);

/// Equal to osmedia.h — harness greps both.
/// OSMEDIA_W = 64, OSMEDIA_H = 64, OSMEDIA_PX = 16, OSMEDIA_PY = 16.

/// FFmpeg path. Harness media0 derives FRAME at (16, 16).
@bare
u64 osmediaFfiFrame() {
  final ini = osmedia_ffi_init(u64(0));
  if (ini != u64(0)) {
    return u64(0);
  }
  final m = osmedia_ffi_open();
  if (m == u64(0)) {
    osmedia_ffi_shutdown();
    return u64(0);
  }
  final dec = osmedia_ffi_decode_frame(m);
  if (dec != u64(0)) {
    osmedia_ffi_close(m);
    osmedia_ffi_shutdown();
    return u64(0);
  }
  final rb = osmedia_ffi_readback(m);
  if (rb == u64(0)) {
    osmedia_ffi_close(m);
    osmedia_ffi_shutdown();
    return u64(0);
  }
  final pix = osmedia_ffi_pixel(m, u64(16), u64(16));
  final wr = osmedia_ffi_ppm(m);
  final ff = osmedia_ffi_backend_ffmpeg();
  final named = osmedia_ffi_backend_is_ffmpeg(m);
  osmedia_ffi_close(m);
  osmedia_ffi_shutdown();
  if (wr != u64(0)) {
    return u64(0);
  }
  if (ff == u64(0)) {
    return u64(0);
  }
  if (named == u64(0)) {
    return u64(0);
  }
  return pix;
}

/// Negative: no avformat_open_input. Pixel is not FRAME.
@bare
u64 osmediaFfiNone() {
  final ini = osmedia_ffi_init(u64(1));
  if (ini != u64(0)) {
    return u64(0);
  }
  final m = osmedia_ffi_open();
  if (m == u64(0)) {
    osmedia_ffi_shutdown();
    return u64(0);
  }
  final dec = osmedia_ffi_decode_frame(m);
  final rb = osmedia_ffi_readback(m);
  final pix = osmedia_ffi_pixel(m, u64(16), u64(16));
  final wr = osmedia_ffi_ppm(m);
  final ff = osmedia_ffi_backend_ffmpeg();
  osmedia_ffi_close(m);
  osmedia_ffi_shutdown();
  if (wr != u64(0)) {
    return u64(0);
  }
  if (ff == u64(0)) {
    return u64(0);
  }
  if (dec != u64(0)) {
    return pix;
  }
  if (rb == u64(0)) {
    return pix;
  }
  return pix;
}
