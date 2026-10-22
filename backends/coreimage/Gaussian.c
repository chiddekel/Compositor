#include "include/CoreImageKernels.h"
#include <string.h>

// Build both versions on x86: the loader selects AVX2 where available, while
// older CPUs retain the same portable vector implementation.
#if defined(__x86_64__) && defined(__ELF__)
#define WIDE_TARGET __attribute__((target_clones("avx2", "default")))
#else
#define WIDE_TARGET
#endif

typedef float Pair __attribute__((vector_size(32)));
#define LOAD_PAIR(v, p) Pair v; memcpy(&v, (p), sizeof v)
#define STORE_PAIR(p, v) memcpy((p), &(v), sizeof(v))

// Clang/GCC lower this to the platform's four-float vector instructions. memcpy
// permits unaligned pixels without imposing an alignment contract on Swift arrays.
typedef float Pixel __attribute__((vector_size(16)));
static inline Pixel load(const float *p) { Pixel v; memcpy(&v, p, sizeof v); return v; }
static inline void store(float *p, Pixel v) { memcpy(p, &v, sizeof v); }
static inline Pixel weight(float v) { return (Pixel){v, v, v, v}; }

WIDE_TARGET
void compositor_gaussian_horizontal(const float *restrict source, size_t source_width,
    size_t first_x, size_t output_width, const float *restrict kernel, size_t radius,
    float *restrict output) {
    size_t x = 0;
    while (x < output_width) {
        const size_t sx = first_x + x;
        if (x + 8 <= output_width && sx >= radius && sx + 7 + radius < source_width) {
            Pair a = {0}, b = {0}, c = {0}, d = {0};
            const float *tap = source + (sx - radius) * 4;
            for (size_t k = 0; k <= radius * 2; ++k, tap += 4) {
                const float w = kernel[k];
                LOAD_PAIR(p0, tap); LOAD_PAIR(p1, tap + 8);
                LOAD_PAIR(p2, tap + 16); LOAD_PAIR(p3, tap + 24);
                a += p0 * w; b += p1 * w; c += p2 * w; d += p3 * w;
            }
            STORE_PAIR(output + x * 4, a); STORE_PAIR(output + x * 4 + 8, b);
            STORE_PAIR(output + x * 4 + 16, c); STORE_PAIR(output + x * 4 + 24, d);
            x += 8;
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

WIDE_TARGET
void compositor_gaussian_vertical(const float *restrict source, size_t width,
    const float *restrict kernel, size_t taps, float *restrict output) {
    const size_t stride = width * 4;
    size_t x = 0;
    for (; x + 8 <= width; x += 8) {
        Pair a = {0}, b = {0}, c = {0}, d = {0};
        for (size_t k = 0; k < taps; ++k) {
            const float *tap = source + k * stride + x * 4;
            const float w = kernel[k];
            LOAD_PAIR(p0, tap); LOAD_PAIR(p1, tap + 8);
            LOAD_PAIR(p2, tap + 16); LOAD_PAIR(p3, tap + 24);
            a += p0 * w; b += p1 * w; c += p2 * w; d += p3 * w;
        }
        STORE_PAIR(output + x * 4, a); STORE_PAIR(output + x * 4 + 8, b);
        STORE_PAIR(output + x * 4 + 16, c); STORE_PAIR(output + x * 4 + 24, d);
    }
    for (; x < width; ++x) {
        Pixel sum = {0};
        for (size_t k = 0; k < taps; ++k)
            sum += load(source + k * stride + x * 4) * weight(kernel[k]);
        store(output + x * 4, sum);
    }
}
