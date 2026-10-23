#include "BrushCoverageValidation.h"
#include <algorithm>
#include <limits>

namespace {
float coverage(float distanceSquared, const CompositorBrushUniforms &u) {
    const float distance = std::sqrt(distanceSquared);
    if (u.hardness >= 1) return std::clamp((u.radius - distance) / u.antialias_width + 0.5f, 0.0f, 1.0f);
    const float t = std::clamp((distance / u.radius - u.hardness) / (1 - u.hardness), 0.0f, 1.0f);
    return std::max(0.0f, (std::exp(-2.5f*t*t) - std::exp(-2.5f)) / (1 - std::exp(-2.5f)));
}
float distanceSquared(float x, float y, const CompositorBrushSegment &s) {
    const float dx = s.x1-s.x0, dy = s.y1-s.y0;
    const float t = std::clamp(((x-s.x0)*dx+(y-s.y0)*dy) / std::max(dx*dx+dy*dy,1e-12f),0.0f,1.0f);
    const float px = x-(s.x0+t*dx), py = y-(s.y0+t*dy);
    return px*px+py*py;
}
float density(float distanceSquared, const CompositorBrushUniforms &u) {
    // Soft tips have a flat center and zero support outside the radius. Avoid exp/log
    // for these exact values at the eight quadrature samples of every covered pixel.
    if (distanceSquared >= u.radius * u.radius) return 0;
    const float core = u.radius * u.hardness;
    if (distanceSquared <= core * core) return -std::log(0.001f);
    return -std::log(std::max(1 - coverage(distanceSquared,u),0.001f));
}
float segmentDensity(float x, float y, const CompositorBrushSegment &s, const CompositorBrushUniforms &u) {
    const float dx = s.x1-s.x0, dy = s.y1-s.y0, length = std::sqrt(dx*dx+dy*dy);
    const float px = x-s.x0, py = y-s.y0;
    if (length < 1e-6f) return density(px*px+py*py,u);
    const float projection = (px*dx+py*dy)/length;
    const float ex = px-projection*dx/length, ey = py-projection*dy/length;
    const float perpendicular = ex*ex+ey*ey;
    if (perpendicular >= u.radius*u.radius) return 0;
    const float reach = std::sqrt(u.radius*u.radius-perpendicular);
    const float lo = std::max(0.0f,projection-reach), hi = std::min(length,projection+reach);
    if (hi <= lo) return 0;
    const float middle = (lo+hi)*0.5f, half = (hi-lo)*0.5f;
    constexpr float nodes[] = {0.1834346425f,0.5255324099f,0.7966664774f,0.9602898565f};
    constexpr float weights[] = {0.3626837834f,0.3137066459f,0.2223810345f,0.1012285363f};
    float integral = 0;
    for (int i=0;i<4;++i) {
        const float a = middle-half*nodes[i]-projection, b = middle+half*nodes[i]-projection;
        integral += weights[i]*(density(perpendicular+a*a,u)+density(perpendicular+b*b,u));
    }
    return integral*half/u.spacing;
}
}
extern "C" int compositor_brush_cpu(const CompositorBrushUniforms *uniforms,
    const CompositorBrushSegment *segments, size_t count,
    const float *permanent, size_t pixels, float *next, uint8_t *preview) {
    return compositor_brush_cpu_rows(uniforms, segments, count, permanent, pixels, next, preview,
                                     0, uniforms ? uniforms->height : 0);
}
extern "C" int compositor_brush_cpu_rows(const CompositorBrushUniforms *uniforms,
    const CompositorBrushSegment *segments, size_t count,
    const float *permanent, size_t pixels, float *next, uint8_t *preview,
    uint32_t firstRow, uint32_t endRow) {
    if (!validBrush(uniforms,segments,count,permanent,pixels,next,preview)) return -1;
    const auto &u = *uniforms;
    if (firstRow > endRow || endRow > u.height) return -1;
    // Most pointer updates cover only a small part of a tile. Outside this support, only the old
    // permanent coverage contributes; rebuilding it also removes the previous provisional tail.
    float minX = std::numeric_limits<float>::infinity(), minY = minX;
    float maxX = -minX, maxY = -minY;
    const float reach = u.radius + (u.hardness >= 1 ? u.antialias_width * 0.5f : 0);
    for (size_t j=0;j<count;++j) {
        const auto &s = segments[j];
        minX = std::min(minX,std::min(s.x0,s.x1)-reach);
        minY = std::min(minY,std::min(s.y0,s.y1)-reach);
        maxX = std::max(maxX,std::max(s.x0,s.x1)+reach);
        maxY = std::max(maxY,std::max(s.y0,s.y1)+reach);
    }
    const auto pixel = [&](uint32_t x, uint32_t y) {
        const size_t i = size_t(y)*u.width+x;
        const float px = u.origin_x+(float(x)+0.5f)*u.a+(float(y)+0.5f)*u.c;
        const float py = u.origin_y+(float(x)+0.5f)*u.b+(float(y)+0.5f)*u.d;
        next[i] = permanent[i]; preview[i] = 0;
        if (px<0 || py<0 || px>=u.canvas_width || py>=u.canvas_height) return;
        // Hard coverage accumulates by max. A fully covered pixel cannot change with another
        // settled segment or provisional tail (notably the many overlapping dabs at warp commit).
        if (u.hardness >= 1 && permanent[i] == 1) { preview[i] = 255; return; }
        // Soft coverage stores density, capped at 20. Further deposition cannot change
        // either that cap or its fully opaque 8-bit preview.
        if (u.hardness < 1 && permanent[i] == 20) { preview[i] = 255; return; }
        float value;
        if (px<minX || px>maxX || py<minY || py>maxY) {
            value = u.hardness >= 1 ? permanent[i]
                : permanent[i] == 0 ? 0 : 1-std::exp(-permanent[i]);
        } else if (u.hardness >= 1) {
            float settled = std::numeric_limits<float>::infinity(), tail = settled;
            for (uint32_t j=0;j<u.settled_count;++j) settled = std::min(settled,distanceSquared(px,py,segments[j]));
            for (uint32_t j=u.settled_count;j<count;++j) tail = std::min(tail,distanceSquared(px,py,segments[j]));
            next[i] = std::max(permanent[i],coverage(settled,u));
            value = std::max(next[i],coverage(tail,u));
        } else {
            float settled = permanent[i], tail = 0;
            for (uint32_t j=0;j<u.settled_count;++j) settled += segmentDensity(px,py,segments[j],u);
            for (uint32_t j=u.settled_count;j<count;++j) tail += segmentDensity(px,py,segments[j],u);
            next[i] = std::min(settled,20.0f);
            value = 1-std::exp(-std::min(settled+tail,20.0f));
        }
        preview[i] = uint8_t(std::clamp(std::round(255*value),0.0f,255.0f));
    };
    // Axis-aligned tile wholly on the canvas (the usual case): outside the segments' support, a pixel only carries its
    // permanent coverage over, exactly as `pixel` does there. Those runs are copied without the per-pixel geometry, so
    // an update costs the dab's area rather than the whole 256x256 tile (a warp commit replays hundreds of updates).
    const auto inside = [&](float px, float py) { return px>=0 && py>=0 && px<u.canvas_width && py<u.canvas_height; };
    const float x0c = u.origin_x+0.5f*u.a, x1c = u.origin_x+(float(u.width)-0.5f)*u.a;
    const float y0c = u.origin_y+0.5f*u.d, y1c = u.origin_y+(float(u.height)-0.5f)*u.d;
    if (u.b == 0 && u.c == 0 && u.a != 0 && u.d != 0 && inside(x0c,y0c) && inside(x1c,y1c)) {
        // Local columns/rows whose centers may fall in [minX,maxX]x[minY,maxY], widened by a pixel each side.
        const auto span = [](float lo, float hi, float origin, float scale, uint32_t size) {
            float a = (lo-origin)/scale-0.5f, b = (hi-origin)/scale-0.5f;
            if (a > b) std::swap(a,b);
            if (!(b >= -1) || !(a <= float(size))) return std::pair<uint32_t,uint32_t>{0,0};
            const uint32_t first = uint32_t(std::max(0.0f,std::floor(a)-1));
            const uint32_t end = uint32_t(std::min(float(size),std::ceil(b)+2));
            return std::pair<uint32_t,uint32_t>{first,std::max(first,end)};
        };
        const auto [sx0,sx1] = count ? span(minX,maxX,u.origin_x,u.a,u.width) : std::pair<uint32_t,uint32_t>{0,0};
        const auto [sy0,sy1] = count ? span(minY,maxY,u.origin_y,u.d,u.height) : std::pair<uint32_t,uint32_t>{0,0};
        const auto carry = [&](size_t i, size_t end) {
            std::copy(permanent+i,permanent+end,next+i);
            for (;i<end;++i) {
                const float p = permanent[i];
                if (p == 0) { preview[i] = 0; continue; }
                if (u.hardness >= 1 ? p == 1 : p == 20) { preview[i] = 255; continue; }
                const float value = u.hardness >= 1 ? p : 1-std::exp(-p);
                preview[i] = uint8_t(std::clamp(std::round(255*value),0.0f,255.0f));
            }
        };
        for (uint32_t y=firstRow;y<endRow;++y) {
            const size_t row = size_t(y)*u.width;
            if (y < sy0 || y >= sy1 || sx0 >= sx1) { carry(row,row+u.width); continue; }
            carry(row,row+sx0);
            for (uint32_t x=sx0;x<sx1;++x) pixel(x,y);
            carry(row+sx1,row+u.width);
        }
        return 0;
    }
    for (uint32_t y=firstRow;y<endRow;++y) for (uint32_t x=0;x<u.width;++x) pixel(x,y);
    return 0;
}
