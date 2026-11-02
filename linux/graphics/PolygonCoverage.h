#pragma once

#include <algorithm>
#include <cmath>
#include <vector>
#include <utility>

#if __has_include("include/effects/SkRuntimeEffect.h")
#include "include/effects/SkRuntimeEffect.h"
#include "include/core/SkBlender.h"
#else
#include <skia/effects/SkRuntimeEffect.h>
#include <skia/core/SkBlender.h>
#endif

// Device-space polygon area coverage for byte surfaces. The caller supplies
// Skia declarations; Skia retains responsibility for clipping, paint and compositing.
namespace polygon_coverage {
struct Point {
    double x, y;
};
struct Polygon {
    std::vector<Point> points;
};

static Polygon clip(const Polygon &input, int axis, double boundary, double sign) {
    Polygon output;
    for (size_t i = 0; i < input.points.size(); ++i) {
        const Point a = input.points[i], b = input.points[(i + 1) % input.points.size()];
        const double av = axis == 0 ? a.x : a.y, bv = axis == 0 ? b.x : b.y;
        const bool insideA = sign * (av - boundary) >= 0, insideB = sign * (bv - boundary) >= 0;
        if (insideA)
            output.points.push_back(a);
        if (insideA != insideB) {
            const double t = (boundary - av) / (bv - av);
            output.points.push_back({a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)});
        }
    }
    return output;
}

static double pixelArea(const Polygon &polygon, int x, int y) {
    auto p = clip(polygon, 0, x, 1);
    p = clip(p, 0, x + 1, -1);
    p = clip(p, 1, y, 1);
    p = clip(p, 1, y + 1, -1);
    double sum = 0;
    for (size_t i = 0; i < p.points.size(); ++i) {
        const auto a = p.points[i], b = p.points[(i + 1) % p.points.size()];
        // Local coordinates avoid losing precision for translated device pixels.
        sum += (a.x - x) * (b.y - y) - (b.x - x) * (a.y - y);
    }
    return std::min(1.0, std::abs(sum) / 2);
}

// Extrema of each edge chain occur at vertices. Their intersection over the
// clipped row identifies pixels completely inside a monotone polygon.
static std::pair<double, double> interiorInterval(const Polygon &row, double top, double bottom) {
    double minY = INFINITY, maxY = -INFINITY;
    for (auto p : row.points) {
        minY = std::min(minY, p.y);
        maxY = std::max(maxY, p.y);
    }
    if (minY > top || maxY < bottom)
        return {0, 0};
    double left = -INFINITY, right = INFINITY;
    for (auto level : row.points) {
        double sliceLeft = INFINITY, sliceRight = -INFINITY;
        for (size_t i = 0; i < row.points.size(); ++i) {
            const Point a = row.points[i], b = row.points[(i + 1) % row.points.size()];
            if (level.y < std::min(a.y, b.y) || level.y > std::max(a.y, b.y))
                continue;
            if (a.y == b.y) {
                sliceLeft = std::min({sliceLeft, a.x, b.x});
                sliceRight = std::max({sliceRight, a.x, b.x});
            } else {
                const double x = a.x + (level.y - a.y) * (b.x - a.x) / (b.y - a.y);
                sliceLeft = std::min(sliceLeft, x);
                sliceRight = std::max(sliceRight, x);
            }
        }
        left = std::max(left, sliceLeft);
        right = std::min(right, sliceRight);
    }
    return {left, right};
}

