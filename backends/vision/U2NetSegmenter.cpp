// U²-Net-small subject segmentation (see include/CompositorVision.h).
//
// Preprocessing and postprocessing follow the model's reference (xuebinqin/U-2-Net, as rembg runs it): RGB resized to
// 320x320, scaled by the image's maximum, normalized with ImageNet mean/std; the first output (d1, the fused map) is
// min-max normalized to 0...1, resized back, refined along the picture's edges, and its edge band tightened to Vision's. Subjects are the connected regions of the map at 0.5, largest first,
// small specks dropped — the per-object instances Apple's model reports.
#include "CompositorVision.h"

#ifdef COMPOSITOR_HAS_OPENCV_DNN
#include <opencv2/core.hpp>
#include <opencv2/dnn.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <vector>

namespace {
std::mutex gate;
cv::dnn::Net net;
bool loaded = false;
constexpr int inputSize = 320;

// The model sees the picture at 320x320, so its map, scaled back up, is soft wherever the subject is finer than that
// (a bird's wing, leaves, a stem). A guided filter (He, Sun and Tang) on the picture's luminance moves the map's edges
// onto the picture's own edges, at full resolution, while leaving flat areas as the model left them. Its window is
// eight of the map's pixels, and a quarter of the model's map is kept for the soft fringe. On 28 reference cut-outs
// (scripts/fetch-segmentation-references.py) the median IoU went from 0.885 (no filter) to 0.917 (0.929 with no fringe
// kept; one map pixel of window gave 0.888, sixteen 0.920). Env: COMPOSITOR_U2NET_GUIDED=0 turns it off; _RADIUS (in
// map pixels), _EPS (default 1e-3) and _SHARE (default 0.75) tune it.
void refineAlongEdges(cv::Mat &map, const cv::Mat &rgb) {
    const char *off = std::getenv("COMPOSITOR_U2NET_GUIDED");
    if (off && off[0] == '0') return;
    const char *chosen = std::getenv("COMPOSITOR_U2NET_GUIDED_EPS");
    const double eps = chosen ? std::max(1e-6, std::atof(chosen)) : 1e-3;
    cv::Mat gray, guide;
    cv::cvtColor(rgb, gray, cv::COLOR_RGB2GRAY);
    gray.convertTo(guide, CV_32F, 1.0 / 255);
    const char *wide = std::getenv("COMPOSITOR_U2NET_GUIDED_RADIUS");
    const double scale = wide ? std::max(0.1, std::atof(wide)) : 8.0;
    const int radius = std::max(2, int(std::lround(scale * std::max(map.cols, map.rows) / double(inputSize))) + 1);
    const cv::Size box(2 * radius + 1, 2 * radius + 1);
    auto mean = [&](const cv::Mat &m) { cv::Mat out; cv::boxFilter(m, out, CV_32F, box, cv::Point(-1, -1), true, cv::BORDER_REFLECT); return out; };
    const cv::Mat meanI = mean(guide), meanP = mean(map);
    const cv::Mat varI = mean(guide.mul(guide)) - meanI.mul(meanI);
    const cv::Mat covIP = mean(guide.mul(map)) - meanI.mul(meanP);
    const cv::Mat a = covIP / (varI + eps);
    const cv::Mat b = meanP - a.mul(meanI);
    cv::Mat refined = mean(a).mul(guide) + mean(b);
    cv::min(cv::max(refined, 0.0), 1.0, refined);
    // Part of the model's own map stays in, so the edge keeps the soft fringe Vision's masks have even where the
    // picture's edge is hard.
    const char *share = std::getenv("COMPOSITOR_U2NET_GUIDED_SHARE");
    const double weight = share ? std::min(1.0, std::max(0.0, std::atof(share))) : 0.75;
    map = weight * refined + (1 - weight) * map;
}
}

