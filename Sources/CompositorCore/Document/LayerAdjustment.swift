// Portable port of Compositor/Document/LayerAdjustment.swift's pure data + validation
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `AdjustmentKind` (with its SF Symbol `symbol` strings kept as opaque data — the Qt
// UI maps them to icons later — and its `filterKind` bridge) and `LayerAdjustment`
// (storage for every adjustment kind, the `resolvedHSV`/`exposure`/`gradientMap`/
// `grain` accessors, and `isValid`). The macOS original `import AppKit`/`CoreImage`;
// on Linux the settings types come from Foundation + CompositorCore.
//
// Omitted from this port (raster / model milestones):
//   - `LayerAdjustment.apply(_ image:)` — routes each kind through a CGImage-taking
//     filter (`HueSaturationFilter.run`, `LevelsFilter.run`, `curves.apply`, …),
//     all of which are the Skia/CPU raster milestone.
//   - the `EditorSession` add/update helpers — SwiftUI-bound, ported with the model.
// `LayerAdjustment` is the dependency of `ImageLayer` (the document model).
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface is exchanged. The macOS original stays the source of truth.

import Foundation

nonisolated enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
    case hsv = "Hue/Saturation", levels = "Levels", curves = "Curves"
    case exposure = "Exposure", gradientMap = "Gradient Map", grain = "Grain"
    var symbol: String {
        switch self {
        case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
        case .levels: return "slider.horizontal.3"
        case .hsv: return "circle.lefthalf.filled"
        case .exposure: return "plusminus.circle"
        case .gradientMap: return "paintpalette"
        case .grain: return "circle.grid.3x3"
        }
    }
    /// The filter panel that edits this kind; Levels and Hue/Saturation have panels of their own.
    var filterKind: FilterKind? {
        switch self {
        case .curves: return .curves
        case .exposure: return .exposure
        case .gradientMap: return .gradientMap
        case .grain: return .grain
        case .hsv, .levels: return nil
        }
    }
}

nonisolated struct LayerAdjustment: Codable, Equatable, Sendable {
    var kind: AdjustmentKind
    var hue: Double = 0
    var saturation: Double = 0
    var lightness: Double = 0
    var colorize = false
    // Optional so projects saved before range-aware HSV adjustments still decode.
    var hsvSettings: HueSaturationSettings?
    var resolvedHSV: HueSaturationSettings {
        hsvSettings ?? HueSaturationSettings(hue: hue, saturation: saturation, lightness: lightness, colorize: colorize)
    }
    var levels = LevelsSettings()
    var curves = CurvesSettings()
    // Optional so projects saved before these adjustments existed decode, and save, exactly as before.
    var exposureSettings: ExposureSettings?
    var gradientMapSettings: GradientMapSettings?
    var grainSettings: GrainSettings?
    var exposure: ExposureSettings {
        get { exposureSettings ?? ExposureSettings() }
        set { exposureSettings = newValue }
    }
    var gradientMap: GradientMapSettings {
        get { gradientMapSettings ?? GradientMapSettings() }
        set { gradientMapSettings = newValue }
    }
    var grain: GrainSettings {
        get { grainSettings ?? GrainSettings() }
        set { grainSettings = newValue }
    }
    var isValid: Bool {
        hue.isFinite && saturation.isFinite && lightness.isFinite && abs(hue) <= 360 && abs(saturation) <= 100 && abs(lightness) <= 100
        && resolvedHSV.adjustments.values.allSatisfy {
            $0.hue.isFinite && abs($0.hue) <= 360 && $0.saturation.isFinite && abs($0.saturation) <= 100
                && $0.lightness.isFinite && abs($0.lightness) <= 100
        }
        && resolvedHSV.bands.values.allSatisfy { $0.handles.allSatisfy { $0.isFinite } }
        && levels.ranges.count == 4 && levels.ranges.allSatisfy { $0 == $0.normalized } && curves.isValid
        && exposure.isValid && gradientMap.isValid && grain.isValid
    }
    // macOS also applies the adjustment to an image here (routing each kind to a
    // CGImage-taking filter); that raster backend is the Skia/CPU milestone.
}