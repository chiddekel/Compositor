#pragma once
// Monocular depth for the Core ML compat layer (Sources/Compat/CoreML): Depth Anything V2 Small (Apache-2.0) through
// OpenCV's DNN module. Stands in for Apple's DepthMini Core ML package used by tip Volumetric Light. Built only when
// OpenCV was configured with the dnn module (COMPOSITOR_HAS_OPENCV_DNN); otherwise every call reports -2.
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the ONNX model once. 0 on success, -1 unreadable model, -2 built without OpenCV DNN.
int32_t compositor_depth_load(const char *model_path);

/// Whether a model is loaded.
int32_t compositor_depth_ready(void);

/// Runs depth on premultiplied BGRA8 (`width`×`height`, row bytes `width * 4`). Writes `out_depth` (`width * height`
/// floats, rows top-down, relative depth — higher usually nearer for Depth Anything; the Swift side normalizes).
/// 0 on success, -2 without a loaded model, -3 inference failed.
int32_t compositor_depth_predict(const uint8_t *bgra, int32_t width, int32_t height, float *out_depth);

#ifdef __cplusplus
}
#endif
