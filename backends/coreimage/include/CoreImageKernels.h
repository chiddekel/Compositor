#ifndef COMPOSITOR_CORE_IMAGE_KERNELS_H
#define COMPOSITOR_CORE_IMAGE_KERNELS_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Packed RGBA floats. Buffers are disjoint. Horizontal output is a subrange of
// the input row; samples outside the input row are transparent. The vertical
// caller supplies the first valid row and corresponding kernel coefficient.
void compositor_gaussian_horizontal(const float *source, size_t source_width,
    size_t first_x, size_t output_width, const float *kernel, size_t radius, float *output);
void compositor_gaussian_vertical(const float *source, size_t width,
    const float *kernel, size_t taps, float *output);
typedef struct {
    ptrdiff_t x, y;
    float tx, ty;
} CompositorMotionTap;
// Each worker writes one output row. Coordinates and bilinear fractions are
// shared by every pixel; out-of-bounds samples remain transparent.
void compositor_motion_row(const float *source, size_t width, size_t height,
    ptrdiff_t first_x, ptrdiff_t y, size_t output_width,
    const CompositorMotionTap *kernel, size_t taps, float *output);
#ifdef __cplusplus
}
#endif
#endif
