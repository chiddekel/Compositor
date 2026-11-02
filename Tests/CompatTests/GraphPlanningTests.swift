import Foundation
import CoreGraphics
@testable import CoreImage
import XCTest

private final class EvaluationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// A CPU-only identity processor. Proxy textures used for planning have no pixel storage.
private final class CountingCopyKernel: CIImageProcessorKernel, @unchecked Sendable {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let source = inputs?.first?.metalTexture, !source.rgbaBytes.isEmpty,
              let destination = output.metalTexture else { return }
        (arguments?["count"] as? EvaluationCount)?.increment()
        destination.rgbaBytes = source.rgbaBytes
    }
}

final class GraphPlanningTests: XCTestCase {
    func testSharedAffinePointwiseNodeIsEvaluatedOncePerRender() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 24)
        let source = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)).cropped(to: bounds)
        let evaluations = EvaluationCount()
        let counted = try CountingCopyKernel.apply(withExtent: bounds, inputs: [source], arguments: ["count": evaluations])
        func branches(_ image: CIImage) -> CIImage {
            let shared = image.applyingFilter("CISRGBToneCurveToLinear")
                .transformed(by: CGAffineTransform(translationX: 0.25, y: -0.5))
            let bright = shared.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 0.1, y: 0.2, z: 0.3, w: 0)])
            return bright.composited(over: shared)
        }
        let expected = try XCTUnwrap(context.createCGImage(branches(source), from: bounds)).portableImage.bytes
        let graph = branches(counted)
        for frame in 1...2 {
            XCTAssertEqual(try XCTUnwrap(context.createCGImage(graph, from: bounds)).portableImage.bytes, expected)
            XCTAssertEqual(evaluations.value, frame)
        }
    }

    func testRenderCacheSeparatesDomainsAndSurvivesOversizedResults() {
        let cache = RasterRenderCache(byteLimit: 64)
        let owner = NSObject(), backend = NSObject()
        let bounds = CGRect(x: 0, y: 0, width: 2, height: 1)
        var calls = 0
        func read(_ region: CGRect = CGRect(x: 0, y: 0, width: 2, height: 1), linear: Bool = false, gpu: AnyObject? = nil) -> Float {
            cache.raster(for: owner, region: region, linear: linear, gpu: gpu) {
                calls += 1
                return Raster(rect: region, data: [Float](repeating: Float(calls), count: Int(region.width * region.height) * 4))
            }.data[0]
        }
        XCTAssertEqual(read(), 1)
        XCTAssertEqual(read(), 1)
        XCTAssertEqual(read(linear: true), 2)
        XCTAssertEqual(read(bounds.offsetBy(dx: 5, dy: 0)), 3)
        XCTAssertEqual(read(gpu: backend), 4)
        // The two most recent 32-byte results remain. A 128-byte request must not evict either.
        XCTAssertEqual(read(CGRect(x: 0, y: 0, width: 8, height: 1)), 5)
        XCTAssertEqual(read(bounds.offsetBy(dx: 5, dy: 0)), 3)
        XCTAssertEqual(read(gpu: backend), 4)
        XCTAssertEqual(calls, 5)
    }

    func testSharedSpatialNodeIsEvaluatedOncePerRender() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 48)
        let source = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)).cropped(to: bounds)
        let evaluations = EvaluationCount()
        let counted = try CountingCopyKernel.apply(withExtent: bounds, inputs: [source], arguments: ["count": evaluations])
        func branches(_ image: CIImage) -> CIImage {
            let shared = image.applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": 5, "inputHeight": 1])
            let red = shared.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 0.125, y: 0, z: 0, w: 0)])
            let green = shared.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 0, y: 0.125, z: 0, w: 0)])
            return red.composited(over: green).composited(over: shared)
        }
        let graph = branches(counted)
        let expected = try XCTUnwrap(context.createCGImage(branches(source), from: bounds)).portableImage.bytes
        for frame in 1...2 {
            XCTAssertEqual(try XCTUnwrap(context.createCGImage(graph, from: bounds)).portableImage.bytes, expected)
            XCTAssertEqual(evaluations.value, frame, "Shared spatial work should run once per render, with a fresh cache next frame")
        }
    }

    private func hardware() throws -> CIContext {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .hardwareCanvas: true])
        if !context.gpuAvailable {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { XCTFail("Hardware Vulkan required") }
            throw XCTSkip("Hardware Vulkan unavailable")
        }
        return context
    }

    func testRejectedPlanDoesNotEvaluateItsCPULeaves() throws {
        let hardware = try hardware()
        let software = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let source = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)).cropped(to: bounds)
        let first = EvaluationCount(), second = EvaluationCount()
        let opaqueA = try CountingCopyKernel.apply(withExtent: bounds, inputs: [source], arguments: ["count": first])
        let opaqueB = try CountingCopyKernel.apply(withExtent: bounds, inputs: [source], arguments: ["count": second])
        let graph = opaqueA.applyingGaussianBlur(sigma: 0.1).composited(over: opaqueB)
        let actual = try XCTUnwrap(hardware.createCGImage(graph, from: bounds)).portableImage.bytes
        let expected = try XCTUnwrap(software.createCGImage(source.applyingGaussianBlur(sigma: 0.1)
            .composited(over: source), from: bounds)).portableImage.bytes
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(first.value, 1, "A rejected GPU plan must not render CPU leaves before fallback")
        XCTAssertEqual(second.value, 1)
    }

    func testSharedLargeGeometryLeafUploadsOnceWithinAFrame() throws {
        let context = try hardware()
        // The 144 MB source exceeds the 128 MiB geometry-cache budget. Per-frame sharing must not depend on
        // admission to that persistent cache, nor require keeping this source's resampling between frames.
        let bytes = Data(repeating: 128, count: 3000 * 3000 * 4)
        let source = CIImage(bitmapData: bytes, bytesPerRow: 3000 * 4,
            size: CGSize(width: 3000, height: 3000), format: .RGBA8, colorSpace: nil)
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let small = source.transformed(by: CGAffineTransform(scaleX: 256.0 / 3000, y: 256.0 / 3000))
        let top = small.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.75, y: 0, z: 0, w: 0)])
        let graph = top.composited(over: small)
        let uploads = context.gpuUploadBytes
        let actual = try XCTUnwrap(context.createCGImage(graph, from: bounds)).portableImage.bytes
        let software = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        let expected = try XCTUnwrap(software.createCGImage(graph, from: bounds)).portableImage.bytes
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(context.gpuUploadBytes - uploads, UInt64(256 * 256 * 16),
            "A shared immutable geometry leaf should be evaluated/uploaded once even when the persistent cache refuses it")
    }
}
