import Foundation
import CoreGraphics
import CoreImage
import Testing
@testable import Compositor

@MainActor
struct Upstream7651033Tests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])

    private func samples(_ image: CIImage, in bounds: CGRect) -> [Float16] {
        var result = [Float16](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        context.render(image, toBitmap: &result, rowBytes: Int(bounds.width) * 8,
                       bounds: bounds, format: .RGBAh, colorSpace: nil)
        return result
    }

    @Test(arguments: BokehShape.allCases)
    func bokehProcessorKeepsHDRTranslationAndTileCoordinates(shape: BokehShape) throws {
        var source = [Float16](repeating: 0, count: 12 * 10 * 4)
        for y in 0..<10 { for x in 0..<12 {
            let at = (y * 12 + x) * 4
            source[at] = Float16(x == 4 && y == 6 ? 8 : 2 + Float(x) / 12)
            source[at + 1] = Float16(Float(y) / 10)
            source[at + 3] = 1
        } }
        let input = CIImage(bitmapData: source.withUnsafeBytes { Data($0) }, bytesPerRow: 12 * 8,
                            size: CGSize(width: 12, height: 10), format: .RGBAh, colorSpace: nil)
        let gpu = try #require(MetalBokeh.shared)
        let bounds = input.extent
        let blurred = try gpu.blur(input, extent: bounds, radius: 2.5, shape: shape, ring: 0.4)
        let full = samples(blurred, in: bounds)
        #expect(full.count == source.count)
        #expect(full.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element == 1 })
        #expect(full.contains { $0 > 1 })
        let shift = CGAffineTransform(translationX: -7, y: 13)
        let translated = try gpu.blur(input.transformed(by: shift), extent: bounds.applying(shift),
                                      radius: 2.5, shape: shape, ring: 0.4)
        #expect(samples(translated, in: bounds.applying(shift)) == full)
        let tile = CGRect(x: 2, y: 3, width: 5, height: 4)
        let cropped = samples(blurred, in: tile)
        var expected: [Float16] = []
        for y in 3..<7 { expected += Array(full[((y * 12 + 2) * 4)..<((y * 12 + 7) * 4)]) }
        #expect(cropped == expected)
    }

    @Test(arguments: BokehShape.allCases)
    func completeBokehGraphStaysOnGPUAndCachedDrawsReuseIt(shape: BokehShape) throws {
        let hardware = CIContext(options: [.workingColorSpace: NSNull(), .hardwareCanvas: true])
        guard hardware.gpuAvailable else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { Issue.record("Hardware Vulkan required") }
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: 48, height: 36)
        var pixels = PixelBuffer(width: 48, height: 36)
        for y in 0..<36 { for x in 0..<48 {
            pixels[x, y] = (UInt8(x * 255 / 47), UInt8(y * 255 / 35), 192, UInt8(128 + x * 2))
        } }
        let image = CIImage(cgImage: CGImage(pixels))
        var settings = LensEffectSettings()
        settings.effect = .bokeh
        settings.bokehShape = shape
        settings.bokehRadius = 35
        let graph = try settings.apply(to: image, side: 128)
        let reads = hardware.gpuReadbackBytes, bokeh = hardware.gpuBokehSubmissionCount
        let kept = try #require(hardware.keepOnGPU(graph))
        #expect(hardware.gpuReadbackBytes == reads)
        #expect(hardware.gpuBokehSubmissionCount == bokeh + 2)
        let submissions = hardware.gpuSubmissionCount, uploads = hardware.gpuUploadBytes
        let actual = try #require(hardware.createCGImage(kept, from: bounds)).portableImage.bytes
        #expect(hardware.gpuReadbackBytes - reads == 48 * 36 * 8)
        #expect(hardware.gpuSubmissionCount == submissions)
        #expect(hardware.gpuUploadBytes == uploads)
        let expected = try #require(context.createCGImage(graph, from: bounds)).portableImage.bytes
        let error = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(error <= 2, "Complete Bokeh graph, \(shape): \(error)/255")
        #expect(try #require(hardware.createCGImage(kept, from: bounds)).portableImage.bytes == actual)
        #expect(hardware.gpuBokehSubmissionCount == bokeh + 2)
    }

    @Test(arguments: [false, true], [Float(0), Float(16)])
    func rgbSplitGraphKeepsItsIntermediateOnGPU(radial: Bool, blur: Float) throws {
        let hardware = CIContext(options: [.workingColorSpace: NSNull(), .hardwareCanvas: true])
        guard hardware.gpuAvailable else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { Issue.record("Hardware Vulkan required") }
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: 61, height: 61)
        var pixels = PixelBuffer(width: 61, height: 61)
        for y in 0..<61 { for x in 0..<61 {
            let a: UInt8 = (x - 31) * (x - 31) + (y - 31) * (y - 31) < 22 * 22 ? 192 : 0
            pixels[x, y] = (UInt8(x * Int(a) / 60), UInt8(y * Int(a) / 60), a / 2, a)
        } }
        let input = CIImage(cgImage: CGImage(pixels))
        let parameters = MetalDispersion.Parameters(center: SIMD2(30.5, 30.5), direction: SIMD2(1, 0),
            distance: 4, blur: blur, reach: 30.5, radial: radial ? 1 : 0, sides: 0, spectral: 8, smear: blur > 0 ? 8 : 1)
        let graph = try #require(MetalDispersion.apply(to: input, parameters, margin: 24)).cropped(to: bounds)
        let reads = hardware.gpuReadbackBytes, submissions = hardware.gpuSubmissionCount
        let kept = try #require(hardware.keepOnGPU(graph))
        #expect(hardware.gpuReadbackBytes == reads)
        // The two-pass path can also align a clipped intermediate ROI on the GPU.
        let required = UInt64(blur > 0 ? 3 : 2)
        #expect((required...(required + (blur > 0 ? 1 : 0))).contains(hardware.gpuSubmissionCount - submissions))
        let actual = try #require(hardware.createCGImage(kept, from: bounds)).portableImage.bytes
        let expected = try #require(context.createCGImage(graph, from: bounds)).portableImage.bytes
        let error = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(error <= 2, "RGB Split radial \(radial), blur \(blur): \(error)/255")
        #expect(hardware.gpuReadbackBytes - reads == 61 * 61 * 8)
    }

    @Test func keptAdjustmentRetainsWorkingPrecisionAndExtent() throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let bounds = CGRect(x: -3, y: 5, width: 4, height: 3)
        let image = CIImage(color: CIColor(red: 3, green: 0.25, blue: 0.5, alpha: 1)).cropped(to: bounds)
        let reads = renderer.context.gpuReadbackBytes, allocated = renderer.context.gpuResidentBytes
        let kept = try #require(renderer.keep(image))
        if renderer.context.gpuAvailable {
            #expect(renderer.context.gpuReadbackBytes == reads)
            #expect(renderer.context.gpuResidentBytes > allocated)
        } else if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" {
            Issue.record("Canvas renderer requires hardware Vulkan")
        }
        #expect(kept.extent == bounds)
        #expect(samples(kept, in: bounds) == samples(image, in: bounds))
        #expect(renderer.keep(CIImage(color: .clear)) == nil)
        #expect(renderer.keep(CIImage.empty()) == nil)
        #expect(renderer.keep(image.cropped(to: CGRect(x: 0, y: 0, width: 17000, height: 1))) == nil)
    }
}
