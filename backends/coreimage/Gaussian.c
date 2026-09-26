#include "include/CoreImageKernels.h"
#include <string.h>

// Clang/GCC lower this to the platform's four-float vector instructions. memcpy
// permits unaligned pixels without imposing an alignment contract on Swift arrays.
typedef float Pixel __attribute__((vector_size(16)));
static inline Pixel load(const float *p) { Pixel v; memcpy(&v, p, sizeof v); return v; }
static inline void store(float *p, Pixel v) { memcpy(p, &v, sizeof v); }
static inline Pixel weight(float v) { return (Pixel){v, v, v, v}; }

void compositor_gaussian_horizontal(const float *restrict source, size_t source_width,
    size_t first_x, size_t output_width, const float *restrict kernel, size_t radius,
    float *restrict output) {
    size_t x = 0;
    while (x < output_width) {
        const size_t sx = first_x + x;
        if (x + 4 <= output_width && sx >= radius && sx + 3 + radius < source_width) {
            Pixel a = {0}, b = {0}, c = {0}, d = {0};
            const float *tap = source + (sx - radius) * 4;
            for (size_t k = 0; k <= radius * 2; ++k, tap += 4) {
                const Pixel w = weight(kernel[k]);
                a += load(tap) * w;
                b += load(tap + 4) * w;
                c += load(tap + 8) * w;
                d += load(tap + 12) * w;
            }
            store(output + x * 4, a); store(output + x * 4 + 4, b);
            store(output + x * 4 + 8, c); store(output + x * 4 + 12, d);
            x += 4;
        } else {
            const size_t first = sx > radius ? sx - radius : 0;
            const size_t last = sx + radius < source_width ? sx + radius : source_width - 1;
            const float *tap = source + first * 4;
            const float *coefficient = kernel + radius - (sx - first);
            Pixel sum = {0};
            for (size_t sample = first; sample <= last; ++sample, tap += 4, ++coefficient)
                sum += load(tap) * weight(*coefficient);
            store(output + x * 4, sum);
            ++x;
        }
    }
}

void compositor_gaussian_vertical(const float *restrict source, size_t width,
    const float *restrict kernel, size_t taps, float *restrict output) {
    const size_t stride = width * 4;
    size_t x = 0;
    for (; x + 4 <= width; x += 4) {
        Pixel a = {0}, b = {0}, c = {0}, d = {0};
        for (size_t k = 0; k < taps; ++k) {
            const float *tap = source + k * stride + x * 4;
            const Pixel w = weight(kernel[k]);
            a += load(tap) * w;
            b += load(tap + 4) * w;
            c += load(tap + 8) * w;
            d += load(tap + 12) * w;
        }
        store(output + x * 4, a); store(output + x * 4 + 4, b);
        store(output + x * 4 + 8, c); store(output + x * 4 + 12, d);
    }
    for (; x < width; ++x) {
        Pixel sum = {0};
        for (size_t k = 0; k < taps; ++k)
            sum += load(source + k * stride + x * 4) * weight(kernel[k]);
        store(output + x * 4, sum);
    }
}
