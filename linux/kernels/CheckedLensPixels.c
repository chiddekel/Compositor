// LensPixels.c under the ENG-17 canonical-buffer contract (generated from LensPixels.h; see CompositorKernelChecks.h).
// Upstream's kernel is compiled here unchanged, with its checked entry points renamed; the wrappers below
// abort on a padded stride before calling it.
#include "CompositorKernelChecks.h"
#define lens_distort lens_distort__unchecked
#include "../../Compositor/Rendering/LensPixels.c"
#undef lens_distort

void lens_distort(const uint8_t *source, uint8_t *destination, size_t width, size_t height, size_t stride, double k) {
    COMPOSITOR_REQUIRE_CANONICAL("lens_distort", stride, width, 4);
    lens_distort__unchecked(source, destination, width, height, stride, k);
}
