// ENG-17: the canonical-buffer contract for the portable C kernels (the CMake CompositorKernels library).
// Kernel entries normally take a tightly packed buffer — stride == width * 4 for
// RGBA, stride == width for gray — so a padded Skia or Qt buffer can't be misread silently. A violation aborts.
// Upstream's kernel sources stay untouched: linux/kernels/Checked*.c compile them with the entries renamed and put
// these checks in front.
// Camera Raw's composed lookup and rounding repair explicitly support padded rows (upstream 1.5.3).
#pragma once
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static inline void compositor_require_canonical(const char *kernel, const char *what, size_t stride, size_t width,
                                                size_t bytesPerPixel) {
    if (stride == width * bytesPerPixel) return;
    fprintf(stderr, "%s: %s %zu is not canonical (width %zu x %zu bytes per pixel)\n", kernel, what, stride, width,
            bytesPerPixel);
    abort();
}
#define COMPOSITOR_REQUIRE_CANONICAL(kernel, stride, width, bpp) \
    compositor_require_canonical(kernel, #stride, (size_t)(stride), (size_t)(width), (size_t)(bpp))

static inline void compositor_require_row(const char *kernel, size_t stride, size_t width, size_t bytesPerPixel) {
    if (bytesPerPixel != 0 && width <= SIZE_MAX / bytesPerPixel && stride >= width * bytesPerPixel) return;
    fprintf(stderr, "%s: stride %zu is too small for width %zu x %zu bytes per pixel\n", kernel, stride, width, bytesPerPixel);
    abort();
}
#define COMPOSITOR_REQUIRE_ROW(kernel, stride, width, bpp) \
    compositor_require_row(kernel, (size_t)(stride), (size_t)(width), (size_t)(bpp))
