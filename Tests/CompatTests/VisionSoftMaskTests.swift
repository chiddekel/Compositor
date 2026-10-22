// VisionSoftMaskTests — a model-backed segmenter's soft foreground (SegmentationResult.confidence) reaching upstream's
// masks the way Apple Vision's soft masks do: the whole subject keeps its soft fringe, a single instance stays within it.

import CoreGraphics
import XCTest
import Vision
import CoreVideo

final class VisionSoftMaskTests: XCTestCase {
    /// 4x1: instance 1 at confidence 0.9, a fringe pixel (label 0) at 0.3, instance 2 at 0.7, background at 0.
    private final class SoftBackend: ForegroundSegmentationBackend {
        func segment(rgba: [UInt8], width: Int, height: Int) throws -> SegmentationResult {
            SegmentationResult(labels: [1, 0, 2, 0], width: 4, height: 1, instanceCount: 2, confidence: [0.9, 0.3, 0.7, 0])
        }
    }

    private func observation() throws -> VNInstanceMaskObservation {
        var pixels = PixelBuffer(width: 4, height: 1)
        for x in 0..<4 { pixels[x, 0] = (128, 128, 128, 255) }
        let handler = VNImageRequestHandler(cgImage: CGImage(pixels), options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try ForegroundSegmentationRegistry.withBackend(SoftBackend()) { try handler.perform([request]) }
        return try XCTUnwrap(request.results?.first)
    }

    func testTheWholeSubjectKeepsTheModelsSoftEdges() throws {
        let observation = try observation()
        let mask = try observation.generateMask(forInstances: observation.allInstances).floats
        XCTAssertEqual(mask, [0.9, 0.3, 0.7, 0])
    }

    func testOneInstanceIsItsOwnPixelsOnly() throws {
        let mask = try observation().generateMask(forInstances: IndexSet(integer: 2)).floats
        XCTAssertEqual(mask, [0, 0, 0.7, 0])
    }

    func testHardLabelSegmentersStillGiveBinaryMasks() throws {
        let hard = SegmentationResult(labels: [1, 0], width: 2, height: 1, instanceCount: 1)
        XCTAssertNil(hard.confidence)
    }
}
