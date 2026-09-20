// Portable port of the pure-math portion of Compositor/Document/BrushStroke.swift's
// `BrushRaster` enum (file-map tier: "Apple replacement/adaptation"). Only the
// affine pixel↔document mapping and the brush-falloff function are portable to the
// Linux core with no model/raster-drawing dependency; the CGContext-based
// `context`/`draw`/`fill` members are the Skia-backed raster-drawing milestone and
// are not reimplemented here. The macOS `BrushRaster` keeps those members.
//
// Also ports the pure value types `SpotHealingMode`, `BrushSettings`, and
// `BrushPatch` (storage only — `BrushPatch.image` becomes `PortableImage`, the
// canonical raster substrate, in place of `CGImage`).
//
// SOLID: the math contracts are unchanged; the Apple API surface is exchanged.
// The macOS originals stay the source of truth.

import Foundation

nonisolated enum SpotHealingMode: String, CaseIterable, Sendable, Hashable {
    case contentAware = "Content-Aware"
    case createTexture = "Create Texture"
    case proximityMatch = "Proximity Match"
}

nonisolated struct BrushSettings: Sendable {
    var diameter: CGFloat = 40
    var hardness: CGFloat = 1
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    /// Caps the whole stroke, as in Photoshop: overlapping dabs never exceed it.
    var opacity: CGFloat = 1
    /// Spot-healing uses nearby source pixels instead of the foreground color.
    /// Erase: the stroke clears the layer's pixels instead of painting color on them.
    var erasing = false
    var healing = false
    var healingMode: SpotHealingMode = .contentAware
}

/// A touched tile's replacement pixels. Storage-only port: `image` is the canonical
/// `PortableImage` (RGBA or mask) rather than `CGImage`.
nonisolated struct BrushPatch: @unchecked Sendable {
    let rect: CGRect
    let image: PortableImage
}

/// Shared top-left raster math. The CGContext drawing members (`context`/`draw`/
/// `fill`) are a Skia-backed milestone on Linux; the macOS `BrushRaster` keeps them.
/// Here we port only the pure math the transform and brush layers depend on.
nonisolated enum BrushRaster {
    /// Soft-brush falloff across the region between the hardness radius and the rim:
    /// a normalized Gaussian that fades across the whole radius and reaches zero at the rim.
    static func falloff(_ u: CGFloat) -> CGFloat {
        let k: CGFloat = 2.5
        return max(0, (exp(-k * u * u) - exp(-k)) / (1 - exp(-k)))
    }
    static func pixelToDocument(_ transform: LayerTransform, width: Int, height: Int) -> CGAffineTransform {
        CGAffineTransform(translationX: transform.center.x, y: transform.center.y)
            .rotated(by: transform.radians)
            .scaledBy(x: transform.size.width / CGFloat(width) * (transform.flipX ? -1 : 1),
                      y: transform.size.height / CGFloat(height) * (transform.flipY ? -1 : 1))
            .translatedBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    }
}