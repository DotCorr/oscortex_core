/* core/plat/osgfx/osgfx_font.h — real TrueType outlines, in .rodata.
 *
 * This is the text half of the osgfx.h paint ABI. It is deliberately NOT a
 * bitmap font and NOT a coverage-mask cache:
 *
 *   - core/scripts/gen-osgfx-font.py reads the `glyf` table of a real
 *     proportional TTF at build time and emits each ASCII glyph's quadratic
 *     outline as move/line/quad/close verbs in font units, plus its real
 *     `hmtx` advance and the face's real vertical metrics.
 *   - osgfx_text() (osgfx_skia.cpp) replays those verbs into an
 *     SkPathBuilder and hands the SkPath to SkCanvas::drawPath with
 *     antialiasing on.
 *
 * So the glyph is scan-converted live, in the OS, by Skia, at whatever
 * pixel size the caller asks for. There is no 8x16 cell and no fixed
 * advance. What is baked is the outline, which is what a .ttf is.
 *
 * What this is NOT: SkFont / SkTypeface / SkTextBlob. The guest-elf Skia
 * is built with skia_use_freetype=false and skia_enable_fontmgr_empty=true,
 * so there is no scaler context and no font manager in the image; Skia has
 * no TrueType parser of its own. Shaping, hinting, kerning (GPOS) and
 * subpixel positioning are therefore absent — see core/docs/known-gaps.md.
 */

#ifndef OSGFX_FONT_H
#define OSGFX_FONT_H

#ifdef __cplusplus
extern "C" {
#endif

enum {
  OSGFX_FONT_FIRST = 0x20,
  OSGFX_FONT_LAST = 0x7E,
  OSGFX_FONT_N = OSGFX_FONT_LAST - OSGFX_FONT_FIRST + 1,
  /* Verb codes in OsgfxFace.verbs. */
  OSGFX_VERB_MOVE = 0,
  OSGFX_VERB_LINE = 1,
  OSGFX_VERB_QUAD = 2,
  OSGFX_VERB_CLOSE = 3
};

typedef struct OsgfxGlyphRec {
  unsigned short verb_off;
  unsigned short verb_n;
  unsigned short pt_off;
  short advance; /* font units */
} OsgfxGlyphRec;

typedef struct OsgfxFace {
  const unsigned char *verbs;
  const short *pts; /* x,y interleaved, y UP */
  const OsgfxGlyphRec *glyphs;
  int upem;
  int ascent;
  int descent; /* negative */
  int line_gap;
  int cap_height;
  int x_height;
} OsgfxFace;

/* Generated in osgfx_font_data.c. */
extern const OsgfxFace osgfx_face_regular;
extern const OsgfxFace osgfx_face_medium;

/* weight is OSGFX_TEXT_REGULAR / OSGFX_TEXT_MEDIUM from osgfx.h. */
const OsgfxFace *osgfx_font_face(int weight);

#ifdef __cplusplus
}
#endif

#endif
