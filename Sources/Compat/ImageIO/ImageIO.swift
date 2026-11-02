// ImageIO.swift — CGImageSource / CGImageDestination as Apple spells them, over `ImageCodecRegistry`.
// Property/option keys are CFString constants (String on Linux), so `[kCGImageSourceShouldCache: false] as CFDictionary`
// and `properties[kCGImagePropertyPixelWidth] as? Int` compile and behave unchanged.

@_exported import CoreGraphics
import Foundation
import Accelerate
import UniformTypeIdentifiers
import CompatSupport

// MARK: - Keys

public let kCGImageSourceShouldCache: CFString = "kCGImageSourceShouldCache"
public let kCGImageSourceShouldCacheImmediately: CFString = "kCGImageSourceShouldCacheImmediately"
public let kCGImageSourceCreateThumbnailFromImageAlways: CFString = "kCGImageSourceCreateThumbnailFromImageAlways"
public let kCGImageSourceCreateThumbnailFromImageIfAbsent: CFString = "kCGImageSourceCreateThumbnailFromImageIfAbsent"
public let kCGImageSourceCreateThumbnailWithTransform: CFString = "kCGImageSourceCreateThumbnailWithTransform"
public let kCGImageSourceThumbnailMaxPixelSize: CFString = "kCGImageSourceThumbnailMaxPixelSize"
public let kCGImagePropertyPixelWidth: CFString = "PixelWidth"
public let kCGImagePropertyPixelHeight: CFString = "PixelHeight"
public let kCGImagePropertyDPIWidth: CFString = "DPIWidth"
public let kCGImagePropertyDPIHeight: CFString = "DPIHeight"
public let kCGImagePropertyDepth: CFString = "Depth"
public let kCGImagePropertyOrientation: CFString = "Orientation"
public let kCGImagePropertyHasAlpha: CFString = "HasAlpha"
public let kCGImageDestinationLossyCompressionQuality: CFString = "kCGImageDestinationLossyCompressionQuality"
public let kCGImagePropertyColorModel: CFString = "ColorModel"
public let kCGImagePropertyColorModelRGB: CFString = "RGB"
public let kCGImagePropertyColorModelGray: CFString = "Gray"
public let kCGImagePropertyColorModelCMYK: CFString = "CMYK"
public let kCGImagePropertyColorModelLab: CFString = "Lab"
public let kCGImagePropertyProfileName: CFString = "ProfileName"
public let kCGImagePropertyTIFFDictionary: CFString = "{TIFF}"
public let kCGImagePropertyTIFFCompression: CFString = "Compression"

public let kCGImagePropertyGIFDictionary: CFString = "{GIF}"
public let kCGImagePropertyGIFDelayTime: CFString = "DelayTime"
public let kCGImagePropertyGIFUnclampedDelayTime: CFString = "UnclampedDelayTime"
public let kCGImagePropertyGIFLoopCount: CFString = "LoopCount"
public let kCGImagePropertyGIFHasGlobalColorMap: CFString = "HasGlobalColorMap"

// MARK: - Source

public final class CGImageSource: @unchecked Sendable {
    let data: Data
    let info: ImageInfo
    let animation: GIFMetadata?
    /// A camera RAW file, read by the RAW decoder from disk (never loaded whole: they can be hundreds of MB).
    let rawURL: URL?
    private var cached: CGImage?
    private var animationSource: (any AnimatedImageSource)?
    private let animationLock = NSLock()
    init(data: Data, info: ImageInfo, animation: GIFMetadata? = nil) { self.data = data; self.info = info; rawURL = nil; self.animation = animation }
    init(rawURL: URL, info: ImageInfo) { data = Data(); self.info = info; self.rawURL = rawURL; animation = nil }

