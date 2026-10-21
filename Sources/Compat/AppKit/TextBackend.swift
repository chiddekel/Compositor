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
    private typealias FamilyFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int64
    private static let familyFn: FamilyFn? = {
        let paths = [ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? "",
                     "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"]
        for path in paths where !path.isEmpty {
            guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            guard let symbol = dlsym(library, "compositor_qt_font_family") else { dlclose(library); continue }
            return unsafeBitCast(symbol, to: FamilyFn.self)
        }
        return nil
    }()
    static func familyName(_ name: String) -> String? {
        guard let familyFn else { return nil }
        return name.withCString { name in
            let count = familyFn(name, nil, 0)
            guard count > 0, count <= 64 * 1024 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(count) + 1)
            guard familyFn(name, &buffer, Int(count)) == count else { return nil }
            return String(cString: buffer)
        }
    }
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
    private static let fontNamesLock = NSLock()
    nonisolated(unsafe) private static var cachedFontNames: [String]?
    static var fontNames: [String] {
        fontNamesLock.lock(); defer { fontNamesLock.unlock() }
        if let cachedFontNames { return cachedFontNames }
        #if canImport(Glibc)
        typealias NamesFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int64
        let env = ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? ""
        for path in [env, "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"] where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            defer { dlclose(handle) }
            guard let sym = dlsym(handle, "compositor_qt_font_names") else { continue }
            let names = unsafeBitCast(sym, to: NamesFn.self)
            let size = names(nil, 0)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: Int(size) + 1)
            guard names(&buffer, Int(size)) == size else { return [] }
            let result = String(cString: buffer).split(separator: "\n").map(String.init)
            // A catalog requested before the Qt application exists must remain retryable at first presentation.
            if !result.isEmpty { cachedFontNames = result }
            return result
        }
        #endif
        return []
    }

    typealias MetricsFn = @convention(c) (UnsafePointer<CChar>?, Double, UnsafeMutablePointer<Double>?,
                                          UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32
    nonisolated(unsafe) static let metricsFn: MetricsFn? = {
        #if canImport(Glibc)
        let env = ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? ""
        for path in [env, "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"] where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(handle, "compositor_qt_font_metrics") else { continue }
            return unsafeBitCast(sym, to: MetricsFn.self)
        }
        #endif
        return nil
    }()

    typealias CoversFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UInt32>?, Int32, UnsafeMutablePointer<UInt8>?) -> Int32
    nonisolated(unsafe) static let coversFn: CoversFn? = {
        #if canImport(Glibc)
        let env = ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? ""
        for path in [env, "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"] where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(handle, "compositor_qt_font_covers") else { continue }
            return unsafeBitCast(sym, to: CoversFn.self)
        }
        #endif
        return nil
    }()

    /// Which of `scalars` the face draws itself, from the Qt text engine; nil without it.
    static func covered(_ font: NSFont, _ scalars: [Unicode.Scalar]) -> [Bool]? {
        guard let coversFn else { return nil }
        let codes = scalars.map(\.value)
        var out = [UInt8](repeating: 0, count: codes.count)
        guard coversFn(font._backendName, codes, Int32(codes.count), &out) == 1 else { return nil }
        return out.map { $0 != 0 }
    }

    /// Ascender, descender (negative) and leading of `font`, in points, from the Qt text engine; nil without it.
    static func metrics(_ font: NSFont) -> (ascender: CGFloat, descender: CGFloat, leading: CGFloat)? {
        guard let metricsFn else { return nil }
        var ascent = 0.0, descent = 0.0, leading = 0.0
        guard metricsFn(font._backendName, Double(font.pointSize), &ascent, &descent, &leading) == 1 else { return nil }
        return (CGFloat(ascent), CGFloat(descent), CGFloat(leading))
    }

    typealias AttributeLayoutFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Double, Double, Double, Double,
        UnsafePointer<CChar>?, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32
    typealias AttributeRenderFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Double, Double, Double, Double,
        Int32, Double, Double, Double, Double, Double, UnsafePointer<CChar>?,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    private static let attributedFunctions: (layout: AttributeLayoutFn, render: AttributeRenderFn)? = {
        #if canImport(Glibc)
        let env = ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? ""
        for path in [env, "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"] where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
                  let layout = dlsym(handle, "compositor_qt_text_layout_attributes"),
                  let render = dlsym(handle, "compositor_qt_text_render_attributes") else { continue }
            return (unsafeBitCast(layout, to: AttributeLayoutFn.self), unsafeBitCast(render, to: AttributeRenderFn.self))
        }
        #endif
        return nil
    }()

    /// Effective ranges combine overlapping color/font attributes before crossing
    /// the ABI. Qt therefore receives disjoint ranges in the same UTF-16 units.
    private static func attributesJSON(_ string: NSAttributedString, font: NSFont, color: NSColor) -> String? {
        var runs: [[String: Any]] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            let face = attributes[.font] as? NSFont ?? font
            let ink = attributes[.foregroundColor] as? NSColor ?? color
            runs.append(["location": range.location, "length": range.length, "font": face._backendName,
                         "size": Double(face.pointSize), "color": [Double(ink.redComponent), Double(ink.greenComponent),
                             Double(ink.blueComponent), Double(ink.alphaComponent)]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: runs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func layout(_ string: NSAttributedString, maxWidth: CGFloat) -> Layout? {
        let attributes = string.length > 0 ? string.attributes(at: 0, effectiveRange: nil) : [:]
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
        let tracking = attributes[.kern] as? CGFloat ?? 0
        let leading = (attributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 0
        guard let functions = attributedFunctions,
              let json = attributesJSON(string, font: font, color: .black) else {
            return layout(string.string, font: font, tracking: tracking, lineHeight: leading, maxWidth: maxWidth)
        }
        var width = 0.0, height = 0.0, baseline = 0.0
        let status = string.string.withCString { text in font._backendName.withCString { name in json.withCString { runs in
            functions.layout(text, name, Double(font.pointSize), Double(tracking), Double(leading), Double(maxWidth),
                             runs, &width, &height, &baseline)
        } } }
        return status == 0 ? Layout(width: CGFloat(width), height: CGFloat(height), baseline: CGFloat(baseline)) : nil
    }

    public static func render(_ string: NSAttributedString, maxWidth: CGFloat, alignment: Int32, boxWidth: CGFloat) -> CGImage? {
        let attributes = string.length > 0 ? string.attributes(at: 0, effectiveRange: nil) : [:]
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
        let color = attributes[.foregroundColor] as? NSColor ?? .black
        let tracking = attributes[.kern] as? CGFloat ?? 0
        let leading = (attributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 0
        guard let functions = attributedFunctions, let json = attributesJSON(string, font: font, color: color) else {
            var runs: [(NSRange, NSColor)] = []
            string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { value, range, _ in
                if let ink = value as? NSColor, ink != color { runs.append((range, ink)) }
            }
            return render(string.string, font: font, tracking: tracking, lineHeight: leading, maxWidth: maxWidth,
                          alignment: alignment, boxWidth: boxWidth, color: color, runs: runs)
        }
        var pixels: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0
        let status = string.string.withCString { text in font._backendName.withCString { name in json.withCString { runs in
            functions.render(text, name, Double(font.pointSize), Double(tracking), Double(leading), Double(maxWidth), alignment,
                             Double(boxWidth), Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent),
                             Double(color.alphaComponent), runs, &pixels, &width, &height)
        } } }
        guard status == 0, let pixels, width > 0, height > 0 else { return nil }
        defer { free(pixels) }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: Int(width) * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = context.data else { return nil }
        destination.copyMemory(from: pixels, byteCount: Int(width) * Int(height) * 4)
        return context.makeImage()
    }

    public struct Layout { public let width: CGFloat; public let height: CGFloat; public let baseline: CGFloat }

    /// Size and first baseline of `text`, lines `lineHeight` apart (0: 1.2 em), wrapping at `maxWidth` (0: never).
    public static func layout(_ text: String, font: NSFont, tracking: CGFloat, lineHeight: CGFloat, maxWidth: CGFloat) -> Layout? {
        _ = autoloaded
        guard let layoutFn else { return nil }
        var w = 0.0, h = 0.0, baseline = 0.0
        let status = text.withCString { t in font._backendName.withCString { f in
            layoutFn(t, f, Double(font.pointSize), Double(tracking), Double(lineHeight), Double(maxWidth), &w, &h, &baseline)
        } }
        return status == 0 ? Layout(width: CGFloat(w), height: CGFloat(h), baseline: CGFloat(baseline)) : nil
    }

    /// The text drawn, premultiplied RGBA, at least `boxWidth` wide with `alignment` (0 left, 1 center, 2 right) in it.
    typealias RenderRunsFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Double, Double, Double, Double, Int32, Double,
                                             Double, Double, Double, Double, UnsafePointer<Double>?, Int32,
                                             UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int32>?,
                                             UnsafeMutablePointer<Int32>?) -> Int32
    nonisolated(unsafe) static let renderRunsFn: RenderRunsFn? = {
        #if canImport(Glibc)
        let env = ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? ""
        for path in [env, "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"] where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(handle, "compositor_qt_text_render_runs") else { continue }
            return unsafeBitCast(sym, to: RenderRunsFn.self)
        }
        #endif
        return nil
    }()

    /// `render` with letters colored on their own: each run is a UTF-16 range and its color.
    public static func render(_ text: String, font: NSFont, tracking: CGFloat, lineHeight: CGFloat, maxWidth: CGFloat,
                              alignment: Int32, boxWidth: CGFloat, color: NSColor, runs: [(NSRange, NSColor)]) -> CGImage? {
        guard !runs.isEmpty, let renderRunsFn else {
            return render(text, font: font, tracking: tracking, lineHeight: lineHeight, maxWidth: maxWidth, alignment: alignment,
                          boxWidth: boxWidth, color: color)
        }
        let flat = runs.flatMap { range, c in
            [Double(range.location), Double(range.length), Double(c.redComponent), Double(c.greenComponent),
             Double(c.blueComponent), Double(c.alphaComponent)]
        }
        var pixels: UnsafeMutablePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0
        let status = text.withCString { t in font._backendName.withCString { f in
            flat.withUnsafeBufferPointer { r in
                renderRunsFn(t, f, Double(font.pointSize), Double(tracking), Double(lineHeight), Double(maxWidth), alignment,
                             Double(boxWidth), Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent),
                             Double(color.alphaComponent), r.baseAddress, Int32(runs.count), &pixels, &w, &h)
            }
        } }
        guard status == 0, let pixels, w > 0, h > 0 else { return nil }
        defer { free(pixels) }
        let count = Int(w) * Int(h) * 4
        guard let context = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: Int(w) * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = context.data else { return nil }
        destination.copyMemory(from: pixels, byteCount: count)
        return context.makeImage()
    }

    public static func render(_ text: String, font: NSFont, tracking: CGFloat, lineHeight: CGFloat, maxWidth: CGFloat,
                       alignment: Int32, boxWidth: CGFloat, color: NSColor) -> CGImage? {
        _ = autoloaded
        guard let renderFn else { return nil }
        var pixels: UnsafeMutablePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0
        let status = text.withCString { t in font._backendName.withCString { f in
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
