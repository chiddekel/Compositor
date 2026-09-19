// Portable port of Compositor/Document/LevelsAutomatic.swift's pure math (file-map
// tier: "Keep logic; replace Apple operations"). Ported verbatim: `LevelsSample`,
// `LevelsAuto.settings(histogram:)`, and `LevelsSettings.sampling(_:mode:)`. These
// compute automatic black/white points (and a neutral-midtone gamma) from a
// 4-channel histogram and calibrate all three channels from one sampled pixel —
// pure functions over `[Double]` / `[[Double]]` and the ported `LevelsSettings`.
//
// Omitted (model + raster milestone, not pure math): the `EditorSession` helpers
// `autoLevels(_:)` and `sampleLevels(at:)` — they read the live `LevelsEdit`
// (`@Observable`), draw a 1x1 crop via `BrushRaster.context`/`draw` (CGContext),
// and route through `updateLevels`. The C `levels_histogram` kernel and the
// CGContext drawing backend are the Skia/CPU raster milestone.
//
// SOLID: the pure math keeps its responsibility and contract (auto black/white
// + neutral gamma from a histogram, sample calibration from a pixel); the Apple
// API surface (CGContext sampling, @Observable edit) is exchanged. The macOS
// original stays the source of truth.

import Foundation

nonisolated enum LevelsSample: String, CaseIterable, Sendable { case black = "Black", gray = "Gray", white = "White" }

nonisolated enum LevelsAuto: String, CaseIterable, Sendable {
    case contrast = "Contrast", color = "Color", neutral = "Color + neutral midtones"
    func settings(histogram: [[Double]]) -> LevelsSettings {
        var result = LevelsSettings()
        func endpoints(_ bins: [Double]) -> (Double, Double)? {
            let total = bins.reduce(0, +)
            guard total > 0 else { return nil }
            var sum = 0.0, low = 0, high = 255
            for i in 0..<256 { sum += bins[i]; if sum > total * 0.001 { low = i; break } }
            sum = 0
            for i in (0..<256).reversed() { sum += bins[i]; if sum > total * 0.001 { high = i; break } }
            return low < high ? (Double(low), Double(high)) : nil
        }
        if self == .contrast {
            // A shared interval preserves channel relationships.
            let limits = histogram.dropFirst().compactMap(endpoints)
            if let low = limits.map({ $0.0 }).min(), let high = limits.map({ $0.1 }).max(), low < high {
                result.ranges[0] = LevelRange(black: low, white: high)
            }
        } else {
            for c in 1...3 {
                guard let (low, high) = endpoints(histogram[c]) else { continue }
                var range = LevelRange(black: low, white: high)
                if self == .neutral {
                    let total = histogram[c].reduce(0, +)
                    let mean = histogram[c].enumerated().reduce(0.0) { $0 + range.apply(Double($1.offset)/255) * $1.element } / total
                    if mean > 0 && mean < 1 { range.gamma = min(9.99, max(0.1, log(mean) / log(0.5))) }
                }
                result.ranges[c] = range
            }
        }
        return result
    }
}

extension LevelsSettings {
    /// Samples are unpremultiplied original RGB. All three channels are calibrated together.
    func sampling(_ rgb: [Double], mode: LevelsSample) -> Self {
        var result = self
        result.ranges[0] = LevelRange()
        for c in 1...3 {
            var range = result.ranges[c]
            let v = rgb[c-1] * 255
            switch mode {
            case .black: range.black = min(range.white - 1, max(0, v))
            case .white: range.white = max(range.black + 1, min(255, v))
            case .gray:
                let fraction = (v - range.black) / (range.white - range.black)
                guard fraction > 0 && fraction < 1 else { continue }
                range.gamma = log(fraction) / log(0.5)
            }
            range.outputBlack = 0; range.outputWhite = 255
            result.ranges[c] = range.normalized
        }
        return result
    }
}