// Portable port of Compositor/Document/SelectionEdits.swift + SelectionClipboard.swift's
// portable slices (file-map tier: "Keep logic; replace Apple operations"). Ported
// verbatim: the `FillSource` enum, `selectionCopyRegion(selection:canvas:)`, and
// `PixelMove` — selected pixels being dragged. `PixelMove.movedSelection` uses
// `PortablePath.copy(using:)` (transform by a translation), replacing the macOS
// `CGPath.copy(using:)`.
//
// On macOS `selectionCopyRegion()` is an `EditorSession` method reading
// `document`/`selection`; ported as a free function over `(selection, canvas)` so
// the geometry is reachable without the app-state class. `boundingBoxOfPath` is
// `PortablePath.boundingBox` on Linux (Foundation provides no CGPath).
//
// Omitted (raster + model + Qt milestone):
//   - `PixelClipboard` (SelectionClipboard.swift) — a `CGImage` + origin +
//     pasteboard changeCount; the system-pasteboard surface is the Qt/clipboard
//     milestone.
//   - `renderSelectedPixels`/`renderMergedPixels`/`copySelection`/`copyMergedSelection`/
//     `cutSelection`/`paste`/`layerViaCopy`/`duplicateActiveLayer`/`duplicateLayer`/
//     `addPixelLayer`/`fillSelection`/`clearSelectedPixels`/the pixel-move orchestration
//     helpers — all drive `CGContext`/`BrushStroke`/`NSPasteboard`/`EditorSession`
//     state; raster + model milestone.
//
// SOLID: the copy-region geometry, the fill-source enum, and the pixel-move value
// type keep their responsibilities and contracts; the Apple API surface (CGContext,
// NSPasteboard, EditorSession state) is exchanged. The macOS original stays the
// source of truth.

import Foundation

enum FillSource: Sendable { case foreground, background }

/// Selected pixels being dragged: the lifted raster plus the outline it started from.
/// Ported verbatim from `Compositor/Document/SelectionEdits.swift`; `movedSelection`
/// exchanges `CGPath.copy(using:)` for `PortablePath.copy(using:)`.
final class PixelMove {
    let raster: BrushStroke
    let origin: DocumentSelection
    let duplicate: Bool
    var offset = CGSize.zero
    var movedSelection: DocumentSelection {
        var shift = CGAffineTransform(translationX: offset.width, y: offset.height)
        let path = origin.path.copy(using: &shift)
        return DocumentSelection(path: path, antialiased: origin.antialiased)
    }
    init(raster: BrushStroke, origin: DocumentSelection, duplicate: Bool = false) {
        self.raster = raster
        self.origin = origin
        self.duplicate = duplicate
    }
}

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