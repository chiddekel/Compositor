// Portable port of Compositor/Document/GuidedMatte.swift's guided-filter arithmetic
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `GuidedMatte.box` and `GuidedMatte.filter` — the (2r+1)² running-sum box mean and
// the He/Sun/Tang guided filter, both pure `[Float]` kernels over width×height arrays.
//
// Also ported (raster milestone): `GuidedMatte.levels(of:)`, `GuidedMatte.image(_:)`,
// and `GuidedMatte.refine`. The macOS `levels(of:)`/`image(_:)` draw a CGImage
// through a DeviceGray `CGContext`; on Linux the canonical premultiplied RGBA raster
// is un-premultiplied and converted to Rec.709 luma (identical for the opaque art a
// guided matte refines), resampled with a box-area average when shrinking and
// bilinear when growing (the CGContext's high interpolation quality). `refine`
// reproduces the macOS pipeline: scale copy to a limit, filter on the shrunken
// levels with a proportional radius, draw back up to full size.
//
// SOLID: the kernels keep their responsibility and contract (edge-aware mask
// refinement); the Apple API surface (CGContext/CGImage bitmap extraction) is
// exchanged. The macOS original stays the source of truth.

import Foundation

/// Guided filtering (He, Sun & Tang): a mask pulled onto the edges of the image it came from, which is what recovers
/// hair and fur that a segmentation model cuts straight through. Core Image's own `CIGuidedFilter` does nothing on
/// this system and its edge-preserving upsample barely moves the mask, so this does the arithmetic directly.
nonisolated enum GuidedMatte {
    enum Failure: LocalizedError {
        case invalidSize, render
        var errorDescription: String? {
            switch self {
            case .invalidSize: "The mask or guide has no pixels to refine."
            case .render: "There isn’t enough memory to refine that mask."
            }
        }
    }
    /// Mean over a (2r+1)² square, as two running-sum passes — the cost doesn't grow with the radius.
    static func box(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let span = Float(radius * 2 + 1)
        var pass = [Float](repeating: 0, count: width * height)
        source.withUnsafeBufferPointer { src in
            pass.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * width
                    var sum: Float = 0
                    for x in -radius...radius { sum += src[row + min(width - 1, max(0, x))] }
                    for x in 0..<width {
                        out[row + x] = sum / span
                        sum -= src[row + min(width - 1, max(0, x - radius))]
                        sum += src[row + min(width - 1, max(0, x + radius + 1))]
                    }
                }
            }
        }
        var result = [Float](repeating: 0, count: width * height)
        pass.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { out in
                for x in 0..<width {
                    var sum: Float = 0
                    for y in -radius...radius { sum += src[min(height - 1, max(0, y)) * width + x] }
                    for y in 0..<height {
                        out[y * width + x] = sum / span
                        sum -= src[min(height - 1, max(0, y - radius)) * width + x]
                        sum += src[min(height - 1, max(0, y + radius + 1)) * width + x]
                    }
                }
            }
        }
        return result
    }

    /// `mask` refined by `guide` (both 0–1, the same size). A bigger radius reaches further for detail; `epsilon`
    /// decides how much of an edge in the guide counts, so a small one follows fine strands.
    static func filter(mask: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float) -> [Float] {
        let count = width * height
        let meanGuide = box(guide, width: width, height: height, radius: radius)
        let meanMask = box(mask, width: width, height: height, radius: radius)
        var squares = [Float](repeating: 0, count: count), products = [Float](repeating: 0, count: count)
        for i in 0..<count { squares[i] = guide[i] * guide[i]; products[i] = guide[i] * mask[i] }
        let meanSquares = box(squares, width: width, height: height, radius: radius)
        let meanProducts = box(products, width: width, height: height, radius: radius)
        var slope = [Float](repeating: 0, count: count), offset = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let variance = meanSquares[i] - meanGuide[i] * meanGuide[i]
            let covariance = meanProducts[i] - meanGuide[i] * meanMask[i]
            slope[i] = covariance / (variance + epsilon)
            offset[i] = meanMask[i] - slope[i] * meanGuide[i]
        }
        let meanSlope = box(slope, width: width, height: height, radius: radius)
        let meanOffset = box(offset, width: width, height: height, radius: radius)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count { result[i] = min(1, max(0, meanSlope[i] * guide[i] + meanOffset[i])) }
        return result
    }

    /// The gray levels of `image` at `width` × `height`, as 0–1. macOS draws the image
    /// through a DeviceGray `CGContext`; here the premultiplied RGBA raster is
    /// un-premultiplied and converted to Rec.709 luma — the same value for the opaque
    /// art a guided matte refines. Shrinking integrates each destination pixel's source
    /// footprint (box average); growing samples with bilinear interpolation, matching
    /// the CGContext's high interpolation quality.
    static func levels(of image: RasterImage, width: Int, height: Int) throws -> [Float] {
        let pixels = image.pixels
        guard width > 0, height > 0, pixels.width > 0, pixels.height > 0 else { throw Failure.invalidSize }
        return resampleLuma(pixels, width: width, height: height)
    }

    /// 0–1 levels back to a gray image (Rec.709 gray repeated across RGB, opaque), as
    /// the canonical premultiplied RGBA substrate.
    static func image(_ levels: [Float], width: Int, height: Int) throws -> PortableImage {
        guard width > 0, height > 0, levels.count == width * height else { throw Failure.invalidSize }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            // macOS truncates `levels * 255 + 0.5` (negative already clamped); half-way
            // values therefore floor, and the top of the range still lands on 255.
            let gray = UInt8(min(255.0, max(0.0, Double(levels[i]) * 255 + 0.5)))
            let at = i * 4
            bytes[at] = gray; bytes[at + 1] = gray; bytes[at + 2] = gray; bytes[at + 3] = 255
        }
        return PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4, bytes: bytes)
    }

    /// `mask` refined against `guide`, both full size. Done on a copy no larger than
    /// `limit` on its longest side (the radius shrinks with it), then drawn back up:
    /// fine detail comes from the guide either way, and a preview stays quick to
    /// redraw while a slider moves.
    static func refine(mask: RasterImage, guide: RasterImage, radius: Double, limit: CGFloat) throws -> RasterImage {
        let full = mask.pixels
        let guidePixel = guide.pixels
        guard full.width > 0, full.height > 0, guidePixel.width > 0, guidePixel.height > 0,
              radius.isFinite, radius >= 0, limit.isFinite, limit > 0 else { throw Failure.invalidSize }
        let factor = min(1, limit / max(CGFloat(full.width), CGFloat(full.height)))
        let width = max(1, Int((CGFloat(full.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(full.height) * factor).rounded()))
        let steps = max(1, Int((radius * Double(factor)).rounded()))
        let refined: [Float]
        if width == full.width && height == full.height {
            refined = filter(mask: try levels(of: mask, width: width, height: height),
                             guide: try levels(of: guide, width: width, height: height),
                             width: width, height: height, radius: steps, epsilon: 1e-4)
        } else {
            let small = filter(mask: try levels(of: mask, width: width, height: height),
                               guide: try levels(of: guide, width: width, height: height),
                               width: width, height: height, radius: steps, epsilon: 1e-4)
            refined = try resampleLumaFromLevels(small, width: width, height: height,
                                                 newWidth: full.width, newHeight: full.height)
        }
        let result = try image(refined, width: full.width, height: full.height)
        return RasterImage(result)
    }

    // MARK: - Raster plumbing

    private static func resampleLuma(_ source: PortableImage, width: Int, height: Int) -> [Float] {
        let srcW = source.width, srcH = source.height, srcRow = source.bytesPerRow
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                if width >= srcW && height >= srcH {
                    let fx = (CGFloat(x) + 0.5) * CGFloat(srcW) / CGFloat(width) - 0.5
                    let fy = (CGFloat(y) + 0.5) * CGFloat(srcH) / CGFloat(height) - 0.5
                    let cx = min(CGFloat(srcW - 1), max(0, fx)), cy = min(CGFloat(srcH - 1), max(0, fy))
                    out[y * width + x] = lumaBilinear(source, bytes: source.bytes, srcRow: srcRow, fx: cx, fy: cy)
                } else {
                    let x0 = x * srcW / width, x1 = min(srcW, (x + 1) * srcW / width)
                    let y0 = y * srcH / height, y1 = min(srcH, (y + 1) * srcH / height)
                    var sum: Float = 0, count = 0
                    for sy in y0..<max(y0 + 1, y1) {
                        let row = sy * srcRow
                        for sx in x0..<max(x0 + 1, x1) {
                            let at = row + sx * 4
                            sum += luma(source.bytes[at], source.bytes[at + 1], source.bytes[at + 2], source.bytes[at + 3])
                            count += 1
                        }
                    }
                    out[y * width + x] = count > 0 ? sum / Float(count) : 0
                }
            }
        }
        return out
    }

    private static func resampleLumaFromLevels(_ levels: [Float], width: Int, height: Int,
                                               newWidth: Int, newHeight: Int) throws -> [Float] {
        // Bilinear upsample of the filtered levels back to full size (the macOS
        // CGContext high-interpolation draw).
        var out = [Float](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let fy = (CGFloat(y) + 0.5) * CGFloat(height) / CGFloat(newHeight) - 0.5
            let cy = min(CGFloat(height - 1), max(0, fy))
            for x in 0..<newWidth {
                let fx = (CGFloat(x) + 0.5) * CGFloat(width) / CGFloat(newWidth) - 0.5
                let cx = min(CGFloat(width - 1), max(0, fx))
                let x0 = Int(floor(cx)), y0 = Int(floor(cy))
                let tx = Float(cx - CGFloat(x0)), ty = Float(cy - CGFloat(y0))
                func v(_ px: Int, _ py: Int) -> Float { levels[min(height - 1, max(0, py)) * width + min(width - 1, max(0, px))] }
                let top = v(x0, y0) * (1 - tx) + v(x0 + 1, y0) * tx
                let bottom = v(x0, y0 + 1) * (1 - tx) + v(x0 + 1, y0 + 1) * tx
                out[y * newWidth + x] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }

    private static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Float {
        let alpha = Float(a)
        guard alpha > 0 else { return 0 }
        let sr = Float(r) * 255 / alpha, sg = Float(g) * 255 / alpha, sb = Float(b) * 255 / alpha
        return (0.2126 * sr + 0.7152 * sg + 0.0722 * sb) / 255
    }

    private static func lumaBilinear(_ source: PortableImage, bytes: [UInt8], srcRow: Int,
                                     fx: CGFloat, fy: CGFloat) -> Float {
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = Float(fx - CGFloat(x0)), ty = Float(fy - CGFloat(y0))
        func v(_ px: Int, _ py: Int) -> Float {
            let cx = min(source.width - 1, max(0, px)), cy = min(source.height - 1, max(0, py))
            let at = cy * srcRow + cx * 4
            return luma(bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3])
        }
        let top = v(x0, y0) * (1 - tx) + v(x0 + 1, y0) * tx
        let bottom = v(x0, y0 + 1) * (1 - tx) + v(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }
}