// Portable port of Compositor/Document/FloatingSelection.swift's selection-transform
// geometry (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `floatingSelectionTransform(_:)` — the affine that maps the original selection
// outline to where the floating pixels now sit. Pure `CGAffineTransform` /
// `LayerTransform` / `BrushRaster.pixelToDocument` geometry.
//
// On macOS this is an `EditorSession` method (it reads `edit.floating` and
// `edit.draft`). Ported here as a free function on `TransformEdit` so the geometry
// is reachable without the app-state class; the Qt document controller calls it
// the same way the macOS `mergeFloatingTransform`/`displayedSelection` did.
//
// Omitted (raster + CGPath + model milestone):
//   - `FloatingTransform` struct — already ported in LayerTransform.swift.
//   - `beginSelectionTransform` / `mergeFloatingTransform` / `cancelFloatingTransform`
//     — they lift/merge pixels through `CGContext`/`DistortWarp.warpTrimmed`/
//     `FloatingMerge.merge` and mutate `EditorSession` state; the raster + model
//     milestone.
//   - `FloatingMerge.merge` — composites the floating pixels back onto the source
//     layer's grid via `CGContext`; raster milestone.
//   - The `PortablePath.copy(using:)` the moved-selection path needs is deferred
//     (PortablePath covers rectangle/ellipse/roundedRect/polygon today); the
//     affine outline carry is the path-raster milestone.
//
// SOLID: the transform math keeps its responsibility and contract (original→draft
// selection mapping); the Apple API surface (CGContext composite, EditorSession
// state, CGPath.copy) is exchanged. The macOS original stays the source of truth.

import Foundation

extension TransformEdit {
    /// Maps the original selection to where the floating pixels are now.
    func floatingSelectionTransform() -> CGAffineTransform? {
        guard let floating = floating else { return nil }
        let width = Int(floating.pixelSize.width), height = Int(floating.pixelSize.height)
        return BrushRaster.pixelToDocument(floating.original, width: width, height: height).inverted()
            .concatenating(BrushRaster.pixelToDocument(draft, width: width, height: height))
    }
}