// Portable port of Compositor/Document/Distort.swift's perspective geometry and resample (file-map
// tier: "Keep logic; replace Apple operations"). Ported verbatim: `DistortWarp.corners(of:)`,
// `isUsable(_:)`, `homography(_:)`, `imageCorners(_:_:_:)`, and `carried(_:by:to:)` —
// the corner placement, convexity check, homography solve, flip-aware image-corner
// mapping, and placement-carry math. All pure `[CGPoint]` / `LayerTransform` /
// `CGAffineTransform` geometry.
//
// The raster milestone: `warp`/`warpTrimmed`/`warpMask` resample pixels — and masks — through the
// homography by inverse-mapping each output pixel and bilinear-sampling, replacing macOS
// `CIImage(CIPerspectiveTransform)`; pixels whose extent straddles the quad's edge get 2 × 2
// subpixel coverage so the boundary matches CG's rasterization. `warpTrimmed` crops to the visible
// pixels via the shared `brush_alpha_bounds` kernel, and `warpMask` fills the area past the shape
// with the mask's background tone (mirroring `PixelAdjust.render`'s background greenscreen on
// macOS). Commit-side session methods now live in TransformEditLinux.swift
// (beginDistort/previewCorners/commitDistort/distort), pinned by the 12 `testDistortWarp*` cases
// in CropWandDistortTests.
//
// Omitted (CGPath + UI milestone):
//   - `DistortWarp.mapPath` — carries a `CGPath` outline through the warp; `CGPath`
//     (and `applyWithBlock`/Bézier elements) is not on Linux. `PortablePath` today
//     covers rectangle/ellipse/roundedRect/polygon; arbitrary Bézier path carry is
//     the path-raster milestone.
//   - `DistortPreviewCache` and the `EditorSession`-hosted interactive preview (hold `CGImage`);
//     commit-side behavior is implemented — only the live-drag preview cache remains deferred.
//
// SOLID: the geometry keeps its responsibility and contract (corner placement, validity, and the
// unit-square→quad homography); the Apple API surface (CIImage resample, CGPath carry) is
// exchanged. The macOS original stays the source of truth.

