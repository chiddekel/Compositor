#pragma once

#include "PolygonCoverage.h"

namespace curve_coverage {
using polygon_coverage::Point;
using polygon_coverage::Polygon;

// Two monotone edge chains and no self-intersections give a single covered
// interval at each height. Unsupported paths fall back before the canvas changes.
static bool supportedPolygon(Polygon &polygon) {
    auto &p = polygon.points;
    p.erase(std::unique(p.begin(), p.end(), [](Point a, Point b) { return a.x == b.x && a.y == b.y; }),
            p.end());
    if (p.size() > 1 && p.front().x == p.back().x && p.front().y == p.back().y)
        p.pop_back();
    if (p.size() < 3)
        return false;
    int previous = 0, first = 0, changes = 0;
    for (size_t i = 0; i < p.size(); ++i) {
        if (!std::isfinite(p[i].x) || !std::isfinite(p[i].y))
            return false;
        const double dy = p[(i + 1) % p.size()].y - p[i].y;
        const int sign = dy > 0 ? 1 : dy < 0 ? -1 : 0;
        if (!sign)
            continue;
        if (!first)
            first = sign;
        if (previous && previous != sign)
            ++changes;
        previous = sign;
    }
    if (previous != first)
        ++changes;
    if (changes != 2)
        return false;
    auto cross = [](Point a, Point b, Point c) {
        return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    };
    for (size_t i = 0; i < p.size(); ++i) {
        const Point a = p[i], b = p[(i + 1) % p.size()];
        for (size_t j = i + 2; j < p.size(); ++j) {
            if ((j + 1) % p.size() == i)
                continue;
            const Point c = p[j], d = p[(j + 1) % p.size()];
            if (std::max(a.x, b.x) < std::min(c.x, d.x) || std::max(c.x, d.x) < std::min(a.x, b.x) ||
                std::max(a.y, b.y) < std::min(c.y, d.y) || std::max(c.y, d.y) < std::min(a.y, b.y))
                continue;
            const double abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a),
                         cdB = cross(c, d, b);
            if (((abC <= 0 && abD >= 0) || (abD <= 0 && abC >= 0)) &&
                ((cdA <= 0 && cdB >= 0) || (cdB <= 0 && cdA >= 0)))
                return false;
        }
    }
    return true;
}

// Device-space adaptive subdivision reproduces default native curve coverage.
// This is independent of CGPath.flattened(threshold:), which uses uniform steps.
static Point midpoint(Point a, Point b) { return {(a.x + b.x) / 2, (a.y + b.y) / 2}; }
static bool quad(Polygon &p, Point a, Point b, Point c, int depth = 0) {
    if (p.points.size() > 4096 || depth > 20)
        return false;
    const double error = .25 * std::max(std::abs(a.x - 2 * b.x + c.x), std::abs(a.y - 2 * b.y + c.y));
    if (error <= .05) {
        p.points.push_back(c);
        return true;
    }
    auto ab = midpoint(a, b), bc = midpoint(b, c), m = midpoint(ab, bc);
    return quad(p, a, ab, m, depth + 1) && quad(p, m, bc, c, depth + 1);
}
static bool cubic(Polygon &p, Point a, Point b, Point c, Point d, int depth = 0) {
    if (p.points.size() > 4096 || depth > 20)
        return false;
    const double error = .75 * std::max({std::abs(a.x - 2 * b.x + c.x), std::abs(a.y - 2 * b.y + c.y),
                                         std::abs(b.x - 2 * c.x + d.x), std::abs(b.y - 2 * c.y + d.y)});
    if (error <= .05) {
        p.points.push_back(d);
        return true;
    }
    auto ab = midpoint(a, b), bc = midpoint(b, c), cd = midpoint(c, d), abc = midpoint(ab, bc),
         bcd = midpoint(bc, cd), m = midpoint(abc, bcd);
    return cubic(p, a, ab, abc, m, depth + 1) && cubic(p, m, bcd, cd, d, depth + 1);
}
static bool draw(SkCanvas &canvas, const SkPath &path, const SkPaint &paint, SkBlendMode blendMode) {
    if (!paint.isAntiAlias() || path.isInverseFillType() || canvas.getTotalMatrix().hasPerspective())
        return false;
    Polygon polygon;
    const auto matrix = canvas.getTotalMatrix();
    auto map = [&](SkPoint p) {
        return Point{
            matrix.getScaleX() * double(p.x()) + matrix.getSkewX() * double(p.y()) + matrix.getTranslateX(),
            matrix.getSkewY() * double(p.x()) + matrix.getScaleY() * double(p.y()) + matrix.getTranslateY()};
    };
    bool started = false, curved = false;
    auto iter = path.iter();
    while (auto rec = iter.next()) {
        switch (rec->fVerb) {
        case SkPathVerb::kMove:
            if (started)
                return false;
            started = true;
            polygon.points.push_back(map(rec->fPoints[0]));
            break;
        case SkPathVerb::kLine:
            polygon.points.push_back(map(rec->fPoints[1]));
            break;
        case SkPathVerb::kQuad:
            curved = true;
            if (!quad(polygon, map(rec->fPoints[0]), map(rec->fPoints[1]), map(rec->fPoints[2])))
                return false;
            break;
        case SkPathVerb::kCubic:
            curved = true;
            if (!cubic(polygon, map(rec->fPoints[0]), map(rec->fPoints[1]), map(rec->fPoints[2]),
                       map(rec->fPoints[3])))
                return false;
            break;
        case SkPathVerb::kConic:
            return false;
        case SkPathVerb::kClose:
            break;
        }
    }
    if (!curved || polygon.points.size() < 3)
        return false;
    if (!supportedPolygon(polygon))
        return false;
    return polygon_coverage::draw(canvas, polygon, paint, blendMode);
}
} // namespace curve_coverage
