// HealPixels.c under the ENG-17 canonical-buffer contract (generated from HealPixels.h; see CompositorKernelChecks.h).
// Upstream's kernel is compiled here unchanged, with its checked entry points renamed; the wrappers below
// abort on a padded stride before calling it.
#include "CompositorKernelChecks.h"
#define heal_coverage_bounds heal_coverage_bounds__unchecked
#define spot_heal spot_heal__unchecked
#include "../../Compositor/Rendering/HealPixels.c"
#undef heal_coverage_bounds
#undef spot_heal

void heal_coverage_bounds(const uint8_t *gray, size_t width, size_t height, size_t stride, long bounds[4]) {
    COMPOSITOR_REQUIRE_CANONICAL("heal_coverage_bounds", stride, width, 1);
    heal_coverage_bounds__unchecked(gray, width, height, stride, bounds);
}

int spot_heal(uint8_t *rgba, const uint8_t *coverage, size_t width, size_t height, size_t stride, float opacity, int mode, uint32_t seed) {
    COMPOSITOR_REQUIRE_CANONICAL("spot_heal", stride, width, 4);
    return spot_heal__unchecked(rgba, coverage, width, height, stride, opacity, mode, seed);
}
