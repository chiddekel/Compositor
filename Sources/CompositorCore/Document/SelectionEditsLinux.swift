import Foundation

extension EditorSession {
    enum FillSource: Sendable { case foreground, background }

    func fillSelection(with source: FillSource) {
        guard canEditLayers, let document, let index = document.layers.firstIndex(where: { $0.id == activeLayerID }),
              let asset = document.layers[index].asset else { return }
        let region = document.selection?.path.boundingBox ?? CGRect(origin: .zero, size: document.size)
        var pixels = PixelBuffer(width: asset.image.width, height: asset.image.height, bytes: asset.image.pixels.bytes)
        let color: (UInt8, UInt8, UInt8, UInt8) = source == .foreground ? (255, 255, 255, 255) : (0, 0, 0, 255)
        let minX = max(0, Int(floor(region.minX - document.layers[index].transform.origin.x)))
        let minY = max(0, Int(floor(region.minY - document.layers[index].transform.origin.y)))
        let maxX = min(asset.image.width, Int(ceil(region.maxX - document.layers[index].transform.origin.x)))
        let maxY = min(asset.image.height, Int(ceil(region.maxY - document.layers[index].transform.origin.y)))
        guard minX < maxX, minY < maxY else { return }
        for y in minY..<maxY {
            for x in minX..<maxX { pixels[x, y] = color }
        }
        beginEdit("Fill")
        var next = document
        let image = PortableImage(pixels)
        next.layers[index].asset = ImportedImage(image: RasterImage(image), thumbnail: RasterImage(PixelAdjust.thumbnail(of: image)), name: asset.name)
        next.layers[index].shape = nil
        next.selection = nil
        replaceCurrentDocument(next)
        endEdit()
    }

    func clearSelectedPixels() {
        guard document?.selection != nil, canEditLayers, let document,
              let index = document.layers.firstIndex(where: { $0.id == activeLayerID }),
              let asset = document.layers[index].asset else { return }
        var pixels = PixelBuffer(width: asset.image.width, height: asset.image.height, bytes: asset.image.pixels.bytes)
        let region = document.selection!.path.boundingBox
        let minX = max(0, Int(floor(region.minX - document.layers[index].transform.origin.x)))
        let minY = max(0, Int(floor(region.minY - document.layers[index].transform.origin.y)))
        let maxX = min(asset.image.width, Int(ceil(region.maxX - document.layers[index].transform.origin.x)))
        let maxY = min(asset.image.height, Int(ceil(region.maxY - document.layers[index].transform.origin.y)))
        guard minX < maxX, minY < maxY else { return }
        for y in minY..<maxY {
            for x in minX..<maxX {
                let pixel = pixels[x, y]
                pixels[x, y] = (0, 0, 0, 0)
                _ = pixel
            }
        }
        beginEdit("Clear")
        var next = document
        let image = PortableImage(pixels)
        next.layers[index].asset = ImportedImage(image: RasterImage(image), thumbnail: RasterImage(PixelAdjust.thumbnail(of: image)), name: asset.name)
        next.layers[index].shape = nil
        replaceCurrentDocument(next)
        endEdit()
    }
}
