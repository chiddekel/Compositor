import Foundation
import CoreGraphics

public let kvImageNoAllocate: Int = 512

public struct vImage_CGImageFormat {
    public var bitsPerComponent: UInt32
    public var bitsPerPixel: UInt32
    public var colorSpace: Unmanaged<CGColorSpace>? {
        didSet { retainedColorSpace = colorSpace?.takeUnretainedValue() }
    }
    // Keep Swift-backed color spaces alive after an inline Unmanaged.passUnretained initializer.
    private var retainedColorSpace: CGColorSpace?
    public var bitmapInfo: CGBitmapInfo
    public var version: UInt32
    public var decode: UnsafePointer<CGFloat>?
    public var renderingIntent: CGColorRenderingIntent

    public init(bitsPerComponent: UInt32 = 0, bitsPerPixel: UInt32 = 0,
                colorSpace: Unmanaged<CGColorSpace>? = nil, bitmapInfo: CGBitmapInfo = [],
                version: UInt32 = 0, decode: UnsafePointer<CGFloat>? = nil,
                renderingIntent: CGColorRenderingIntent = .defaultIntent) {
        self.bitsPerComponent = bitsPerComponent; self.bitsPerPixel = bitsPerPixel
        self.colorSpace = colorSpace; self.bitmapInfo = bitmapInfo; self.version = version
        self.retainedColorSpace = colorSpace?.takeUnretainedValue()
        self.decode = decode; self.renderingIntent = renderingIntent
    }
}

