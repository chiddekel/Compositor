import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// The GPU brush takes all of one stroke event's tiles in one submission (as upstream's Metal encoder does). Each
/// tile's density and preview must be exactly what the one-tile path computes, and both stay within the CPU kernel's
/// tolerance; more tiles than one batch holds are split across submissions.
struct BrushCoverageBatchTests {
    private func requests(count: Int, hardness: Float) -> [BrushCoverageRequest] {
        let settled: [SIMD4<Float>] = (0..<40).map { i in
            let t = Float(i) / 40
            return SIMD4(30 + 900 * t, 200 + 150 * sinf(t * 6), 30 + 900 * (t + 0.025), 200 + 150 * sinf((t + 0.025) * 6))
        }
        let tail: [SIMD4<Float>] = [SIMD4(930, 220, 960, 260), SIMD4(960, 260, 990, 300)]
        return (0..<count).map { index in
            let column = index % 6, row = index / 6
            let width = index % 3 == 0 ? 256 : 200, height = index % 2 == 0 ? 256 : 180
            let permanent = (0..<(width * height)).map { Float(($0 * 7 + index) % 13) / (hardness >= 1 ? 13 : 4) }
            return BrushCoverageRequest(width: width, height: height, origin: CGPoint(x: column * 170, y: row * 160),
                mapping: .identity, canvas: CGSize(width: 1100, height: 900), radius: 150, hardness: hardness,
                antialiasWidth: 1, spacing: 9, settled: settled, tail: tail, permanent: permanent)
        }
    }

    @Test(arguments: [Float(0.2), Float(0.8), Float(1)], [3, 20])
    func batchedTilesMatchOneTileSubmissionsExactly(hardness: Float, count: Int) throws {
        guard let gpu = VulkanBrushCoverage.shared else { return }   // no Vulkan device: nothing to compare
        let batch = requests(count: count, hardness: hardness)
        let together = try gpu.renderAll(batch)
        #expect(together.count == batch.count)
        let cpu = CPUBrushCoverage()
        for (request, result) in zip(batch, together) {
            let alone = try gpu.render(request)
            #expect(result.permanent == alone.permanent)
            #expect(result.preview == alone.preview)
            let reference = try cpu.render(request)
            let worst = zip(result.preview, reference.preview).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= 1, "GPU preview differs from the CPU kernel by \(worst) levels")
        }
    }

    @Test func batchRefusesTilesWithDifferentSegments() throws {
        guard let gpu = VulkanBrushCoverage.shared else { return }
        var batch = requests(count: 2, hardness: 0.5)
        let other = batch[1]
        batch[1] = BrushCoverageRequest(width: other.width, height: other.height, origin: other.origin, mapping: other.mapping,
            canvas: other.canvas, radius: other.radius, hardness: other.hardness, antialiasWidth: other.antialiasWidth,
            spacing: other.spacing, settled: [], tail: other.tail, permanent: other.permanent)
        #expect(throws: BrushCoverageFailure.self) { try gpu.renderAll(batch) }
    }
}
