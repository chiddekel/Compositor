// Portable port of Compositor/Document/Filters.swift's pure data + validation
// (file-map tier: "Apple replacement/adaptation: Keep transformation math and
// serialization; replace graphics types/paths as needed"). Ported verbatim:
// `FilterKind`, `BackgroundQuality`, and `FilterSettings` (storage + `normalized`).
// The macOS original `import AppKit`, `import CoreImage`, and `import Observation`;
// on Linux none of those are needed for the pure settings struct.
//
// PixelFilter.swift supplies image execution; FilterEdit.swift owns portable
// preview/update/cancel/commit transactions. Qt panel wiring and the offline
// background-removal model remain integration work.
// `FilterSettings` is the dependency of `LayerAdjustment` and the model layer.
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface is exchanged. The macOS original stays the source of truth.

import Foundation

/// Filters from the Filter menu. Each runs on the active image layer, inside the selection if
/// there is one, with a live preview and one undo step on OK.
nonisolated enum FilterKind: String, CaseIterable, Sendable {
    case gaussianBlur = "Gaussian Blur"
    case motionBlur = "Motion Blur"
    case addNoise = "Add Noise"
    case lensCorrection = "Lens Correction"
    case removeBackground = "Remove Background"
    case contentAwareFill = "Content-Aware Fill"
    case curves = "Curves"
    case exposure = "Exposure"
    case gradientMap = "Gradient Map"
    case grain = "Grain"
    var isAutomatic: Bool { self == .contentAwareFill || self == .removeBackground }
    /// Color adjustments: in the Image menu (and editable as adjustment layers), not under Filter.
    var isImageAdjustment: Bool { self == .curves || self == .exposure || self == .gradientMap || self == .grain }
}

/// Remove Background's two ways of working: Apple's own subject mask on its own, or that mask refined against the
/// layer's detail, which recovers hair and fur but takes longer.
nonisolated enum BackgroundQuality: String, CaseIterable, Sendable {
    case basic = "Basic"
    case advanced = "Advanced"
}

/// Every filter's settings; each filter reads only its own.
nonisolated struct FilterSettings: Equatable, Sendable {
    /// Gaussian Blur radius in layer pixels (the blur's standard deviation), 0.1–250.
    var radius: Double = 1
    /// Motion Blur direction in degrees, counterclockwise from horizontal as in Photoshop, −90–90.
    var angle: Double = 0
    /// Motion Blur streak length in layer pixels, 1–2000.
    var distance: Double = 10
    /// Add Noise strength as Photoshop's percentage, 0.1–400.
    var amount: Double = 10
    /// Add Noise distribution: Gaussian (more speckled) instead of Uniform.
    var gaussian = false
    /// Add Noise changes brightness only, the same amount on every channel.
    var monochromatic = false
    /// Lens Correction's Remove Distortion, −100–100: positive straightens barrel distortion
    /// (lines bowing outward), negative straightens pincushion (lines bowing inward).
    var distortion: Double = 0
    var curves = CurvesSettings()
    var exposure = ExposureSettings()
    var gradientMap = GradientMapSettings()
    var grain = GrainSettings()
    /// Remove Background: Basic is the quick subject mask; Advanced refines it (see the three settings below).
    var backgroundQuality: BackgroundQuality = .basic
    /// Remove Background: how far the mask is pulled onto the image's own edges (0 off, in layer pixels).
    var refineEdges: Double = 12
    /// Remove Background: pushes the mask's grays toward black and white, 0–100, clearing haze in thin areas.
    var matteContrast: Double = 25
    /// Remove Background: contracts (negative) or expands (positive) the mask edge, in layer pixels.
    var shiftEdge: Double = 0
    var normalized: Self {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        var result = self
        result.radius = clamp(radius, 0.1...250, 1)
        result.angle = clamp(angle, -90...90, 0)
        result.distance = clamp(distance, 1...2000, 10)
        result.amount = clamp(amount, 0.1...400, 10)
        result.distortion = clamp(distortion, -100...100, 0)
        result.refineEdges = clamp(refineEdges, 0...40, 12)
        result.matteContrast = clamp(matteContrast, 0...100, 25)
        result.shiftEdge = clamp(shiftEdge, -10...10, 0)
        result.exposure = exposure.normalized
        result.gradientMap = gradientMap.normalized
        result.grain = grain.normalized
        return result
    }
}
