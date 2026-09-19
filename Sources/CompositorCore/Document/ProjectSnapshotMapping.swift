import Foundation

extension ProjectSnapshot {
    init(document: CanvasDocument, activeLayerID: UUID?) throws {
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let records = document.layers.map { layer in
            images[layer.id] = layer.asset
            masks[layer.id] = layer.mask?.asset
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png",
                parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode,
                maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled,
                maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement,
                maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style)
        }
        let manifest = ProjectManifest(resolution: document.resolution, documentID: document.id,
            width: document.width, height: document.height, activeLayerID: activeLayerID, layers: records)
        try ProjectStore.validate(manifest)
        self.init(manifest: manifest, images: images, masks: masks)
    }

    func document() throws -> CanvasDocument {
        try ProjectStore.validate(manifest)
        let layers = try manifest.layers.map { record -> ImageLayer in
            if record.imageFile != nil, images[record.id] == nil { throw ProjectError.missingImage }
            if record.maskFile != nil, masks[record.id] == nil { throw ProjectError.missingImage }
            var mask: LayerMask?
            if record.maskFile != nil, let asset = masks[record.id] {
                guard LayerMask.isValid(asset.image.pixels) else { throw ProjectError.invalid }
                mask = LayerMask(asset: asset, isEnabled: record.maskEnabled ?? true,
                    placement: record.maskPlacement, isLinked: record.maskLinked ?? true)
            }
            let asset = record.imageFile == nil ? nil : images[record.id]
            return ImageLayer(id: record.id, asset: asset, name: record.name, isVisible: record.isVisible,
                transform: record.transform, parentID: record.parentID, isGroup: record.isGroup == true,
                opacity: record.opacity ?? 1, blendMode: record.blendMode ?? .normal, mask: mask,
                maskSourceID: record.maskSourceID, adjustment: record.adjustment,
                shape: LayerShape.loaded(record.shape, image: asset?.image))
        }
        return CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
                              layers: layers, resolution: manifest.resolution ?? 72)
    }
}
