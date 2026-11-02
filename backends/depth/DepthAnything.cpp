// Depth Anything V2 Small (ONNX) for Core ML compat — see include/CompositorDepth.h.
#include "CompositorDepth.h"

#ifdef COMPOSITOR_HAS_OPENCV_DNN
#include <opencv2/core.hpp>
#include <opencv2/dnn.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <mutex>
#include <vector>

namespace {
std::mutex gate;
cv::dnn::Net net;
bool loaded = false;

int roundMultiple(int value, int multiple) {
    return std::max(multiple, ((value + multiple - 1) / multiple) * multiple);
}
}

extern "C" int32_t compositor_depth_load(const char *model_path) {
    std::lock_guard<std::mutex> lock(gate);
    if (loaded) return 0;
    if (!model_path) return -1;
    try {
        net = cv::dnn::readNetFromONNX(model_path);
        if (net.empty()) return -1;
        net.setPreferableBackend(cv::dnn::DNN_BACKEND_OPENCV);
        net.setPreferableTarget(cv::dnn::DNN_TARGET_CPU);
        loaded = true;
        return 0;
    } catch (const cv::Exception &) {
        return -1;
    }
}

extern "C" int32_t compositor_depth_ready(void) {
    std::lock_guard<std::mutex> lock(gate);
    return loaded ? 1 : 0;
}

extern "C" int32_t compositor_depth_predict(const uint8_t *bgra, int32_t width, int32_t height, float *out_depth) {
    if (!bgra || !out_depth || width <= 0 || height <= 0) return -3;
    std::lock_guard<std::mutex> lock(gate);
    if (!loaded) return -2;
    try {
        // Tip DepthMini feeds BGRA; OpenCV wants RGB floats with ImageNet mean/std (HF DPT preprocessor).
        const cv::Mat source(height, width, CV_8UC4, const_cast<uint8_t *>(bgra), size_t(width) * 4);
        cv::Mat rgb;
        cv::cvtColor(source, rgb, cv::COLOR_BGRA2RGB);
        const int side = roundMultiple(std::max(width, height) > 518 ? 518 : std::max(width, height), 14);
        const int rw = roundMultiple(int(std::lround(double(width) * double(side) / double(std::max(width, height)))), 14);
        const int rh = roundMultiple(int(std::lround(double(height) * double(side) / double(std::max(width, height)))), 14);
        cv::Mat resized;
        cv::resize(rgb, resized, cv::Size(std::max(14, rw), std::max(14, rh)), 0, 0, cv::INTER_AREA);
        cv::Mat floats;
        resized.convertTo(floats, CV_32FC3, 1.0 / 255.0);
        const cv::Scalar mean(0.485, 0.456, 0.406), deviation(0.229, 0.224, 0.225);
        cv::subtract(floats, mean, floats);
        cv::divide(floats, deviation, floats);
        const cv::Mat blob = cv::dnn::blobFromImage(floats);
        net.setInput(blob);
        cv::Mat output = net.forward();
        // Expected NCHW depth or HxW; flatten to a 2-D map at network size.
        cv::Mat map;
        if (output.dims == 4) {
            const int oh = output.size[2], ow = output.size[3];
            map = cv::Mat(oh, ow, CV_32F, output.ptr<float>());
        } else if (output.dims == 3) {
            const int oh = output.size[1], ow = output.size[2];
            map = cv::Mat(oh, ow, CV_32F, output.ptr<float>());
        } else if (output.dims == 2) {
            map = output;
        } else {
            return -3;
        }
        cv::Mat full;
        cv::resize(map, full, cv::Size(width, height), 0, 0, cv::INTER_LINEAR);
        full.copyTo(cv::Mat(height, width, CV_32F, out_depth));
        return 0;
    } catch (const cv::Exception &) {
        return -3;
    }
}

#else

extern "C" int32_t compositor_depth_load(const char *) { return -2; }
extern "C" int32_t compositor_depth_ready(void) { return 0; }
extern "C" int32_t compositor_depth_predict(const uint8_t *, int32_t, int32_t, float *) { return -2; }

#endif
