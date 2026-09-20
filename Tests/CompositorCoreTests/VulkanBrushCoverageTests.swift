import XCTest
@testable import CompositorCore

final class VulkanBrushCoverageTests: XCTestCase {
    private func gpu() throws -> VulkanBrushCoverage {
        if let gpu = VulkanBrushCoverage.shared { return gpu }
        if ProcessInfo.processInfo.environment["COMPOSITOR_REQUIRE_VULKAN"] == "1" {
            throw NSError(domain: "VulkanRequired", code: 1)
        }
        throw XCTSkip("No Vulkan compute device; CPU/fallback tests still run")
    }

    private func request(hardness: Float = 0, permanent: [Float]? = nil,
                         settled: [SIMD4<Float>] = [], tail: [SIMD4<Float>] = [],
                         mapping: CGAffineTransform = .identity, origin: CGPoint = .zero,
                         radius: Float = 8, width: Int = 31, height: Int = 29) -> BrushCoverageRequest {
        BrushCoverageRequest(width: width, height: height, origin: origin, mapping: mapping,
            canvas: CGSize(width: 64, height: 64), radius: radius, hardness: hardness,
            antialiasWidth: 1, spacing: max(0.25, radius * 2 * (hardness >= 1 ? 0.015 : 0.025)),
            settled: settled, tail: tail, permanent: permanent ?? [Float](repeating: 0, count: width * height))
    }

