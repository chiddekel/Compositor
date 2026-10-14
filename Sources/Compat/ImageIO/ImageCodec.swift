// ImageCodec.swift — the seam under CGImageSource / CGImageDestination.
//
// Decoding and encoding are pluggable (dependency inversion): the Qt host registers its image plugins (PNG, JPEG,
// TIFF, WebP, ...) through `compositor_imageio_register`; without one, a portable pure-Swift PNG codec still lets
// projects, exports and tests round-trip. A backend that does not know a format returns nil.

import Foundation
import CompositorColorManagement
import CompatSupport
#if canImport(Glibc)
import Glibc
#endif
import CoreGraphics
import UniformTypeIdentifiers

public struct ImageInfo: Sendable {
    public var typeIdentifier: String
    public var width: Int
    public var height: Int
    public var bitDepth: Int = 8
    public var dpi: Double?
    /// EXIF orientation 1...8.
    public var orientation: Int32 = 1
    public var hasAlpha = true
    /// Apple's color model (`kCGImagePropertyColorModel`): "RGB", "Gray" or "CMYK".
    public var colorModel = "RGB"
    /// The embedded profile's description (`kCGImagePropertyProfileName`), when the file carries one.
    public var profileName: String?
    public init(typeIdentifier: String, width: Int, height: Int, bitDepth: Int = 8, dpi: Double? = nil,
                orientation: Int32 = 1, hasAlpha: Bool = true) {
        self.typeIdentifier = typeIdentifier; self.width = width; self.height = height; self.bitDepth = bitDepth
        self.dpi = dpi; self.orientation = orientation; self.hasAlpha = hasAlpha
    }
}

public protocol ImageCodecBackend: AnyObject {
    /// Cheap header read; nil when the format is not recognised.
    func identify(_ data: Data) -> ImageInfo?
    /// Full decode to 8-bit premultiplied RGBA (or an 8-bit gray plane as a mask image).
    func decode(_ data: Data) -> CGImage?
    /// `quality` is 0...1 for lossy formats; `dpi` is written when the format can carry it.
    func encode(_ image: CGImage, typeIdentifier: String, quality: Double?, dpi: Double?) -> Data?
    /// Like `encode` but also records an EXIF orientation (1...8) in the file when the format can carry one.
    func encode(_ image: CGImage, typeIdentifier: String, quality: Double?, dpi: Double?, orientation: Int32) -> Data?
}

public extension ImageCodecBackend {
    func encode(_ image: CGImage, typeIdentifier: String, quality: Double?, dpi: Double?, orientation: Int32) -> Data? {
        encode(image, typeIdentifier: typeIdentifier, quality: quality, dpi: dpi)
    }
}

public enum ImageCodecRegistry {
    /// Tried first; falls through to the portable codec when it does not handle a format.
    public static let hostSlot = ServiceSlot<ImageCodecBackend>()
    public static var host: ImageCodecBackend? {
        get { hostSlot.installedValue }
        set { hostSlot.install(newValue) }
    }
    /// Runs `body` with `codec` as the host backend (nil: only the portable codecs), then restores the previous one.
    public static func withHost<Result>(_ codec: ImageCodecBackend?, _ body: () throws -> Result) rethrows -> Result {
        try hostSlot.withOverride(codec, body)
    }
    public static let portable: ImageCodecBackend = PortablePNGCodec()

    static var backends: [ImageCodecBackend] {
        _ = autoloaded
        return host.map { [$0, portable, gif] } ?? [portable, gif]
    }
    static let gif: ImageCodecBackend = PortableGIFEncoder()

