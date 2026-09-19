import Foundation

/// Shared centerline for CPU and Vulkan, ported from the Metal stroke path.
enum BrushCenterline {
    static func segment(_ a: CGPoint, _ b: CGPoint) -> SIMD4<Float> {
        SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y))
    }

    /// Adaptive chord subdivision keeps the centerline within 0.2 document pixels
    /// of the spline. Straight movement requires just one segment even at 4K.
    static func curve(from start: CGPoint, to end: CGPoint, before: CGPoint, after: CGPoint) -> [SIMD4<Float>] {
        func knot(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint) -> CGFloat { t + max(0.0001, sqrt(hypot(b.x - a.x, b.y - a.y))) }
        func mix(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let wa = (tb - t) / (tb - ta), wb = (t - ta) / (tb - ta)
            return CGPoint(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb)
        }
        let t0: CGFloat = 0, t1 = knot(t0, before, start), t2 = knot(t1, start, end), t3 = knot(t2, end, after)
        func point(_ u: CGFloat) -> CGPoint {
            if u == 0 { return start }; if u == 1 { return end }
            let t = t1 + (t2 - t1) * u
            let a = mix(before, start, t0, t1, t), b = mix(start, end, t1, t2, t), c = mix(end, after, t2, t3, t)
            return mix(mix(a, b, t0, t2, t), mix(b, c, t1, t3, t), t1, t2, t)
        }
        var result: [SIMD4<Float>] = []
        func subdivide(_ a: CGPoint, _ b: CGPoint, _ lo: CGFloat, _ hi: CGFloat, _ depth: Int) {
            let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = dx * dx + dy * dy
            func error(_ p: CGPoint) -> CGFloat {
                let t = lengthSquared > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
                return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
            }
            let mid = (lo + hi) / 2, m = point(mid)
            let deviation = max(error(m), error(point((lo + mid) / 2)), error(point((mid + hi) / 2)))
            if deviation <= 0.2 || depth >= 10 { result.append(segment(a, b)); return }
            subdivide(a, m, lo, mid, depth + 1)
            subdivide(m, b, mid, hi, depth + 1)
        }
        subdivide(start, end, 0, 1, 0)
        return result
    }

}
