// Portable port of Compositor/Document/CloneStamp.swift's `CloneSettings` (file-map
// tier: "Keep logic; replace Apple operations"). The struct is pure data; ported
// verbatim. The macOS original `import AppKit` only for the EditorSession extension
// that follows (the source/offset/sample helpers, which read EditorSession state
// and draw a clone sample via CGContext) — those are the model/raster milestones.
//
// SOLID: the value type keeps its responsibility and contract; the Apple API
// surface is exchanged. The macOS original stays the source of truth.

import Foundation

/// Clone Stamp's options-bar settings.
nonisolated struct CloneSettings: Equatable, Sendable {
    /// The source moves with the brush and keeps its offset between strokes; off, every stroke
    /// starts again at the source point.
    var aligned = true
    /// Copy from every visible layer as shown rather than the active layer alone.
    var sampleAllLayers = false
}