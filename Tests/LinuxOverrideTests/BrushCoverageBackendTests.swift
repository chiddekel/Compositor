import Foundation
import CoreGraphics
import Testing
import CompositorBrushBackend
@testable import Compositor

struct BrushCoverageBackendTests {
    @Test func parallelSoftCoverageMatchesSerialKernelExactly() throws {
        let width = 193, height = 157
        let settled = [SIMD4<Float>(90, 100, 130, 105), SIMD4<Float>(130, 105, 132, 130)]
        let tail = [SIMD4<Float>(132, 130, 120, 135)]
        let segments = (settled + tail).map { CompositorBrushSegment(x0: $0.x, y0: $0.y, x1: $0.z, y1: $0.w) }
        for hardness: Float in [0, 0.5, 0.99] {
            let permanent = (0..<(width * height)).map { $0 % 53 == 0 ? Float(20) : Float($0 % 47) / 10 }
            let request = BrushCoverageRequest(width: width, height: height, origin: CGPoint(x: -12, y: 8),
                mapping: CGAffineTransform(a: 0.9, b: 0.2, c: -0.2, d: 0.9, tx: 0, ty: 0),
                canvas: CGSize(width: 220, height: 190), radius: 128, hardness: hardness,
                antialiasWidth: 0.9, spacing: 6.4, settled: settled, tail: tail, permanent: permanent)
            var uniforms = CompositorBrushUniforms(a: 0.9, b: 0.2, c: -0.2, d: 0.9,
                origin_x: -12, origin_y: 8, radius: 128, hardness: hardness,
                canvas_width: 220, canvas_height: 190, antialias_width: 0.9, spacing: 6.4,
                width: UInt32(width), height: UInt32(height), settled_count: 2, segment_count: 3)
            var expected = permanent
            var preview = [UInt8](repeating: 0, count: permanent.count)
            let code = compositor_brush_cpu(&uniforms, segments, segments.count, permanent, permanent.count, &expected, &preview)
            #expect(code == 0)
            let actual = try CPUBrushCoverage().render(request)
            #expect(actual.permanent == expected)
            #expect(actual.preview == preview)
        }
    }

    @Test func saturatedHardCoveragePreservesCanvasClippingAndPartialEdges() throws {
        // Centers are -0.5 ... 3.5; the first and last pixels are outside the canvas.
        // A distant segment cannot change previously settled coverage.
        let request = BrushCoverageRequest(width: 5, height: 1, origin: CGPoint(x: -1, y: 0),
            mapping: .identity, canvas: CGSize(width: 3, height: 1), radius: 1, hardness: 1,
            antialiasWidth: 1, spacing: 1, settled: [SIMD4(20, 20, 21, 20)],
            tail: [SIMD4(22, 20, 23, 20)], permanent: [1, 1, 0.5, 0, 1])
        let result = try CPUBrushCoverage().render(request)
        #expect(result.permanent == request.permanent)
        #expect(result.preview == [0, 255, 128, 0, 0])
    }

    @Test func provisionalCoverageNeverBecomesPermanent() throws {
        let request = BrushCoverageRequest(width: 2, height: 1, origin: .zero,
            mapping: .identity, canvas: CGSize(width: 2, height: 1), radius: 8, hardness: 1,
            antialiasWidth: 1, spacing: 1, settled: [], tail: [SIMD4(0, 0, 2, 0)],
            permanent: [1, 0])
        let result = try CPUBrushCoverage().render(request)
        #expect(result.permanent == [1, 0])
        #expect(result.preview == [255, 255])
    }

    @Test func softDensityOfOneIsNotSaturatedCoverage() throws {
        let request = BrushCoverageRequest(width: 4, height: 1, origin: CGPoint(x: -1, y: 0),
            mapping: .identity, canvas: CGSize(width: 2, height: 1), radius: 1, hardness: 0.5,
            antialiasWidth: 1, spacing: 1, settled: [SIMD4(20, 20, 21, 20)], tail: [], permanent: [20, 1, 20, 20])
        let result = try CPUBrushCoverage().render(request)
        #expect(result.permanent == [20, 1, 20, 20])
        #expect(result.preview == [0, 161, 255, 0]) // 255 * (1 - exp(-1)), rounded.
    }
}
