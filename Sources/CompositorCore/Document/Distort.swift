// Portable port of Compositor/Document/Distort.swift's perspective geometry (file-map
// tier: "Keep logic; replace Apple operations"). Ported verbatim: `DistortWarp.corners(of:)`,
// `isUsable(_:)`, `homography(_:)`, `imageCorners(_:_:_:)`, and `carried(_:by:to:)` —
// the corner placement, convexity check, homography solve, flip-aware image-corner
// mapping, and placement-carry math. All pure `[CGPoint]` / `LayerTransform` /
// `CGAffineTransform` geometry.
//
// Omitted (raster + CGPath milestone):
//   - `DistortWarp.warp`/`warpTrimmed`/`warpMask` — resample pixels through the
//     homography via `CIImage(CIPerspectiveTransform)` / `CGContext`. The Skia/CPU
//     perspective resample is the raster milestone.
//   - `DistortWarp.mapPath` — carries a `CGPath` outline through the warp; `CGPath`
//     (and `applyWithBlock`/Bézier elements) is not on Linux. `PortablePath` today
//     covers rectangle/ellipse/roundedRect/polygon; arbitrary Bézier path carry is
//     the path-raster milestone.
//   - `DistortPreviewCache` and the `EditorSession` distort preview/commit helpers
//     (hold `CGImage`, drive `ImageLayer`/`LayerMask`/`ImportedImage` state).
//
// SOLID: the geometry keeps its responsibility and contract (corner placement,
// validity, and the unit-square→quad homography); the Apple API surface (CIImage
// resample, CGPath carry) is exchanged. The macOS original stays the source of truth.

import Foundation

nonisolated enum DistortWarp {
    /// The transform's corners in handle order: top-left, top-right, bottom-right, bottom-left.
    static func corners(of transform: LayerTransform) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(transform.point)
    }

    /// Four finite corners making a convex, non-degenerate shape; a twisted (bow-tie) or collapsed
    /// shape has no sensible warp and is refused.
    static func isUsable(_ corners: [CGPoint]) -> Bool {
        guard corners.count == 4,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else { return false }
        var sign: CGFloat = 0
        for index in 0..<4 {
            let a = corners[index], b = corners[(index + 1) % 4], c = corners[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 0.01 else { return false }
            if sign == 0 { sign = cross < 0 ? -1 : 1 } else if (cross < 0) != (sign < 0) { return false }
        }
        return true
    }

    /// The perspective mapping of the unit square (corners in `corners(of:)` order) onto `c`.
    static func homography(_ c: [CGPoint]) -> (CGPoint) -> CGPoint {
        let sx = c[0].x - c[1].x + c[2].x - c[3].x, sy = c[0].y - c[1].y + c[2].y - c[3].y
        var g: CGFloat = 0, h: CGFloat = 0
        if abs(sx) > 1e-9 || abs(sy) > 1e-9 {
            let dx1 = c[1].x - c[2].x, dx2 = c[3].x - c[2].x, dy1 = c[1].y - c[2].y, dy2 = c[3].y - c[2].y
            let den = dx1 * dy2 - dx2 * dy1
            if abs(den) > 1e-12 {
                g = (sx * dy2 - dx2 * sy) / den
                h = (dx1 * sy - sx * dy1) / den
            }
        }
        let a = c[1].x - c[0].x + g * c[1].x, b = c[3].x - c[0].x + h * c[3].x, x0 = c[0].x
        let d = c[1].y - c[0].y + g * c[1].y, e = c[3].y - c[0].y + h * c[3].y, y0 = c[0].y
        return { p in
            let w = g * p.x + h * p.y + 1
            return CGPoint(x: (a * p.x + b * p.y + x0) / w, y: (d * p.x + e * p.y + y0) / w)
        }
    }

    /// Where each corner of the image's own pixels lands: a flipped layer shows its pixels
    /// mirrored, so they go to the opposite corners of the shape.
    static func imageCorners(_ corners: [CGPoint], flipX: Bool, flipY: Bool)
        -> (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        func corner(_ x: Int, _ y: Int) -> CGPoint {
            let u = flipX ? 1 - x : x, v = flipY ? 1 - y : y
            return corners[[0, 1, 3, 2][v * 2 + u]]
        }
        return (corner(0, 0), corner(1, 0), corner(1, 1), corner(0, 1))
    }

    /// Corners of `placement` carried through the warp of `transform` onto `corners`: where a mask
    /// placed apart from its layer should land once the layer is distorted.
    ///
    /// Note: the concatenation chain below is verbatim from macOS CoreGraphics. It shares the
    /// `CGAffineTransform.concatenating` convention that `BrushRaster.pixelToDocument`/`unitToDocument`
    /// rely on; the carried output is pinned against real macOS distort behavior at the raster
    /// milestone (the distort preview/commit that calls this), not by a unit test.
    static func carried(_ placement: LayerTransform, by transform: LayerTransform, to corners: [CGPoint]) -> [CGPoint] {
        let toUnit = CGAffineTransform(translationX: -0.5, y: -0.5)
            .concatenating(CGAffineTransform(scaleX: transform.size.width, y: transform.size.height))
            .concatenating(CGAffineTransform(rotationAngle: transform.radians))
            .concatenating(CGAffineTransform(translationX: transform.center.x, y: transform.center.y)).inverted()
        let map = homography(corners)
        return self.corners(of: placement).map { map($0.applying(toUnit)) }
    }
}