    func image(at index: Int = 0) -> CGImage? {
        if animation != nil {
            animationLock.lock(); defer { animationLock.unlock() }
            if animationSource == nil {
                animationSource = ImageCodecRegistry.backends.compactMap { $0 as? AnimatedImageCodecBackend }
                    .lazy.compactMap { $0.makeAnimationSource(self.data) }.first
            }
            return animationSource?.image(at: index)
        }
        guard index == 0 else { return nil }
        if let cached { return cached }
        if let rawURL {
            // As shot, full size (the Develop sheet is the place for settings).
            guard let handle = RawDecoding.open(rawURL),
                  let developed = handle.develop(exposure: 0, temperature: handle.asShotTemperature, tint: handle.asShotTint,
                                                 boost: 1, scale: 1, draft: false),
                  let provider = CGDataProvider(data: Data(developed.bytes) as CFData) else { return nil }
            RawDecoding.releaseIfConsumed(handle)
            cached = CGImage(width: developed.width, height: developed.height, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: developed.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            return cached
        }
        cached = ImageCodecRegistry.decodeSource(data)
        return cached
    }
}

private func boolOption(_ options: CFDictionary?, _ key: CFString) -> Bool? {
    options?[key] as? Bool
}

public func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource? {
    if data.starts(with: Data("GIF8".utf8)) {
        guard let metadata = GIFMetadata(data) else { return nil }
        return CGImageSource(data: data, info: ImageInfo(typeIdentifier: "com.compuserve.gif",
            width: metadata.width, height: metadata.height), animation: metadata)
    }
    guard let info = ImageCodecRegistry.identify(data) else { return nil }
    return CGImageSource(data: data, info: info)
}

public func CGImageSourceCreateWithURL(_ url: CFURL, _ options: CFDictionary?) -> CGImageSource? {
    // Camera RAW: size from the header alone; pixels only when asked for.
    if RawDecoding.isRaw(url as URL), let size = RawDecoding.probe(url as URL) {
        return CGImageSource(rawURL: url as URL, info: ImageInfo(typeIdentifier: "public.camera-raw-image", width: size.width,
                                                               height: size.height, hasAlpha: false))
    }
    guard let data = try? Data(contentsOf: url) else { return nil }
    return CGImageSourceCreateWithData(data, options)
}

/// The image's type identifier, or nil when it is not an image.
public func CGImageSourceGetType(_ source: CGImageSource) -> CFString? { source.info.typeIdentifier }
public func CGImageSourceGetCount(_ source: CGImageSource) -> Int { source.animation?.delays.count ?? 1 }

public func CGImageSourceCopyPropertiesAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CFDictionary? {
    guard (0..<CGImageSourceGetCount(source)).contains(index) else { return nil }
    var info = source.info
    if let animation = source.animation { info.width = animation.width; info.height = animation.height }
    // Header-only recognition (magic bytes) knows the type but not the size; decode to learn it.
    if info.width == 0, let image = source.image() { info.width = image.width; info.height = image.height }
    guard info.width > 0 else { return nil }
    var dict: [AnyHashable: Any] = [
        kCGImagePropertyPixelWidth: info.width, kCGImagePropertyPixelHeight: info.height,
        kCGImagePropertyDepth: info.bitDepth, kCGImagePropertyOrientation: info.orientation,
        kCGImagePropertyHasAlpha: info.hasAlpha, kCGImagePropertyColorModel: info.colorModel,
    ]
    if let animation = source.animation {
        dict[kCGImagePropertyPixelWidth] = animation.width
        dict[kCGImagePropertyPixelHeight] = animation.height
        dict[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: animation.delays[index],
            kCGImagePropertyGIFUnclampedDelayTime: animation.delays[index]]
    }
    if let profileName = info.profileName { dict[kCGImagePropertyProfileName] = profileName }
    if let dpi = info.dpi { dict[kCGImagePropertyDPIWidth] = dpi; dict[kCGImagePropertyDPIHeight] = dpi }
    return dict
}

public func CGImageSourceCreateImageAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard (0..<CGImageSourceGetCount(source)).contains(index) else { return nil }
    return source.image(at: index)
}

/// Downscaled image with its longest side at most `kCGImageSourceThumbnailMaxPixelSize`. With
/// `kCGImageSourceCreateThumbnailWithTransform` the EXIF orientation is applied.
public func CGImageSourceCreateThumbnailAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard (0..<CGImageSourceGetCount(source)).contains(index), var image = source.image(at: index) else { return nil }
    if boolOption(options, kCGImageSourceCreateThumbnailWithTransform) == true, source.info.orientation != 1 {
        image = ImageOrientation.apply(source.info.orientation, to: image)
    }
    guard let maxSide = options?[kCGImageSourceThumbnailMaxPixelSize] as? Int, maxSide > 0,
          max(image.width, image.height) > maxSide else { return image }
    let scale = Double(maxSide) / Double(max(image.width, image.height))
    let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
    return ImageOrientation.resampled(image, width: w, height: h)
}

// MARK: - Destination

public final class CGImageDestination: @unchecked Sendable {
    let sink: NSMutableData
    let type: String
    var image: CGImage?
    var properties: [AnyHashable: Any] = [:]
    var frames: [(CGImage, Double)] = []
    var globalProperties: CFDictionary = [:]
    var expectedCount = 1
    var finalized = false
    var url: URL?
    init(sink: NSMutableData, type: String) { self.sink = sink; self.type = type }
}

