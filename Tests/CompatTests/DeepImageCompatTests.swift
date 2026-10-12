// DeepImageCompatTests — 16-bit and HDR pixels through the compat Core Graphics, Core Image and ImageIO, as upstream's
// 16-bit and HDR layers (DeepLayers.swift) use them: 16-bit and half-float bitmap contexts, Core Image's RGBA16 / RGBAh /
// RGBAf output, and 16-bit PNG, OpenEXR and Radiance HDR files.

import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class DeepImageCompatTests: XCTestCase {
    /// Whether the host codecs (the Qt ImageIO backend, found lazily on first use) are there.
    private var hostCodecs: Bool {
        _ = CGImageSourceCreateWithData(Data([0x89, 0x50, 0x4E, 0x47]) as CFData, nil)
        return ImageCodecRegistry.host != nil
    }

    private func context(_ width: Int, _ height: Int, hdr: Bool) throws -> CGContext {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            | (hdr ? CGBitmapInfo.floatComponents.rawValue : 0)
        return try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                                       space: CGColorSpace(name: hdr ? CGColorSpace.extendedSRGB : CGColorSpace.sRGB)!,
                                       bitmapInfo: info))
    }

    /// A 16-bit context draws at 16 bits and its image says so, values exact to the 16-bit step.
    func testSixteenBitContextKeepsSixteenBits() throws {
        let ctx = try context(4, 2, hdr: false)
        XCTAssertEqual(ctx.bitsPerComponent, 16)
        XCTAssertTrue(ctx.bitmapInfo.contains(.byteOrder16Little))
        ctx.setFillColor(CGColor(red: 0.4, green: 0.25, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = try XCTUnwrap(ctx.makeImage())
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertFalse(image.bitmapInfo.contains(.floatComponents))
        let words = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(Int(words[0]), 26214, accuracy: 1)   // 0.4 of 65535: finer than any 8-bit level
        XCTAssertEqual(Int(words[1]), 16384, accuracy: 1)
        XCTAssertEqual(words[3], 65535)
        // Its 8-bit view, for the compat's 8-bit paths, rounds as expected.
        XCTAssertEqual(image.portableImage.bytes[0], 102)
    }

    /// A half-float context keeps light brighter than white through drawing.
    func testHalfFloatContextKeepsHighlights() throws {
        let source = try context(2, 2, hdr: true)
        let halves = try XCTUnwrap(source.data).assumingMemoryBound(to: Float16.self)
        for i in 0..<4 { halves[i * 4] = 3; halves[i * 4 + 1] = 0.5; halves[i * 4 + 2] = 0; halves[i * 4 + 3] = 1 }
        let image = try XCTUnwrap(source.makeImage())
        XCTAssertTrue(image.bitmapInfo.contains(.floatComponents))
        let target = try context(2, 2, hdr: true)
        target.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        let drawn = try XCTUnwrap(target.data).assumingMemoryBound(to: Float16.self)
        XCTAssertEqual(Float(drawn[0]), 3, accuracy: 0.01)
        XCTAssertEqual(Float(drawn[1]), 0.5, accuracy: 0.01)
        // Drawn into an 8-bit context it is clipped to white, as Core Graphics does.
        let eight = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        eight.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(try XCTUnwrap(eight.data).assumingMemoryBound(to: UInt8.self)[0], 255)
    }

    /// Linear-light float pixels (an EXR's) are encoded when drawn into an extended sRGB context.
    func testLinearFloatsAreEncodedWhenDrawn() throws {
        let linear: [Float] = [4, 1, 0.5, 1]
        let provider = try XCTUnwrap(CGDataProvider(data: linear.withUnsafeBytes { Data($0) } as CFData))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let target = try context(1, 1, hdr: true)
        target.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let drawn = try XCTUnwrap(target.data).assumingMemoryBound(to: Float16.self)
        XCTAssertEqual(Float(drawn[0]), 1.055 * pow(4, 1 / 2.4) - 0.055, accuracy: 0.01)   // linear 4 ≈ 1.83 encoded
        XCTAssertEqual(Float(drawn[1]), 1, accuracy: 0.005)
        XCTAssertEqual(Float(drawn[2]), 1.055 * pow(0.5, 1 / 2.4) - 0.055, accuracy: 0.005)
    }

    /// Core Image keeps a 16-bit image's precision and an HDR image's highlights in its deep formats.
    func testCoreImageDeepFormats() throws {
        let ctx = try context(256, 1, hdr: false)
        let words = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt16.self)
        for x in 0..<256 { let v = UInt16(25600 + x); words[x * 4] = v; words[x * 4 + 1] = v; words[x * 4 + 2] = v; words[x * 4 + 3] = 65535 }
        let image = try XCTUnwrap(ctx.makeImage())
        let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let out = try XCTUnwrap(ci.createCGImage(CIImage(cgImage: image), from: CGRect(x: 0, y: 0, width: 256, height: 1),
                                                 format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        XCTAssertEqual(out.bitsPerComponent, 16)
        let values = out.nativeImage.bytes.withUnsafeBytes { raw in (0..<256).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt16.self) } }
        XCTAssertEqual(Set(values).count, 256, "every 16-bit step kept")

        let hdr = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let bright = CIImage(color: CIColor(red: 2, green: 0.5, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        var pixel = [Float](repeating: 0, count: 4)
        hdr.render(bright, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                   colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
        XCTAssertEqual(pixel[0], 2, accuracy: 0.01, "past white through a linear working space: \(pixel)")
        XCTAssertEqual(pixel[1], 0.5, accuracy: 0.01)
        let half = try XCTUnwrap(hdr.createCGImage(bright, from: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAh,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)))
        XCTAssertTrue(half.bitmapInfo.contains(.floatComponents))
        XCTAssertEqual(Float(half.nativeImage.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float16.self) }), 2, accuracy: 0.01)
    }

    /// As on the Mac, a filter's own input image in the parameters wins over the receiver; the HDR filters exist.
    func testExplicitInputImageAndHDRFilters() throws {
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let half = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: rect)
        let one = CIImage(color: CIColor(red: 1, green: 0.25, blue: 0)).cropped(to: rect)
        let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!])
        func read(_ image: CIImage) -> [Float] {
            var out = [Float](repeating: 0, count: 4)
            ci.render(image, toBitmap: &out, rowBytes: 16, bounds: rect, format: .RGBAf,
                      colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
            return out
        }
        let divided = half.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: half,
                                                                            kCIInputImageKey: CIImage(color: .white).cropped(to: rect)])
        XCTAssertEqual(read(divided)[0], 0.5, accuracy: 0.001, "half divided by white, not by itself")
        XCTAssertEqual(read(one.applyingFilter("CIMaximumComponent"))[2], 1, accuracy: 0.001)
        let multiplied = half.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: one])
        XCTAssertEqual(read(multiplied)[1], 0.125, accuracy: 0.001)
    }

    /// 16-bit PNGs read and write at 16 bits through the host codecs (Apple's ImageIO keeps a PNG's depth).
    func testSixteenBitPNGRoundTrip() throws {
        try XCTSkipUnless(hostCodecs, "no host image codecs")
        let ctx = try context(64, 1, hdr: false)
        let words = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt16.self)
        for x in 0..<64 { let v = UInt16(40000 + x * 3); words[x * 4] = v; words[x * 4 + 1] = 0; words[x * 4 + 2] = v; words[x * 4 + 3] = 65535 }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 16)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.bitsPerComponent, 16)
        let back = decoded.nativeImage.bytes.withUnsafeBytes { raw in (0..<64).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt16.self) } }
        XCTAssertEqual(back, (0..<64).map { UInt16(40000 + $0 * 3) })
    }

    /// OpenEXR: linear-light floats written as half floats and read back as linear floats, highlights and all.
    func testEXRRoundTrip() throws {
        try XCTSkipUnless(hostCodecs, "no host image codecs")
        let linear: [Float] = [6, 1, 0.25, 1, 0.5, 0.5, 0.5, 0.5]
        let provider = try XCTUnwrap(CGDataProvider(data: linear.withUnsafeBytes { Data($0) } as CFData))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.ilm.openexr-image" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "OpenEXR encoder present")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.ilm.openexr-image")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue(decoded.bitmapInfo.contains(.floatComponents))
        XCTAssertEqual(decoded.bitsPerComponent, 32)
        let back = decoded.nativeImage.bytes.withUnsafeBytes { raw in (0..<8).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        for (a, b) in zip(back, linear) { XCTAssertEqual(a, b, accuracy: 0.005) }
    }

    /// Radiance RGBE (.hdr) comes in as linear-light floats past white (Qt's HDR reader).
    func testRadianceHDRDecodes() throws {
        try XCTSkipUnless(hostCodecs, "no host image codecs")
        // A flat 2x1 RGBE file: (8, 1, 0.5) and (0.25, 0.25, 0.25), uncompressed scanline.
        func rgbe(_ r: Float, _ g: Float, _ b: Float) -> [UInt8] {
            let m = max(r, g, b)
            guard m > 1e-32 else { return [0, 0, 0, 0] }
            let e = Int(floor(log2(m))) + 1   // mantissa in [0.5, 1), as frexp
            let scale = Float(256) / pow(2, Float(e))
            return [UInt8(r * scale), UInt8(g * scale), UInt8(b * scale), UInt8(e + 128)]
        }
        var bytes = Array("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n".utf8)
        bytes += rgbe(8, 1, 0.5) + rgbe(0.25, 0.25, 0.25)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".hdr")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(UTType(filenameExtension: "hdr")?.identifier, "public.radiance")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "Radiance reader present")
        XCTAssertTrue(decoded.bitmapInfo.contains(.floatComponents))
        let values = decoded.nativeImage.bytes.withUnsafeBytes { raw in (0..<8).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        XCTAssertEqual(values[0], 8, accuracy: 0.1, "\(values)")
        XCTAssertEqual(values[1], 1, accuracy: 0.02)
        XCTAssertEqual(values[4], 0.25, accuracy: 0.01)
    }

    func testHDRTypes() {
        XCTAssertEqual(UTType(filenameExtension: "exr")?.identifier, "com.ilm.openexr-image")
        XCTAssertTrue(UTType("com.ilm.openexr-image")!.conforms(to: .image))
        XCTAssertTrue(UTType("public.radiance")!.conforms(to: .image))
    }
}
