#if os(Linux)
import CompatSupport
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

    @Test(arguments: [false, true])
    func exposureSurvivesAutomaticBrightness(draft: Bool) throws {
        try #require(compositor_parity_install() != 0)
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_RAW_PRECISION_INPUT"])
        func redMean(exposure: Float, boost: Float) throws -> Double {
            let filter = try #require(CIRAWFilter(imageURL: URL(fileURLWithPath: path)))
            filter.exposure = exposure
            filter.boostAmount = boost
            filter.isDraftModeEnabled = draft
            filter.scaleFactor = draft ? 0.5 : 1
            let output = try #require(filter.outputImage)
            let image = try #require(CIContext().createCGImage(output, from: output.extent,
                format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            let context = try DeepLayer.canonical(image)
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
            let values = (16..<(image.width - 16)).map { Double(pixels[(image.height / 2 * image.width + $0) * 4]) }
            return values.reduce(0, +) / Double(values.count)
        }
        for boost: Float in [0, 1] {
            let baseline = try redMean(exposure: 0, boost: boost)
            var preceding = baseline
            for exposure: Float in [-1, -2, -3] {
                let darker = try redMean(exposure: exposure, boost: boost)
                #expect(darker < preceding * 0.9,
                    "Every negative stop must darken the RAW, including the sheet's -3 EV endpoint")
                preceding = darker
            }
            #expect(try redMean(exposure: 1, boost: boost) > baseline * 1.1,
                "Positive exposure must brighten the RAW")
        }
    }

    @Test(arguments: [Float(-1), Float(1)])
    func fullExposureDoesNotContaminateCachedLinearPreview(exposure: Float) throws {
        try #require(compositor_parity_install() != 0)
        let previous = ProcessInfo.processInfo.environment["COMPOSITOR_RAW_PREVIEW"]
        setenv("COMPOSITOR_RAW_PREVIEW", "libraw", 1)
        defer {
            if let previous { setenv("COMPOSITOR_RAW_PREVIEW", previous, 1) }
            else { unsetenv("COMPOSITOR_RAW_PREVIEW") }
        }
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_RAW_PRECISION_INPUT"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sensor.dng")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        let reused = try #require(RawDecoding.open(url))
        defer { RawDecoding.releaseIfConsumed(reused) }
        _ = try #require(reused.develop16(exposure: exposure, temperature: reused.asShotTemperature,
            tint: reused.asShotTint, boost: 1, scale: 1, draft: false))
        let fresh = try #require(RawDecoding.open(url))
        let actual = try #require(reused.develop(exposure: 0, temperature: reused.asShotTemperature,
            tint: reused.asShotTint, boost: 1, scale: 0.5, draft: true))
        let expected = try #require(fresh.develop(exposure: 0, temperature: fresh.asShotTemperature,
            tint: fresh.asShotTint, boost: 1, scale: 0.5, draft: true))
        #expect(actual.width == expected.width && actual.height == expected.height)
        let matches = actual.bytes == expected.bytes
        #expect(matches, "A cached linear preview must not inherit an earlier full develop's exposure")
    }
}
#endif
