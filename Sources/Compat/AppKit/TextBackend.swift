import Foundation
import CoreGraphics
#if canImport(Glibc)
import Glibc
#endif

/// Real text layout and rasterisation for the compat text system, from the host's Qt text engine: the shell registers
/// it at startup (`compositor_text_register`, via `compositor_qt_imageio_install`); a process without the shell (the
/// test runner) loads the same functions from the Qt image-codec library, as `ImageCodec` does for images. Without
/// either, the text system keeps its approximate built-in layout.
public enum TextBackend {
    public typealias LayoutFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Double, Double, Double, Double,
                                                UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32
    public typealias RenderFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Double, Double, Double, Double, Int32, Double,
                                                Double, Double, Double, Double, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                                                UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32

    nonisolated(unsafe) static var layoutFn: LayoutFn?
    nonisolated(unsafe) static var renderFn: RenderFn?

    private static let autoloaded: Bool = {
        guard layoutFn == nil else { return true }
        #if canImport(Glibc)
        let env = ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? ""
        typealias Functions = @convention(c) (UnsafeMutablePointer<LayoutFn?>?, UnsafeMutablePointer<RenderFn?>?) -> Int32
        for path in [env, "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"] where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(handle, "compositor_qt_text_functions") else { continue }
            var layout: LayoutFn?, render: RenderFn?
            if unsafeBitCast(sym, to: Functions.self)(&layout, &render) == 1 { layoutFn = layout; renderFn = render; return true }
        }
        #endif
        return false
    }()

    /// The installed faces as the Qt text engine names them ("Family", "Family-Style"), for font menus
    /// (NSFontManager.availableFonts). Empty when the engine isn't there (then the menu falls back to the font files).
    static let fontNames: [String] = {
        #if canImport(Glibc)
        typealias NamesFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int64
        let env = ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? ""
        for path in [env, "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"] where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(handle, "compositor_qt_font_names") else { continue }
            let names = unsafeBitCast(sym, to: NamesFn.self)
            let size = names(nil, 0)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: Int(size) + 1)
            guard names(&buffer, Int(size)) == size else { return [] }
            return String(cString: buffer).split(separator: "\n").map(String.init)
        }
        #endif
        return []
    }()

    public struct Layout { public let width: CGFloat; public let height: CGFloat; public let baseline: CGFloat }

    /// Size and first baseline of `text`, lines `lineHeight` apart (0: 1.2 em), wrapping at `maxWidth` (0: never).
    static func layout(_ text: String, font: NSFont, tracking: CGFloat, lineHeight: CGFloat, maxWidth: CGFloat) -> Layout? {
        _ = autoloaded
        guard let layoutFn else { return nil }
        var w = 0.0, h = 0.0, baseline = 0.0
        let status = text.withCString { t in font.fontName.withCString { f in
            layoutFn(t, f, Double(font.pointSize), Double(tracking), Double(lineHeight), Double(maxWidth), &w, &h, &baseline)
        } }
        return status == 0 ? Layout(width: CGFloat(w), height: CGFloat(h), baseline: CGFloat(baseline)) : nil
    }

    /// The text drawn, premultiplied RGBA, at least `boxWidth` wide with `alignment` (0 left, 1 center, 2 right) in it.
    static func render(_ text: String, font: NSFont, tracking: CGFloat, lineHeight: CGFloat, maxWidth: CGFloat,
                       alignment: Int32, boxWidth: CGFloat, color: NSColor) -> CGImage? {
        _ = autoloaded
        guard let renderFn else { return nil }
        var pixels: UnsafeMutablePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0
        let status = text.withCString { t in font.fontName.withCString { f in
            renderFn(t, f, Double(font.pointSize), Double(tracking), Double(lineHeight), Double(maxWidth), alignment,
                     Double(boxWidth), Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent),
                     Double(color.alphaComponent), &pixels, &w, &h)
        } }
        guard status == 0, let pixels, w > 0, h > 0 else { return nil }
        defer { free(pixels) }
        let data = Data(bytes: pixels, count: Int(w) * Int(h) * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

@_cdecl("compositor_text_register")
public func compositor_text_register(_ layout: TextBackend.LayoutFn?, _ render: TextBackend.RenderFn?) {
    TextBackend.layoutFn = layout
    TextBackend.renderFn = render
}
