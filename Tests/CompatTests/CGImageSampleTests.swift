import XCTest
import CoreGraphics
import ImageIO
import Accelerate

final class CGImageSampleTests: XCTestCase {
    func testDeepChannelConversionDividesBeforeQuantizing() throws {
        // A nearly clear pixel has enough precision in the layer to retain its straight channel values.
        // Quantizing its premultiplied samples first would turn all three colors into zero.
        let cases: [(PortableImage.Depth, [UInt8])] = [
            (.uint16, [UInt16(26), 77, 128, 256].withUnsafeBytes { Array($0) }),
            (.half, [Float16(0.001), 0.002, 0.003, 0.004].withUnsafeBytes { Array($0) }),
            (.float32, [Float(0.001), 0.002, 0.003, 0.004].withUnsafeBytes { Array($0) }),
        ]
        for (depth, bytes) in cases {
            let source = CGImage(PortableImage(width: 1, height: 1, kind: .rgba, depth: depth,
                                               bytesPerRow: bytes.count, bytes: bytes))
            var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                colorSpace: Unmanaged.passUnretained(CGColorSpace(name: CGColorSpace.sRGB)!),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
            var buffer = vImage_Buffer()
            XCTAssertEqual(vImageBuffer_InitWithCGImage(&buffer, &format, nil, source, 0), kvImageNoError)
            guard let data = buffer.data else { return XCTFail("No channel samples for \(depth)") }
            defer { free(data) }
            let converted = data.assumingMemoryBound(to: UInt8.self)
            if depth == .uint16 { XCTAssertEqual(Array(UnsafeBufferPointer(start: converted, count: 4)), [26, 77, 128, 1]) }
            else if depth == .half {
                XCTAssertEqual(converted[0], 64); XCTAssertEqual(converted[1], 128); XCTAssertEqual(converted[2], 191)
            } else {
                // Float32 assets are linear light: straight .25 encodes near sRGB .537.
                XCTAssertLessThanOrEqual(abs(Int(converted[0]) - 137), 1)
                XCTAssertLessThanOrEqual(abs(Int(converted[1]) - 188), 1)
                XCTAssertLessThanOrEqual(abs(Int(converted[2]) - 225), 1)
            }
        }
    }

    func testVImageFormatOwnsItsColorSpaceUntilReplaced() {
        var space: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)
        weak var observed = space
        var format = vImage_CGImageFormat(colorSpace: Unmanaged.passUnretained(space!))
        _ = CGColorSpace(name: CGColorSpace.extendedSRGB) // Replace the constructor's temporary bridge owner.
        space = nil
        XCTAssertNotNil(observed)
        format.colorSpace = nil
        XCTAssertNil(observed)
    }

    private let samples: [UInt8] = [51, 153, 255, 0, 90, 60, 30, 128]

    private func image(_ alpha: CGImageAlphaInfo = .last) throws -> CGImage {
        try XCTUnwrap(CGImage(width: 2, height: 1, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: CGDataProvider(data: samples)))
    }

    private func sourceSamples(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Rendering must not invalidate the source samples retained for vImage and file output.
        _ = image.nativeImage
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(CGColorSpace(name: CGColorSpace.sRGB)!),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
        var buffer = vImage_Buffer()
        XCTAssertEqual(vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, 0), kvImageNoError)
        defer { free(buffer.data) }
        return Array(UnsafeBufferPointer(start: buffer.data.assumingMemoryBound(to: UInt8.self), count: 8))
    }

    func testSourceSamplesSurviveDrawingAndOpaquePreviewIgnoresStoredAlpha() throws {
        let source = try image()
        XCTAssertEqual(source.nativeImage.bytes, [0, 0, 0, 0, 45, 30, 15, 128])
        XCTAssertEqual(source.dataProvider?.data, Data(samples))
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try image(.noneSkipLast), in: CGRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(try XCTUnwrap(context.makeImage()).bytes, [51, 153, 255, 255, 90, 60, 30, 255])
    }

    func testPNGKeepsZeroAlphaRGBWithNativeAndPortableCodecs() throws {
        let original = try image()
        let native = try XCTUnwrap(ImageCodecRegistry.encode(original, typeIdentifier: "public.png", dpi: 144))
        XCTAssertEqual(try sourceSamples(native), samples)
        try ImageCodecRegistry.withHost(nil) {
            let portable = try XCTUnwrap(ImageCodecRegistry.encode(original, typeIdentifier: "public.png", dpi: 144))
            XCTAssertEqual(try sourceSamples(portable), samples)
        }
    }

    func testVImageConvertsByteOrderIntoCallerOwnedPaddedRows() throws {
        let bytes: [UInt8] = [30, 60, 90, 128, 7, 9, 11, 0]
        let original = try XCTUnwrap(CGImage(width: 2, height: 1, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: CGDataProvider(data: bytes)))
        _ = original.nativeImage
        let memory = try XCTUnwrap(malloc(16)); defer { free(memory) }
        memset(memory, 0xcc, 16)
        var buffer = vImage_Buffer(data: memory, height: 1, width: 2, rowBytes: 16)
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(CGColorSpace(name: CGColorSpace.sRGB)!),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
        XCTAssertEqual(vImageBuffer_InitWithCGImage(&buffer, &format, nil, original, vImage_Flags(kvImageNoAllocate)), kvImageNoError)
        XCTAssertEqual(buffer.data, memory)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: UInt8.self), count: 16)),
            [90, 60, 30, 128, 11, 9, 7, 0] + [UInt8](repeating: 0xcc, count: 8))
    }
}
