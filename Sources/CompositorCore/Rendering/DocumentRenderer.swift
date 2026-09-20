import Foundation

/// CPU document compositor shared by the editor and export. A render owns its
/// dependency cache; committed document pixels are never mutated.
final class DocumentRenderer {
    private let document: CanvasDocument
    private let layers: [UUID: ImageLayer]
    private let placement: LayerTransform
    private var coverageCache: [UUID: MaskBuffer] = [:]
    private var visiting = Set<UUID>()

    init(_ document: CanvasDocument) throws {
        guard (1...30_000).contains(document.width), (1...30_000).contains(document.height),
              document.width * document.height <= 100_000_000 else { throw ProjectError.tooLarge }
        let snapshot = try ProjectSnapshot(document: document, activeLayerID: nil)
        try ProjectStore.validate(snapshot.manifest)
        self.document = document
        layers = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        placement = LayerTransform(origin: .zero, size: document.size, sampling: .nearest)
    }

    func render() throws -> PortableImage {
        let visible = LayerHierarchy.visibleLayers(document.layers.map(\.hierarchyRecord)).compactMap { layers[$0.id] }
        var output = empty()
        var index = 0
        while index < visible.count {
            let layer = visible[index]
            if layer.adjustment != nil {
                if layer.maskSourceID == nil { try adjust(layer, into: &output, includeFolders: true) }
                index += 1
                continue
            }
            var children: [ImageLayer] = []
            if layer.maskSourceID == nil {
                var next = index + 1
                while next < visible.count, visible[next].maskSourceID == layer.id, visible[next].parentID == layer.parentID {
                    children.append(visible[next]); next += 1
                }
            }
            var own = try ownPixels(layer)
            if children.isEmpty {
                if let sourceID = layer.maskSourceID { multiply(&own, by: try coverage(sourceID)) }
            } else {
                // The entire contiguous clipping stack shares the base alpha;
                // repeated source-over would incorrectly thicken soft edges.
                let alpha = alphaOf(own)
                for i in stride(from: 0, to: own.bytes.count, by: 4) {
                    let a = Int(own.bytes[i + 3])
                    for c in 0..<3 { own.bytes[i + c] = a == 0 ? 0 : UInt8(min(255, (Int(own.bytes[i + c]) * 255 + a / 2) / a)) }
                    own.bytes[i + 3] = 255
                }
                for child in children {
                    if child.adjustment != nil { try adjust(child, into: &own, includeFolders: false) }
                    else { composite(try ownPixels(child), mode: child.blendMode, into: &own) }
                }
                multiply(&own, by: alpha)
            }
            multiply(&own, by: try folderCoverage(layer))
            composite(own, mode: layer.blendMode, into: &output)
            index += children.count + 1
        }
        return PortableImage(output)
    }

    private func empty() -> PixelBuffer { PixelBuffer(width: document.width, height: document.height) }

    private func ownPixels(_ layer: ImageLayer) throws -> PixelBuffer {
        var buffer = empty()
        guard let asset = layer.asset else { return buffer }
        let mask = layer.mask.flatMap { $0.clipImage(placement: $0.placement, over: layer.transform,
                                                    width: asset.image.width, height: asset.image.height) }
        LayerRenderer.draw(asset.image, transform: layer.transform, center: layer.transform.center,
            opacity: layer.opacity, mask: mask, into: &buffer)
        return buffer
    }

    private func coverage(_ id: UUID) throws -> MaskBuffer {
        if let found = coverageCache[id] { return found }
        guard let layer = layers[id], visiting.count < 256, visiting.insert(id).inserted else { throw ProjectError.invalid }
        defer { visiting.remove(id) }
        var pixels = try ownPixels(layer)
        if let source = layer.maskSourceID { multiply(&pixels, by: try coverage(source)) }
        let alpha = alphaOf(pixels)
        coverageCache[id] = alpha
        return alpha
    }

    private func maskCoverage(_ layer: ImageLayer) -> MaskBuffer {
        guard let mask = layer.mask, mask.isEnabled else {
            return MaskBuffer(width: document.width, height: document.height, fill: 255)
        }
        // Adjustment and folder masks cover their placed rectangle; pixels
        // outside that rectangle do not affect the underlying image.
        var result = MaskBuffer(width: document.width, height: document.height)
        LayerRenderer.drawCoverage(mask.asset.image, transform: layer.maskTransform, into: &result)
        return result
    }

    private func folderCoverage(_ layer: ImageLayer) throws -> MaskBuffer {
        var result = MaskBuffer(width: document.width, height: document.height, fill: 255)
        var parent = layer.parentID
        var count = 0
        while let id = parent {
            guard let folder = layers[id], count < 64 else { throw ProjectError.invalid }
            if folder.mask?.isEnabled == true {
                let mask = maskCoverage(folder)
                for i in result.bytes.indices { result.bytes[i] = UInt8((Int(result.bytes[i]) * Int(mask.bytes[i]) + 127) / 255) }
            }
            parent = folder.parentID
            count += 1
        }
        return result
    }

    private func adjust(_ layer: ImageLayer, into output: inout PixelBuffer, includeFolders: Bool) throws {
        guard let adjustment = layer.adjustment else { return }
        let original = PortableImage(output)
        let changed = try adjustment.apply(original)
        var mask = maskCoverage(layer)
        if includeFolders {
            let folders = try folderCoverage(layer)
            for i in mask.bytes.indices { mask.bytes[i] = UInt8((Int(mask.bytes[i]) * Int(folders.bytes[i]) + 127) / 255) }
        }
        for p in 0..<(output.width * output.height) {
            let i = p * 4
            let alpha = Float(original.bytes[i + 3])
            guard alpha > 0 else { continue }
            let amount = Float(mask.bytes[p]) / 255 * Float(layer.opacity)
            let cs = (Float(changed.bytes[i]) / alpha, Float(changed.bytes[i + 1]) / alpha, Float(changed.bytes[i + 2]) / alpha)
            let cb = (Float(original.bytes[i]) / alpha, Float(original.bytes[i + 1]) / alpha, Float(original.bytes[i + 2]) / alpha)
            let blend = LayerRenderer.blendPixel(layer.blendMode, cs, 1, cb, 1)
            for (c, value) in [blend.0, blend.1, blend.2].enumerated() {
                output.bytes[i + c] = clampU8(value * alpha * amount + Float(original.bytes[i + c]) * (1 - amount))
            }
            // An adjustment changes color, never the underlying coverage.
        }
    }

    private func composite(_ source: PixelBuffer, mode: LayerBlendMode, into destination: inout PixelBuffer) {
        LayerRenderer.draw(RasterImage(PortableImage(source)), transform: placement, center: placement.center,
                           blendMode: mode, into: &destination)
    }

    private func alphaOf(_ pixels: PixelBuffer) -> MaskBuffer {
        var result = MaskBuffer(width: pixels.width, height: pixels.height)
        for i in result.bytes.indices { result.bytes[i] = pixels.bytes[i * 4 + 3] }
        return result
    }

    private func multiply(_ pixels: inout PixelBuffer, by mask: MaskBuffer) {
        for p in mask.bytes.indices {
            let alpha = Int(mask.bytes[p])
            for c in 0..<4 { pixels.bytes[p * 4 + c] = UInt8((Int(pixels.bytes[p * 4 + c]) * alpha + 127) / 255) }
        }
    }
}
