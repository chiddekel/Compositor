#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

// Core Graphics high-quality minification, independent of paint and canvas state.
// The caller supplies Skia declarations and selects the destination dimensions.
namespace image_sampling {
struct Tap {
    int index;
    double weight;
};
using Contributions = std::vector<std::vector<Tap>>;

static double lanczos2(double x) {
    x = std::abs(x);
    if (x >= 2)
        return 0;
    if (x == 0)
        return 1;
    constexpr double pi = 3.1415926535897932384626433832795;
    return std::sin(pi * x) * std::sin(pi * x / 2) / (pi * pi * x * x / 2);
}

static Contributions contributions(int source, int destination) {
    Contributions result(destination);
    if (source == destination) {
        for (int i = 0; i < destination; ++i)
            result[i].push_back({i, 1});
        return result;
    }
    const double scale = double(source - 1) / (destination - 1);
    for (int i = 0; i < destination; ++i) {
        const double position = i * scale;
        const int nearest = int(std::floor(position + .5));
        const int64_t first = int64_t(std::ceil(position - 2 * scale));
        const int64_t last = int64_t(std::floor(position + 2 * scale));
        double total = 0;
        for (int64_t tap = first; tap <= last; ++tap) {
            // Native captures fix the nearest tap at one before normalization,
            // even when its distance from the mapped pixel center is nonzero.
            const double weight = tap == nearest ? 1 : lanczos2((tap - position) / scale);
            result[i].push_back({int(std::clamp<int64_t>(tap, 0, source - 1)), weight});
            total += weight;
        }
        for (auto &tap : result[i])
            tap.weight /= total;
    }
    return result;
}

static sk_sp<SkImage> minify(const sk_sp<SkImage> &image, int width, int height,
                             SkColorType destinationType) {
    const int sourceWidth = image->width(), sourceHeight = image->height();
    if (width == sourceWidth && height == sourceHeight)
        return image;
    // One-pixel destinations need separate native geometry controls.
    if (width < 2 || height < 2 || width > sourceWidth || height > sourceHeight)
        return nullptr;
    const bool byteIntermediate =
        image->colorType() == kRGBA_8888_SkColorType && destinationType == kRGBA_8888_SkColorType;
    const auto horizontal = contributions(sourceWidth, width);
    const auto vertical = contributions(sourceHeight, height);
    std::vector<float> intermediate(size_t(width) * sourceHeight * 4);
    constexpr int chunk = 64;
    std::vector<float> rows(size_t(sourceWidth) * chunk * 4);
    const auto rowInfo =
        SkImageInfo::Make(sourceWidth, 1, kRGBA_F32_SkColorType, kPremul_SkAlphaType, image->refColorSpace());
    for (int y = 0; y < sourceHeight; y += chunk) {
        const int count = std::min(chunk, sourceHeight - y);
        if (!image->readPixels(nullptr, rowInfo.makeWH(sourceWidth, count), rows.data(),
                               size_t(sourceWidth) * 16, 0, y))
            return nullptr;
        for (int r = 0; r < count; ++r) {
            const float *source = rows.data() + size_t(r) * sourceWidth * 4;
            float *target = intermediate.data() + size_t(y + r) * width * 4;
            for (int x = 0; x < width; ++x) {
                double value[4] = {};
                for (const auto &tap : horizontal[x])
                    for (int c = 0; c < 4; ++c)
                        value[c] += tap.weight * source[size_t(tap.index) * 4 + c];
                for (int c = 0; c < 4; ++c) {
                    // Byte captures round the horizontal intermediate before the vertical pass.
                    const double v = byteIntermediate
                                         ? std::clamp(std::floor(value[c] * 255 + .5), 0.0, 255.0) / 255
                                         : value[c];
                    target[size_t(x) * 4 + c] = float(v);
                }
                if (byteIntermediate)
                    for (int c = 0; c < 3; ++c)
                        target[size_t(x) * 4 + c] =
                            std::min(target[size_t(x) * 4 + c], target[size_t(x) * 4 + 3]);
            }
        }
    }
    auto data = SkData::MakeUninitialized(size_t(width) * height * 16);
    if (!data)
        return nullptr;
    auto *output = static_cast<float *>(data->writable_data());
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x) {
            double value[4] = {};
            for (const auto &tap : vertical[y]) {
                const float *source = intermediate.data() + (size_t(tap.index) * width + x) * 4;
                for (int c = 0; c < 4; ++c)
                    value[c] += tap.weight * source[c];
            }
            float *target = output + (size_t(y) * width + x) * 4;
            if (byteIntermediate)
                for (int c = 0; c < 4; ++c)
                    value[c] = std::clamp(std::floor(value[c] * 255 + .5), 0.0, 255.0) / 255;
            for (int c = 0; c < 3; ++c)
                target[c] = float(byteIntermediate ? std::min(value[c], value[3]) : value[c]);
            // Native float surfaces preserve negative/HDR color, but clamp alpha.
            target[3] = float(std::clamp(value[3], 0.0, 1.0));
        }
    // Native float32 captures repeat the final pixel from its left neighbor when
    // either axis is reduced. Byte draws and 1:1 copies do not.
    if (image->colorType() == kRGBA_F32_SkColorType && destinationType == kRGBA_F32_SkColorType &&
        (width < sourceWidth || height < sourceHeight)) {
        float *last = output + (size_t(width) * height - 1) * 4;
        std::copy(last - 4, last, last);
    }
    const auto info =
        SkImageInfo::Make(width, height, kRGBA_F32_SkColorType, kPremul_SkAlphaType, image->refColorSpace());
    return SkImages::RasterFromData(info, std::move(data), size_t(width) * 16);
}
} // namespace image_sampling
