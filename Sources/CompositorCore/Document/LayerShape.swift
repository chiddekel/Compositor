// Portable port of Compositor/Document/ShapeTool.swift's value types (file-map
// tier: "Apple replacement/adaptation"). Ported verbatim: `ShapeKind` (cases),
// `LayerShapeStyle` (pure data), `LayerShape` (style + `RasterImage`, `==` via
// `RasterImage` identity, `loaded(_:_:)`), the `ImageLayer.liveShape` extension,
// and `ShapeDraft` (pure data). The macOS original `import AppKit` for `CGPath`;
// on Linux the geometry comes from Foundation + CompositorCore and the image
// from `RasterImage`.
//
// Omitted (raster/path milestone): `ShapeKind.path(in:cornerRadius:)` builds a
// `CGPath` (rectangle/ellipse/rounded-rect). On Linux the path/shape rasterization
// is the Skia/CPU milestone; `PortablePath` (Selection.swift) carries the same
// outline kinds. The `EditorSession` shape helpers (begin/drag/finish/…) are
// SwiftUI-bound (model milestone).
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface (CGPath/CGImage) is exchanged. The macOS original stays the source of
// truth.

import Foundation

nonisolated enum ShapeKind: String, CaseIterable, Codable, Sendable {
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    // macOS also builds a CGPath here (rectangle/ellipse/rounded-rect); on Linux the
    // Skia/CPU path milestone rasterizes these. `PortablePath` carries the same kinds.
}

/// What a shape layer draws, kept so the shape can be drawn again at a new size.
nonisolated struct LayerShapeStyle: Codable, Equatable, Sendable {
    var kind: ShapeKind
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// Document pixels, whatever size the shape is scaled to.
    var cornerRadius: CGFloat
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
}

/// A layer made with the Shape tool. Its pixels are an ordinary raster, so it clips, masks, blends and filters like
/// any layer; `image` is the raster the shape drew. Once anything else changes those pixels (painting, a filter),
/// the layer's image is no longer this one and the layer is plain pixels from then on.
nonisolated struct LayerShape: Equatable, @unchecked Sendable {
    var style: LayerShapeStyle
    let image: RasterImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerShapeStyle?, image: RasterImage?) -> LayerShape? {
        guard let style, let image else { return nil }
        return LayerShape(style: style, image: image)
    }
}

extension ImageLayer {
    /// The shape this layer still is: nil once its pixels were edited some other way.
    var liveShape: LayerShape? {
        guard let shape, let image = asset?.image, image === shape.image else { return nil }
        return shape
    }
}

/// A shape being dragged out with the Shape tool, in whole document pixels.
struct ShapeDraft: Equatable {
    let kind: ShapeKind
    let anchor: CGPoint
    var rect: CGRect
    /// Document pixels, fixed when the drag starts; rectangles only.
    var cornerRadius: CGFloat = 0
}