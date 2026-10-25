#if os(Linux)
import CoreGraphics
import CoreImage
import Foundation
import RenderParitySupport
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_RAW_PRECISION_INPUT"] != nil))
struct RawPrecisionTests {
    @Test func sixteenBitRawImportRetainsSensorPrecision() throws {
        try #require(compositor_parity_install() != 0)
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_RAW_PRECISION_INPUT"])
        let url = URL(fileURLWithPath: path)
        let settings = try #require(RawImporter.asShot(url))
        let image = try RawImporter.develop(url, settings: settings, sixteenBit: true)
        #expect(image.bitsPerComponent == 16)
        #expect(image.width == 1024 && image.height == 128)
        let context = try DeepLayer.canonical(image)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        let row = image.height / 2
        let values = (16..<(image.width - 16)).map { pixels[(row * image.width + $0) * 4] }
        #expect(Set(values).count > 256, "A 16-bit RAW import must retain more levels than an eight-bit decoder can supply")
    }

    @Test func nondraftScalingRetainsSensorPrecision() throws {
        try #require(compositor_parity_install() != 0)
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_RAW_PRECISION_INPUT"])
        let filter = try #require(CIRAWFilter(imageURL: URL(fileURLWithPath: path)))
        filter.scaleFactor = 0.5
        filter.isDraftModeEnabled = false
        let output = try #require(filter.outputImage)
        let image = try #require(CIContext().createCGImage(output, from: output.extent,
            format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        #expect(image.width == 512 && image.height == 64 && image.bitsPerComponent == 16)
        let context = try DeepLayer.canonical(image)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        let values = (16..<(image.width - 16)).map { pixels[(32 * image.width + $0) * 4] }
        #expect(Set(values).count > 256, "Scaling a full RAW develop must preserve its higher precision")
    }
}
#endif
