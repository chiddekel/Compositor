#include "include/CoreImageKernels.h"
#include <math.h>
#include <string.h>

typedef float Pixel __attribute__((vector_size(16)));
static inline Pixel sample(const float *source, size_t width, size_t height,
                           ptrdiff_t x, ptrdiff_t y) {
    if (x < 0 || y < 0 || (size_t)x >= width || (size_t)y >= height) return (Pixel){0};
    Pixel value;
    memcpy(&value, source + ((size_t)y * width + (size_t)x) * 4, sizeof value);
    return value;
}

static inline __attribute__((always_inline)) void motion_row(const float *restrict source, size_t width, size_t height,
    ptrdiff_t first_x, ptrdiff_t y, size_t output_width,
    const CompositorMotionTap *restrict kernel, size_t taps, float *restrict output, int byte_samples) {
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
                    if (byte_samples) {
                        for (size_t lane = 0; lane < 8; ++lane) {
                            a[lane] = floorf(a[lane] * 255 + 0.5f);
                            b[lane] = floorf(b[lane] * 255 + 0.5f);
                        }
                    }
                    Pair value = a * (1 - tx) + b * tx;
                    if (ty != 0) {
                        memcpy(&c, top + width * 4 + j * 8, sizeof c);
                        memcpy(&d, top + width * 4 + j * 8 + 4, sizeof d);
                        if (byte_samples) {
                            for (size_t lane = 0; lane < 8; ++lane) {
                                c[lane] = floorf(c[lane] * 255 + 0.5f);
                                d[lane] = floorf(d[lane] * 255 + 0.5f);
                            }
                        }
                        value = value * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
                    }
                    if (byte_samples) {
                        for (size_t lane = 0; lane < 8; ++lane) {
                            value[lane] = floorf(value[lane] * 16 + 0.5f) / 4080;
                        }
                    }
                    sums[j] += value * kernel[k].weight;
                }
            }
            for (size_t j = 0; j < 4; ++j) {
                memcpy(output + x * 4 + j * 8, &sums[j], sizeof sums[j]);
            }
            x += 8;
            continue;
        }
        Pixel sum = {0};
        for (size_t k = 0; k < taps; ++k) {
            const ptrdiff_t sx = first_x + (ptrdiff_t)x + kernel[k].x, sy = y + kernel[k].y;
            const float tx = kernel[k].tx, ty = kernel[k].ty;
            Pixel a = sample(source, width, height, sx, sy);
            Pixel b = sample(source, width, height, sx + 1, sy);
            Pixel c = sample(source, width, height, sx, sy + 1);
            Pixel d = sample(source, width, height, sx + 1, sy + 1);
            if (byte_samples) {
                for (size_t lane = 0; lane < 4; ++lane) {
                    a[lane] = floorf(a[lane] * 255 + 0.5f);
                    b[lane] = floorf(b[lane] * 255 + 0.5f);
                    c[lane] = floorf(c[lane] * 255 + 0.5f);
                    d[lane] = floorf(d[lane] * 255 + 0.5f);
                }
            }
            // Keep the original bilinear grouping and tap accumulation order.
            Pixel value = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
            if (byte_samples) {
                for (size_t lane = 0; lane < 4; ++lane) {
                    value[lane] = floorf(value[lane] * 16 + 0.5f) / 4080;
                }
            }
            sum += value * kernel[k].weight;
        }
        memcpy(output + x * 4, &sum, sizeof sum);
        ++x;
    }
}

#if defined(__x86_64__) && defined(__ELF__)
__attribute__((target_clones("avx2", "default")))
#endif
void compositor_motion_row(const float *restrict source, size_t width, size_t height,
    ptrdiff_t first_x, ptrdiff_t y, size_t output_width,
    const CompositorMotionTap *restrict kernel, size_t taps, float *restrict output) {
    motion_row(source, width, height, first_x, y, output_width, kernel, taps, output, 0);
}

#if defined(__x86_64__) && defined(__ELF__)
__attribute__((target_clones("avx2", "default")))
#endif
void compositor_motion_row_byte_samples(const float *restrict source, size_t width, size_t height,
    ptrdiff_t first_x, ptrdiff_t y, size_t output_width,
    const CompositorMotionTap *restrict kernel, size_t taps, float *restrict output) {
    motion_row(source, width, height, first_x, y, output_width, kernel, taps, output, 1);
}