public func CGImageDestinationCreateWithData(_ data: CFMutableData, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? {
    guard count > 0, (count == 1 || type == "com.compuserve.gif"), UTType(type)?.conforms(to: .image) == true else { return nil }
    let destination = CGImageDestination(sink: data, type: type)
    destination.expectedCount = count
    return destination
}

public func CGImageDestinationCreateWithURL(_ url: CFURL, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? {
    guard count > 0, (count == 1 || type == "com.compuserve.gif"), UTType(type)?.conforms(to: .image) == true else { return nil }
    let destination = CGImageDestination(sink: NSMutableData(), type: type)
    destination.expectedCount = count
    destination.url = url
    return destination
}

public func CGImageDestinationAddImage(_ destination: CGImageDestination, _ image: CGImage, _ properties: CFDictionary?) {
    guard !destination.finalized else { return }
    if destination.type == "com.compuserve.gif" {
        guard destination.frames.count < destination.expectedCount else { return }
        let gif = properties?[kCGImagePropertyGIFDictionary] as? CFDictionary
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        destination.frames.append((image, delay))
        return
    }
    guard destination.image == nil else { return }
    destination.image = image
    destination.properties = properties ?? [:]
}

public func CGImageDestinationSetProperties(_ destination: CGImageDestination, _ properties: CFDictionary?) {
    guard !destination.finalized else { return }
    destination.globalProperties = properties ?? [:]
}

public func CGImageDestinationFinalize(_ destination: CGImageDestination) -> Bool {
    if destination.type == "com.compuserve.gif" {
        guard !destination.finalized, destination.frames.count == destination.expectedCount else { return false }
        destination.finalized = true
        let gif = destination.globalProperties[kCGImagePropertyGIFDictionary] as? CFDictionary
        guard let data = PortableGIFEncoder().encodeFrames(destination.frames, loopCount: gif?[kCGImagePropertyGIFLoopCount] as? Int) else { return false }
        if let url = destination.url {
            do { try data.write(to: url); return true } catch { return false }
        }
        destination.sink.append(data)
        return true
    }
    guard !destination.finalized, let image = destination.image else { return false }
    destination.finalized = true
    let quality = destination.properties[kCGImageDestinationLossyCompressionQuality] as? Double
    let dpi = (destination.properties[kCGImagePropertyDPIWidth] as? Double) ?? (destination.properties[kCGImagePropertyDPIWidth] as? CGFloat).map(Double.init)
    let orientation = (destination.properties[kCGImagePropertyOrientation] as? Int).map(Int32.init) ?? (destination.properties[kCGImagePropertyOrientation] as? Int32) ?? 1
    guard let data = ImageCodecRegistry.encode(image, typeIdentifier: destination.type, quality: quality, dpi: dpi, orientation: orientation) else { return false }
    if let url = destination.url {
        do { try data.write(to: url); return true } catch { return false }
    }
    destination.sink.append(data)
    return true
}

// MARK: - Orientation and resampling helpers

enum ImageOrientation {
    /// Applies an EXIF orientation (1...8) so the result is upright. Works on the canonical pixel layout.
    static func apply(_ orientation: Int32, to image: CGImage) -> CGImage {
        guard orientation != 1, (2...8).contains(orientation) else { return image }
        let w = image.width, h = image.height, ch = image.isGrayPlane ? 1 : 4
        let swap = orientation >= 5
        let ow = swap ? h : w, oh = swap ? w : h
        let src = image.portableImage.bytes, srcRow = image.bytesPerRow
        var out = [UInt8](repeating: 0, count: ow * oh * ch)
        for y in 0..<h {
            for x in 0..<w {
                var nx = x, ny = y
                switch orientation {
                case 2: nx = w - 1 - x
                case 3: nx = w - 1 - x; ny = h - 1 - y
                case 4: ny = h - 1 - y
                case 5: nx = y; ny = x
                case 6: nx = h - 1 - y; ny = x
                case 7: nx = h - 1 - y; ny = w - 1 - x
                default: nx = y; ny = w - 1 - x
                }
                for c in 0..<ch { out[(ny * ow + nx) * ch + c] = src[y * srcRow + x * ch + c] }
            }
        }
        return CGImage(PortableImage(width: ow, height: oh, kind: image.isGrayPlane ? .mask : .rgba, bytesPerRow: ow * ch, bytes: out))
    }

    static func resampled(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let ch = image.isGrayPlane ? 1 : 4
        var out = [UInt8](repeating: 0, count: width * height * ch)
        var src = image.portableImage.bytes
        src.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { o in
                vImageResample8(source: s.baseAddress!, sourceWidth: image.width, sourceHeight: image.height,
                                sourceRowBytes: image.bytesPerRow, destination: o.baseAddress!, destinationWidth: width,
                                destinationHeight: height, destinationRowBytes: width * ch, channels: ch, highQuality: true)
            }
        }
        return CGImage(PortableImage(width: width, height: height, kind: image.isGrayPlane ? .mask : .rgba, bytesPerRow: width * ch, bytes: out))
    }
}
