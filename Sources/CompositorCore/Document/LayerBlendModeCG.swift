// The CoreGraphics blend-mode mapping for the domain's `LayerBlendMode`. It lives here, on the domain
// side, because the CoreGraphics compat module must not depend on document types (dependency inversion:
// upstream macOS code defines `cgMode` itself, so this file disappears when upstream's file is compiled).

import CoreGraphics

extension LayerBlendMode {
    public var cgMode: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .difference: return .difference
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        }
    }
}