    /// Without a host-registered backend, look for the Qt codec library (`COMPOSITOR_IMAGEIO_BACKEND`, then the
    /// system loader path and the Flatpak install) once, the way the Skia bridge is found.
    private static let autoloaded: Bool = {
        guard host == nil else { return false }
        #if canImport(Glibc)
        let env = ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] ?? ""
        // Environment override, the system loader's path, or the Flatpak install: never the working directory.
        let candidates = [env, "libCompositorQtImageIO.so", "/app/lib/libCompositorQtImageIO.so"]
        typealias Functions = @convention(c) (UnsafeMutablePointer<CompositorImageDecodeFn?>?, UnsafeMutablePointer<CompositorImageEncodeFn?>?) -> Int32
        for path in candidates where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(handle, "compositor_qt_imageio_functions") else { continue }
            var decode: CompositorImageDecodeFn?, encode: CompositorImageEncodeFn?
            if unsafeBitCast(sym, to: Functions.self)(&decode, &encode) == 1, let decode, let encode {
                typealias DeepFunction = @convention(c) (UnsafeMutablePointer<CompositorImageDecodeFn?>?) -> Int32
                var deep: CompositorImageDecodeFn?
                if let deepSym = dlsym(handle, "compositor_qt_imageio_deep_decode") { _ = unsafeBitCast(deepSym, to: DeepFunction.self)(&deep) }
                host = CCallbackCodec(decode: decode, encode: encode, deepDecode: deep)
                typealias CMYKFunctions = @convention(c) (UnsafeMutablePointer<CompositorCMYKDecodeFn?>?,
                                                          UnsafeMutablePointer<CompositorCMYKEncodeFn?>?) -> Int32
                var cmykDecode: CompositorCMYKDecodeFn?, cmykEncode: CompositorCMYKEncodeFn?
                if let cmykSym = dlsym(handle, "compositor_qt_imageio_cmyk_functions"),
                   unsafeBitCast(cmykSym, to: CMYKFunctions.self)(&cmykDecode, &cmykEncode) == 1 {
                    (host as? CCallbackCodec)?.cmykDecodeFn = cmykDecode; (host as? CCallbackCodec)?.cmykEncodeFn = cmykEncode
                }
                return true
            }
        }
        #endif
        return false
    }()

    public static func identify(_ data: Data) -> ImageInfo? {
        for b in backends { if let info = b.identify(data) { return info } }
        return Self.sniff(data)
    }
    public static func decode(_ data: Data) -> CGImage? {
        for b in backends { if let image = b.decode(data) { return image } }
        return nil
    }
    public static func encode(_ image: CGImage, typeIdentifier: String, quality: Double? = nil, dpi: Double? = nil, orientation: Int32 = 1) -> Data? {
        for b in backends { if let data = b.encode(image, typeIdentifier: typeIdentifier, quality: quality, dpi: dpi, orientation: orientation) { return data } }
        return nil
    }

    /// Format recognition by magic bytes, for when no backend can read the header (type known, size not).
    static func sniff(_ d: Data) -> ImageInfo? {
        let b = [UInt8](d.prefix(12))
        func info(_ uti: String) -> ImageInfo { ImageInfo(typeIdentifier: uti, width: 0, height: 0) }
        if b.count >= 8, b[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return info("public.png") }
        if b.count >= 4, b[0...3] == [0x76, 0x2F, 0x31, 0x01] { return info("com.ilm.openexr-image") }
        if b.count >= 6, String(bytes: b[0...5], encoding: .ascii).map({ $0 == "#?RADI" || $0 == "#?RGBE" }) == true {
            return info("public.radiance")
        }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return info("public.jpeg") }
        if b.count >= 4, b[0...3] == [0x49, 0x49, 0x2A, 0x00] || b[0...3] == [0x4D, 0x4D, 0x00, 0x2A] { return info("public.tiff") }
        if b.count >= 6, String(bytes: b[0...2], encoding: .ascii) == "GIF" { return info("com.compuserve.gif") }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return info("com.microsoft.bmp") }
        if b.count >= 12, String(bytes: b[0...3], encoding: .ascii) == "RIFF", String(bytes: b[8...11], encoding: .ascii) == "WEBP" { return info("org.webmproject.webp") }
        if b.count >= 12, String(bytes: b[4...7], encoding: .ascii) == "ftyp", let brand = String(bytes: b[8...11], encoding: .ascii) {
            // HEVC brands are public.heic; the generic MIAF brands cameras write (.hif/.heif) are public.heif.
            if ["heic", "heix", "hevc", "hevx", "heim", "heis"].contains(brand) { return info("public.heic") }
            if ["mif1", "msf1"].contains(brand) { return info("public.heif") }
        }
        return nil
    }
}

