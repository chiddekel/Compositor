// Portable port of Compositor/Document/Levels.swift's pure data + validation + math
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `LevelsChannel`, `LevelRange`, `LevelsSettings`, and the display-only
// `LevelsHistogramDisplay`. The macOS originals `import AppKit` for CoreGraphics
// types and `import Observation` for the `@Observable` edit; on Linux the geometry
// types come from Foundation, so those imports drop.
//
// Omitted from this port (raster / model milestones, not pure math):
//   - `LevelsJob` and `LevelsFilter.run`/`histogram` — they build a CGContext, draw
//     the image, and call the `levels_apply`/`levels_histogram` C kernels. The C
//     kernels already exist portably; the CGContext drawing backend is the
//     Skia/CPU raster milestone.
//   - `LevelsEdit` (`@Observable`) and the `EditorSession` begin/update/cancel/commit
//     helpers — SwiftUI-bound, ported with the document model.
// The `apply(_:channel:)` per-value math and `normalized`/`isIdentity` validation
// are pure and are the dependency of `CurvesSettings` and the model layer.
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface is exchanged. The macOS original stays the source of truth.

import Foundation

nonisolated enum LevelsChannel: String, CaseIterable, Sendable, Codable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    var index: Int { Self.allCases.firstIndex(of: self)! }
}

nonisolated struct LevelRange: Equatable, Sendable, Codable {
    var black: Double = 0
    var gamma: Double = 1
    var white: Double = 255
    var outputBlack: Double = 0
    var outputWhite: Double = 255
    var normalized: Self {
        func clamp(_ n: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            n.isFinite ? min(range.upperBound, max(range.lowerBound, n)) : fallback
        }
        var result = self
        result.black = clamp(black, 0...254, 0)
        result.white = clamp(white, (result.black + 1)...255, 255)
        result.gamma = clamp(gamma, 0.1...9.99, 1)
        result.outputBlack = clamp(outputBlack, 0...255, 0)
        result.outputWhite = clamp(outputWhite, 0...255, 255)
        return result
    }
    func apply(_ value: Double) -> Double {
        let s = normalized
        let input = min(1, max(0, (value * 255 - s.black) / (s.white - s.black)))
        return (s.outputBlack + pow(input, 1 / s.gamma) * (s.outputWhite - s.outputBlack)) / 255
    }
}

nonisolated struct LevelsSettings: Equatable, Sendable, Codable {
    var channel: LevelsChannel = .rgb
    var ranges = Array(repeating: LevelRange(), count: 4)
    var current: LevelRange {
        get { ranges[channel.index] }
        set { ranges[channel.index] = newValue.normalized }
    }
    var isIdentity: Bool { ranges.allSatisfy { $0.normalized == LevelRange() } }
    /// Individual channels, followed by the composite RGB adjustment.
    func apply(_ value: Double, channel: LevelsChannel) -> Double {
        ranges[0].apply(ranges[channel.index].apply(value))
    }
}

/// Display-only vertical scaling. Keep linear bin ratios, but cap isolated spikes
/// so large solid backgrounds cannot flatten the useful tonal distribution.
nonisolated enum LevelsHistogramDisplay {
    static func scale(for bins: [Double]) -> Double {
        let peak = bins.filter { $0.isFinite && $0 > 0 }.max() ?? 0
        guard peak > 0 else { return 0 }
        let interior = bins.dropFirst().dropLast().filter { $0.isFinite && $0 > 0 }.sorted()
        guard !interior.isEmpty else { return peak }
        let typicalPeak = interior[Int(Double(interior.count - 1) * 0.95)]
        return min(peak, typicalPeak * 4)
    }
}