// Portable port of Compositor/Document/MagicWand.swift's value types (file-map tier:
// "Keep logic; replace Apple operations"). Ported verbatim: `WandSampleSize` and
// `WandSettings`, plus the `MagicWand.Failure` error enum (trivially portable).
//
// Omitted (raster milestone): `MagicWand.select`/`outline` — they build a CGContext,
// draw the image, and call the `wand_mask`/`wand_trace` C kernels to match and outline
// pixels. The C kernels are (or will be) portable; the CGContext drawing backend is
// the Skia/CPU raster milestone. The `EditorSession.magicWand`/`wandSample` helpers
// (drawLiveComposite/LayerRenderer) are model + raster.
//
// SOLID: the value types keep their responsibilities and contracts (the wand's
// options-bar settings); the Apple API surface (CGImage/CGContext/CGPath tracing)
// is exchanged. The macOS original stays the source of truth.

import Foundation

nonisolated enum WandSampleSize: Int, CaseIterable, Sendable {
    case point, threeByThree, fiveByFive
    var title: String { ["Point Sample", "3 by 3 Average", "5 by 5 Average"][rawValue] }
    /// Pixels either side of the click that are averaged into the color to match.
    var radius: Int { rawValue }
}

/// The Magic Wand's options-bar settings.
nonisolated struct WandSettings: Equatable, Sendable {
    /// How far (0–255) each channel may differ from the sampled color and still be selected.
    var tolerance = 32
    var sampleSize = WandSampleSize.point
    /// Only similar pixels connected to the clicked one, rather than every similar pixel.
    var contiguous = true
    /// Read the visible composite rather than just the active layer.
    var sampleAllLayers = false
}

/// Selects pixels similar to a clicked one. Matching and tracing run in C (`WandPixels.c`):
/// in Swift they would crawl on a large canvas in an unoptimized build.
nonisolated enum MagicWand {
    enum Failure: LocalizedError {
        case tooDetailed, memory
        var errorDescription: String? {
            switch self {
            case .tooDetailed: "That selection is too detailed to outline. Try a different Tolerance, or turn on Contiguous."
            case .memory: "There isn’t enough memory to make that selection."
            }
        }
    }
}