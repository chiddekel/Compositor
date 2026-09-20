// Portable port of Compositor/Document/ImageAdjustments.swift's pure data +
// validation + table-building math (file-map tier: "Keep logic; replace Apple
// operations"). Ported verbatim: `AdjustmentColor`, `ExposureSettings`,
// `GradientMapSettings`, and `GrainSettings` — their storage, `isValid`/
// `normalized` validation, and the pure lookup-table generators
// (`ExposureSettings.table`, `GradientMapSettings`'s color table). The macOS
// original `import AppKit` for CoreGraphics types; on Linux those come from
// Foundation.
//
// Omitted from this port (raster milestone):
//   - `ImageAdjustmentPixels.run` — draws an image into a CGContext and hands the
//     raw pixel buffer to a C-kernel closure. The C kernels are already portable;
//     the CGContext drawing backend is the Skia/CPU raster milestone. The pure
//     `clamp` helper it carried is kept (validation depends on it).
//   - every `apply(_ image:)` method — each builds a table then routes it through
//     `ImageAdjustmentPixels.run` + a C kernel. The tables are pure (ported); the
//     image routing is the raster milestone.
// The settings structs are the dependency of `FilterSettings` and the model layer.
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface is exchanged. The macOS original stays the source of truth.

import Foundation

/// Shared clamping for adjustment validation: finite values stay in range, non-finite
/// values fall back to the identity. The macOS original lived on `ImageAdjustmentPixels`
/// alongside the CGContext-based `run`; here it stands alone, the raster `run` being the
/// Skia/CPU milestone.
nonisolated enum AdjustmentClamp {
    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// A straight sRGB color stored with an adjustment, 0–1 per channel.
nonisolated struct AdjustmentColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
    init(_ color: PaletteColor) { self.init(red: Double(color.red), green: Double(color.green), blue: Double(color.blue)) }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var clamped: Self {
        Self(red: AdjustmentClamp.clamp(red, 0...1, 0), green: AdjustmentClamp.clamp(green, 0...1, 0),
             blue: AdjustmentClamp.clamp(blue, 0...1, 0))
    }
}

/// Photoshop's Exposure: `exposure` (stops) scales linear light and `offset` shifts it, then gamma
/// correction bends the result. The same curve runs on every channel; alpha is kept.
nonisolated struct ExposureSettings: Codable, Equatable, Sendable {
    static let exposureRange: ClosedRange<Double> = -20...20
    static let offsetRange: ClosedRange<Double> = -0.5...0.5
    static let gammaRange: ClosedRange<Double> = 0.01...9.99
    /// Stops of light, −20…20.
    var exposure: Double = 0
    /// Added in linear light, −0.5…0.5: negative deepens the shadows, positive lifts them.
    var offset: Double = 0
    /// Gamma correction, 0.01…9.99; above 1 brightens the midtones.
    var gamma: Double = 1
    var isValid: Bool { Self.exposureRange.contains(exposure) && Self.offsetRange.contains(offset) && Self.gammaRange.contains(gamma) }
    var normalized: Self {
        Self(exposure: AdjustmentClamp.clamp(exposure, Self.exposureRange, 0),
             offset: AdjustmentClamp.clamp(offset, Self.offsetRange, 0),
             gamma: AdjustmentClamp.clamp(gamma, Self.gammaRange, 1))
    }
    /// Each channel's output (0–1) for each input byte, decoded to linear light and encoded back.
    var table: [Float] {
        let scale = pow(2, exposure)
        return (0...255).map { index in
            let encoded = Double(index) / 255
            var linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            linear = pow(max(0, linear * scale + offset), 1 / gamma)
            let output = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return Float(min(1, max(0, output)))
        }
    }
    // macOS also applies the table to an image here via ImageAdjustmentPixels.run +
    // levels_apply; that raster backend is the Skia/CPU milestone.
}

/// Gradient Map: each pixel's brightness picks a color between `shadows` and `highlights` (the other
/// way round when reversed); alpha is kept.
nonisolated struct GradientMapSettings: Codable, Equatable, Sendable {
    var shadows = AdjustmentColor(red: 0, green: 0, blue: 0)
    var highlights = AdjustmentColor(red: 1, green: 1, blue: 1)
    var reversed = false
    var isValid: Bool { shadows.isValid && highlights.isValid }
    var normalized: Self {
        var result = self
        result.shadows = shadows.clamped
        result.highlights = highlights.clamped
        return result
    }
    /// The colors for the darkest and lightest tones, in the order they apply.
    var ends: (dark: AdjustmentColor, light: AdjustmentColor) { reversed ? (highlights, shadows) : (shadows, highlights) }
    /// The 256-entry RGB lookup the gradient runs on (pure): byte index → [r, g, b] in 0–255.
    var table: [UInt8] {
        let (dark, light) = ends
        return (0...255).flatMap { index -> [UInt8] in
            let t = Double(index) / 255
            return [dark.red + (light.red - dark.red) * t, dark.green + (light.green - dark.green) * t,
                    dark.blue + (light.blue - dark.blue) * t].map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }
        }
    }
    // macOS also applies the table to an image here via ImageAdjustmentPixels.run +
    // adjust_gradient_map; that raster backend is the Skia/CPU milestone.
}

/// Film grain: brightness noise, strongest in the midtones. Its pattern is fixed in document space by
/// `seed`, so it stays put as the canvas pans or redraws part of the image.
nonisolated struct GrainSettings: Codable, Equatable, Sendable {
    static let amountRange: ClosedRange<Double> = 0...100
    static let sizeRange: ClosedRange<Double> = 0.5...20
    static let roughnessRange: ClosedRange<Double> = 0...100
    /// Strength, 0–100.
    var amount: Double = 25
    /// Grain scale in document pixels, 0.5–20.
    var size: Double = 1.5
    /// 0–100: how much per-pixel noise roughens the smooth grain.
    var roughness: Double = 50
    var seed: UInt32 = 0
    var isValid: Bool { Self.amountRange.contains(amount) && Self.sizeRange.contains(size) && Self.roughnessRange.contains(roughness) }
    var normalized: Self {
        var result = self
        result.amount = AdjustmentClamp.clamp(amount, Self.amountRange, 25)
        result.size = AdjustmentClamp.clamp(size, Self.sizeRange, 1.5)
        result.roughness = AdjustmentClamp.clamp(roughness, Self.roughnessRange, 50)
        return result
    }
    // macOS also applies the grain to an image here via ImageAdjustmentPixels.run +
    // adjust_grain; that raster backend is the Skia/CPU milestone.
}