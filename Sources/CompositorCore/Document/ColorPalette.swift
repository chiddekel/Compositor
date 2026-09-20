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

extension PaletteColor {
    /// Snaps to the 8-bit values that painting and export actually store.
    var quantized: PaletteColor {
        PaletteColor(red: (red * 255).rounded() / 255, green: (green * 255).rounded() / 255, blue: (blue * 255).rounded() / 255)
    }
    var hex: String {
        String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    /// Accepts `RRGGBB` or shorthand `RGB`, with or without a leading `#`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255)
    }
}

/// What the open color picker edits: a palette swatch, or one end of the Gradient Map being edited.
enum ColorPickerTarget: Equatable {
    case palette(background: Bool)
    case gradientMap(highlights: Bool)
    var title: String {
        switch self {
        case .palette(let background): return background ? "Color Picker (Background Color)" : "Color Picker (Foreground Color)"
        case .gradientMap(let highlights): return highlights ? "Color Picker (Gradient Map Highlights)" : "Color Picker (Gradient Map Shadows)"
        }
    }
}

/// The open color picker's working color. Nothing is written to the palette until OK.
// macOS marks this `@Observable`; the macro is Apple-only, so on Linux it is a plain
// `final class`. The working-color surface (target/original/hsb/color) is unchanged;
// the Qt UI observes mutations through signals where SwiftUI used @Observable.
final class ColorPickerState {
    let target: ColorPickerTarget
    var background: Bool { target == .palette(background: true) }
    let original: PaletteColor
    var hsb: PickerHSB
    var color: PaletteColor { hsb.rgb.quantized }
    init(target: ColorPickerTarget, original: PaletteColor) {
        self.target = target
        self.original = original
        hsb = PickerHSB(original)
    }
    convenience init(background: Bool, original: PaletteColor) {
        self.init(target: .palette(background: background), original: original)
    }
}

/// Hue in degrees, saturation and brightness 0...1. Kept as the picker's source of
/// truth so hue survives dragging through grays and black.
struct PickerHSB: Equatable {
    var hue: CGFloat
    var saturation: CGFloat
    var brightness: CGFloat

    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness
    }
    init(_ color: PaletteColor) {
        self.init(hue: 0, saturation: 0, brightness: 0)
        setRGB(color)
    }

    var rgb: PaletteColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return PaletteColor(red: r + m, green: g + m, blue: b + m)
    }

    /// Updates from RGB while keeping the previous hue for grays and the previous
    /// saturation for black, matching how Photoshop's field behaves.
    mutating func setRGB(_ color: PaletteColor) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let delta = high - low
        brightness = high
        if high > 0 { saturation = delta / high }
        guard delta > 0 else { return }
        var h: CGFloat
        if high == color.red { h = (color.green - color.blue) / delta }
        else if high == color.green { h = (color.blue - color.red) / delta + 2 }
        else { h = (color.red - color.green) / delta + 4 }
        h *= 60
        hue = h < 0 ? h + 360 : h
    }
}