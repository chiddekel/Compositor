import Foundation

struct PixelClipboard {
    let image: PortableImage
    let origin: CGPoint
}

extension EditorSession {
    func selectionCopyRegion() -> CGRect? {
        guard let document else { return nil }
        let canvas = CGRect(origin: .zero, size: document.size)
        let bounds = document.selection?.path.boundingBox ?? canvas
        let minX = floor(bounds.minX + 0.001)
        let minY = floor(bounds.minY + 0.001)
        let region = CGRect(x: minX, y: minY,
                            width: ceil(bounds.maxX - 0.001) - minX,
                            height: ceil(bounds.maxY - 0.001) - minY).intersection(canvas)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        return region
    }

    var canCopyPixels: Bool {
        canEditLayers && activeLayer?.asset != nil && document?.selection?.isEmpty != true
    }

    func copySelection() {
        guard canCopyPixels, let region = selectionCopyRegion() else { return }
        do {
            let rendered = try render()
            guard let image = rendered.cropping(to: region) else { return }
            storePixelClipboard(PixelClipboard(image: image,
                                               origin: CGPoint(x: floor(region.minX), y: floor(region.minY))))
        } catch { }
    }

    func copyMergedSelection() {
        guard canEditLayers, let region = selectionCopyRegion() else { return }
        do {
            guard let image = try render().cropping(to: region) else { return }
            storePixelClipboard(PixelClipboard(image: image,
                                               origin: CGPoint(x: floor(region.minX), y: floor(region.minY))))
        } catch { }
    }

    func paste() {
        guard canEditLayers, let clipboard = pixelClipboard else { return }
        let asset = ImportedImage(image: RasterImage(clipboard.image),
                                  thumbnail: RasterImage(PixelAdjust.thumbnail(of: clipboard.image)),
                                  name: nextLayerName())
        try? performEdit("Paste") { doc in
            var layer = ImageLayer(asset: asset, origin: clipboard.origin)
            layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
            let insertion = doc.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? doc.layers.count
            doc.layers.insert(layer, at: min(insertion, doc.layers.count))
            setActiveLayer(layer.id)
            doc.selection = nil
        }
    }

    func cutSelection() {
        guard canCopyPixels else { return }
        copySelection()
        guard let region = selectionCopyRegion(), let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }),
              let asset = document?.layers[index].asset,
              let cropped = asset.image.pixels.cropping(to: region) else { return }
        var next = document!
        next.layers[index].asset = ImportedImage(image: RasterImage(cropped), thumbnail: RasterImage(PixelAdjust.thumbnail(of: cropped)), name: asset.name)
        replaceCurrentDocument(next)
    }

    func duplicateActiveLayer() {
        guard canEditLayers, let document, let layer = activeLayer, !layer.isGroup,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        beginEdit("Duplicate Layer")
        var next = document
        let copy = ImageLayer(id: UUID(), asset: layer.asset, name: "\(layer.name) copy", isVisible: layer.isVisible,
                              transform: layer.transform, parentID: layer.parentID, isGroup: false,
                              opacity: layer.opacity, blendMode: layer.blendMode, mask: layer.mask,
                              maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, shape: layer.shape)
        next.layers.insert(copy, at: index + 1)
        replaceCurrentDocument(next)
        setActiveLayer(copy.id)
        endEdit()
    }

    func layerViaCopy() {
        guard canCopyPixels else { return }
        copySelection()
        paste()
    }

    private func nextLayerName() -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        return "Layer \(number)"
    }
}
