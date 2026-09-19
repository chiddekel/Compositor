// Portable port of Compositor/Document/SelectionEdits.swift + SelectionClipboard.swift's
// portable slices (file-map tier: "Keep logic; replace Apple operations"). Ported
// verbatim: the `FillSource` enum and `selectionCopyRegion(selection:canvas:)` —
// the whole-pixel bounds of what Copy takes (the selection, or the whole canvas),
// rounded with a tolerance to absorb path-boolean float noise.
//
// On macOS `selectionCopyRegion()` is an `EditorSession` method reading
// `document`/`selection`; ported as a free function over `(selection, canvas)` so
// the geometry is reachable without the app-state class. `boundingBoxOfPath` is
// `PortablePath.boundingBox` on Linux (Foundation provides no CGPath).
//
// Omitted (raster + model milestone):
//   - `PixelMove` (SelectionEdits.swift) — holds a `BrushStroke` raster and a
//     `DocumentSelection` whose `movedSelection` needs `PortablePath.copy(using:)`
//     (deferred); the brush raster engine is the Skia/CPU milestone.
//   - `PixelClipboard` (SelectionClipboard.swift) — a `CGImage` + origin +
//     pasteboard changeCount; the system-pasteboard surface is the Qt/clipboard
//     milestone.
//   - `renderSelectedPixels`/`renderMergedPixels`/`copySelection`/`copyMergedSelection`/
//     `cutSelection`/`paste`/`layerViaCopy`/`duplicateActiveLayer`/`duplicateLayer`/
//     `addPixelLayer`/`fillSelection`/`clearSelectedPixels`/`invertPixels`/the pixel-move
//     helpers — all drive `CGContext`/`BrushStroke`/`NSPasteboard`/`EditorSession`
//     state; raster + model milestone.
//
// SOLID: the copy-region geometry and the fill-source enum keep their
// responsibilities and contracts; the Apple API surface (CGContext, NSPasteboard,
// EditorSession state) is exchanged. The macOS original stays the source of truth.

import Foundation

enum FillSource: Sendable { case foreground, background }

/// Whole-pixel bounds of what Copy takes: the selection, or the whole canvas without one.
/// Path boolean operations leave tiny float noise (59.9999999), so round with a tolerance
/// rather than letting it add a whole pixel.
func selectionCopyRegion(selection: DocumentSelection?, canvas: CGRect) -> CGRect? {
    let bounds = selection?.path.boundingBox ?? canvas
    let tolerance: CGFloat = 0.001
    let minX = floor(bounds.minX + tolerance), minY = floor(bounds.minY + tolerance)
    let region = CGRect(x: minX, y: minY, width: ceil(bounds.maxX - tolerance) - minX,
                        height: ceil(bounds.maxY - tolerance) - minY).intersection(canvas)
    guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
    return region
}