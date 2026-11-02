#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CompositorVulkanRaster CompositorVulkanRaster;
CompositorVulkanRaster *compositor_vulkan_raster_create(int allow_software);
void compositor_vulkan_raster_destroy(CompositorVulkanRaster *context);
const char *compositor_vulkan_raster_device(CompositorVulkanRaster *context);
uint32_t compositor_vulkan_raster_device_type(CompositorVulkanRaster *context);
int compositor_vulkan_raster_available(CompositorVulkanRaster *context);
uint64_t compositor_vulkan_raster_submissions(CompositorVulkanRaster *context);
/* Graph submissions that ran as one fused pass (intermediates in registers rather than buffers). */
uint64_t compositor_vulkan_raster_fused_submissions(CompositorVulkanRaster *context);
uint64_t compositor_vulkan_raster_upload_bytes(CompositorVulkanRaster *context);
uint64_t compositor_vulkan_raster_readback_bytes(CompositorVulkanRaster *context);
/* Operations: 1 source-over, 2 mask blend, 3 color matrix, 4 color clamp,
 * 5 unpremultiply, 6 maximum component, 7 crop (x0,y0,x1,y1 relative pixel coordinates).
 * Inputs/outputs are premultiplied float RGBA.
 * Matrix parameters are four rows and a bias (20 floats); clamp uses min/max (8).
 * Returns 0 on success, -1 invalid input, -2 unavailable/failed, -3 a graph beyond the retained-memory budget (the
 * device stays usable; evaluate on the CPU). Failed calls leave output untouched. */
int compositor_vulkan_raster_render(CompositorVulkanRaster *context, uint32_t width, uint32_t height,
    uint32_t operation, uint32_t channel, const float *source, const float *background,
    const float *mask, const float *parameters, float *output);
/* Retain immutable inputs between frames. upload_mask bits 1/2/4 request source,
 * background/mask uploads. Caller must retain the matching immutable arrays.
 * A null or stale generation forces all uploads, including after other callers.
 * The generation is updated only on success. Parameters always upload. */
int compositor_vulkan_raster_render_cached(CompositorVulkanRaster *context, uint32_t width, uint32_t height,
    uint32_t operation, uint32_t channel, const float *source, const float *background,
    const float *mask, const float *parameters, float *output, uint32_t upload_mask, uint64_t *generation);
typedef struct CompositorVulkanRasterStep {
    uint32_t operation, channel, source, background, mask;
    float parameters[20];
} CompositorVulkanRasterStep;
/* Topological graph: input nodes [0,input_count), then one node per step.
 * Up to 64 inputs and 128 steps. Each reference must precede its step; unary
 * operations ignore background/mask. All nodes cover the same raster bounds.
 * The final step is the result. Inputs upload according to upload_inputs, with
 * the same generation contract as render_cached. One submission/readback for
 * the whole graph; intermediate storage is reused after its last consumer. */
int compositor_vulkan_raster_render_graph(CompositorVulkanRaster *context, uint32_t width, uint32_t height,
    const float *const *inputs, uint32_t input_count, const CompositorVulkanRasterStep *steps,
    uint32_t step_count, const uint8_t *upload_inputs, uint64_t *generation, float *output);
/* Immutable GPU results. Each handle retains its device, including after context_destroy.
 * Operations never read image pixels on the CPU; only image_read copies them back.
 * Input handles must belong to context. Allocations share a 512 MiB resident budget.
 * Bokeh, half-storage and bottom-up processor dispersion results use packed RGBA16 floats
 * (8 bytes per pixel). Value-preserving crops, alpha replacement and nearest/integer
 * affine placement retain half storage; other results use RGBA32 floats. image_read expands either format
 * to float32 output. Resident/readback counters count stored pixel bytes, not expanded output.
 * In addition to operations 1-9: 10 dispersion, 11 Bokeh, 13 affine sampler, 14 half-float storage,
 * 15 transfer conversion, 16 tone-curve lookup (background holds RGB table texels),
 * 17 alpha replacement, 18 linear-dodge blend. Parameters are 20 floats;
 * Bokeh/affine source dimensions are supplied internally in slots 16/17.
 * Bokeh: radius, shape, ring, region origin x/y, size x/y, output top x/y,
 * input top x/y; parameter 18 selects bottom-up storage (1) versus top-down (0).
 * Affine: inverse a/b/c/d/tx/ty, output origin x/y, input origin x/y, nearest, clamp.
 * Dispersion: existing 20-float ABI; parameter 19 selects bottom-up half-float processor storage.
 * Transfer: parameter 0 selects linear (1) or encoded sRGB (0). */
typedef struct CompositorVulkanImage CompositorVulkanImage;
CompositorVulkanImage *compositor_vulkan_image_upload(CompositorVulkanRaster *context,
    uint32_t width, uint32_t height, const float *pixels);
/* Contiguous RGBA8 pixels, with the same row order and premultiplication as image_upload.
 * GPU reads recover exactly the float32 value of each byte divided by 255. */
CompositorVulkanImage *compositor_vulkan_image_upload_rgba8(CompositorVulkanRaster *context,
    uint32_t width, uint32_t height, const uint8_t *pixels);
CompositorVulkanImage *compositor_vulkan_image_apply(CompositorVulkanRaster *context,
    uint32_t width, uint32_t height, uint32_t operation, uint32_t channel,
    const CompositorVulkanImage *source, const CompositorVulkanImage *background,
    const CompositorVulkanImage *mask, const float *parameters);
int compositor_vulkan_image_read(const CompositorVulkanImage *image, float *output);
void compositor_vulkan_image_destroy(CompositorVulkanImage *image);
uint64_t compositor_vulkan_raster_resident_bytes(CompositorVulkanRaster *context);
uint64_t compositor_vulkan_raster_bokeh_submissions(CompositorVulkanRaster *context);
#ifdef __cplusplus
}
#endif
