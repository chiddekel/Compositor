// Portable port of Compositor/Document/CloneStamp.swift (file-map tier: "Keep
// logic; replace Apple operations"). Ported verbatim: the `CloneSettings` struct
// and the two pure geometry helpers `cloneStrokeOffset(at:...)` and
// `cloneSamplePoint(for:...)`. On macOS those are `EditorSession` methods reading
// `cloneSource`/`cloneOffset`/`cloneSettings`/`brushStroke` state; ported as free
// functions over their inputs so the geometry is reachable without the app-state
// class.
//
// Omitted (raster milestone): `cloneSample(_:)` — draws the active layer or the
// live composite into a `CGContext` via `BrushRaster.context`/`drawLiveComposite`/
// `LayerRenderer.draw`, which is the Skia/CPU raster milestone.
//
// SOLID: the value type and the two free helpers keep their responsibilities and
// contracts; the Apple API surface (CGContext, EditorSession state) is exchanged.
// The macOS original stays the source of truth.

import Foundation

/// Clone Stamp's options-bar settings.
nonisolated struct CloneSettings: Equatable, Sendable {
    /// The source moves with the brush and keeps its offset between strokes; off, every stroke
    /// starts again at the source point.
    var aligned = true
    /// Copy from every visible layer as shown rather than the active layer alone.
    var sampleAllLayers = false
}

/// The whole-pixel offset a stroke starting at `point` would copy with: aligned strokes keep
/// the first stroke's `offset`; otherwise it runs from the brush to the `source`. Nil without a
/// source. Shared by the stroke and the hover preview, so the preview is exactly what a click
/// stamps. (`EditorSession.cloneStrokeOffset(at:)` on macOS.)
func cloneStrokeOffset(at point: CGPoint, source: CGPoint?, offset: CGSize?, settings: CloneSettings) -> CGSize? {
    guard let source else { return nil }
    return (settings.aligned ? offset : nil)
        ?? CGSize(width: (source.x - point.x).rounded(), height: (source.y - point.y).rounded())
}

/// Where the source sits for a brush at `point` (document pixels), for the canvas's crosshair:
/// the source itself until a stroke fixes the offset. (`EditorSession.cloneSamplePoint(for:)`
/// on macOS; `strokeActive` is `brushStroke != nil`.)
func cloneSamplePoint(for point: CGPoint, source: CGPoint?, offset: CGSize?, settings: CloneSettings, strokeActive: Bool) -> CGPoint? {
    guard let source else { return nil }
    guard let offset, settings.aligned || strokeActive else { return source }
    return CGPoint(x: point.x + offset.width, y: point.y + offset.height)
}