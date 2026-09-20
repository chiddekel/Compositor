// Portable port of Compositor/Document/EditorSession.swift's pure value types
// `ImageLayer`, `CanvasDocument`, and `NavigationTool` (file-map tier: "Apple
// replacement/adaptation"). Ported verbatim. The macOS original `import SwiftUI`;
// on Linux the geometry/types come from Foundation + CompositorCore, and
// `Identifiable` is in the Swift standard library.
//
// Omitted from this port (SwiftUI model milestone): the `@Observable final class
// EditorSession` — it is the SwiftUI-bound application state (hundreds of
// @MainActor properties, brush/edit/filter state, continuations). It is not
// portable as-is and is rebuilt as a Qt-side document controller in the UI tier.
// `ImageLayer`, `CanvasDocument`, and `NavigationTool` are the portable model core
// the Qt controller and the operation files build on.
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface (SwiftUI/AppKit) is exchanged. The macOS original stays the source of
// truth.

import Foundation

struct ImageLayer: Identifiable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isVisible == rhs.isVisible && lhs.transform == rhs.transform
            && lhs.asset?.image === rhs.asset?.image && lhs.parentID == rhs.parentID && lhs.isGroup == rhs.isGroup && lhs.opacity == rhs.opacity && lhs.blendMode == rhs.blendMode && lhs.mask == rhs.mask && lhs.maskSourceID == rhs.maskSourceID && lhs.adjustment == rhs.adjustment && lhs.shape == rhs.shape
    }
    let id: UUID
    var asset: ImportedImage?
    var transform: LayerTransform
    var origin: CGPoint { transform.origin }
    var name: String
    var isVisible = true
    var parentID: UUID?
    var isGroup = false
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
    var maskSourceID: UUID?
    var mask: LayerMask?
    var adjustment: LayerAdjustment?
    /// Set on layers the Shape tool made; see `liveShape`.
    var shape: LayerShape?
    var size: CGSize { transform.size }

    init(asset: ImportedImage, origin: CGPoint) {
        self.id = UUID()
        self.asset = asset
        self.transform = LayerTransform(origin: origin, size: CGSize(width: asset.image.width, height: asset.image.height))
        self.name = asset.name
    }

    init(name: String, blankSize: CGSize) {
        self.id = UUID()
        self.asset = nil // Allocate pixels when painting begins, not when adding an empty layer.
        self.transform = LayerTransform(origin: .zero, size: blankSize)
        self.name = name
    }

    init(id: UUID, asset: ImportedImage?, name: String, isVisible: Bool, transform: LayerTransform, parentID: UUID? = nil, isGroup: Bool = false, opacity: Double = 1, blendMode: LayerBlendMode = .normal, mask: LayerMask? = nil, maskSourceID: UUID? = nil, adjustment: LayerAdjustment? = nil, shape: LayerShape? = nil) {
        self.id = id
        self.asset = asset
        self.name = name
        self.isVisible = isVisible
        self.transform = transform
        self.parentID = parentID
        self.isGroup = isGroup
        self.opacity = opacity
        self.blendMode = blendMode
        self.mask = mask
        self.maskSourceID = maskSourceID
        self.adjustment = adjustment
        self.shape = shape
    }
}

struct CanvasDocument: Equatable {
    let id: UUID
    let width: Int
    let height: Int
    var resolution: Double = 72
    var layers: [ImageLayer] = [] // Bottom to top.
    /// Part of the document so undo/redo covers selection changes. Not saved to disk.
    var selection: DocumentSelection?
    var size: CGSize { CGSize(width: width, height: height) }
    init(id: UUID = UUID(), width: Int, height: Int, layers: [ImageLayer] = [], resolution: Double = 72) {
        self.id = id
        self.width = width
        self.height = height
        self.layers = layers
        self.resolution = resolution
    }

    // Geometry limit; raster memory limits will be established with image import.
    static func validDimension(_ value: String) -> Int? {
        guard let n = Int(value.trimmingCharacters(in: .whitespaces)),
              (1...30_000).contains(n) else { return nil }
        return n
    }
}

enum NavigationTool: String, CaseIterable {
    case move, marquee, lasso, wand, crop, brush, spotHealing, cloneStamp, blur, gradient, shape, eyedropper, hand, zoom
    /// No tool (A): nothing in the tool rail is selected and canvas clicks do nothing.
    case idle
    /// Tools that paint with the brush tip, sharing its size, hardness, opacity, and keys.
    var isBrushTool: Bool { self == .brush || self == .spotHealing || self == .cloneStamp || self == .blur }
    /// Tools that draw and edit selections, sharing modifiers, moving, and nudging.
    var isSelectionTool: Bool { self == .marquee || self == .lasso || self == .wand }
    var symbol: String { self == .eyedropper ? "eyedropper" : self == .marquee ? "rectangle.dashed" : self == .lasso ? "lasso" : self == .wand ? "wand.and.stars" : self == .brush ? "paintbrush.pointed" : self == .spotHealing ? "bandage" : self == .cloneStamp ? "seal" : self == .blur ? "drop" : self == .gradient ? "square.bottomhalf.filled" : self == .shape ? "square.on.circle" : self == .crop ? "crop" : self == .move ? "arrow.up.left.and.arrow.down.right" : self == .hand ? "hand.draw" : "magnifyingglass" }
    var label: String { self == .eyedropper ? "Eyedropper (I)" : self == .marquee ? "Marquee (M)" : self == .lasso ? "Lasso (L)" : self == .wand ? "Magic Wand (W)" : self == .brush ? "Brush (B) · Eraser (E)" : self == .spotHealing ? "Spot Healing Brush (J)" : self == .cloneStamp ? "Clone Stamp (S) · Option-click sets the source" : self == .blur ? "Smear (R)" : self == .gradient ? "Gradient (G)" : self == .shape ? "Shape (U) · Shift-U switches Rectangle/Ellipse" : self == .crop ? "Crop (C)" : self == .move ? "Move / Transform (V)" : self == .hand ? "Hand (H)" : "Zoom (Z)" }
}