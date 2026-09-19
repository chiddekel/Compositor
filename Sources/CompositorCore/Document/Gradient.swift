// Portable port of Compositor/Document/Gradient.swift's value types (file-map
// tier: "Keep logic; replace Apple operations"). Ported verbatim: `GradientStyle`,
// `GradientShape`, and `GradientSettings`. The macOS original `import AppKit` for
// the `GradientEdit` class (which holds a `BrushStroke` — raster) and the
// `EditorSession` gradient helpers (SwiftUI-bound, draw via `BrushStroke.fillGradient`
// and `CGColor`). Those are the model/raster milestones.
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface is exchanged. The macOS original stays the source of truth.

import Foundation

nonisolated enum GradientStyle: String, CaseIterable, Sendable {
    case foregroundToBackground = "Foreground to Background"
    case foregroundToTransparent = "Foreground to Transparent"
}

/// Linear runs from start to end; radial is centered on the start with the end on its rim.
nonisolated enum GradientShape: String, CaseIterable, Sendable {
    case linear = "Linear"
    case radial = "Radial"
}

nonisolated struct GradientSettings: Equatable, Sendable {
    var shape = GradientShape.linear
    var style = GradientStyle.foregroundToTransparent
    var reversed = false
    var opacity: CGFloat = 1
}

// macOS also defines `GradientEdit` here (an uncommitted gradient holding a
// BrushStroke raster + endpoints); that is the raster/model milestone. The
// settings the gradient tool stores are the portable part above.