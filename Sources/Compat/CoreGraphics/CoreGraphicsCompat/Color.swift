// CoreGraphicsCompat/Color.swift — CGColor, CGColorSpace, CGBlendMode shims.
//
// Plan §3, §5: CoreGraphics compatibility types for color and blending.
// Maps blend modes to Skia blend mode integers (SkBlendMode).

import Foundation

// MARK: - CGColorSpace

public final class CGColorSpace: @unchecked Sendable, Equatable {
    public enum Model: Sendable {
        case rgb
        case monochrome
        case unknown
    }

    public let name: String
    public let model: Model

    public static let sRGB = CGColorSpace(name: "sRGB", model: .rgb)
    public static let deviceRGB = CGColorSpace(name: "kCGColorSpaceDeviceRGB", model: .rgb)
    public static let deviceGray = CGColorSpace(name: "kCGColorSpaceDeviceGray", model: .monochrome)

    public init(name: String, model: Model = .rgb) {
        self.name = name
        self.model = model
    }

    public static func == (lhs: CGColorSpace, rhs: CGColorSpace) -> Bool {
        lhs.name == rhs.name && lhs.model == rhs.model
    }
}

public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace {
    .deviceRGB
}

public func CGColorSpaceCreateDeviceGray() -> CGColorSpace {
    .deviceGray
}

// MARK: - CGColor

public struct CGColor: Equatable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat
    public var colorSpace: CGColorSpace

    public var components: [CGFloat] {
        if colorSpace.model == .monochrome {
            return [red, alpha]
        }
        return [red, green, blue, alpha]
    }

    public var numberOfComponents: Int {
        colorSpace.model == .monochrome ? 2 : 4
    }

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.colorSpace = .sRGB
    }

    public init(gray: CGFloat, alpha: CGFloat) {
        self.red = gray
        self.green = gray
        self.blue = gray
        self.alpha = alpha
        self.colorSpace = .deviceGray
    }

    public init(colorSpace: CGColorSpace, components: [CGFloat]) {
        self.colorSpace = colorSpace
        if colorSpace.model == .monochrome {
            self.red = components.first ?? 0
            self.green = components.first ?? 0
            self.blue = components.first ?? 0
            self.alpha = components.count > 1 ? components[1] : 1
        } else {
            self.red = components.count > 0 ? components[0] : 0
            self.green = components.count > 1 ? components[1] : 0
            self.blue = components.count > 2 ? components[2] : 0
            self.alpha = components.count > 3 ? components[3] : 1
        }
    }

    public static let white = CGColor(gray: 1, alpha: 1)
    public static let black = CGColor(gray: 0, alpha: 1)
    public static let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
}

// MARK: - CGBlendMode

public enum CGBlendMode: Int32, Sendable, CaseIterable {
    case normal = 0
    case multiply = 1
    case screen = 2
    case overlay = 3
    case darken = 4
    case lighten = 5
    case colorDodge = 6
    case colorBurn = 7
    case softLight = 8
    case hardLight = 9
    case difference = 10
    case exclusion = 11
    case hue = 12
    case saturation = 13
    case color = 14
    case luminosity = 15
    case clear = 16
    case copy = 17
    case sourceIn = 18
    case sourceOut = 19
    case sourceAtop = 20
    case destinationOver = 21
    case destinationIn = 22
    case destinationOut = 23
    case destinationAtop = 24
    case xor = 25
    case plusDarker = 26
    case plusLighter = 27
}

