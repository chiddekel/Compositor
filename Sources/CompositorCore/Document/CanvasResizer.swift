import Foundation

/// Canvas size changes placement without resampling existing artwork.
actor CanvasResizer {
    static let shared = CanvasResizer()

    func resize(_ snapshot: ProjectSnapshot, to options: CanvasSizeOptions) throws -> ProjectSnapshot {
        try Self.resizeSnapshot(snapshot, to: options)
    }

    nonisolated static func resizeSnapshot(_ snapshot: ProjectSnapshot, to options: CanvasSizeOptions) throws -> ProjectSnapshot {
        try ProjectStore.validate(snapshot.manifest)
        try Task.checkCancellation()
        guard (1...30_000).contains(options.width), (1...30_000).contains(options.height),
              (0...8).contains(options.anchor) else { throw ProjectError.tooLarge }
        let old = snapshot.manifest
        let offset = options.offset(fromWidth: old.width, height: old.height)
        guard offset.x.isFinite, offset.y.isFinite, abs(offset.x) <= 1_000_000,
              abs(offset.y) <= 1_000_000 else { throw ProjectError.invalid }
        guard options.width != old.width || options.height != old.height || offset != .zero else { return snapshot }
        var manifest = ProjectManifest(resolution: old.resolution, documentID: old.documentID,
            width: options.width, height: options.height, activeLayerID: old.activeLayerID, layers: [])
        for layer in old.layers {
            try Task.checkCancellation()
            var transform = layer.transform
            transform.origin.x += offset.x
            transform.origin.y += offset.y
            guard transform.isValid else { throw ProjectError.tooLarge }
            var maskPlacement = layer.maskPlacement
            if maskPlacement != nil {
                maskPlacement!.origin.x += offset.x
                maskPlacement!.origin.y += offset.y
                guard maskPlacement!.isValid else { throw ProjectError.tooLarge }
            }
            manifest.layers.append(ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: transform, imageFile: layer.imageFile, parentID: layer.parentID, isGroup: layer.isGroup,
                opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.maskFile,
                maskEnabled: layer.maskEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment,
                maskPlacement: maskPlacement, maskLinked: layer.maskLinked, shape: layer.shape))
        }
        var images = snapshot.images
        if let color = options.fill, options.width > old.width || options.height > old.height {
            let used = images.values.reduce(0) { $0 + $1.image.width * $1.image.height }
            guard options.width * options.height <= 100_000_000 - used,
                  manifest.layers.count < 10_000 else { throw ProjectError.tooLarge }
            guard [color.red, color.green, color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ProjectError.invalid
            }
            let channels = [color.red, color.green, color.blue].map { UInt8(($0 * 255).rounded()) }
            let fill = UInt32(channels[0]) << 24 | UInt32(channels[1]) << 16 | UInt32(channels[2]) << 8 | 255
            var pixels = PixelBuffer(width: options.width, height: options.height, fill: fill)
            let oldBounds = CGRect(origin: offset, size: CGSize(width: old.width, height: old.height))
            // Area coverage keeps a fractional crop's edge in place as well.
            for y in 0..<options.height {
                try Task.checkCancellation()
                for x in 0..<options.width {
                    let overlap = oldBounds.intersection(CGRect(x: x, y: y, width: 1, height: 1))
                    guard !overlap.isNull, !overlap.isEmpty else { continue }
                    let keep = max(0, 1 - overlap.width * overlap.height)
                    let i = (y * options.width + x) * 4
                    for c in 0..<4 { pixels.bytes[i + c] = UInt8((CGFloat(pixels.bytes[i + c]) * keep).rounded()) }
                }
            }
            let image = PortableImage(pixels)
            let asset = ImportedImage(image: RasterImage(image), thumbnail: RasterImage(PixelAdjust.thumbnail(of: image)),
                                      name: "Canvas Extension")
            let id = UUID()
            images[id] = asset
            manifest.layers.insert(ProjectLayerRecord(id: id, name: asset.name, isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: options.width, height: options.height)),
                imageFile: "\(id.uuidString).png"), at: 0)
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: snapshot.masks)
    }
}
