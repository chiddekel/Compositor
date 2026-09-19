// Portable port of Compositor/Document/HueSaturation.swift's pure data + band
// math + color-cube building (file-map tier: "Keep logic; replace Apple
// operations"). Ported verbatim: `ColorRange`, `HueBand`, `RangeAdjustment`,
// `HueSaturationSettings`, and the pure math of `HueSaturationFilter` —
// `hueResponse`, `cube`, `adjust`, `shiftedHue`, and the `toHSL`/`toRGB`
// conversions. The macOS original `import AppKit`; on Linux the types it needs
// come from Foundation.
//
// Omitted from this port (raster / model milestones):
//   - `HueSaturationJob` (carries a `CGImage`) and `HueSaturationFilter.run`,
//     which routes a `CIColorCube` through CoreImage and `PixelAdjust`. The pure
//     cube it builds is ported; the CoreImage application is the Skia/CPU raster
//     milestone.
//   - the `@Observable` `HueSaturationEdit` and the `EditorSession` helpers —
//     SwiftUI-bound, ported with the document model.
// The band-weight math, the HSL cube, and the per-hue response table are pure and
// are the dependency of `LayerAdjustment` and the model layer.
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface is exchanged. The macOS original stays the source of truth.

import Foundation

nonisolated enum ColorRange: String, CaseIterable, Sendable, Hashable, Codable {
    case master = "Master", reds = "Reds", yellows = "Yellows", greens = "Greens"
    case cyans = "Cyans", blues = "Blues", magentas = "Magentas"

    /// Photoshop's starting hue band: falloff start, range start, range end, falloff end.
    var defaultBand: HueBand {
        switch self {
        case .master: HueBand(falloffStart: 0, rangeStart: 0, rangeEnd: 360, falloffEnd: 360)
        case .reds: HueBand(falloffStart: 315, rangeStart: 345, rangeEnd: 15, falloffEnd: 45)
        case .yellows: HueBand(falloffStart: 15, rangeStart: 45, rangeEnd: 75, falloffEnd: 105)
        case .greens: HueBand(falloffStart: 75, rangeStart: 105, rangeEnd: 135, falloffEnd: 165)
        case .cyans: HueBand(falloffStart: 135, rangeStart: 165, rangeEnd: 195, falloffEnd: 225)
        case .blues: HueBand(falloffStart: 195, rangeStart: 225, rangeEnd: 255, falloffEnd: 285)
        case .magentas: HueBand(falloffStart: 255, rangeStart: 285, rangeEnd: 315, falloffEnd: 345)
        }
    }
    static let colorRanges = ColorRange.allCases.filter { $0 != .master }
}

/// A hue band in degrees, wrapping at 360: full strength between `rangeStart` and
/// `rangeEnd`, fading to nothing at `falloffStart` and `falloffEnd`.
nonisolated struct HueBand: Equatable, Sendable, Codable {
    var falloffStart: Double
    var rangeStart: Double
    var rangeEnd: Double
    var falloffEnd: Double

    /// Degrees from `from` forward to `to`, always 0…360.
    static func forward(_ from: Double, _ to: Double) -> Double {
        let delta = (to - from).truncatingRemainder(dividingBy: 360)
        return delta < 0 ? delta + 360 : delta
    }

    /// How strongly this band claims a hue: 1 inside the range, ramping linearly through
    /// each falloff shoulder, 0 outside. Wraparound is handled by measuring forward.
    func weight(of hue: Double) -> Double {
        let span = Self.forward(falloffStart, falloffEnd)
        guard span > 0 else { return 1 } // Master covers everything.
        let position = Self.forward(falloffStart, hue)
        guard position <= span else { return 0 }
        let rampIn = Self.forward(falloffStart, rangeStart)
        let plateauEnd = Self.forward(falloffStart, rangeEnd)
        if position < rampIn { return rampIn > 0 ? position / rampIn : 1 }
        if position <= plateauEnd { return 1 }
        let rampOut = span - plateauEnd
        return rampOut > 0 ? (span - position) / rampOut : 1
    }

    var handles: [Double] { [falloffStart, rangeStart, rangeEnd, falloffEnd] }

    /// A band centered on one hue, keeping this band's core and shoulder widths.
    func centered(on hue: Double) -> HueBand {
        let core = Self.forward(rangeStart, rangeEnd)
        let leading = Self.forward(falloffStart, rangeStart)
        let trailing = Self.forward(rangeEnd, falloffEnd)
        func wrap(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: 360)
            return remainder < 0 ? remainder + 360 : remainder
        }
        let start = wrap(hue - core / 2)
        return HueBand(falloffStart: wrap(start - leading), rangeStart: start,
                       rangeEnd: wrap(start + core), falloffEnd: wrap(start + core + trailing))
    }
}

nonisolated struct RangeAdjustment: Equatable, Sendable, Codable {
    var hue: Double = 0
    var saturation: Double = 0
    var lightness: Double = 0
}

