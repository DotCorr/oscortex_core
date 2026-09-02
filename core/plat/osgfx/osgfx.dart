// core/plat/osgfx/osgfx.dart — DCDart calls the platform C paint module.
//
// Same shape as DCDart examples/ffi-extern: `@extern` names are C symbols.
// Handles are u64 (GAP-0025: Pointer is not an @extern type).
// Prelude spelling is ADR-0043: through core/build/dcdart only.
import '../../build/dcdart/core/runtime/dc-core-bare/prelude.dart';

@extern
external u64 osgfx_ffi_create(u64 w, u64 h);

@extern
external void osgfx_ffi_destroy(u64 g);

@extern
external void osgfx_ffi_clear(u64 g, u64 rgb);

@extern
external void osgfx_ffi_fill_rrect(
  u64 g,
  u64 x,
  u64 y,
  u64 w,
  u64 h,
  u64 radius,
  u64 rgb,
);

@extern
external u64 osgfx_ffi_flush(u64 g);

@extern
external u64 osgfx_ffi_ppm(u64 g);

@extern
external void osgfx_ffi_scene_two(u64 g);

@extern
external void osgfx_ffi_scene_compose(u64 g);

/// One rounded window. Harness CMOD-FFI1 reads the AABB corner.
@bare
u64 osgfxFfiPaint() {
  final g = osgfx_ffi_create(u64(800), u64(600));
  osgfx_ffi_clear(g, u64(0x00184060));
  osgfx_ffi_fill_rrect(
    g,
    u64(48),
    u64(40),
    u64(240),
    u64(160),
    u64(14),
    u64(0x00E8E0D0),
  );
  final fl = osgfx_ffi_flush(g);
  final wr = osgfx_ffi_ppm(g);
  osgfx_ffi_destroy(g);
  return fl + wr;
}

/// Session chrome through the same C ABI. Host harnesses sample the PPM.
@bare
u64 osgfxFfiPreview() {
  final g = osgfx_ffi_create(u64(800), u64(600));
  osgfx_ffi_scene_compose(g);
  final fl = osgfx_ffi_flush(g);
  final wr = osgfx_ffi_ppm(g);
  osgfx_ffi_destroy(g);
  return fl + wr;
}
