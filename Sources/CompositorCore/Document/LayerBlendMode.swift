// Portable port of Compositor/Document/LayerAppearance.swift's `LayerBlendMode`
// (file-map tier: "Apple replacement/adaptation"). The enum cases and their raw
// values are ported verbatim. The macOS `cgMode` bridge maps each case to a
// `CGBlendMode` (Core Graphics); on Linux the compositing backend is Skia, which
// has its own blend-mode enum, so `cgMode` is omitted and the Skia/Vulkan
// compositing milestone maps `LayerBlendMode` → `SkBlendMode`.
//
// SOLID: the value type keeps its responsibility and contract (the set of blend
// modes the document stores); the Apple API surface (CGBlendMode) is exchanged.
// The macOS original stays the source of truth.

import Foundation

nonisolated enum LayerBlendMode: String, Codable, CaseIterable, Sendable {
    case normal = "Normal", multiply = "Multiply", screen = "Screen", overlay = "Overlay"
    case darken = "Darken", lighten = "Lighten", difference = "Difference"
    case colorDodge = "Color Dodge", colorBurn = "Color Burn"
    case hue = "Hue", saturation = "Saturation", color = "Color", luminosity = "Luminosity"
    // macOS also exposes `cgMode: CGBlendMode` here; on Linux the Skia compositing
    // milestone maps these cases to SkBlendMode. The stored set of modes is unchanged.
}