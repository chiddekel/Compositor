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

#if defined(__x86_64__) && defined(__ELF__)
__attribute__((target_clones("avx2", "default")))
#endif
void compositor_motion_row(const float *restrict source, size_t width, size_t height,
    ptrdiff_t first_x, ptrdiff_t y, size_t output_width,
    const CompositorMotionTap *restrict kernel, size_t taps, float *restrict output) {
    // All taps use the same offsets. Check the footprint once, then process
    // eight interior pixels together without bounds checks in the sampling loop.
    ptrdiff_t min_x = 0, max_x = 0, min_y = 0, max_y = 0;
    for (size_t k = 0; k < taps; ++k) {
        if (kernel[k].x < min_x) min_x = kernel[k].x;
        if (kernel[k].x + 1 > max_x) max_x = kernel[k].x + 1;
        if (kernel[k].y < min_y) min_y = kernel[k].y;
        if (kernel[k].y + 1 > max_y) max_y = kernel[k].y + 1;
    }
    const int inside_y = y + min_y >= 0 && y + max_y < (ptrdiff_t)height;
    typedef float Pair __attribute__((vector_size(32)));
    size_t x = 0;
    while (x < output_width) {
        ptrdiff_t sx = first_x + (ptrdiff_t)x;
        if (inside_y && x + 8 <= output_width && sx + min_x >= 0 && sx + 7 + max_x < (ptrdiff_t)width) {
            Pair sums[4] = {{0}, {0}, {0}, {0}};
            for (size_t k = 0; k < taps; ++k) {
                const float *top = source + ((y + kernel[k].y) * (ptrdiff_t)width + sx + kernel[k].x) * 4;
                const float tx = kernel[k].tx, ty = kernel[k].ty;
                for (size_t j = 0; j < 4; ++j) {
                    Pair a, b, c, d;
                    memcpy(&a, top + j * 8, sizeof a);
                    memcpy(&b, top + j * 8 + 4, sizeof b);
                    Pair value = a * (1 - tx) + b * tx;
                    if (ty != 0) {
                        memcpy(&c, top + width * 4 + j * 8, sizeof c);
                        memcpy(&d, top + width * 4 + j * 8 + 4, sizeof d);
                        value = value * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
                    }
                    sums[j] += value;
                }
            }
            for (size_t j = 0; j < 4; ++j) {
                sums[j] /= (float)taps;
                memcpy(output + x * 4 + j * 8, &sums[j], sizeof sums[j]);
            }
            x += 8;
            continue;
        }
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
        ++x;
    }
}
