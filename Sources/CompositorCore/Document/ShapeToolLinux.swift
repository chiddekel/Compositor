import Foundation

extension EditorSession {
    func addShape(kind: ShapeKind, rect: CGRect, color: PaletteColor, cornerRadius: CGFloat = 0) throws {
        try requireShapeRect(rect)
        let width = Int(rect.width.rounded()), height = Int(rect.height.rounded())
        var pixels = PixelBuffer(width: width, height: height)
        let radius = min(max(0, cornerRadius), rect.width / 2, rect.height / 2)
        for y in 0..<height {
            for x in 0..<width {
                let px = CGFloat(x) + 0.5, py = CGFloat(y) + 0.5
                let inside: Bool
                switch kind {
                case .ellipse:
                    let dx = (px - rect.width / 2) / max(1, rect.width / 2)
                    let dy = (py - rect.height / 2) / max(1, rect.height / 2)
                    inside = dx * dx + dy * dy <= 1
                case .rectangle:
                    if radius == 0 {
                        inside = true
                    } else {
                        let dx = max(radius - px, 0, px - (rect.width - radius))
                        let dy = max(radius - py, 0, py - (rect.height - radius))
                        inside = dx * dx + dy * dy <= radius * radius ||
                            (px >= radius && px <= rect.width - radius) ||
                            (py >= radius && py <= rect.height - radius)
                    }
                }
                if inside {
                    pixels[x, y] = (UInt8((color.red * 255).rounded()), UInt8((color.green * 255).rounded()),
                                    UInt8((color.blue * 255).rounded()), 255)
                }
            }
        }
        let image = PortableImage(pixels)
        let raster = RasterImage(image)
        let asset = ImportedImage(image: raster, thumbnail: RasterImage(PixelAdjust.thumbnail(of: image)), name: "\(kind.rawValue) 1")
        var layer = ImageLayer(asset: asset, origin: rect.origin)
        layer.name = nextShapeName(kind)
        layer.shape = LayerShape(style: LayerShapeStyle(kind: kind, red: color.red, green: color.green,
                                                        blue: color.blue, cornerRadius: radius), image: raster)
        try performEdit(kind.rawValue) { doc in
            let insertion = doc.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? doc.layers.count
            doc.layers.insert(layer, at: min(insertion, doc.layers.count))
            setActiveLayer(layer.id)
        }
    }

    private func requireShapeRect(_ rect: CGRect) throws {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width >= 1, rect.height >= 1,
              rect.width <= 30_000, rect.height <= 30_000,
              rect.width * rect.height <= 100_000_000, canEditLayers else { throw Failure.invalidArgument }
    }

    private func nextShapeName(_ kind: ShapeKind) -> String {
        let prefix = kind.rawValue
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("\(prefix) \(number)") { number += 1 }
        return "\(prefix) \(number)"
    }
}