// MARK: - C registration (the Qt host installs its codecs here)

/// Decode: returns 0 on success and hands back a malloc'd premultiplied-RGBA buffer (freed by the callee's caller
/// with `free`). `channels` gives the layout, as bytes a pixel: 1 gray plane, 4 RGBA 8-bit, 8 RGBA 16-bit unsigned
/// (native-endian), 16 RGBA 32-bit float (linear light: EXR, Radiance HDR). `uti` receives a NUL-terminated identifier.
public typealias CompositorImageDecodeFn = @convention(c) (
    UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<CChar>?, Int) -> Int32
/// Encode: `pixels` premultiplied RGBA (channels 4) or gray (1). Returns 0 and a malloc'd buffer on success.
public typealias CompositorImageEncodeFn = @convention(c) (
    UnsafePointer<UInt8>?, Int32, Int32, Int32, UnsafePointer<CChar>?, Double, Double, Int32,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?) -> Int32
/// CMYK decode: 0 for a CMYK JPEG or TIFF, with malloc'd inks (four a pixel, 0 none, 255 full) and its embedded ICC
/// profile (malloc'd, or nil when it names none); nonzero for anything else.
public typealias CompositorCMYKDecodeFn = @convention(c) (
    UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?,
    UnsafeMutablePointer<Double>?, UnsafeMutablePointer<CChar>?, Int) -> Int32
/// CMYK encode: inks (four a pixel) and an ICC profile to embed, as a JPEG or LZW TIFF.
public typealias CompositorCMYKEncodeFn = @convention(c) (
    UnsafePointer<UInt8>?, Int32, Int32, UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?, Double, Double,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?) -> Int32

final class CCallbackCodec: ImageCodecBackend {
    let decodeFn: CompositorImageDecodeFn, encodeFn: CompositorImageEncodeFn
    /// The host's deep decode (16-bit and linear-float layouts), when it has one: used instead of the 8-bit decode so
    /// a file keeps its depth, as with Apple's ImageIO.
    var deepDecodeFn: CompositorImageDecodeFn?
    /// CMYK JPEG/TIFF, kept in inks as Apple's ImageIO keeps them.
    var cmykDecodeFn: CompositorCMYKDecodeFn?
    var cmykEncodeFn: CompositorCMYKEncodeFn?
    init(decode: @escaping CompositorImageDecodeFn, encode: @escaping CompositorImageEncodeFn,
         deepDecode: CompositorImageDecodeFn? = nil) { decodeFn = decode; encodeFn = encode; deepDecodeFn = deepDecode }

    private func run(_ data: Data) -> (pixels: [UInt8], w: Int, h: Int, channels: Int, dpi: Double, orientation: Int32, uti: String)? {
        var out: UnsafeMutablePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0, channels: Int32 = 0, orientation: Int32 = 1
        var dpi: Double = 0
        var uti = [CChar](repeating: 0, count: 96)
        let rc = data.withUnsafeBytes { raw in
            (deepDecodeFn ?? decodeFn)(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &out, &w, &h, &channels, &dpi, &orientation, &uti, uti.count)
        }
        guard rc == 0, let out, w > 0, h > 0, [1, 4, 8, 16].contains(channels) else { return nil }
        defer { free(out) }
        let count = Int(w) * Int(h) * Int(channels)
        return (Array(UnsafeBufferPointer(start: out, count: count)), Int(w), Int(h), Int(channels), dpi, orientation, String(cString: uti))
    }

