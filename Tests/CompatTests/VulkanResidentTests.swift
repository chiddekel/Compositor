import Foundation
import CoreGraphics
@testable import CoreImage
import XCTest

final class VulkanResidentTests: XCTestCase {
    func testByteStorageSelectionIsLosslessAndRejectsOtherFormats() {
        let bytes = (0...255).map(UInt8.init)
        let values = bytes.map { Float($0) / 255 }
        XCTAssertEqual(NormalizedByteStorage.encode(values), bytes)
        for value: Float in [-0.0, -0.25, 0.5, 2, .infinity, .nan, .leastNonzeroMagnitude] {
            XCTAssertNil(NormalizedByteStorage.encode([0, 1, value, 1]))
        }
    }

    func testLargeByteBitmapScalesAndKeepsOnGPUWithoutAReadback() throws {
        let context = try hardware()
        let width = 4000, height = 2600
        let data = Data(repeating: 128, count: width * height * 4)
        let image = CIImage(bitmapData: data, bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: 0.8, y: 2000.0 / 2600))
        let reads = context.gpuReadbackBytes, uploads = context.gpuUploadBytes
        let kept = try XCTUnwrap(context.keepOnGPU(image))
        XCTAssertEqual(context.gpuReadbackBytes, reads)
        XCTAssertEqual(context.gpuUploadBytes - uploads, UInt64(width * height * 4))
        var values = [Float](repeating: 0, count: 4)
        context.render(kept, toBitmap: &values, rowBytes: 16,
                       bounds: CGRect(x: 1600, y: 1000, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        XCTAssertEqual(values, [Float](repeating: Float(Float16(Float(128) / 255)), count: 4))
    }

    private func hardware() throws -> CIContext {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .hardwareCanvas: true])
        if !context.gpuAvailable {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { XCTFail("Hardware Vulkan is required") }
            throw XCTSkip("Hardware Vulkan unavailable")
        }
        return context
    }

    func testKeptHDRImagesComposeWithoutPixelTransfersAndReleaseTheirAllocations() throws {
        let context = try hardware()
        let bounds = CGRect(x: -3, y: 5, width: 8, height: 6)
        let before = context.gpuResidentBytes
        do {
            let a = CIImage(color: CIColor(red: 3, green: -0.25, blue: 0.5, alpha: 0.5)).cropped(to: bounds)
            let b = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 2, alpha: 1)).cropped(to: bounds)
            let reads = context.gpuReadbackBytes
            let keptA = try XCTUnwrap(context.keepOnGPU(a)), keptB = try XCTUnwrap(context.keepOnGPU(b))
            XCTAssertEqual(context.gpuReadbackBytes, reads)
            let uploads = context.gpuUploadBytes
            let composed = try XCTUnwrap(context.keepOnGPU(keptA.composited(over: keptB)))
            XCTAssertEqual(context.gpuReadbackBytes, reads)
            XCTAssertEqual(context.gpuUploadBytes, uploads)
            XCTAssertGreaterThan(context.gpuResidentBytes, before)
            let image = try XCTUnwrap(context.createCGImage(composed, from: bounds, format: .RGBAh))
            let values = image.nativeImage.bytes.withUnsafeBytes { bytes in
                (0..<4).map { Float(Float16(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self))) }
            }
            XCTAssertEqual(values, [1.625, 0.125, 1.25, 1])
            XCTAssertEqual(context.gpuReadbackBytes - reads, UInt64(8 * 6 * 8))
            XCTAssertEqual(context.gpuUploadBytes, uploads)
        }
        XCTAssertEqual(context.gpuResidentBytes, before)
    }

    func testKeptGeometryCropsAndTransformsMatchTheCPU() throws {
        let context = try hardware()
        let software = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        var pixels = PixelBuffer(width: 7, height: 5)
        for y in 0..<5 { for x in 0..<7 { pixels[x, y] = (UInt8(x * 31), UInt8(y * 41), 100, UInt8(50 + x * 23)) } }
        let source = CIImage(cgImage: CGImage(pixels))
        let kept = try XCTUnwrap(context.keepOnGPU(source))
        for transform in [CGAffineTransform(translationX: -2, y: 3),
                          CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 5),
                          CGAffineTransform(a: 0.75, b: 0, c: 0, d: 1.5, tx: -0.25, ty: 0.5)] {
            let bounds = CGRect(x: -3, y: -2, width: 15, height: 14)
            let output = kept.transformed(by: transform).cropped(to: bounds)
            let expected = source.transformed(by: transform).cropped(to: bounds)
            let actualBytes = try XCTUnwrap(context.createCGImage(output, from: bounds)).portableImage.bytes
            let expectedBytes = try XCTUnwrap(software.createCGImage(expected, from: bounds)).portableImage.bytes
            XCTAssertEqual(actualBytes.count, expectedBytes.count)
            XCTAssertLessThanOrEqual(zip(actualBytes, expectedBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
        }
    }
}
