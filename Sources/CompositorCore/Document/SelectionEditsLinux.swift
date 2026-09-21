import Foundation

// Fill / Clear Selection. Both honour the selection's actual shape (ellipse, lasso,
// combined contours) with its anti-aliased coverage, and map each layer pixel through
// the layer's transform into document space, so a moved, scaled or rotated layer is
// edited where the selection really is. With no selection the whole layer is edited.

extension EditorSession {
    enum FillSource: Sendable { case foreground, background }

    typealias RGBA8 = (UInt8, UInt8, UInt8, UInt8)

    /// `color` is straight RGB in 0...1; the default keeps the previous white foreground / black background.
    func fillSelection(with source: FillSource, color: (red: Double, green: Double, blue: Double)? = nil) {
        let rgb = color ?? (source == .foreground ? (1, 1, 1) : (0, 0, 0))
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        let fill: RGBA8 = (byte(rgb.red), byte(rgb.green), byte(rgb.blue), 255)
        editActiveLayerPixels(name: "Fill", clearSelectionAfter: true) { old, coverage in
            EditorSession.blend(old, toward: fill, coverage: coverage)
        }
    }

    func clearSelectedPixels() {
        guard document?.selection != nil else { return }
        editActiveLayerPixels(name: "Clear", clearSelectionAfter: false) { old, coverage in
            EditorSession.blend(old, toward: (0, 0, 0, 0), coverage: coverage)
        }
    }

    /// Premultiplied RGBA lerp toward `target` by `coverage` / 255.
    private static func blend(_ old: RGBA8, toward target: RGBA8, coverage: Int) -> RGBA8 {
        if coverage >= 255 { return target }
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Int(b) * coverage + Int(a) * (255 - coverage) + 127) / 255) }
        return (mix(old.0, target.0), mix(old.1, target.1), mix(old.2, target.2), mix(old.3, target.3))
    }

    private func editActiveLayerPixels(name: String, clearSelectionAfter: Bool,
                                       _ body: (RGBA8, Int) -> RGBA8) {
        guard canEditLayers, let document, let index = document.layers.firstIndex(where: { $0.id == activeLayerID }),
              let asset = document.layers[index].asset else { return }
        let layer = document.layers[index]
        let canvas = CGRect(origin: .zero, size: document.size)
        var region = canvas
        var coverage: MaskBuffer?
        if let selection = document.selection {
            region = selection.path.boundingBox.insetBy(dx: -1, dy: -1).integral.intersection(canvas)
            guard !selection.isEmpty, !region.isNull, region.width >= 1, region.height >= 1 else { return }
            coverage = selection.rasterized(in: region)
        }
        var pixels = PixelBuffer(width: asset.image.width, height: asset.image.height, bytes: asset.image.pixels.bytes)
        var changed = false
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                var weight = 255
                if let coverage {
                    let p = layer.transform.point(CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(pixels.width),
                                                          y: (CGFloat(y) + 0.5) / CGFloat(pixels.height)))
                    let dx = Int(floor(p.x - region.minX)), dy = Int(floor(p.y - region.minY))
                    guard dx >= 0, dy >= 0, dx < coverage.width, dy < coverage.height else { continue }
                    weight = Int(coverage[dx, dy])
                    if weight == 0 { continue }
                }
                pixels[x, y] = body(pixels[x, y], weight)
                changed = true
            }
        }
        guard changed else { return }
        beginEdit(name)
        var next = document
        let image = PortableImage(pixels)
        next.layers[index].asset = ImportedImage(image: RasterImage(image), thumbnail: RasterImage(PixelAdjust.thumbnail(of: image)), name: asset.name)
        next.layers[index].shape = nil
        if clearSelectionAfter { next.selection = nil }
        replaceCurrentDocument(next)
        endEdit()
    }
}
