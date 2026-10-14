#ifndef COMPOSITOR_BRUSH_BACKEND_H
#define COMPOSITOR_BRUSH_BACKEND_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Matches the shader's four 16-byte push-constant groups; no platform types.
typedef struct {
    float a, b, c, d;
    float origin_x, origin_y, radius, hardness;
    float canvas_width, canvas_height, antialias_width, spacing;
    uint32_t width, height, settled_count, segment_count;
} CompositorBrushUniforms;
typedef struct { float x0, y0, x1, y1; } CompositorBrushSegment;
typedef struct CompositorVulkanBrush CompositorVulkanBrush;
// Each call processes one <=256x256 tile and <=2048 centerline segments.
// Input/output permanent arrays have width*height floats; preview has that many
// bytes. Outputs are disjoint from input. Return 0 on success, -1 invalid input,
// -2 unavailable/runtime failure. Failure leaves caller output untouched.
int compositor_brush_cpu(const CompositorBrushUniforms *uniforms,
    const CompositorBrushSegment *segments, size_t segment_count,
    const float *permanent, size_t pixel_count, float *next, uint8_t *preview);
// Same tile coordinates and buffers, but writes only [first_row, end_row).
// Disjoint row ranges may run concurrently; each preserves the full kernel's arithmetic.
int compositor_brush_cpu_rows(const CompositorBrushUniforms *uniforms,
    const CompositorBrushSegment *segments, size_t segment_count,
    const float *permanent, size_t pixel_count, float *next, uint8_t *preview,
    uint32_t first_row, uint32_t end_row);
CompositorVulkanBrush *compositor_vulkan_brush_create(void);
void compositor_vulkan_brush_destroy(CompositorVulkanBrush *context);
int compositor_vulkan_brush_render(CompositorVulkanBrush *context,
    const CompositorBrushUniforms *uniforms,
    const CompositorBrushSegment *segments, size_t segment_count,
    const float *permanent, size_t pixel_count, float *next, uint8_t *preview);
// Immutable diagnostics, valid until context destruction.
const char *compositor_vulkan_brush_device(CompositorVulkanBrush *context);
uint32_t compositor_vulkan_brush_device_type(CompositorVulkanBrush *context);
uint32_t compositor_vulkan_brush_driver_version(CompositorVulkanBrush *context);
typedef struct CompositorVulkanSmudge CompositorVulkanSmudge;
CompositorVulkanSmudge *compositor_vulkan_smudge_create(void);
void compositor_vulkan_smudge_destroy(CompositorVulkanSmudge *context);
// Tightly packed RGBA floats and one weight per pixel; output may alias carried.
// Caller outputs are untouched on invalid input (-1) or GPU failure (-2).
int compositor_vulkan_smudge_render(CompositorVulkanSmudge *context,
    uint32_t width, uint32_t height, float strength, const float *under,
    const float *carried, const float *weights, float *output);
const char *compositor_vulkan_smudge_device(CompositorVulkanSmudge *context);
uint32_t compositor_vulkan_smudge_device_type(CompositorVulkanSmudge *context);
// Current host-cached bindings: bit 0..4; zero before buffer allocation or when unsupported.
uint32_t compositor_vulkan_warp_cached_buffers(CompositorVulkanSmudge *context);
// The same stroke-local compute context also retains an untouched Liquify source.
typedef struct {
    uint32_t source_width, source_height, origin_x, origin_y;
    uint32_t width, height, padding0, padding1;
    float move_x, move_y, padding2, padding3;
} CompositorLiquifyUniforms;
int compositor_vulkan_liquify_original(CompositorVulkanSmudge *context,
    uint32_t width, uint32_t height, const float *rgba);
// Prior/output offsets have width*height RG pairs; pixels have that many RGBA values.
// Weights are in [0,1]; inactive pixels retain their prior offsets and return zero color.
// Failure leaves both caller outputs untouched. Outputs must be disjoint from each other.
int compositor_vulkan_liquify_render(CompositorVulkanSmudge *context,
    const CompositorLiquifyUniforms *uniforms, const float *prior, const float *weights,
    float *offsets, float *pixels);
// Cached radial weights: exactly 2*radius*radius+1 floats, indexed by squared distance.
int compositor_vulkan_warp_weights(CompositorVulkanSmudge *context,
    uint32_t radius, const float *weights, size_t count);
typedef struct {
    uint32_t width, height; float strength; uint32_t format;
    int32_t center_x, center_y; uint32_t canvas_width, canvas_height;
    uint32_t radius, padding0, padding1, padding2;
} CompositorSmudgePackedUniforms;
typedef struct {
    CompositorLiquifyUniforms base;
    int32_t center_x, center_y; uint32_t radius, padding;
} CompositorLiquifyPackedUniforms;
// Formats: 0 RGBA8, 1 unsigned RGBA16, 2 IEEE half RGBA. Packed arrays are tight native rows.
// Smudge output carried may alias input carried. Other outputs must be disjoint.
// Failure preserves every caller output; both packed operations require cached radial weights.
int compositor_vulkan_smudge_packed(CompositorVulkanSmudge *context,
    const CompositorSmudgePackedUniforms *uniforms, const void *under,
    const float *carried, float *output_carried, void *output_pixels);
int compositor_vulkan_liquify_packed(CompositorVulkanSmudge *context,
    const CompositorLiquifyPackedUniforms *uniforms, const float *prior,
    float *output_offsets, void *output_pixels);
#ifdef __cplusplus
}
#endif
#endif
