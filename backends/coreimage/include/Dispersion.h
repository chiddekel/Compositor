#pragma once
#include "VulkanRaster.h"
#ifdef __cplusplus
extern "C" {
#endif
// Premultiplied RGBA Float32, top-down rows. Twenty parameters describe the spectral gather,
// input/output origins, row direction and input dimensions. Parameter 18 selects the legacy gather (0),
// smear (1), or spectrum (2) pass. Parameter 19 bit 1 selects native UNORM8 sampling;
// bit 0 is the retained GPU graph's bottom-up half-storage flag.
// Returns 1 for Vulkan, 0 for CPU, -1 for invalid input.
int compositor_dispersion_render(CompositorVulkanRaster *gpu, unsigned width, unsigned height,
    const float *source, const float *parameters, float *output);
#ifdef __cplusplus
}
#endif
