import Foundation

// Portable mask construction and placement. Committed masks remain immutable;
// resampling makes a new image and preserves the mask's border tone outside it.
extension LayerMask {
    static func isValid(_ image: PortableImage) -> Bool {
        image.kind == .mask && image.width > 0 && image.height > 0
            && image.bytesPerRow == image.width && image.bytes.count == image.width * image.height
    }

    static func solid(revealing: Bool) -> LayerMask {
        let image = RasterImage(PortableImage(MaskBuffer(width: 1, height: 1, fill: revealing ? 255 : 0)))
        return LayerMask(asset: ImportedImage(image: image, thumbnail: image, name: "Layer Mask"))
    }

    static func asset(from image: PortableImage) throws -> ImportedImage {
        guard isValid(image) else { throw ProjectError.invalid }
        return ImportedImage(image: RasterImage(image), thumbnail: RasterImage(PixelAdjust.thumbnail(of: image)),
                             name: "Layer Mask")
    }

    static func background(of thumbnail: RasterImage) -> CGFloat { BlurTool.background(of: thumbnail) }

    func clipImage(placement: LayerTransform?, over layer: LayerTransform,
                   width: Int, height: Int, limit: CGFloat? = nil) -> RasterImage? {
        guard let image = enabledImage else { return nil }
        guard let placement, !placement.samePlacement(as: layer) else { return image }
        guard width > 0, height > 0, width <= 30_000, height <= 30_000,
              width * height <= 100_000_000, layer.isValid, placement.isValid else { return nil }
        let factor = limit.map { $0.isFinite ? min(1, max(1, $0) / CGFloat(max(width, height))) : 1 } ?? 1
        let w = max(1, Int((CGFloat(width) * factor).rounded(.up)))
        let h = max(1, Int((CGFloat(height) * factor).rounded(.up)))
        let pixels = image.pixels
        guard Self.isValid(pixels) else { return nil }
        let map = BrushRaster.pixelToDocument(layer, width: w, height: h)
            .concatenating(BrushRaster.pixelToDocument(placement, width: image.width, height: image.height).inverted())
        var output = MaskBuffer(width: w, height: h, fill: Self.background(of: asset.thumbnail) >= 0.5 ? 255 : 0)
        for y in 0..<h {
            for x in 0..<w {
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(map)
                guard p.x >= 0, p.y >= 0, p.x < CGFloat(image.width), p.y < CGFloat(image.height) else { continue }
                // Sample centers and clamp at the source edge: transparent padding
                // would introduce black seams into a reveal-all mask.
                output[x, y] = RasterSample.grayBilinear(pixels,
                    fx: min(CGFloat(image.width - 1), max(0, p.x - 0.5)),
                    fy: min(CGFloat(image.height - 1), max(0, p.y - 0.5)))
            }
        }
        return RasterImage(PortableImage(output))
    }
}
