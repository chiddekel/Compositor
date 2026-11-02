#include "include/CoreImageKernels.h"
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
// Four independent complex FFTs share the twiddles: one per RGBA channel.
// Forward DIF and inverse DIT use the same bit-reversed frequency order, so
// neither transform needs a separate permutation pass.
typedef float V __attribute__((vector_size(16)));
struct CompositorGaussianPlan {
    size_t n, radius;
    float *wr, *wi, *kr, *ki;
};
typedef struct CompositorGaussianPlan Plan;
static void fft(V *r, V *i, const Plan *p, int inverse) {
    size_t n = p->n;
    if (!inverse) {
        for (size_t len = n; len >= 2; len /= 2) {
            size_t half = len / 2, step = n / len;
            for (size_t base = 0; base < n; base += len)
                for (size_t j = 0; j < half; j++) {
                    size_t a = base + j, b = a + half, t = j * step;
                    V dr = r[a] - r[b], di = i[a] - i[b];
                    r[a] += r[b];
                    i[a] += i[b];
                    r[b] = dr * p->wr[t] - di * p->wi[t];
                    i[b] = dr * p->wi[t] + di * p->wr[t];
                }
        }
    } else {
        for (size_t len = 2; len <= n; len *= 2) {
            size_t half = len / 2, step = n / len;
            for (size_t base = 0; base < n; base += len)
                for (size_t j = 0; j < half; j++) {
                    size_t a = base + j, b = a + half, t = j * step;
                    V br = r[b] * p->wr[t] + i[b] * p->wi[t], bi = i[b] * p->wr[t] - r[b] * p->wi[t];
                    r[b] = r[a] - br;
                    i[b] = i[a] - bi;
                    r[a] += br;
                    i[a] += bi;
                }
        }
    }
}
Plan *compositor_gaussian_plan(const float *k, size_t radius) {
    if (radius == 0 || radius > SIZE_MAX / (16 * sizeof(V)))
        return NULL;
    Plan *p = calloc(1, sizeof *p);
    if (!p)
        return NULL;
    p->n = 1;
    p->radius = radius;
    while (p->n < radius * 4 + 1)
        p->n *= 2;
    size_t n = p->n;
    p->wr = malloc(n / 2 * sizeof(float));
    p->wi = malloc(n / 2 * sizeof(float));
    p->kr = malloc(n * sizeof(float));
    p->ki = malloc(n * sizeof(float));
    V *r = calloc(n, sizeof(V)), *i = calloc(n, sizeof(V));
    if (!p->wr || !p->wi || !p->kr || !p->ki || !r || !i) {
        free(r);
        free(i);
        compositor_gaussian_plan_free(p);
        return NULL;
    }
    for (size_t j = 0; j < n / 2; j++) {
        p->wr[j] = cos(-2 * M_PI * j / n);
        p->wi[j] = sin(-2 * M_PI * j / n);
    }
    for (size_t j = 0; j <= radius * 2; j++)
        r[j] = (V){k[j], k[j], k[j], k[j]};
    fft(r, i, p, 0);
    for (size_t j = 0; j < n; j++) {
        p->kr[j] = r[j][0] / n;
        p->ki[j] = i[j][0] / n;
    }
    free(r);
    free(i);
    return p;
}
void compositor_gaussian_plan_free(Plan *p) {
    if (!p)
        return;
    free(p->wr);
    free(p->wi);
    free(p->kr);
    free(p->ki);
    free(p);
}
int compositor_gaussian_fft(const Plan *p, const float *src, size_t count, size_t stride, size_t first,
                            size_t width, float *out, size_t outstride) {
    size_t n = p->n, radius = p->radius, block = n - 2 * radius;
    V *r = malloc(n * sizeof(V)), *i = malloc(n * sizeof(V));
    if (!r || !i) {
        free(r);
        free(i);
        return 0;
    }
    // Overlap-save: the first 2*radius outputs contain circular wraparound.
    // Discard them and keep the remaining exact linear-convolution samples.
    for (size_t x = 0; x < width; x += block) {
        memset(r, 0, n * sizeof(V));
        memset(i, 0, n * sizeof(V));
        ptrdiff_t start = (ptrdiff_t)(first + x) - (ptrdiff_t)radius;
        for (size_t j = 0; j < n; j++) {
            ptrdiff_t at = start + (ptrdiff_t)j;
            if (at >= 0 && (size_t)at < count)
                memcpy(r + j, src + at * stride, sizeof(V));
        }
        fft(r, i, p, 0);
        for (size_t j = 0; j < n; j++) {
            V v = r[j] * p->kr[j] - i[j] * p->ki[j];
            i[j] = r[j] * p->ki[j] + i[j] * p->kr[j];
            r[j] = v;
        }
        fft(r, i, p, 1);
        size_t len = width - x < block ? width - x : block;
        for (size_t j = 0; j < len; j++)
            memcpy(out + (x + j) * outstride, r + 2 * radius + j, sizeof(V));
    }
    free(r);
    free(i);
    return 1;
}
