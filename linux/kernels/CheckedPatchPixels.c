// PatchPixels.c under the canonical-buffer contract; the upstream kernel compiles unchanged.
#include "CompositorKernelChecks.h"
#define patch_fill patch_fill__unchecked
#include "../../Compositor/Rendering/PatchPixels.c"
#undef patch_fill

int patch_fill(uint8_t *rgba, size_t stride, const uint8_t *hole, size_t holeStride, int width, int height, uint32_t seed) {
    COMPOSITOR_REQUIRE_CANONICAL("patch_fill", stride, width, 4);
    COMPOSITOR_REQUIRE_CANONICAL("patch_fill", holeStride, width, 1);
    return patch_fill__unchecked(rgba, stride, hole, holeStride, width, height, seed);
}