import Foundation
import CompositorKernels

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

    // MARK: - Portable warp (replaces `CIPerspectiveTransform` + `PixelAdjust.render`)

    /// The perspective taking the unit square onto `c`, as a 3×3 homogeneous matrix (row-major).
    private static func homographyMatrix(_ c: [CGPoint]) -> [CGFloat] {
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
        return [a, b, x0, d, e, y0, g, h, 1]
    }

    /// Row-major 3×3 inverse; nil when singular (a degenerate quad never reaches here).
    private static func invertMatrix(_ m: [CGFloat]) -> [CGFloat]? {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        return [.init((e * i - f * h) * inv), .init((c * h - b * i) * inv), .init((b * f - c * e) * inv),
                .init((f * g - d * i) * inv), .init((a * i - c * g) * inv), .init((c * d - a * f) * inv),
                .init((d * h - e * g) * inv), .init((b * g - a * h) * inv), .init((a * e - b * d) * inv)]
    }

    /// Unit-square coordinates of a document point under the homography onto `target`; nil outside or singular.
    private static func unit(of point: CGPoint, under inverse: [CGFloat]) -> CGPoint? {
        let w = inverse[6] * point.x + inverse[7] * point.y + inverse[8]
        guard abs(w) > 1e-12 else { return nil }
        let u = (inverse[0] * point.x + inverse[1] * point.y + inverse[2]) / w
        let v = (inverse[3] * point.x + inverse[4] * point.y + inverse[5]) / w
        guard u.isFinite, v.isFinite, (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }

    /// Whether a point sits inside the convex quad (handle order) — same-sign cross products, as `isUsable`.
    private static func quadContains(_ point: CGPoint, _ quad: [CGPoint]) -> Bool {
        var sign: CGFloat = 0
        for index in 0..<4 {
            let a = quad[index], b = quad[(index + 1) % 4]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 1e-12 { continue }
            if sign == 0 { sign = cross < 0 ? -1 : 1 } else if (cross < 0) != (sign < 0) { return false }
        }
        return true
    }

    /// The warped sample at a document point under `inverse`: nil outside the unit square.
    private static func sample(_ point: CGPoint, width: Int, height: Int, pixels: PortableImage, kind: PortableImage.Kind,
                               inverse: [CGFloat], background: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let unit = unit(of: point, under: inverse) else { return nil }
        if kind == .mask {
            let tone = RasterSample.grayBilinear(pixels,
                fx: min(CGFloat(pixels.width - 1), max(0, unit.x * CGFloat(pixels.width) - 0.5)),
                fy: min(CGFloat(pixels.height - 1), max(0, unit.y * CGFloat(pixels.height) - 0.5)))
            return (tone, tone, tone, 255)
        }
        let s = RasterSample.rgbaBilinear(pixels,
            fx: unit.x * CGFloat(pixels.width) - 0.5, fy: unit.y * CGFloat(pixels.height) - 0.5)
        return (s.r, s.g, s.b, s.a)
    }

    /// `image`, shown through `transform`, resampled so its corners land on `corners`. Returns the
    /// warped pixels over the shape's whole-pixel bounds and the axis-aligned transform for them.
    /// `limit` caps the longest side for previews. When a mask warp passes `background`, pixels past
    /// the shape keep that tone instead of black (masks placed apart from their layers show beyond
    /// their own bounds). The inverse-homography bilinear resample replaces macOS
    /// `CIPerspectiveTransform`; sample centers follow the integer = pixel-center convention used by
    /// `RasterSample`/MaskRaster (`fx = u * width - 0.5`). `RasterImage` reference identity keeps the
    /// macOS `===` checks working unchanged (a 1 × 1 mask passes through as the same image).
    static func warp(_ image: RasterImage, transform: LayerTransform, corners: [CGPoint], isMask: Bool,
                     limit: CGFloat? = nil, background: CGFloat = 0)
        throws -> (image: RasterImage, transform: LayerTransform) {
        guard isUsable(corners) else { throw ProjectError.invalid }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = floor(xs.min()!), minY = floor(ys.min()!)
        let bounds = CGRect(x: minX, y: minY, width: ceil(xs.max()!) - minX, height: ceil(ys.max()!) - minY)
        guard bounds.width >= 1, bounds.height >= 1, bounds.width <= 30_000, bounds.height <= 30_000,
              bounds.width * bounds.height <= 100_000_000 else { throw ProjectError.tooLarge }
        let placed = LayerTransform(origin: bounds.origin, size: bounds.size, sampling: transform.sampling)
        let factor = limit.map { min(1, $0 / max(bounds.width, bounds.height)) } ?? 1
        let width = max(1, Int((bounds.width * factor).rounded(.up)))
        let height = max(1, Int((bounds.height * factor).rounded(.up)))
        let target = imageCorners(corners, flipX: transform.flipX, flipY: transform.flipY)
        guard let inverse = invertMatrix(homographyMatrix([target.topLeft, target.topRight,
                                                           target.bottomRight, target.bottomLeft])) else { throw ProjectError.invalid }
        let pixels = image.pixels
        guard pixels.kind == (isMask ? .mask : .rgba) else { throw ProjectError.invalid }
        if isMask {
            // A uniform 1 × 1 mask already covers any shape.
            if pixels.width == 1, pixels.height == 1, background == 0 { return (image, placed) }
            let quad = [target.topLeft, target.topRight, target.bottomRight, target.bottomLeft]
            let fill = background > 0 ? UInt8(min(255, max(0, Int((background * 255).rounded())))) : 0
            var output = MaskBuffer(width: width, height: height, fill: fill)
            for y in 0..<height {
                for x in 0..<width {
                    let extent = CGRect(x: bounds.minX + CGFloat(x), y: bounds.minY + CGFloat(y), width: 1, height: 1)
                    // Boundary pixels (extent straddles the quad's edge) average their subpixels with
                    // coverage, like CG rasterization — uncovered subpixels contribute the fill.
                    var sums = 0
                    for dx in [CGFloat(0.25), -0.25] {
                        for dy in [CGFloat(0.25), -0.25] {
                            let p = CGPoint(x: extent.midX + dx, y: extent.midY + dy)
                            if quadContains(p, quad), let s = sample(p, width: pixels.width, height: pixels.height, pixels: pixels, kind: .mask, inverse: inverse, background: background) {
                                sums += Int(s.r)
                            } else {
                                sums += Int(fill)
                            }
                        }
                    }
                    output[x, y] = UInt8((sums + 2) / 4)
                }
            }
            return (RasterImage(PortableImage(output)), placed)
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let quad = [target.topLeft, target.topRight, target.bottomRight, target.bottomLeft]
        for y in 0..<height {
            for x in 0..<width {
                let extent = CGRect(x: bounds.minX + CGFloat(x), y: bounds.minY + CGFloat(y), width: 1, height: 1)
                let centerInside = quadContains(CGPoint(x: extent.midX, y: extent.midY), quad)
                var counter = 0
                var full = true
                for dx in [CGFloat(0.25), -0.25] {
                    for dy in [CGFloat(0.25), -0.25] {
                        let inside = quadContains(CGPoint(x: extent.midX + dx, y: extent.midY + dy), quad)
                        full = full && (inside == centerInside)
                        counter += inside ? 1 : 0
                    }
                }
                let s: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
                if full {
                    s = sample(CGPoint(x: extent.midX, y: extent.midY), width: pixels.width, height: pixels.height, pixels: pixels, kind: .rgba, inverse: inverse, background: background) ?? (0, 0, 0, 0)
                } else if counter == 0 {
                    s = (0, 0, 0, 0)
                } else {
                    // Coverage-weighted: the covered subpixels' bilinear samples, averaged.
                    var r = 0, g = 0, b = 0, a = 0
                    for dx in [CGFloat(0.25), -0.25] {
                        for dy in [CGFloat(0.25), -0.25] {
                            let p = CGPoint(x: extent.midX + dx, y: extent.midY + dy)
                            guard quadContains(p, quad), let v = sample(p, width: pixels.width, height: pixels.height, pixels: pixels, kind: .rgba, inverse: inverse, background: background) else { continue }
                            r += Int(v.r); g += Int(v.g); b += Int(v.b); a += Int(v.a)
                        }
                    }
                    s = (UInt8((r + 2) / 4), UInt8((g + 2) / 4), UInt8((b + 2) / 4), UInt8((a + 2) / 4))
                }
                let i = (y * width + x) * 4
                bytes[i] = s.r
                bytes[i + 1] = s.g
                bytes[i + 2] = s.b
                bytes[i + 3] = s.a
            }
        }
        return (RasterImage(PortableImage(PixelBuffer(width: width, height: height, bytes: bytes))), placed)
    }

    /// A full-resolution warp cropped to its visible pixels. A distorted shape rarely fills its
    /// bounding box — and a brush stroke never does — so the layer (and its transform handles)
    /// should hug what is actually there. `crop` is in the warp's pixels, for cropping a mask to match.
    static func warpTrimmed(_ image: RasterImage, transform: LayerTransform, corners: [CGPoint])
        throws -> (image: RasterImage, transform: LayerTransform, crop: CGRect) {
        let warped = try warp(image, transform: transform, corners: corners, isMask: false)
        let pixels = warped.image.pixels
        let full = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        var edges = [Int](repeating: 0, count: 4)
        let ok = pixels.bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            brush_alpha_bounds(UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self)),
                               pixels.width, pixels.height, pixels.bytesPerRow, &edges)
            return true
        }
        let crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        guard ok, edges[0] <= edges[2], edges[1] <= edges[3],
              crop.width >= 1, crop.height >= 1, crop != full, let cropped = pixels.cropped(to: crop) else {
            return (warped.image, warped.transform, full)
        }
        var placed = warped.transform
        placed.origin = CGPoint(x: placed.origin.x + crop.minX, y: placed.origin.y + crop.minY)
        placed.size = crop.size
        return (RasterImage(cropped), placed, crop)
    }

    /// A mask warped like `warp`, but `background` (its tone past its pixels) outside the shape instead of black —
    /// for masks placed apart from their layers, which show beyond their own bounds.
    static func warpMask(_ image: RasterImage, transform: LayerTransform, corners: [CGPoint], background: CGFloat,
                         limit: CGFloat? = nil) throws -> (image: RasterImage, transform: LayerTransform) {
        try warp(image, transform: transform, corners: corners, isMask: true, limit: limit, background: background)
    }
}

