// Portable port of Compositor/Document/ColorPalette.swift's `PaletteColor` (file-map
// tier: "Apple replacement/adaptation"). The macOS original carries an `nsColor`
// bridge and an `init?(_ NSColor)`; both depend on AppKit, which is not on Linux.
// The SOLID responsibility of `PaletteColor` — a straight sRGB color, 0–1 per
// channel, that adjustments and the palette read and write — is unchanged; only
// the AppKit color-space bridge is exchanged. The macOS original keeps the bridge
// and the EditorSession palette helpers (SwiftUI-bound, ported with the model).
//
// SOLID: the value type keeps its responsibility and contract; the Apple API
// surface is exchanged. The macOS original stays the source of truth.

import Foundation

nonisolated struct PaletteColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    static let black = PaletteColor(red: 0, green: 0, blue: 0)
    static let white = PaletteColor(red: 1, green: 1, blue: 1)
    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red; self.green = green; self.blue = blue
    }
    // macOS also bridges to/from NSColor here; on Linux the color-space bridge is
    // the Skia/Qt milestone. The straight-sRGB storage and the palette contract it
    // backs are unchanged.
}