/* Mac CoreGraphics generator is not linked into kernel.elf. */
#include "include/core/SkImageGenerator.h"
#ifdef SK_BUILD_FOR_MAC
#undef SK_BUILD_FOR_MAC
#endif