static bool draw(SkCanvas &canvas, const Polygon &polygon, const SkPaint &paint, SkBlendMode blendMode) {
    double left = INFINITY, top = INFINITY, right = -INFINITY, bottom = -INFINITY;
    for (auto p : polygon.points) {
        if (!std::isfinite(p.x) || !std::isfinite(p.y))
            return false;
        left = std::min(left, p.x);
        right = std::max(right, p.x);
        top = std::min(top, p.y);
        bottom = std::max(bottom, p.y);
    }
    const auto bounds = canvas.getDeviceClipBounds();
    left = std::max(left, double(bounds.left()));
    top = std::max(top, double(bounds.top()));
    right = std::min(right, double(bounds.right()));
    bottom = std::min(bottom, double(bounds.bottom()));
    if (left >= right || top >= bottom)
        return true;
    const int x0 = int(std::floor(left)), y0 = int(std::floor(top));
    const int width = int(std::ceil(right)) - x0, height = int(std::ceil(bottom)) - y0;
    // Bound temporary storage even when a document contains enormous coordinates.
    if (size_t(width) * height > 16000000)
        return false;
    auto data = SkData::MakeUninitialized(size_t(width) * height);
    if (!data)
        return false;
    auto *pixels = static_cast<uint8_t *>(data->writable_data());
    constexpr int tileSize = 16;
    const int tileColumns = (width + tileSize - 1) / tileSize;
    const int tileRows = (height + tileSize - 1) / tileSize;
    std::vector<uint8_t> occupiedTiles(size_t(tileColumns) * tileRows, 0);
    std::fill(pixels, pixels + size_t(width) * height, uint8_t(0));
    for (int y = 0; y < height; ++y) {
        // Limit work to this row's footprint rather than the diagonal's whole bounding box.
        auto row = clip(polygon, 1, y0 + y, 1);
        row = clip(row, 1, y0 + y + 1, -1);
        if (row.points.empty())
            continue;
        double rowLeft = right, rowRight = left;
        for (size_t i = 0; i < row.points.size(); ++i) {
            rowLeft = std::min(rowLeft, row.points[i].x);
            rowRight = std::max(rowRight, row.points[i].x);
        }
        const int begin = int(std::floor(std::clamp(rowLeft, double(x0), double(x0 + width)))) - x0;
        const int end = int(std::ceil(std::clamp(rowRight, double(x0), double(x0 + width)))) - x0;
        const auto interior = interiorInterval(row, y0 + y, y0 + y + 1);
        const int fullBegin =
            int(std::ceil(std::clamp(interior.first, double(x0 + begin), double(x0 + end)))) - x0;
        const int fullEnd =
            int(std::floor(std::clamp(interior.second, double(x0 + begin), double(x0 + end)))) - x0;
        if (fullBegin < fullEnd) {
            std::fill(pixels + size_t(y) * width + fullBegin, pixels + size_t(y) * width + fullEnd,
                      uint8_t(255));
            for (int tile = fullBegin / tileSize; tile <= (fullEnd - 1) / tileSize; ++tile)
                occupiedTiles[size_t(y / tileSize) * tileColumns + tile] = 1;
        }
        for (int x = begin; x < end; ++x) {
            if (x >= fullBegin && x < fullEnd) {
                x = fullEnd - 1;
                continue;
            }
            // Native opaque and floating-surface controls use 256 coverage steps,
            // clamped to the largest A8 value before source alpha is applied.
            const auto coverage = uint8_t(std::min(255.0, std::floor(pixelArea(row, x0 + x, y0 + y) * 256)));
            pixels[size_t(y) * width + x] = coverage;
            if (coverage)
                occupiedTiles[size_t(y / tileSize) * tileColumns + x / tileSize] = 1;
        }
    }
    // Fully covered tiles need no mask sampling. Partial tiles retain the exact
    // A8 clip, including copy/clear behavior at the path boundary.
    for (int ty = 0; ty < tileRows; ++ty)
        for (int tx = 0; tx < tileColumns; ++tx) {
            auto &state = occupiedTiles[size_t(ty) * tileColumns + tx];
            if (!state)
                continue;
            bool full = true;
            for (int y = ty * tileSize; y < std::min((ty + 1) * tileSize, height) && full; ++y)
                for (int x = tx * tileSize; x < std::min((tx + 1) * tileSize, width); ++x)
                    if (pixels[size_t(y) * width + x] != 255) {
                        full = false;
                        break;
                    }
            if (full)
                state = 2;
        }
    auto mask = SkImages::RasterFromData(SkImageInfo::MakeA8(width, height), data, width);
    if (!mask)
        return false;
    SkPaint fill = paint;
    fill.setStyle(SkPaint::kFill_Style);
    if (blendMode == SkBlendMode::kSrcOver) {
        // Byte source-over uses the full 255 denominator. The low-precision Skia
        // fast path can add another byte of error before coverage is applied.
        static auto sourceOver = [] {
            auto effect = SkRuntimeEffect::MakeForBlender(
                SkString("half4 main(half4 src, half4 dst) { "
                         "float4 s = floor(float4(src) * 255.0 + 0.5); "
                         "float4 d = floor(float4(dst) * 255.0 + 0.5); "
                         "return half4((s + floor((d * (255.0 - s.a) + 127.0) / 255.0)) / 255.0); }"));
            return effect.effect ? effect.effect->makeBlender(nullptr) : nullptr;
        }();
        if (!sourceOver)
            return false;
        fill.setBlender(sourceOver);
    }
    canvas.save();
    canvas.resetMatrix();
    canvas.translate(x0, y0);
    auto shader = mask->makeShader(SkTileMode::kDecal, SkTileMode::kDecal, SkSamplingOptions());
    // Clip shaders otherwise shade the diagonal's entire bounding rectangle.
    // Integer tile clips partition its coverage without touching a pixel twice.
    for (int y = 0; y < tileRows; ++y)
        for (int x = 0; x < tileColumns;) {
            if (!occupiedTiles[size_t(y) * tileColumns + x]) {
                ++x;
                continue;
            }
            const int state = occupiedTiles[size_t(y) * tileColumns + x];
            const int begin = x++;
            while (x < tileColumns && occupiedTiles[size_t(y) * tileColumns + x] == state)
                ++x;
            canvas.save();
            canvas.clipRect(SkRect::MakeXYWH(begin * tileSize, y * tileSize,
                                             std::min(x * tileSize, width) - begin * tileSize,
                                             std::min(tileSize, height - y * tileSize)),
                            SkClipOp::kIntersect, false);
            if (state == 1)
                canvas.clipShader(shader);
            canvas.drawPaint(fill);
            canvas.restore();
        }
    canvas.restore();
    return true;
}
} // namespace polygon_coverage
