// CompositorCore consumes the CoreGraphics compat module as if it were Apple's CoreGraphics: every file in this
// module sees the CG types without an import, exactly as upstream macOS files do via AppKit.

@_exported import CoreGraphics
import Foundation

/// Installs the domain's pure-Swift renderer as the compat context's software fallback. Idempotent; called
/// from every entry point that can create a `CGContext` before a render device is bound.
public enum CompatBootstrap {
    private static let installed: Void = {
        CGContext.softwareDraw = { image, rect, opacity, buffer in
            let raster = RasterImage(image)
            let placement = LayerTransform(origin: rect.origin, size: rect.size, sampling: .smooth)
            LayerRenderer.draw(raster, transform: placement,
                               center: CGPoint(x: rect.midX, y: rect.midY),
                               opacity: opacity, into: &buffer)
        }
    }()
    public static func install() { _ = installed }
}