    /// The file's inks and profile, when it is a CMYK JPEG or TIFF.
    private func runCMYK(_ data: Data) -> (inks: [UInt8], w: Int, h: Int, profile: Data?, dpi: Double, uti: String)? {
        guard let cmykDecodeFn else { return nil }
        var out: UnsafeMutablePointer<UInt8>?, icc: UnsafeMutablePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0, iccLength = 0
        var dpi: Double = 0
        var uti = [CChar](repeating: 0, count: 96)
        let rc = data.withUnsafeBytes { raw in
            cmykDecodeFn(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &out, &w, &h, &icc, &iccLength, &dpi, &uti, uti.count)
        }
        defer { free(out); free(icc) }
        guard rc == 0, let out, w > 0, h > 0 else { return nil }
        let profile = icc.map { Data(bytes: $0, count: iccLength) }
        return (Array(UnsafeBufferPointer(start: out, count: Int(w) * Int(h) * 4)), Int(w), Int(h), profile, dpi, String(cString: uti))
    }

    func identify(_ data: Data) -> ImageInfo? {
        if let c = runCMYK(data) {
            var info = ImageInfo(typeIdentifier: c.uti, width: c.w, height: c.h, dpi: c.dpi > 0 ? c.dpi : nil, hasAlpha: false)
            info.colorModel = "CMYK"
            info.profileName = c.profile.flatMap(ICCProfiles.description)
            return info
        }
        guard let r = run(data) else { return nil }
        var info = ImageInfo(typeIdentifier: r.uti, width: r.w, height: r.h, bitDepth: r.channels == 8 ? 16 : r.channels == 16 ? 32 : 8,
                             dpi: r.dpi > 0 ? r.dpi : nil, orientation: r.orientation, hasAlpha: r.channels != 1)
        if r.channels == 1 { info.colorModel = "Gray" }
        return info
    }
    func decode(_ data: Data) -> CGImage? {
        // A CMYK file with its profile stays in inks (drawn through the profile); one naming no profile comes in as RGB.
        if let c = runCMYK(data), let profile = c.profile, let space = CGColorSpace(iccData: profile), space.model == .cmyk {
            return CGImage(width: c.w, height: c.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: c.w * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: CGDataProvider(data: c.inks),
                           intent: .defaultIntent)
        }
        guard let r = run(data) else { return nil }
        let kind: PortableImage.Kind = r.channels == 1 ? .mask : .rgba
        let depth: PortableImage.Depth = r.channels == 8 ? .uint16 : r.channels == 16 ? .float32 : .uint8
        return CGImage(PortableImage(width: r.w, height: r.h, kind: kind, depth: depth, bytesPerRow: r.w * r.channels, bytes: r.pixels))
    }
    func encode(_ image: CGImage, typeIdentifier: String, quality: Double?, dpi: Double?) -> Data? {
        encode(image, typeIdentifier: typeIdentifier, quality: quality, dpi: dpi, orientation: 1)
    }
    func encode(_ image: CGImage, typeIdentifier: String, quality: Double?, dpi: Double?, orientation: Int32) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        // A CMYK image goes out in its inks, its profile embedded (JPEG, or TIFF compressed with LZW).
        if image.colorSpace?.model == .cmyk, ["public.jpeg", "public.tiff"].contains(typeIdentifier), let cmykEncodeFn,
           let profile = image.colorSpace?.iccData, let provided = image.dataProvider?.data.map([UInt8].init),
           provided.count >= image.bytesPerRow * (image.height - 1) + image.width * 4 {
            var inks = [UInt8](repeating: 0, count: image.width * image.height * 4)
            for y in 0..<image.height {
                for x in 0..<(image.width * 4) { inks[y * image.width * 4 + x] = provided[y * image.bytesPerRow + x] }
            }
            let rc = inks.withUnsafeBufferPointer { px in
                profile.withUnsafeBytes { icc in
                    typeIdentifier.withCString { uti in
                        cmykEncodeFn(px.baseAddress, Int32(image.width), Int32(image.height), icc.bindMemory(to: UInt8.self).baseAddress,
                                     icc.count, uti, quality ?? -1, dpi ?? 0, &out, &length)
                    }
                }
            }
            guard rc == 0, let out, length > 0 else { return nil }
            defer { free(out) }
            return Data(bytes: out, count: length)
        }
        // The layout the file wants, as Apple's ImageIO writes it: EXR linear-light floats (converted from any depth),
        // PNG / TIFF at 16 bits from a 16-bit or half-float image (half clipped to 0...1), anything else at 8 bits.
        let native = image.nativeImage
        let channels: Int32
        let pixels: [UInt8]
        if typeIdentifier == "com.ilm.openexr-image", !image.isGrayPlane {
            let linear = native.premultipliedLinear()
            channels = 16
            pixels = linear.withUnsafeBytes { Array($0) }
        } else if ["public.png", "public.tiff"].contains(typeIdentifier), !image.isGrayPlane, native.depth != .uint8 {
            channels = 8
            if native.depth == .uint16, native.bytesPerRow == native.width * 8 {
                pixels = native.bytes
            } else {
                let values = native.premultipliedSRGB().map { UInt16(max(0, min(65535, ($0.isFinite ? $0 : 0) * 65535 + 0.5))) }
                pixels = values.withUnsafeBytes { Array($0) }
            }
        } else {
            channels = image.isGrayPlane ? 1 : 4
            pixels = image.portableImage.bytes
        }
        let rc = pixels.withUnsafeBufferPointer { px in
            typeIdentifier.withCString { uti in
                encodeFn(px.baseAddress, Int32(image.width), Int32(image.height), channels, uti, quality ?? -1, dpi ?? 0, orientation, &out, &length)
            }
        }
        guard rc == 0, let out, length > 0 else { return nil }
        defer { free(out) }
        return Data(bytes: out, count: length)
    }
}