    private func compare(_ a: BrushCoverageResult, _ b: BrushCoverageResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.preview.count, b.preview.count, file: file, line: line)
        let error = zip(a.preview, b.preview).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(error, 1, "coverage byte difference", file: file, line: line)
        let densityError = zip(a.permanent, b.permanent).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(densityError, 0.002, "float density difference", file: file, line: line)
    }

    func testVulkanMatchesCPUForHardSoftTransformedClippedAndOddTiles() throws {
        let gpu = try gpu(), cpu = CPUBrushCoverage()
        print("Vulkan brush device: \(gpu.deviceName); type=\(gpu.deviceType); driver=\(gpu.driverVersion)")
        let mappings = [CGAffineTransform.identity,
            CGAffineTransform(a: 0.8, b: 0.3, c: -0.4, d: 1.2, tx: 0, ty: 0),
            CGAffineTransform(a: -1, b: 0, c: 0, d: 0.6, tx: 0, ty: 0)]
        for hardness: Float in [0, 0.5, 0.99, 1] {
            for mapping in mappings {
                for origin in [CGPoint.zero, CGPoint(x: -8, y: -4), CGPoint(x: 63, y: 58)] {
                    let input = request(hardness: hardness,
                        settled: [SIMD4(5, 6, 5, 6), SIMD4(5, 6, 24, 22), SIMD4(24, 22, 2, 27)],
                        tail: [SIMD4(2, 27, 19, 3)], mapping: mapping, origin: origin)
                    compare(try cpu.render(input), try gpu.render(input))
                }
            }
        }
        compare(try cpu.render(request(width: 256, height: 256)), try gpu.render(request(width: 256, height: 256)))
    }

    func testTailReplacementDoesNotChangePermanentOrAccumulate() throws {
        for engine in [CPUBrushCoverage() as BrushCoverageComputing, try gpu()] {
            let first = try engine.render(request(settled: [SIMD4(7, 7, 7, 7)]))
            let preview = request(permanent: first.permanent, tail: [SIMD4(7, 7, 22, 22)])
            let a = try engine.render(preview), b = try engine.render(preview)
            XCTAssertEqual(a.permanent, first.permanent)
            XCTAssertEqual(a.preview, b.preview)
            let removed = try engine.render(request(permanent: first.permanent))
            XCTAssertEqual(removed.preview, first.preview)
            let settled = try engine.render(request(permanent: first.permanent, settled: [SIMD4(7, 7, 22, 22)]))
            XCTAssertEqual(a.preview, settled.preview)
        }
    }

    func testCPUClickAndCanvasClippingHaveKnownCoverage() throws {
        let result = try CPUBrushCoverage().render(request(hardness: 1,
            settled: [SIMD4(0.5, 0.5, 0.5, 0.5)], origin: CGPoint(x: -1, y: -1), radius: 1, width: 4, height: 4))
        XCTAssertEqual(result.preview[0], 0)
        XCTAssertEqual(result.preview[5], 255)
        XCTAssertEqual(result.preview[6], 128)
        XCTAssertEqual(result.preview[15], 0)
    }

    func testInvalidInputIsRejectedByBothBackends() throws {
        for engine in [CPUBrushCoverage() as BrushCoverageComputing, try gpu()] {
            XCTAssertThrowsError(try engine.render(request(radius: .nan)))
            XCTAssertThrowsError(try engine.render(request(width: 257)))
            XCTAssertThrowsError(try engine.render(request(settled: [SIMD4(.infinity, 0, 1, 1)])))
            XCTAssertThrowsError(try engine.render(request(permanent: [-1])))
        }
    }

    private final class FailsAfter: BrushCoverageComputing {
        var calls = 0
        let successes: Int
        init(_ successes: Int) { self.successes = successes }
        func render(_ request: BrushCoverageRequest) throws -> BrushCoverageResult {
            calls += 1
            if calls > successes { throw BrushCoverageFailure.unavailable }
            return try CPUBrushCoverage().render(request)
        }
    }

    func testExecutionFailureReplaysUnchangedInputAndStaysOnCPU() throws {
        let failing = FailsAfter(1)
        let adaptive = AdaptiveBrushCoverage(accelerator: failing)
        let first = try adaptive.render(request(settled: [SIMD4(5, 5, 5, 5)]))
        let second = request(permanent: first.permanent, settled: [SIMD4(5, 5, 18, 18)], tail: [SIMD4(18, 18, 25, 4)])
        let expected = try CPUBrushCoverage().render(second)
        let actual = try adaptive.render(second)
        XCTAssertEqual(expected.preview, actual.preview)
        XCTAssertEqual(expected.permanent, actual.permanent)
        XCTAssertTrue(adaptive.fellBack)
        _ = try adaptive.render(second)
        XCTAssertEqual(failing.calls, 2)
        XCTAssertEqual(try AdaptiveBrushCoverage(accelerator: nil).render(second).preview, expected.preview)
    }

    func testWholeStrokeFallbackAcrossTilesSelectionUndoAndRedo() throws {
        let failing = FailsAfter(2)
        let adaptive = AdaptiveBrushCoverage(accelerator: failing)
        let sessions = [EditorSession(), EditorSession(coverageFactory: { adaptive })]
        var outputs: [PortableImage] = []
        for session in sessions {
            try session.createDocument(width: 520, height: 80, emptyLayer: true)
            try session.setSelection(DocumentSelection(path: .rectangle(CGRect(x: 8, y: 8, width: 502, height: 64))))
            let blank = try session.render()
            var settings = BrushSettings(); settings.diameter = 30; settings.hardness = 0; settings.opacity = 0.5; settings.red = 1
            try session.beginBrush(at: CGPoint(x: 12, y: 20), settings: settings)
            for point in [CGPoint(x: 240, y: 60), CGPoint(x: 490, y: 20), CGPoint(x: 180, y: 20)] { try session.continueBrush(at: point) }
            try session.finishBrush()
            let image = try session.render(); outputs.append(image)
            XCTAssertLessThanOrEqual(stride(from: 3, to: image.bytes.count, by: 4).map { image.bytes[$0] }.max()!, 128)
            try session.undo(); XCTAssertEqual(try session.render(), blank)
            try session.redo(); XCTAssertEqual(try session.render(), image)
        }
        XCTAssertEqual(outputs[0], outputs[1])
        XCTAssertTrue(adaptive.fellBack)
    }

    func testVulkanStrokeFlushIsIdempotentAndMatchesCPU() throws {
        let accelerated = try gpu()
        var results: [PortableImage] = []
        for computer in [CPUBrushCoverage() as BrushCoverageComputing, accelerated] {
            let layer = ImageLayer(name: "Test", blankSize: CGSize(width: 520, height: 90))
            var settings = BrushSettings(); settings.diameter = 27; settings.hardness = 0.3; settings.opacity = 0.7
            let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 520, height: 90), coverageComputer: computer)
            for point in [CGPoint(x: 3, y: 20), CGPoint(x: 250, y: 80), CGPoint(x: 510, y: 4), CGPoint(x: 120, y: 20)] { try stroke.append(point) }
            try stroke.flush()
            let first = try stroke.paintSnapshot().asset.image.pixels
            try stroke.flush()
            XCTAssertEqual(try stroke.paintSnapshot().asset.image.pixels, first)
            results.append(first)
        }
        XCTAssertEqual(results[0].width, results[1].width)
        XCTAssertEqual(results[0].height, results[1].height)
        XCTAssertLessThanOrEqual(zip(results[0].bytes, results[1].bytes).map { abs(Int($0)-Int($1)) }.max()!, 1)
    }
}
