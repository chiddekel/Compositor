#pragma once
// Subject segmentation for the Vision compat layer (Sources/Compat/Vision): U²-Net-small (u2netp, Apache-2.0)
// through OpenCV's DNN module. Stands in for Apple Vision's foreground instance mask model — Select Subject, Object
// Selection and Remove Background. Built only when OpenCV was configured with the dnn module
// (COMPOSITOR_HAS_OPENCV_DNN); otherwise every call reports -2 and the classical segmenter stays in charge.
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the ONNX model once. 0 on success, -1 unreadable model, -2 built without OpenCV DNN.
int32_t compositor_u2net_load(const char *model_path);

/// Segments premultiplied RGBA8 (`width`x`height`, rows `width * 4` bytes). Writes `labels` (width*height: 0 background,
/// 1...N connected subjects, largest first) and `confidence` (width*height floats 0...1: the model's soft foreground),
/// and the instance count. 0 on success, -2 without a loaded model, -3 inference failed.
int32_t compositor_u2net_segment(const uint8_t *rgba, int32_t width, int32_t height, uint8_t *labels, float *confidence,
                                 int32_t *instance_count);

#ifdef __cplusplus
}
#endif
