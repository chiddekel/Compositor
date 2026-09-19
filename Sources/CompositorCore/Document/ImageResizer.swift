import Foundation

nonisolated struct ImageSizeOptions: Sendable {
    var width: Int
    var height: Int
    var resolution: Double
    var sampling: LayerSampling = .high
}

/// Rasterizes each layer in the resized document axes, preserving shear from a
/// nonuniform resize of a rotated layer. Changing resolution alone shares pixels.
actor ImageResizer {
    static let shared = ImageResizer()

    func resize(_ snapshot: ProjectSnapshot, to options: ImageSizeOptions) throws -> ProjectSnapshot {
        try ProjectStore.validate(snapshot.manifest)
        try Task.checkCancellation()
        guard (1...30_000).contains(options.width), (1...30_000).contains(options.height),
              options.resolution.isFinite, (1...9600).contains(options.resolution) else { throw ProjectError.tooLarge }
        let old = snapshot.manifest
        var manifest = ProjectManifest(resolution: options.resolution, documentID: old.documentID,
            width: options.width, height: options.height, activeLayerID: old.activeLayerID, layers: old.layers)
        if old.width == options.width, old.height == options.height {
            return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
        }
        guard options.width * options.height <= 100_000_000 else { throw ProjectError.tooLarge }
        let sx = CGFloat(options.width) / CGFloat(old.width), sy = CGFloat(options.height) / CGFloat(old.height)
        let scale = CGAffineTransform(scaleX: sx, y: sy)
        var placements: [LayerTransform] = []
        var usedPixels = 0, usedMaskPixels = 0
        // Preflight ALL outputs before allocating any raster.
        for layer in old.layers {
            try Task.checkCancellation()
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                .map { layer.transform.point($0).applying(scale) }
            let left = floor(corners.map(\.x).min()!), top = floor(corners.map(\.y).min()!)
            let width = Int(ceil(corners.map(\.x).max()!) - left)
            let height = Int(ceil(corners.map(\.y).max()!) - top)
            let placed = LayerTransform(origin: CGPoint(x: left, y: top), size: CGSize(width: width, height: height),
                                        sampling: options.sampling)
            guard placed.isValid else { throw ProjectError.tooLarge }
            placements.append(placed)
            if layer.imageFile != nil {
                guard snapshot.images[layer.id] != nil else { throw ProjectError.missingImage }
                guard width <= 30_000, height <= 30_000, width * height <= 100_000_000 - usedPixels else {
                    throw ProjectError.tooLarge
                }
                usedPixels += width * height
            }
            if layer.maskFile != nil {
                guard let mask = snapshot.masks[layer.id] else { throw ProjectError.missingImage }
                if layer.maskPlacement == nil, mask.image.width != 1 || mask.image.height != 1 {
                    guard width <= 30_000, height <= 30_000, width * height <= 100_000_000 - usedMaskPixels else {
                        throw ProjectError.tooLarge
                    }
                    usedMaskPixels += width * height
                }
            }
        }
        var images: [UUID: ImportedImage] = [:], masks: [UUID: ImportedImage] = [:]
        manifest.layers = []
        for (layer, placed) in zip(old.layers, placements) {
            try Task.checkCancellation()
            let w = Int(placed.size.width), h = Int(placed.size.height)
            if layer.imageFile != nil, let source = snapshot.images[layer.id] {
                let image = try resample(source.image.pixels, from: layer.transform, scale: scale,
                                         into: placed, width: w, height: h, sampling: options.sampling)
                images[layer.id] = ImportedImage(image: RasterImage(image),
                    thumbnail: RasterImage(PixelAdjust.thumbnail(of: image)), name: source.name)
            }
            if layer.maskFile != nil, let source = snapshot.masks[layer.id] {
                if (source.image.width == 1 && source.image.height == 1) || layer.maskPlacement != nil {
                    masks[layer.id] = source
                } else {
                    let mask = try resample(source.image.pixels, from: layer.transform, scale: scale,
                                            into: placed, width: w, height: h, sampling: options.sampling)
                    masks[layer.id] = try LayerMask.asset(from: mask)
                }
            }
            manifest.layers.append(ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: placed, imageFile: layer.imageFile, parentID: layer.parentID, isGroup: layer.isGroup,
                opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.maskFile,
                maskEnabled: layer.maskEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment,
                maskPlacement: layer.maskPlacement.map { $0.placing($0.unitToDocument.concatenating(scale)) },
                maskLinked: layer.maskLinked))
        }
        try ProjectStore.validate(manifest)
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks)
    }

    private func resample(_ source: PortableImage, from original: LayerTransform, scale: CGAffineTransform,
                          into target: LayerTransform, width: Int, height: Int, sampling: LayerSampling) throws -> PortableImage {
        let inverse = BrushRaster.pixelToDocument(original, width: source.width, height: source.height)
            .concatenating(scale).inverted()
        let mapping = BrushRaster.pixelToDocument(target, width: width, height: height).concatenating(inverse)
        let bpp = source.bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: width * height * bpp)
        let minifies = sampling != .nearest && (hypot(mapping.a, mapping.b) > 1.000001 || hypot(mapping.c, mapping.d) > 1.000001)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                if minifies {
                    // Integrate the destination pixel's entire source footprint,
                    // including rotated/sheared footprints. Sampling only its
                    // center aliases high-frequency detail during reduction.
                    let footprint = [CGPoint(x: x, y: y), CGPoint(x: x + 1, y: y),
                                     CGPoint(x: x + 1, y: y + 1), CGPoint(x: x, y: y + 1)].map { $0.applying(mapping) }
                    let pixel = areaSample(source, footprint: footprint)
                    let at = (y * width + x) * bpp
                    for c in 0..<bpp { bytes[at + c] = pixel[c] }
                    continue
                }
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(mapping)
                guard p.x >= 0, p.y >= 0, p.x < CGFloat(source.width), p.y < CGFloat(source.height) else { continue }
                let at = (y * width + x) * bpp
                if sampling == .nearest {
                    let src = Int(p.y) * source.bytesPerRow + Int(p.x) * bpp
                    for c in 0..<bpp { bytes[at + c] = source.bytes[src + c] }
                } else {
                    let fx = min(CGFloat(source.width - 1), max(0, p.x - 0.5))
                    let fy = min(CGFloat(source.height - 1), max(0, p.y - 0.5))
                    if source.kind == .mask {
                        bytes[at] = RasterSample.grayBilinear(source, fx: fx, fy: fy)
                    } else {
                        let pixel = RasterSample.rgbaBilinear(source, fx: fx, fy: fy)
                        bytes[at] = pixel.r; bytes[at + 1] = pixel.g; bytes[at + 2] = pixel.b; bytes[at + 3] = pixel.a
                    }
                }
            }
        }
        return PortableImage(width: width, height: height, kind: source.kind, bytesPerRow: width * bpp, bytes: bytes)
    }

    /// Exact box integration over an affine pixel footprint. Polygon clipping
    /// avoids imposing an arbitrary sample-count cap on large reductions.
    private func areaSample(_ source: PortableImage, footprint: [CGPoint]) -> [UInt8] {
        func area(_ polygon: [CGPoint]) -> CGFloat {
            guard polygon.count > 2 else { return 0 }
            var sum: CGFloat = 0
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                sum += a.x * b.y - b.x * a.y
            }
            return abs(sum) / 2
        }
        func clip(_ polygon: [CGPoint], axisX: Bool, boundary: CGFloat, greater: Bool) -> [CGPoint] {
            guard var previous = polygon.last else { return [] }
            func coordinate(_ p: CGPoint) -> CGFloat { axisX ? p.x : p.y }
            func inside(_ p: CGPoint) -> Bool { greater ? coordinate(p) >= boundary : coordinate(p) <= boundary }
            var output: [CGPoint] = []
            for current in polygon {
                if inside(previous) != inside(current) {
                    let t = (boundary - coordinate(previous)) / (coordinate(current) - coordinate(previous))
                    output.append(CGPoint(x: previous.x + (current.x - previous.x) * t,
                                          y: previous.y + (current.y - previous.y) * t))
                }
                if inside(current) { output.append(current) }
                previous = current
            }
            return output
        }
        let fullArea = area(footprint)
        var sums = [CGFloat](repeating: 0, count: source.bytesPerPixel)
        let left = max(0, Int(floor(footprint.map(\.x).min()!)))
        let right = min(source.width, Int(ceil(footprint.map(\.x).max()!)))
        let top = max(0, Int(floor(footprint.map(\.y).min()!)))
        let bottom = min(source.height, Int(ceil(footprint.map(\.y).max()!)))
        guard fullArea > 0, left < right, top < bottom else { return sums.map { _ in 0 } }
        for y in top..<bottom {
            for x in left..<right {
                var polygon = clip(footprint, axisX: true, boundary: CGFloat(x), greater: true)
                polygon = clip(polygon, axisX: true, boundary: CGFloat(x + 1), greater: false)
                polygon = clip(polygon, axisX: false, boundary: CGFloat(y), greater: true)
                polygon = clip(polygon, axisX: false, boundary: CGFloat(y + 1), greater: false)
                let weight = area(polygon) / fullArea
                let at = y * source.bytesPerRow + x * source.bytesPerPixel
                for c in sums.indices { sums[c] += CGFloat(source.bytes[at + c]) * weight }
            }
        }
        return sums.map { UInt8(min(255, max(0, $0.rounded()))) }
    }
}