/// Copies native samples without an alpha round trip when formats match. RGB8 conversion supports straight,
/// premultiplied and opaque RGBA layouts, RGB, grayscale and caller-owned padded buffers.
public func vImageBuffer_InitWithCGImage(_ buffer: UnsafeMutablePointer<vImage_Buffer>,
                                       _ format: UnsafeMutablePointer<vImage_CGImageFormat>,
                                       _ backgroundColor: UnsafePointer<CGFloat>?, _ image: CGImage,
                                       _ flags: vImage_Flags) -> vImage_Error {
    guard format.pointee.version == 0, format.pointee.decode == nil else { return kvImageInvalidParameter }
    if format.pointee.bitsPerComponent == 0 && format.pointee.bitsPerPixel == 0 {
        format.pointee = vImage_CGImageFormat(bitsPerComponent: UInt32(image.bitsPerComponent),
            bitsPerPixel: UInt32(image.bitsPerPixel), colorSpace: image.colorSpace.map(Unmanaged.passUnretained),
            bitmapInfo: image.bitmapInfo, renderingIntent: format.pointee.renderingIntent)
    }
    let requested = format.pointee
    let row = image.width.multipliedReportingOverflow(by: Int(requested.bitsPerPixel))
    guard !row.overflow, row.partialValue > 0, row.partialValue % 8 == 0 else { return kvImageInvalidParameter }
    let minimumRow = row.partialValue / 8
    let supplied = flags & vImage_Flags(kvImageNoAllocate) != 0
    let rowBytes = supplied ? buffer.pointee.rowBytes : minimumRow
    let allocation = rowBytes.multipliedReportingOverflow(by: image.height)
    guard rowBytes >= minimumRow, !allocation.overflow, allocation.partialValue > 0 else { return kvImageBufferSizeMismatch }
    if supplied && (buffer.pointee.data == nil || buffer.pointee.width < UInt(image.width) || buffer.pointee.height < UInt(image.height)) {
        return kvImageBufferSizeMismatch
    }
    let targetSpace = requested.colorSpace?.takeUnretainedValue() ?? image.colorSpace
    guard targetSpace == image.colorSpace, let data = image.dataProvider?.data else { return kvImageInvalidParameter }
    let native = Int(requested.bitsPerComponent) == image.bitsPerComponent && Int(requested.bitsPerPixel) == image.bitsPerPixel &&
        requested.bitmapInfo == image.bitmapInfo
    let targetAlpha = CGImageAlphaInfo(rawValue: requested.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none
    let sourceAlpha = image.alphaInfo
    let supportedAlpha: Set<CGImageAlphaInfo> = [.last, .premultipliedLast, .noneSkipLast, .first, .premultipliedFirst, .noneSkipFirst]
    if !native {
        guard image.bitsPerComponent == 8, [8, 24, 32].contains(image.bitsPerPixel), requested.bitsPerComponent == 8,
              [8, 24, 32].contains(requested.bitsPerPixel),
              requested.bitsPerPixel != 32 || supportedAlpha.contains(targetAlpha),
              image.bitsPerPixel != 32 || supportedAlpha.contains(sourceAlpha) else { return kvImageInvalidParameter }
    }
    let sourcePixelBytes = (image.bitsPerPixel + 7) / 8
    guard image.bytesPerRow >= image.width * sourcePixelBytes,
          data.count >= image.bytesPerRow * (image.height - 1) + image.width * sourcePixelBytes else { return kvImageInvalidParameter }
    guard let output = supplied ? buffer.pointee.data : malloc(allocation.partialValue) else { return kvImageMemoryAllocationError }
    let destination = output.assumingMemoryBound(to: UInt8.self)
    data.withUnsafeBytes { raw in
        let source = raw.bindMemory(to: UInt8.self)
        if native {
            for y in 0..<image.height { memcpy(destination + y * rowBytes, source.baseAddress! + y * image.bytesPerRow, minimumRow) }
            return
        }
        let sourceLittle = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        let targetLittle = requested.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        let sourceFirst = sourceAlpha == .first || sourceAlpha == .premultipliedFirst || sourceAlpha == .noneSkipFirst
        let targetFirst = targetAlpha == .first || targetAlpha == .premultipliedFirst || targetAlpha == .noneSkipFirst
        let premultiplied = sourceAlpha == .premultipliedFirst || sourceAlpha == .premultipliedLast
        let targetPremultiplied = targetAlpha == .premultipliedFirst || targetAlpha == .premultipliedLast
        let opaque = sourceAlpha == .none || sourceAlpha == .noneSkipFirst || sourceAlpha == .noneSkipLast
        let targetOpaque = (requested.bitsPerPixel != 32 && targetAlpha != .only) || targetAlpha == .noneSkipFirst || targetAlpha == .noneSkipLast
        for y in 0..<image.height { for x in 0..<image.width {
            let offset = y * image.bytesPerRow + x * sourcePixelBytes
            var r: Int, g: Int, b: Int, a = 255
            if image.bitsPerPixel == 8 {
                r = Int(source[offset]); g = r; b = r
                if sourceAlpha == .only { a = r; r = 0; g = 0; b = 0 }
            } else if image.bitsPerPixel == 24 {
                r = Int(source[offset]); g = Int(source[offset + 1]); b = Int(source[offset + 2])
            } else {
                func component(_ index: Int) -> Int { Int(source[offset + (sourceLittle ? 3 - index : index)]) }
                a = opaque ? 255 : component(sourceFirst ? 0 : 3)
                r = component(sourceFirst ? 1 : 0); g = component(sourceFirst ? 2 : 1); b = component(sourceFirst ? 3 : 2)
                if premultiplied { r = a == 0 ? 0 : min(255, (r * 255 + a / 2) / a)
                    g = a == 0 ? 0 : min(255, (g * 255 + a / 2) / a); b = a == 0 ? 0 : min(255, (b * 255 + a / 2) / a) }
            }
            if targetOpaque {
                let colors = [r, g, b].enumerated().map { channel, value in
                    let background = Int(max(0, min(1, backgroundColor?[channel] ?? 0)) * 255 + 0.5)
                    return (value * a + background * (255 - a) + 127) / 255
                }
                r = colors[0]; g = colors[1]; b = colors[2]; a = 255
            } else if targetPremultiplied { r = (r * a + 127) / 255; g = (g * a + 127) / 255; b = (b * a + 127) / 255 }
            let at = y * rowBytes + x * Int(requested.bitsPerPixel / 8)
            if requested.bitsPerPixel == 8 {
                destination[at] = UInt8(targetAlpha == .only ? a : Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded()))
            } else {
                let values = requested.bitsPerPixel == 24 ? [r, g, b] : targetFirst ? [a, r, g, b] : [r, g, b, a]
                for i in values.indices { destination[at + (targetLittle && values.count == 4 ? 3 - i : i)] = UInt8(values[i]) }
            }
        } }
    }
    buffer.pointee = vImage_Buffer(data: output, height: UInt(image.height), width: UInt(image.width), rowBytes: rowBytes)
    return kvImageNoError
}
