#pragma once

#include "PolygonCoverage.h"

// Native area coverage for sufficiently wide straight strokes.
namespace straight_stroke_coverage {
using polygon_coverage::Point;
using polygon_coverage::Polygon;

static bool draw(SkCanvas &canvas, const SkPath &path, const SkPaint &paint, SkBlendMode blendMode) {
    SkPoint endpoints[2];
    if (!paint.isAntiAlias() || !path.isLine(endpoints) || paint.getStrokeWidth() <= 0 ||
        paint.getStrokeCap() == SkPaint::kRound_Cap || canvas.getTotalMatrix().hasPerspective())
        return false;
    const double dx = endpoints[1].x() - endpoints[0].x(), dy = endpoints[1].y() - endpoints[0].y();
    const double length = std::hypot(dx, dy), half = paint.getStrokeWidth() / 2.0;
    if (!std::isfinite(length) || !std::isfinite(half))
        return false;
    if (length == 0)
        return false;
    const double nx = -dy * half / length, ny = dx * half / length;
    const double ex = paint.getStrokeCap() == SkPaint::kSquare_Cap ? dx * half / length : 0;
    const double ey = paint.getStrokeCap() == SkPaint::kSquare_Cap ? dy * half / length : 0;
    Polygon polygon;
    polygon.points.resize(4);
    polygon.points[0] = {endpoints[0].x() - ex + nx, endpoints[0].y() - ey + ny};
    polygon.points[1] = {endpoints[0].x() - ex - nx, endpoints[0].y() - ey - ny};
    polygon.points[2] = {endpoints[1].x() + ex - nx, endpoints[1].y() + ey - ny};
    polygon.points[3] = {endpoints[1].x() + ex + nx, endpoints[1].y() + ey + ny};
    const auto matrix = canvas.getTotalMatrix();
    double left = INFINITY, top = INFINITY, right = -INFINITY, bottom = -INFINITY;
    for (int i = 0; i < polygon.points.size(); ++i) {
        auto &p = polygon.points[i];
        const Point before = p;
        p = {matrix.getScaleX() * before.x + matrix.getSkewX() * before.y + matrix.getTranslateX(),
             matrix.getSkewY() * before.x + matrix.getScaleY() * before.y + matrix.getTranslateY()};
        if (!std::isfinite(p.x) || !std::isfinite(p.y))
            return false;
        left = std::min(left, p.x);
        top = std::min(top, p.y);
        right = std::max(right, p.x);
        bottom = std::max(bottom, p.y);
    }
    const double deviceLength = std::hypot(matrix.getScaleX() * dx + matrix.getSkewX() * dy,
                                           matrix.getSkewY() * dx + matrix.getScaleY() * dy);
    const double determinant =
        double(matrix.getScaleX()) * matrix.getScaleY() - double(matrix.getSkewX()) * matrix.getSkewY();
    // Native narrow strokes use a different coverage rule. Keep those and round
    // caps on the existing renderer until independently captured controls match.
    const double deviceWidth = paint.getStrokeWidth() * std::abs(determinant) * length / deviceLength;
    if (!std::isfinite(deviceWidth) || deviceWidth < 2)
        return false;
    return polygon_coverage::draw(canvas, polygon, paint, blendMode);
}
} // namespace straight_stroke_coverage
