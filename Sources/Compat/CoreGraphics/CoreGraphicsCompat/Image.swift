// CoreGraphicsCompat/Image.swift — CGImage, CGDataProvider, and related shims.
//
// Plan §3, §5: Wraps the portable raster substrate (PortableImage, PixelBuffer,
// MaskBuffer) in a reference-typed CGImage interface matching CoreGraphics.

import Foundation

// MARK: - CGImageAlphaInfo

public enum CGImageAlphaInfo: UInt32, Sendable {
    case none = 0
    case premultipliedLast = 1
    case premultipliedFirst = 2
    case last = 3
    case first = 4
    case noneSkipLast = 5
    case noneSkipFirst = 6
    case only = 7
}

// MARK: - CGBitmapInfo

public struct CGBitmapInfo: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let alphaInfoMask = CGBitmapInfo(rawValue: 0x1F)
    public static let floatComponents = CGBitmapInfo(rawValue: 1 << 8)
    public static let byteOrderMask = CGBitmapInfo(rawValue: 0x7000)
    public static let byteOrderDefault = CGBitmapInfo(rawValue: 0 << 12)
    public static let byteOrder16Little = CGBitmapInfo(rawValue: 1 << 12)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 2 << 12)
    public static let byteOrder16Big = CGBitmapInfo(rawValue: 3 << 12)
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 4 << 12)
}

// MARK: - CGColorRenderingIntent

public enum CGColorRenderingIntent: Int32, Sendable {
    case defaultIntent = 0
    case absoluteColorimetric = 1
    case relativeColorimetric = 2
    case perceptual = 3
    case saturation = 4
}

// MARK: - CGDataProvider

public struct CGDataProviderDirectCallbacks {
    public var version: UInt32
    public var getBytePointer: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafeRawPointer?)?
    public var releaseBytePointer: (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void)?
    public var getBytesAtPosition: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer, off_t, Int) -> Int)?
    public var releaseInfo: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?

    public init(version: UInt32 = 0,
                getBytePointer: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafeRawPointer?)? = nil,
                releaseBytePointer: (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void)? = nil,
                getBytesAtPosition: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer, off_t, Int) -> Int)? = nil,
                releaseInfo: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil) {
        self.version = version
        self.getBytePointer = getBytePointer
        self.releaseBytePointer = releaseBytePointer
        self.getBytesAtPosition = getBytesAtPosition
        self.releaseInfo = releaseInfo
    }
}

public final class CGDataProvider: @unchecked Sendable {
    public let data: [UInt8]

    public init(data: [UInt8]) {
        self.data = data
    }

    /// Failable like Apple's `CGDataProvider(data:)` (which returns nil for an unusable CFData).
    public init?(data: Data) {
        guard !data.isEmpty else { return nil }
        self.data = [UInt8](data)
    }

    public init?(directInfo: UnsafeMutableRawPointer?, size: off_t, callbacks: UnsafePointer<CGDataProviderDirectCallbacks>) {
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        let cb = callbacks.pointee
        if let getBytes = cb.getBytesAtPosition {
            _ = buffer.withUnsafeMutableBytes { rawBuf in
                getBytes(directInfo, rawBuf.baseAddress!, 0, Int(size))
            }
        } else if let getBytePtr = cb.getBytePointer, let src = getBytePtr(directInfo) {
            _ = buffer.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress!, src, Int(size))
            }
            cb.releaseBytePointer?(directInfo, src)
        }
        cb.releaseInfo?(directInfo)
        self.data = buffer
    }
}

// MARK: - CGImage

public final class CGImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int
    let space: CGColorSpace
    /// Optional like Apple's: a mask or unmanaged image may have none.
    public var colorSpace: CGColorSpace? { space }
    public let alphaInfo: CGImageAlphaInfo
    public let bitmapInfo: CGBitmapInfo
    public let portableImage: PortableImage

    public var bytes: [UInt8] { portableImage.bytes }
    public var isMask: Bool { space.model == .monochrome || alphaInfo == .only }

    public init(_ portableImage: PortableImage) {
        self.width = portableImage.width
        self.height = portableImage.height
        self.bytesPerRow = portableImage.bytesPerRow
        self.bitsPerComponent = 8
        self.bitsPerPixel = portableImage.kind == .rgba ? 32 : 8
        self.space = portableImage.kind == .rgba ? .srgbSpace : .deviceGraySpace
        self.alphaInfo = portableImage.kind == .rgba ? .premultipliedLast : .none
        self.bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
        self.portableImage = portableImage
    }

    public convenience init(_ buffer: PixelBuffer) {
        self.init(PortableImage(buffer))
    }

    public convenience init(mask: MaskBuffer) {
        self.init(PortableImage(mask))
    }

    public init?(width: Int,
                 height: Int,
                 bitsPerComponent: Int = 8,
                 bitsPerPixel: Int = 32,
                 bytesPerRow: Int,
                 space: CGColorSpace = .srgbSpace,
                 bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                 provider: CGDataProvider,
                 decode: UnsafePointer<CGFloat>? = nil,
                 shouldInterpolate: Bool = true,
                 intent: CGColorRenderingIntent = .defaultIntent) {
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bitsPerComponent = bitsPerComponent
        self.bitsPerPixel = bitsPerPixel
        self.space = space
        self.alphaInfo = CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .premultipliedLast
        self.bitmapInfo = bitmapInfo

        let kind: PortableImage.Kind = (space.model == .monochrome || bitsPerPixel == 8) ? .mask : .rgba
        let expectedBytes = height * bytesPerRow
        var pixelBytes = provider.data
        if pixelBytes.count < expectedBytes {
            pixelBytes.append(contentsOf: repeatElement(0, count: expectedBytes - pixelBytes.count))
        }
        self.portableImage = PortableImage(width: width, height: height, kind: kind, bytesPerRow: bytesPerRow, bytes: pixelBytes)
    }

    public func cropping(to rect: CGRect) -> CGImage? {
        guard let cropped = portableImage.cropping(to: rect) else { return nil }
        return CGImage(cropped)
    }

    public var dataProvider: CGDataProvider? {
        CGDataProvider(data: portableImage.bytes)
    }
}