/// Hue is −180…180 (0…360 when colorizing), Saturation −100…100 (0…100 colorizing),
/// Lightness −100…100. Each color range keeps its own values; Master applies everywhere.
nonisolated struct HueSaturationSettings: Equatable, Sendable, Codable {
    /// Which range the sliders and spectrum edit.
    var range: ColorRange = .master
    var colorize = false
    /// Applies the selected range to everything *outside* its band instead.
    var invertRange = false
    var adjustments: [ColorRange: RangeAdjustment] = [:]
    var bands: [ColorRange: HueBand] = Dictionary(uniqueKeysWithValues: ColorRange.allCases.map { ($0, $0.defaultBand) })

    init(hue: Double = 0, saturation: Double = 0, lightness: Double = 0, colorize: Bool = false,
         range: ColorRange = .master) {
        self.range = range
        self.colorize = colorize
        adjustments[range] = RangeAdjustment(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// The sliders read and write the selected range.
    var hue: Double {
        get { adjustments[range]?.hue ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].hue = newValue }
    }
    var saturation: Double {
        get { adjustments[range]?.saturation ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].saturation = newValue }
    }
    var lightness: Double {
        get { adjustments[range]?.lightness ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].lightness = newValue }
    }
    var band: HueBand {
        get { bands[range] ?? range.defaultBand }
        set { bands[range] = newValue }
    }

    /// Photoshop's starting point when Colorize is switched on.
    static let colorizeStart = HueSaturationSettings(hue: 0, saturation: 25, lightness: 0, colorize: true)
    var isIdentity: Bool { !colorize && adjustments.values.allSatisfy { $0 == RangeAdjustment() } }

    /// How much a range applies to one hue: Master everywhere, others through their band.
    func weight(of colorRange: ColorRange, hue: Double) -> Double {
        guard colorRange != .master else { return 1 }
        let weight = (bands[colorRange] ?? colorRange.defaultBand).weight(of: hue)
        return invertRange && colorRange == range ? 1 - weight : weight
    }
}

/// Builds a color cube from the settings. Only the pure cube-building math is ported; the
/// macOS `run` applies the cube via CoreImage's `CIColorCube`, which is the Skia/CPU raster
/// milestone. Working through a cube keeps slider dragging fast on large images.
nonisolated enum HueSaturationFilter {
    /// 33 points per axis, the usual size for this kind of lookup: fast to build, smooth enough.
    static let dimension = 33

    /// How much every range shifts a given hue, sampled once per degree. Building this
    /// once per settings keeps the cube cheap: without it each of ~36k cube entries would
    /// re-evaluate all seven ranges.
    typealias HueResponse = (shift: Double, saturation: Double, lightness: Double)

    static func hueResponse(_ settings: HueSaturationSettings) -> [HueResponse] {
        (0...360).map { degree in
            var response: HueResponse = (0, 0, 0)
            for (colorRange, adjustment) in settings.adjustments where adjustment != RangeAdjustment() {
                let weight = settings.weight(of: colorRange, hue: Double(degree))
                guard weight > 0 else { continue }
                response.shift += adjustment.hue * weight
                response.saturation += adjustment.saturation * weight
                response.lightness += adjustment.lightness * weight
            }
            return response
        }
    }

    /// The lookup table: every cube corner converted to HSL, adjusted, and back.
    static func cube(_ settings: HueSaturationSettings) -> [Float] {
        let response = hueResponse(settings)
        var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var index = 0
        let step = Double(dimension - 1)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let color = adjust(red: Double(red) / step, green: Double(green) / step, blue: Double(blue) / step,
                                       settings: settings, response: response)
                    values[index] = Float(color.red)
                    values[index + 1] = Float(color.green)
                    values[index + 2] = Float(color.blue)
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values
    }

    static func adjust(red: Double, green: Double, blue: Double, settings: HueSaturationSettings,
                       response: [HueResponse]? = nil) -> (red: Double, green: Double, blue: Double) {
        var (hue, saturation, lightness) = toHSL(red: red, green: green, blue: blue)
        var lightnessAmount = 0.0
        if settings.colorize {
            hue = settings.hue.truncatingRemainder(dividingBy: 360)
            saturation = min(1, max(0, settings.saturation / 100))
            lightnessAmount = settings.lightness / 100
        } else {
            // Every range contributes, weighted by how strongly it claims the original hue.
            let table = response ?? hueResponse(settings)
            let sampled = table[min(table.count - 1, max(0, Int(hue.rounded())))]
            lightnessAmount = sampled.lightness / 100
            hue = (hue + sampled.shift).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            // Multiplicative, so neutral grays stay neutral.
            saturation = min(1, max(0, saturation * (1 + sampled.saturation / 100)))
        }
        // Lightness pulls toward white above 0 and toward black below, reaching either at ±100.
        let amount = min(1, max(-1, lightnessAmount))
        lightness = amount >= 0 ? lightness + (1 - lightness) * amount : lightness * (1 + amount)
        return toRGB(hue: hue, saturation: saturation, lightness: min(1, max(0, lightness)))
    }

    /// The hue a spectrum swatch becomes, for the "after" bar.
    static func shiftedHue(_ hue: Double, settings: HueSaturationSettings) -> Double {
        var shift = 0.0
        for (colorRange, adjustment) in settings.adjustments where adjustment.hue != 0 {
            shift += adjustment.hue * settings.weight(of: colorRange, hue: hue)
        }
        let shifted = (hue + shift).truncatingRemainder(dividingBy: 360)
        return shifted < 0 ? shifted + 360 : shifted
    }

    static func toHSL(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if high == red { hue = (green - blue) / delta }
        else if high == green { hue = (blue - red) / delta + 2 }
        else { hue = (red - green) / delta + 4 }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(1, saturation), lightness)
    }

    static func toRGB(hue: Double, saturation: Double, lightness: Double)
        -> (red: Double, green: Double, blue: Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = lightness - chroma / 2
        let (red, green, blue): (Double, Double, Double)
        switch Int(sector) {
        case 0: (red, green, blue) = (chroma, second, 0)
        case 1: (red, green, blue) = (second, chroma, 0)
        case 2: (red, green, blue) = (0, chroma, second)
        case 3: (red, green, blue) = (0, second, chroma)
        case 4: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        return (min(1, max(0, red + base)), min(1, max(0, green + base)), min(1, max(0, blue + base)))
    }
}