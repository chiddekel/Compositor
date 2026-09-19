// Portable port of Compositor/Document/SmudgeLiquify.swift's tool-mode enums
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `BrushToolMode` and `BlurToolMode`. The macOS original also defines `WarpStroke`,
// a raster class holding a `CGContext` working buffer that smudge/liquify push pixels
// into dab by dab; that is the Skia/CPU raster milestone and is omitted here.
//
// SOLID: the enums keep their responsibilities and contracts (the Brush tool paints
// or erases; the Blur tool liquifies, blurs, or smudges); the Apple API surface
// (the surrounding AppKit import / CGContext raster) is exchanged. The macOS
// original stays the source of truth.

import Foundation

/// The Brush tool's modes.
nonisolated enum BrushToolMode: String, CaseIterable, Sendable {
    case paint = "Paint"
    case erase = "Erase"
}

/// The Blur tool's modes. Smudge and Liquify push the active layer's pixels around under the brush.
nonisolated enum BlurToolMode: String, CaseIterable, Sendable {
    case liquify = "Liquify"
    case blur = "Blur"
    case smudge = "Smudge"
}