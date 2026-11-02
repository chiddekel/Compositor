#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CompositorCameraRawLookup CompositorCameraRawLookup;
CompositorCameraRawLookup *compositor_camera_raw_lookup_create(void);
void compositor_camera_raw_lookup_destroy(CompositorCameraRawLookup *context);
void compositor_camera_raw_lookup_discard(CompositorCameraRawLookup *context);
const char *compositor_camera_raw_lookup_device(CompositorCameraRawLookup *context);
uint64_t compositor_camera_raw_lookup_submissions(CompositorCameraRawLookup *context);
uint64_t compositor_camera_raw_lookup_max_pixels(CompositorCameraRawLookup *context);
/* RGBA8 rows, including padding, are preserved. Output and repair flags are written only on
 * success. The caller applies upstream's double-precision repair before installing output. */
int compositor_camera_raw_lookup_apply(CompositorCameraRawLookup *context, const uint8_t *input,
    uint8_t *output, uint8_t *repair, uint32_t width, uint32_t height, uint32_t stride,
    const float *table, uint32_t grid);
#ifdef __cplusplus
}
#endif