/// Called by the Qt host at startup with its QImageReader/QImageWriter-backed callbacks.
/// Called by the Qt host after `compositor_imageio_register` with its CMYK JPEG/TIFF decode and encode.
@_cdecl("compositor_imageio_register_cmyk")
public func compositor_imageio_register_cmyk(_ decode: CompositorCMYKDecodeFn?, _ encode: CompositorCMYKEncodeFn?) {
    (ImageCodecRegistry.host as? CCallbackCodec)?.cmykDecodeFn = decode
    (ImageCodecRegistry.host as? CCallbackCodec)?.cmykEncodeFn = encode
}

/// Called by the Qt host after `compositor_imageio_register` with its deep decode (16-bit and float layouts).
@_cdecl("compositor_imageio_register_deep")
public func compositor_imageio_register_deep(_ decode: CompositorImageDecodeFn?) {
    (ImageCodecRegistry.host as? CCallbackCodec)?.deepDecodeFn = decode
}

@_cdecl("compositor_imageio_register")
public func compositor_imageio_register(_ decode: CompositorImageDecodeFn?, _ encode: CompositorImageEncodeFn?) {
    guard let decode, let encode else { ImageCodecRegistry.host = nil; return }
    ImageCodecRegistry.host = CCallbackCodec(decode: decode, encode: encode)
}

/// ICC profile facts for the properties ImageIO reports.
enum ICCProfiles {
    /// The profile's description (`kCGImagePropertyProfileName`), nil when it has none.
    static func description(_ profile: Data) -> String? {
        let length = profile.withUnsafeBytes { compositor_icc_description($0.bindMemory(to: UInt8.self).baseAddress, $0.count, nil, 0) }
        guard length >= 0 else { return nil }
        var text = [CChar](repeating: 0, count: Int(length) + 1)
        _ = profile.withUnsafeBytes { compositor_icc_description($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &text, text.count) }
        return String(cString: text)
    }
}
