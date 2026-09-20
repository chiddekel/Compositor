// Portable port of Compositor/Document/BlurTool.swift (file-map tier: "Keep
// logic; replace Apple operations"). The `blurSample` semantics are kept: what
// a Blur stroke paints is the active layer (or, with `mask`, its mask) as the
// canvas shows it, at document size, softened by an amount that follows the
// brush size — taken when the stroke starts, so going over an area again in a
// new stroke softens it further, as in Photoshop.
//
// The EditorSession members (`activeLayer`, `displayedTransform`,
// `displayedMaskPlacement`) are the Qt controller's state; this port takes
// them as parameters so the controller drives the same sequence.
//
// Replaced: CGContext/CoreImage with `LayerRenderer.draw`/`drawCoverage` and
// the portable `GaussianBlur` (the mask path keeps CI's clampedToExtent edge
// behavior, the layer path its transparent padding).

import Foundation

nonisolated enum BlurTool {

    /// The edge tone of a mask's thumbnail (the macOS `LayerMask.background`):
    /// 1 when its border is mostly white, else 0. Past its pixels a mask keeps
    /// this tone, so blurring near its edge doesn't pull in the wrong one.
    static func background(of thumbnail: RasterImage) -> CGFloat {
        let pixels = thumbnail.pixels
        let width = pixels.width, height = pixels.height
        guard width > 0, height > 0 else { return 1 }
        var total = 0, count = 0
        for y in 0..<height {
            for x in 0..<width where y == 0 || y == height - 1 || x == 0 || x == width - 1 {
                total += Int(RasterSample.grayNearest(pixels, fx: CGFloat(x), fy: CGFloat(y)))
                count += 1
            }
        }
        return total * 2 >= count * 255 ? 1 : 0
    }

    /// What a Blur stroke paints. `displayedTransform` places the layer as the
    /// canvas shows it; `displayedMaskPlacement` is where the mask sits when it
    /// has been moved apart from the layer (nil = the layer's own placement).
    static func blurSample(layer: ImageLayer, document: CanvasDocument, mask: Bool,
                           diameter: CGFloat, displayedTransform: LayerTransform,
                           displayedMaskPlacement: LayerTransform?) -> PortableImage? {
        let sigma = min(30, max(1.5, Double(diameter) / 10))
        if mask {
            guard let owned = layer.mask else { return nil }
            let tone = background(of: owned.asset.thumbnail)
            var coverage = MaskBuffer(width: document.width, height: document.height,
                                      fill: tone >= 0.5 ? 255 : 0)
            let placement = displayedMaskPlacement ?? layer.maskTransform
            // The mask's own area starts black: coverage only adds white.
            fillBlackRect(&coverage, transform: placement)
            LayerRenderer.drawCoverage(owned.asset.image, transform: placement, into: &coverage)
            GaussianBlur.apply(&coverage, sigma: sigma, edges: .clamp)
            return PortableImage(coverage)
        }
        guard let image = layer.asset?.image else { return nil }
        var canvas = PixelBuffer(width: document.width, height: document.height)
        LayerRenderer.draw(image, transform: displayedTransform, center: displayedTransform.center, into: &canvas)
        GaussianBlur.apply(&canvas, sigma: sigma, edges: .transparent)
        return PortableImage(canvas)
    }

    /// Fills black inside a (possibly rotated/flipped) placed rect, the
    /// CG saveGState/rotate/scale/fill sequence of the macOS original.
    private static func fillBlackRect(_ buffer: inout MaskBuffer, transform: LayerTransform) {
        // The unit square through the placement gives the rotated placed rect.
        let mapping = BrushRaster.pixelToDocument(transform, width: 1, height: 1)
        let inverse = mapping.inverted()
        let placed = CGRect(x: 0, y: 0, width: 1, height: 1).applying(mapping)
        let clip = placed.intersection(CGRect(x: 0, y: 0, width: CGFloat(buffer.width), height: CGFloat(buffer.height)))
        guard !clip.isNull, !clip.isEmpty else { return }
        let x0 = max(0, Int(floor(clip.minX))), x1 = min(buffer.width - 1, Int(ceil(clip.maxX)) - 1)
        let y0 = max(0, Int(floor(clip.minY))), y1 = min(buffer.height - 1, Int(ceil(clip.maxY)) - 1)
        for y in y0...y1 {
            for x in x0...x1 {
                let local = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
                guard local.x >= 0, local.x < 1, local.y >= 0, local.y < 1 else { continue }
                buffer[x, y] = 0
            }
        }
    }
}

// MARK: - PixelInvert

/// Whole-image invert in one pass, optionally limited to a selection.
/// Inverting never changes a layer's size, so no tiles, bounds scans, or re-cropping.
/// (The macOS original used vImage; the math is the same table/matrix in a plain loop.)
nonisolated enum PixelInvert {
    struct Job: @unchecked Sendable {
        let image: PortableImage
        let isMask: Bool
        /// Maps the image's top-left pixel grid to document pixels.
        let pixelToDocument: CGAffineTransform
        let selection: SelectionClip?
    }

    static func run(_ job: Job) throws -> PortableImage {
        guard job.image.kind == (job.isMask ? .mask : .rgba) else { throw ProjectError.invalid }
        let width = job.image.width, height = job.image.height
        var bytes = job.image.bytes
        if job.isMask {
            for i in 0..<bytes.count { bytes[i] = 255 - bytes[i] }
        } else {
            // Premultiplied RGBA: each color becomes alpha − color, so transparency is kept.
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let a = bytes[i + 3]
                bytes[i] = a - bytes[i]
                bytes[i + 1] = a - bytes[i + 1]
                bytes[i + 2] = a - bytes[i + 2]
            }
        }
        let inverted = PortableImage(width: width, height: height, kind: job.isMask ? .mask : .rgba,
                                     bytesPerRow: job.isMask ? width : width * 4, bytes: bytes)
        guard let selection = job.selection else { return inverted }
        let coverage = PixelAdjust.coverage(selection, width: width, height: height, pixelToDocument: job.pixelToDocument)
        return PixelAdjust.blend(inverted, over: job.image, through: coverage)
    }
}