extension PortableImage {
    /// A sub-image from `rect` in this image's own pixel grid; nil when the rect is outside it.
    func cropped(to rect: CGRect) -> PortableImage? {
        let x = Int(max(0, floor(rect.minX))), y = Int(max(0, floor(rect.minY)))
        let w = Int(min(CGFloat(width) - CGFloat(x), ceil(rect.maxX) - CGFloat(x)))
        let h = Int(min(CGFloat(height) - CGFloat(y), ceil(rect.maxY) - CGFloat(y)))
        guard w >= 1, h >= 1, x + w <= width, y + h <= height else { return nil }
        if kind == .mask {
            var bytes = [UInt8]()
            bytes.reserveCapacity(w * h)
            for row in y..<(y + h) {
                bytes.append(contentsOf: self.bytes[(row * width + x)..<(row * width + x + w)])
            }
            return PortableImage(MaskBuffer(width: w, height: h, bytes: bytes))
        }
        let bpp = 4
        var bytes = [UInt8]()
        bytes.reserveCapacity(w * h * bpp)
        for row in y..<(y + h) {
            let start = row * bytesPerRow + x * bpp
            bytes.append(contentsOf: self.bytes[start..<(start + w * bpp)])
        }
        return PortableImage(PixelBuffer(width: w, height: h, bytes: bytes))
    }
}