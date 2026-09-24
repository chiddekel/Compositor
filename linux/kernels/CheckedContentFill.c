// ContentFill.c under the ENG-17 canonical-buffer contract (generated from ContentFill.h; see CompositorKernelChecks.h).
// Upstream's kernel is compiled here unchanged, with its checked entry points renamed; the wrappers below
// abort on a padded stride before calling it.
#include "CompositorKernelChecks.h"
#define content_fill content_fill__unchecked
#include "../../Compositor/Rendering/ContentFill.c"
#undef content_fill

int content_fill(uint8_t *rgba, size_t stride, const uint8_t *mask, size_t maskStride, int width, int height) {
    COMPOSITOR_REQUIRE_CANONICAL("content_fill", stride, width, 4);
    COMPOSITOR_REQUIRE_CANONICAL("content_fill", maskStride, width, 1);
    return content_fill__unchecked(rgba, stride, mask, maskStride, width, height);
}
