import Foundation
import CoreGraphics
import ImageIO

/// A bitmap wrapper. Rendering symbols/vector art is a macOS feature; on Linux an `NSImage` holds pixels.
open class NSImage: @unchecked Sendable {
    public var size: CGSize
    private var bitmap: CGImage?

    public final class SymbolConfiguration {
        public init(pointSize: CGFloat, weight: Int = 0) {}
    }

    public init(size: CGSize) { self.size = size }
    public init(cgImage: CGImage, size: CGSize) { self.bitmap = cgImage; self.size = size }
    public convenience init(size: CGSize, flipped: Bool, drawingHandler: (CGRect) -> Bool) {
        self.init(size: size)
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let ctx = CGContext(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: flipped)
        _ = drawingHandler(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        bitmap = ctx.makeImage()
    }
    /// SF Symbols do not exist on Linux; callers fall back to their own drawing.
    public convenience init?(systemSymbolName: String, accessibilityDescription: String?) { return nil }
    /// Reads an image the pasteboard holds as PNG/TIFF data (needs the ImageIO codec backend).
    public convenience init?(pasteboard: NSPasteboard) {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = ImageCodecRegistry.decode(data) {
                self.init(cgImage: image, size: CGSize(width: image.width, height: image.height)); return
            }
        }
        return nil
    }

    public func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<CGRect>?, context: NSGraphicsContext?,
                        hints: [NSImageRep.HintKey: Any]?) -> CGImage? { bitmap }
    public func lockFocus() {}
    public func unlockFocus() {}
}

open class NSImageRep {
    public struct HintKey: Hashable, RawRepresentable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
}

public final class NSBitmapImageRep: NSImageRep, @unchecked Sendable {
    public enum FileType { case png, jpeg, tiff, bmp, gif }
    private let image: CGImage
    public init(cgImage: CGImage) { self.image = cgImage }

    public func representation(using type: FileType, properties: [PropertyKey: Any]) -> Data? {
        let uti: String
        switch type { case .png: uti = "public.png"; case .jpeg: uti = "public.jpeg"; case .tiff: uti = "public.tiff"
                      case .bmp: uti = "com.microsoft.bmp"; case .gif: uti = "com.compuserve.gif" }
        return ImageCodecRegistry.encode(image, typeIdentifier: uti)
    }
    public struct PropertyKey: Hashable, RawRepresentable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
}
