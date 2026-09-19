// Portable port of Compositor/Document/LayerMask.swift's value type + placement math
// (file-map tier: "Apple replacement/adaptation: Keep transformation math and
// serialization; replace graphics types/paths as needed"). Ported verbatim:
// `LayerMask` (storage, `==` via `RasterImage` identity, `replacing(_:)`, and the
// pure `placement(movingLayer:to:)` math) and the `ImageLayer.maskTransform`
// extension. The macOS original `import Foundation`/`CoreGraphics`; on Linux the
// geometry comes from Foundation + CompositorCore and the image from `RasterImage`.
//
// Omitted from this port (raster milestone — Skia/CPU drawing backend):
//   - `LayerMask.enabledImage`/`solid`/`asset(from:)`/`background`/`placed`/
//     `drawSmooth`/`clipImage` — all CGContext/CGImage drawing and resampling.
//   - `MaskPlacementCache`, `FolderMaskClip`, the `ProjectSnapshot` and
//     `EditorSession` extensions, and the `BrushStroke.placedMaskPreview` extension.
// The `enabledImage` accessor returns `RasterImage?` (a thin wrapper) so the model
// keeps its contract; the resampling caches behind it are the raster milestone.
//
// SOLID: the value type keeps its responsibility and contract (immutable,
// normalized layer-local coverage + where it sits); the Apple API surface
// (CGImage/CGContext) is exchanged. The macOS original stays the source of truth.

import Foundation

/// Immutable, normalized layer-local coverage. Regular grayscale images use white
/// for reveal, black for hide, and intermediate gray for soft coverage.
nonisolated struct LayerMask: Equatable, @unchecked Sendable {
    let asset: ImportedImage
    var isEnabled = true
    /// Where the mask sits on the document once it has been moved apart from its layer; nil while it covers the
    /// layer's own pixel grid (and follows every change to it).
    var placement: LayerTransform? = nil
    /// Linked, layer and mask move together; unlinked, each transforms on its own, as in Photoshop.
    var isLinked = true
    var enabledImage: RasterImage? { isEnabled ? asset.image : nil }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.asset.image === rhs.asset.image && lhs.isEnabled == rhs.isEnabled && lhs.placement == rhs.placement && lhs.isLinked == rhs.isLinked
    }
    /// The same mask with new pixels (in its own grid), still enabled or not, linked or not, and where it sits.
    func replacing(_ asset: ImportedImage) -> LayerMask {
        LayerMask(asset: asset, isEnabled: isEnabled, placement: placement, isLinked: isLinked)
    }
    // macOS also validates a mask image's grayscale format here (isValid); on Linux
    // the canonical MaskBuffer substrate carries that contract, so the check moves
    // to the raster/IO milestone.

    // MARK: Placement

    /// Where the mask sits once its layer moves from `old` to `new`: carried along when linked (still covering the
    /// layer, or its own placement moved the same way); left where it was on the document when unlinked.
    func placement(movingLayer old: LayerTransform, to new: LayerTransform) -> LayerTransform? {
        // A uniform mask looks the same wherever it sits.
        guard asset.image.width > 1 || asset.image.height > 1 else { return nil }
        let moved = isLinked ? placement.map { $0.following(from: old, to: new) } : (placement ?? old)
        return moved.flatMap { $0.samePlacement(as: new) ? nil : $0 }
    }
}

extension ImageLayer {
    /// Where the mask's pixels sit on the document: its own placement, else the layer's.
    var maskTransform: LayerTransform { mask?.placement ?? transform }
}