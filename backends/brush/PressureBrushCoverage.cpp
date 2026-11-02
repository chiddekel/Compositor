#include "BrushCoverageValidation.h"
#include <algorithm>

namespace {
float mix(float a, float b, float t) { return a + (b - a) * t; }
float along(float x, float y, const CompositorBrushSegment &s) {
    const float dx = s.x1 - s.x0, dy = s.y1 - s.y0;
    return std::clamp(((x - s.x0) * dx + (y - s.y0) * dy) / std::max(dx * dx + dy * dy, 1e-12f), 0.0f, 1.0f);
}
float distanceSquared(float x, float y, const CompositorBrushSegment &s, float t) {
    const float dx = x - mix(s.x0, s.x1, t), dy = y - mix(s.y0, s.y1, t);
    return dx * dx + dy * dy;
}
float coverage(float squared, float radius, const CompositorBrushUniforms &u) {
    const float distance = std::sqrt(squared);
    if (u.hardness >= 1) return std::clamp((radius - distance) / u.antialias_width + 0.5f, 0.0f, 1.0f);
    if (radius <= 0) return 0;
    const float t = std::clamp((distance / radius - u.hardness) / (1 - u.hardness), 0.0f, 1.0f);
    return std::max(0.0f, (std::exp(-2.5f * t * t) - std::exp(-2.5f)) / (1 - std::exp(-2.5f)));
}
float density(float squared, float radius, const CompositorBrushUniforms &u) {
    return -std::log(std::max(1 - coverage(squared, radius, u), 0.001f));
}
float segmentDensity(float x, float y, const CompositorBrushSegment &s, const CompositorBrushDynamics &d,
                     const CompositorBrushUniforms &u) {
    const float dx = s.x1 - s.x0, dy = s.y1 - s.y0, length = std::hypot(dx, dy);
    const float px = x - s.x0, py = y - s.y0;
    if (length < 1e-6f) return density(px * px + py * py, d.radius0, u);
    const float projection = (px * dx + py * dy) / length;
    const float ex = px - projection * dx / length, ey = py - projection * dy / length;
    const float perpendicular = ex * ex + ey * ey, radius = std::max(d.radius0, d.radius1);
    if (perpendicular >= radius * radius) return 0;
    const float reach = std::sqrt(radius * radius - perpendicular);
    const float lo = std::max(0.0f, projection - reach), hi = std::min(length, projection + reach);
    if (hi <= lo) return 0;
    const float midpoint = (lo + hi) * 0.5f, half = (hi - lo) * 0.5f;
    constexpr float nodes[] = {0.1834346425f, 0.5255324099f, 0.7966664774f, 0.9602898565f};
    constexpr float weights[] = {0.3626837834f, 0.3137066459f, 0.2223810345f, 0.1012285363f};
    float integral = 0;
    for (int i = 0; i < 4; ++i) {
        const float a = midpoint - half * nodes[i] - projection, b = midpoint + half * nodes[i] - projection;
        const float ra = mix(d.radius0, d.radius1, std::clamp((projection + a) / length, 0.0f, 1.0f));
        const float rb = mix(d.radius0, d.radius1, std::clamp((projection + b) / length, 0.0f, 1.0f));
        integral += weights[i] * (density(perpendicular + a * a, ra, u) + density(perpendicular + b * b, rb, u));
    }
    return integral * half / u.spacing;
}
}

extern "C" int compositor_brush_pressure_cpu(const CompositorBrushUniforms *uniforms,
    const CompositorBrushSegment *segments, const CompositorBrushDynamics *dynamics, size_t count,
    const float *permanent, const float *cap, size_t pixels, float *next, float *nextCap, uint8_t *preview) {
    if (!validBrush(uniforms, segments, count, permanent, pixels, next, preview) || (count && !dynamics)
        || (cap && (!nextCap || nextCap == cap)) || (!cap && nextCap)) return -1;
    const auto &u = *uniforms;
    for (size_t i = 0; i < count; ++i) {
        const auto &d = dynamics[i];
        for (float r : {d.radius0, d.radius1}) if (!std::isfinite(r) || r < 0 || r > u.radius) return -1;
        for (float s : {d.strength0, d.strength1}) if (!(s >= 0 && s <= 1)) return -1;
    }
    if (cap) for (size_t i = 0; i < pixels; ++i) if (!(cap[i] >= 0 && cap[i] <= 1)) return -1;
    for (uint32_t row = 0; row < u.height; ++row) for (uint32_t column = 0; column < u.width; ++column) {
        const size_t index = size_t(row) * u.width + column;
        const float x = u.origin_x + (column + 0.5f) * u.a + (row + 0.5f) * u.c;
        const float y = u.origin_y + (column + 0.5f) * u.b + (row + 0.5f) * u.d;
        float value = permanent[index], tail = 0, settledCap = cap ? cap[index] : 1, tailCap = 0;
        next[index] = value;
        if (cap) nextCap[index] = settledCap;
        preview[index] = 0;
        if (x < 0 || y < 0 || x >= u.canvas_width || y >= u.canvas_height) continue;
        for (size_t i = 0; i < count; ++i) {
            const auto &s = segments[i]; const auto &d = dynamics[i];
            const float t = along(x, y, s), squared = distanceSquared(x, y, s, t);
            const float radius = mix(d.radius0, d.radius1, t), strength = mix(d.strength0, d.strength1, t);
            float &destination = i < u.settled_count ? value : tail;
            if (u.hardness >= 1) destination = std::max(destination, strength * coverage(squared, radius, u));
            else {
                destination += segmentDensity(x, y, s, d, u);
                if (cap && squared < radius * radius) {
                    float &limit = i < u.settled_count ? settledCap : tailCap;
                    limit = std::max(limit, strength);
                }
            }
        }
        next[index] = u.hardness >= 1 ? value : std::min(value, 20.0f);
        if (cap) nextCap[index] = settledCap;
        const float result = u.hardness >= 1 ? std::max(value, tail)
            : std::max(settledCap, tailCap) * (1 - std::exp(-std::min(value + tail, 20.0f)));
        preview[index] = uint8_t(std::clamp(std::round(255 * result), 0.0f, 255.0f));
    }
    return 0;
}
