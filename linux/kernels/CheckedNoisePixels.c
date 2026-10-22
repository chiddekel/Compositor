// NoisePixels.c under the ENG-17 canonical-buffer contract (generated from NoisePixels.h; see CompositorKernelChecks.h).
// Upstream's kernel is compiled here unchanged, with its checked entry points renamed; the wrappers below
// abort on a padded stride before calling it.
#include "CompositorKernelChecks.h"
#define noise_add noise_add__unchecked
#define noise_add_at noise_add_at__unchecked
#include "../../Compositor/Rendering/NoisePixels.c"
#undef noise_add
#undef noise_add_at

void noise_add(uint8_t *rgba, size_t width, size_t height, size_t stride, float amount, int gaussian, int monochromatic, uint32_t seed) {
    COMPOSITOR_REQUIRE_CANONICAL("noise_add", stride, width, 4);
    noise_add__unchecked(rgba, width, height, stride, amount, gaussian, monochromatic, seed);
}

void noise_add_at(uint8_t *rgba, size_t width, size_t height, size_t stride, float amount, int gaussian, int monochromatic, uint32_t seed, int64_t origin_x, int64_t origin_y) {
    COMPOSITOR_REQUIRE_CANONICAL("noise_add_at", stride, width, 4);
    noise_add_at__unchecked(rgba, width, height, stride, amount, gaussian, monochromatic, seed, origin_x, origin_y);
}
