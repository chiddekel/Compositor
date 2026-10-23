#pragma once
#include "include/CompositorBrushBackend.h"
#include <cmath>
#include <initializer_list>
inline bool validBrush(const CompositorBrushUniforms *u, const CompositorBrushSegment *segments,
                       size_t count, const float *permanent, size_t pixels, float *next, uint8_t *preview) {
    if (!u || !permanent || !next || !preview || next == permanent || !u->width || !u->height ||
        u->width > 256 || u->height > 256 || pixels != size_t(u->width) * u->height ||
        count != u->segment_count || count > 2048 || u->settled_count > count || (count && !segments)) return false;
    const float values[] = {u->a,u->b,u->c,u->d,u->origin_x,u->origin_y,u->radius,u->hardness,
        u->canvas_width,u->canvas_height,u->antialias_width,u->spacing};
    for (float v : values) if (!std::isfinite(v) || std::abs(v) > 1e9f) return false;
    // BrushStroke permits internal tips up to 2100 px; Smudge/Liquify commit wider than the 2000 px UI limit.
    if (u->radius <= 0 || u->radius > 1050 || u->hardness < 0 || u->hardness > 1 ||
        u->canvas_width <= 0 || u->canvas_height <= 0 || u->antialias_width < 0.001f || u->spacing < 0.25f) return false;
    for (size_t i = 0; i < count; ++i) {
        const auto &s = segments[i];
        for (float v : {s.x0,s.y0,s.x1,s.y1}) if (!std::isfinite(v) || std::abs(v) > 1e7f) return false;
    }
    // Finite and within [0, cap]: NaN fails both comparisons and an infinity fails one, so no isfinite is needed. No
    // early exit, so the scan vectorizes (it runs on every coverage update of a 256x256 tile).
    const float cap = u->hardness >= 1 ? 1 : 20;
    unsigned inRange = 1;
    for (size_t i = 0; i < pixels; ++i) inRange &= unsigned(permanent[i] >= 0) & unsigned(permanent[i] <= cap);
    return inRange != 0;
}
