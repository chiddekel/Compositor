#include "include/CoreImageKernels.h"
#include <string.h>

typedef float Pixel __attribute__((vector_size(16)));
static inline Pixel sample(const float *source, size_t width, size_t height,
                           ptrdiff_t x, ptrdiff_t y) {
    if (x < 0 || y < 0 || (size_t)x >= width || (size_t)y >= height) return (Pixel){0};
    Pixel value;
    memcpy(&value, source + ((size_t)y * width + (size_t)x) * 4, sizeof value);
    return value;
}

void compositor_motion_row(const float *restrict source, size_t width, size_t height,
    ptrdiff_t first_x, ptrdiff_t y, size_t output_width,
    const CompositorMotionTap *restrict kernel, size_t taps, float *restrict output) {
    for (size_t x = 0; x < output_width; ++x) {
        Pixel sum = {0};
        for (size_t k = 0; k < taps; ++k) {
            const ptrdiff_t sx = first_x + (ptrdiff_t)x + kernel[k].x, sy = y + kernel[k].y;
            const float tx = kernel[k].tx, ty = kernel[k].ty;
            const Pixel a = sample(source, width, height, sx, sy);
            const Pixel b = sample(source, width, height, sx + 1, sy);
            const Pixel c = sample(source, width, height, sx, sy + 1);
            const Pixel d = sample(source, width, height, sx + 1, sy + 1);
            // Keep the original bilinear grouping and tap accumulation order.
            sum += (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
        }
        sum /= (float)taps;
        memcpy(output + x * 4, &sum, sizeof sum);
    }
}
