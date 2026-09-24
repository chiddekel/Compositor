// BrushPixels.c under the ENG-17 canonical-buffer contract (generated from BrushPixels.h; see CompositorKernelChecks.h).
// Upstream's kernel is compiled here unchanged, with its checked entry points renamed; the wrappers below
// abort on a padded stride before calling it.
#include "CompositorKernelChecks.h"
#define layer_extract_alpha layer_extract_alpha__unchecked
#define layer_unpremultiply_opaque layer_unpremultiply_opaque__unchecked
#define layer_restore_alpha layer_restore_alpha__unchecked
#include "../../Compositor/Rendering/BrushPixels.c"
#undef layer_extract_alpha
#undef layer_unpremultiply_opaque
#undef layer_restore_alpha

void layer_extract_alpha(const uint8_t *rgba, size_t rgbaStride, uint8_t *gray, size_t grayStride, size_t width, size_t height) {
    COMPOSITOR_REQUIRE_CANONICAL("layer_extract_alpha", rgbaStride, width, 4);
    COMPOSITOR_REQUIRE_CANONICAL("layer_extract_alpha", grayStride, width, 1);
    layer_extract_alpha__unchecked(rgba, rgbaStride, gray, grayStride, width, height);
}

void layer_unpremultiply_opaque(uint8_t *rgba, size_t stride, size_t width, size_t height) {
    COMPOSITOR_REQUIRE_CANONICAL("layer_unpremultiply_opaque", stride, width, 4);
    layer_unpremultiply_opaque__unchecked(rgba, stride, width, height);
}

void layer_restore_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alphaStride, size_t width, size_t height) {
    COMPOSITOR_REQUIRE_CANONICAL("layer_restore_alpha", stride, width, 4);
    COMPOSITOR_REQUIRE_CANONICAL("layer_restore_alpha", alphaStride, width, 1);
    layer_restore_alpha__unchecked(rgba, stride, alpha, alphaStride, width, height);
}
