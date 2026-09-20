// Portable port of Compositor/Document/PixelAdjust.swift (file-map tier:
// "Apple replacement/adaptation: Replace CoreImage rendering/context with named
// imaging operations").
//
// Kept: the responsibility — shared plumbing for whole-image adjustments:
// selection coverage on an image's own pixel grid, blending a result back
// through a selection in float, and thumbnails matching imported ones.
//
// Replaced: `CIContext`/`CIBlendWithMask` with direct float math over the
// canonical buffers — coverage × adjusted + (1 − coverage) × original, per
// channel, so fully selected pixels stay exact and soft edges blend.

import Foundation

nonisolated enum PixelAdjust {

    /// Selection coverage rasterized on the image's pixel grid (a fill, which is
    /// exact): the clip rect mapped through the inverse placement, sampled
    /// nearest like the CG mask fill it replaces.
    static func coverage(_ selection: SelectionClip, width: Int, height: Int,
                         pixelToDocument: CGAffineTransform) -> MaskBuffer {
        var buffer = MaskBuffer(width: width, height: height)
        let inverse = pixelToDocument.inverted()
        for y in 0..<height {
            for x in 0..<width {
                let doc = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(pixelToDocument)
                guard doc.x >= selection.rect.minX, doc.x < selection.rect.maxX,
                      doc.y >= selection.rect.minY, doc.y < selection.rect.maxY else { continue }
                if let cov = selection.coverage {
                    buffer[x, y] = RasterSample.grayNearest(cov,
                        fx: doc.x - selection.rect.minX, fy: doc.y - selection.rect.minY)
                } else {
                    buffer[x, y] = 255
                }
                _ = inverse
            }
        }
        return buffer
    }

    /// coverage × adjusted + (1 − coverage) × original, in float without color
    /// conversion, so fully selected pixels stay exact and soft edges blend.
    /// (The CIBlendWithMask contract, one pass.)
    static func blend(_ adjusted: PortableImage, over original: PortableImage,
                      through coverage: MaskBuffer) -> PortableImage {
        let width = min(adjusted.width, original.width, coverage.width)
        let height = min(adjusted.height, original.height, coverage.height)
        precondition(adjusted.kind == original.kind)
        let bpp = adjusted.bytesPerPixel
        var out = [UInt8](repeating: 0, count: width * height * bpp)
        for y in 0..<height {
            for x in 0..<width {
                let f = Float(coverage[x, y]) / 255
                let o = y * width * bpp + x * bpp
                let ai = y * adjusted.bytesPerRow + x * bpp
                let bi = y * original.bytesPerRow + x * bpp
                for b in 0..<bpp {
                    let a = Float(adjusted.bytes[ai + b])
                    let c = Float(original.bytes[bi + b])
                    out[o + b] = UInt8(min(255, max(0, a * f + c * (1 - f) + 0.5)))
                }
            }
        }
        return PortableImage(width: width, height: height, kind: adjusted.kind,
                             bytesPerRow: width * bpp, bytes: out)
    }

    /// A small preview for the Layers panel, matching imported thumbnails.
    static func thumbnail(of image: PortableImage) -> PortableImage {
        RasterSample.thumbnail(image)
    }
}
