// WandPixels.c under the ENG-17 canonical-buffer contract (generated from WandPixels.h; see CompositorKernelChecks.h).
// Upstream's kernel is compiled here unchanged, with its checked entry points renamed; the wrappers below
// abort on a padded stride before calling it.
#include "CompositorKernelChecks.h"
#define wand_mask wand_mask__unchecked
#include "../../Compositor/Rendering/WandPixels.c"
#undef wand_mask

long wand_mask(const uint8_t *rgba, size_t width, size_t height, size_t stride, size_t seedX, size_t seedY, size_t radius, int tolerance, int contiguous, uint8_t *mask) {
    COMPOSITOR_REQUIRE_CANONICAL("wand_mask", stride, width, 4);
    return wand_mask__unchecked(rgba, width, height, stride, seedX, seedY, radius, tolerance, contiguous, mask);
}