extern "C" int32_t compositor_u2net_load(const char *model_path) {
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

extern "C" int32_t compositor_u2net_segment(const uint8_t *rgba, int32_t width, int32_t height, uint8_t *labels,
                                           float *confidence, int32_t *instance_count) {
    if (!rgba || !labels || !confidence || width <= 0 || height <= 0) return -3;
    std::lock_guard<std::mutex> lock(gate);
    if (!loaded) return -2;
    try {
        // Premultiplied RGBA over nothing: un-premultiplying would amplify noise in near-transparent pixels, and the
        // model expects an opaque picture, so transparent areas read as black, as Vision sees them.
        const cv::Mat source(height, width, CV_8UC4, const_cast<uint8_t *>(rgba), size_t(width) * 4);
        cv::Mat rgb;
        cv::cvtColor(source, rgb, cv::COLOR_RGBA2RGB);
        cv::Mat resized;
        cv::resize(rgb, resized, cv::Size(inputSize, inputSize), 0, 0, cv::INTER_AREA);
        cv::Mat floats;
        resized.convertTo(floats, CV_32FC3);
        double maxValue = 0;
        cv::minMaxLoc(floats.reshape(1), nullptr, &maxValue);
        floats /= std::max(1e-6, maxValue);
        const cv::Scalar mean(0.485, 0.456, 0.406), deviation(0.229, 0.224, 0.225);
        cv::subtract(floats, mean, floats);
        cv::divide(floats, deviation, floats);
        const cv::Mat blob = cv::dnn::blobFromImage(floats);   // NCHW, already scaled
        net.setInput(blob);
        cv::Mat output = net.forward();                         // the first output: d1, 1x1x320x320
        cv::Mat map(inputSize, inputSize, CV_32F, output.ptr<float>());
        double lo = 0, hi = 0;
        cv::minMaxLoc(map, &lo, &hi);
        cv::Mat normalized = (map - lo) / std::max(1e-6, hi - lo);
        cv::Mat full;
        cv::resize(normalized, full, cv::Size(width, height), 0, 0, cv::INTER_LINEAR);
        refineAlongEdges(full, rgb);
        // The model's transition band is wider than Apple Vision's edge (a halo of background shows through a cut-out):
        // a smoothstep over 0.25...0.75 keeps the edge antialiased but as tight as Vision's.
        cv::Mat soft(height, width, CV_32F, confidence);
        cv::Mat t = (full - 0.25) / 0.5;
        cv::min(cv::max(t, 0.0), 1.0, t);
        cv::Mat squared = t.mul(t);
        soft = squared.mul(3.0 - 2.0 * t);

        cv::Mat binary;
        cv::threshold(soft, binary, 0.5, 255, cv::THRESH_BINARY);
        binary.convertTo(binary, CV_8U);
        cv::Mat components, stats, centroids;
        const int count = cv::connectedComponentsWithStats(binary, components, stats, centroids, 8, CV_32S);
        // Largest first; specks under 0.2% of the picture are not subjects.
        std::vector<int> order;
        const int minimum = std::max(16, int(0.002 * double(width) * double(height)));
        for (int i = 1; i < count; ++i)
            if (stats.at<int>(i, cv::CC_STAT_AREA) >= minimum) order.push_back(i);
        std::sort(order.begin(), order.end(), [&](int a, int b) {
            return stats.at<int>(a, cv::CC_STAT_AREA) > stats.at<int>(b, cv::CC_STAT_AREA);
        });
        if (order.size() > 255) order.resize(255);
        std::vector<uint8_t> remap(size_t(std::max(count, 1)), 0);
        for (size_t k = 0; k < order.size(); ++k) remap[size_t(order[k])] = uint8_t(k + 1);
        for (int y = 0; y < height; ++y) {
            const int *row = components.ptr<int>(y);
            uint8_t *out = labels + size_t(y) * size_t(width);
            for (int x = 0; x < width; ++x) out[x] = remap[size_t(row[x])];
        }
        if (instance_count) *instance_count = int32_t(order.size());
        return 0;
    } catch (const cv::Exception &) {
        return -3;
    }
}

#else

extern "C" int32_t compositor_u2net_load(const char *) { return -2; }
extern "C" int32_t compositor_u2net_segment(const uint8_t *, int32_t, int32_t, uint8_t *, float *, int32_t *) { return -2; }

#endif
