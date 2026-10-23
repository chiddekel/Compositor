import Foundation
import CoreGraphics

/// `NSColor` for the subset upstream uses: device-independent sRGB values with a `cgColor`, and drawing helpers
/// that set the colour on the current `NSGraphicsContext`.
open class NSColor: @unchecked Sendable, Equatable {
    public let redComponent: CGFloat
    public let greenComponent: CGFloat
    public let blueComponent: CGFloat
    public let alphaComponent: CGFloat
    /// Same components, same color (AppKit compares colors in the same space by value).
    public static func == (lhs: NSColor, rhs: NSColor) -> Bool {
        lhs.redComponent == rhs.redComponent && lhs.greenComponent == rhs.greenComponent
            && lhs.blueComponent == rhs.blueComponent && lhs.alphaComponent == rhs.alphaComponent
    }

    public init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        redComponent = red; greenComponent = green; blueComponent = blue; alphaComponent = alpha
    }
    /// HSB (all 0...1, hue in turns), as AppKit's.
    public convenience init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        let h = (hue - floor(hue)) * 6, i = Int(h) % 6, f = h - floor(h)
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * f), t = brightness * (1 - saturation * (1 - f))
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = [(brightness, t, p), (q, brightness, p), (p, brightness, t),
                                                     (p, q, brightness), (t, p, brightness), (brightness, p, q)][i]
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
    public convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
    public convenience init(calibratedRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
    public convenience init(white: CGFloat, alpha: CGFloat) {
        self.init(srgbRed: white, green: white, blue: white, alpha: alpha)
    }
    public convenience init(calibratedWhite white: CGFloat, alpha: CGFloat) {
        self.init(srgbRed: white, green: white, blue: white, alpha: alpha)
    }
    public convenience init(cgColor: CGColor) {
        self.init(srgbRed: cgColor.red, green: cgColor.green, blue: cgColor.blue, alpha: cgColor.alpha)
    }

    public var cgColor: CGColor {
        CGColor(red: redComponent, green: greenComponent, blue: blueComponent, alpha: alphaComponent)
    }
    public var whiteComponent: CGFloat { (redComponent + greenComponent + blueComponent) / 3 }

    public func withAlphaComponent(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: redComponent, green: greenComponent, blue: blueComponent, alpha: alpha)
    }

    /// All colours here are sRGB values; converting between the spaces the model asks for keeps the components.
    public func usingColorSpace(_ space: NSColorSpace) -> NSColor? { self }

    public func setFill() { NSGraphicsContext.current?.cgContext.setFillColor(cgColor) }
    public func setStroke() { NSGraphicsContext.current?.cgContext.setStrokeColor(cgColor) }
    public func set() { setFill(); setStroke() }

    public static let white = NSColor(white: 1, alpha: 1)
    /// Dark-aqua text selection highlight (the system accent's selection tint).
    public static let selectedTextBackgroundColor = NSColor(srgbRed: 0.25, green: 0.4, blue: 0.64, alpha: 1)
    public static let black = NSColor(white: 0, alpha: 1)
    public static let clear = NSColor(white: 0, alpha: 0)
    public static let gray = NSColor(white: 0.5, alpha: 1)
    public static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    public static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    public static let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    /// The system accent colour; a fixed blue on Linux (the Qt shell owns real theming).
    // Semantic colors, as the dark appearance gives them (the editor's).
    public static let labelColor = NSColor(white: 1, alpha: 0.85)
    public static let secondaryLabelColor = NSColor(white: 1, alpha: 0.55)
    public static let tertiaryLabelColor = NSColor(white: 1, alpha: 0.25)
    public static let quaternaryLabelColor = NSColor(white: 1, alpha: 0.1)
    public static let separatorColor = NSColor(white: 1, alpha: 0.1)
    public static let textColor = NSColor(white: 1, alpha: 1)
    public static let systemRed = NSColor(srgbRed: 1, green: 0.271, blue: 0.227, alpha: 1)
    public static let systemOrange = NSColor(srgbRed: 1, green: 0.624, blue: 0.039, alpha: 1)
    public static let systemYellow = NSColor(srgbRed: 1, green: 0.839, blue: 0.039, alpha: 1)
    public static let systemGreen = NSColor(srgbRed: 0.188, green: 0.82, blue: 0.345, alpha: 1)
    public static let systemBlue = NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1)
    public static let systemGray = NSColor(srgbRed: 0.596, green: 0.596, blue: 0.616, alpha: 1)
    public static let controlAccentColor = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
    /// A selected row in a list that has the keys, and in one that doesn't (dark appearance).
    public static let selectedContentBackgroundColor = NSColor(srgbRed: 0, green: 0.345, blue: 0.816, alpha: 1)
    public static let unemphasizedSelectedContentBackgroundColor = NSColor(white: 0.275, alpha: 1)
}

public final class NSColorSpace: @unchecked Sendable {
    public let name: String
    private init(_ name: String) { self.name = name }
    public static let sRGB = NSColorSpace("sRGB")
    public static let deviceRGB = NSColorSpace("deviceRGB")
    public static let genericRGB = NSColorSpace("genericRGB")
    public static let displayP3 = NSColorSpace("displayP3")
    public static let genericGamma22Gray = NSColorSpace("genericGamma22Gray")
    public static let deviceGray = NSColorSpace("deviceGray")
}
