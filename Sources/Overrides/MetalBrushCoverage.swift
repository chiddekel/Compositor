// OVERRIDE for Compositor/Rendering/MetalBrushCoverage.swift (excluded from the Linux build).
//
// Same public surface as upstream's Metal type — `MetalBrushCoverage.shared`, `Tile`, `tile(width:height:)`,
// `render(_:settled:tail:mapping:settings:canvas:)` — so upstream's BrushStroke compiles unmodified, implemented by the
// portable backend chain: the C CPU kernel for inexpensive tips, Vulkan compute for wider soft tips when available
// (see `AdaptiveBrushCoverage`). Tiles keep their density and preview as plain arrays instead of MTLBuffers.
// Contract test: Tests/CompositorCoreTests/OverrideSignatureTests.swift.

import Foundation
import CoreGraphics

final class MetalBrushCoverage {
    static let shared: MetalBrushCoverage? = MetalBrushCoverage()

    private lazy var backend: BrushCoverageComputing = BrushCoverageBackends.automatic()
    private let cpu: BrushCoverageComputing = BrushCoverageBackends.cpu()

    private init() {}

    /// Stroke-local tile storage: accumulated density and the 8-bit preview that is copied into the coverage context.
    final class Tile {
        let width: Int, height: Int
        var permanent: [Float]
        var preview: [UInt8]
        init(width: Int, height: Int) {
            self.width = width; self.height = height
            permanent = [Float](repeating: 0, count: width * height)
            preview = [UInt8](repeating: 0, count: width * height)
        }
    }

    func tile(width: Int, height: Int) throws -> Tile {
        guard (1...256).contains(width), (1...256).contains(height) else { throw ExportError.render }
        return Tile(width: width, height: height)
    }

    func render(_ tiles: [(Tile, CGRect, CGContext)], settled: [SIMD4<Float>], tail: [SIMD4<Float>],
                mapping: CGAffineTransform, settings: BrushSettings, canvas: CGSize) throws {
        guard !tiles.isEmpty else { return }
        // For hard tips and small soft tips, a Vulkan submission and fence per tile costs more than
        // the CPU kernel. Keep expensive wide soft-tip integration on the accelerated backend.
        let computer = settings.hardness >= 1 || settings.diameter <= 64 ? cpu : backend
        let scale = Float(max(0.001, min(hypot(mapping.a, mapping.b), hypot(mapping.c, mapping.d))))
        let spacing = Float(max(0.25, settings.diameter * BrushStroke.spacingFraction(settings.hardness)))
        // Compute every tile first; only publish once all succeeded, so a failure leaves nothing half-written.
        let requests = tiles.map { (tile, rect, _) in
            BrushCoverageRequest(
                width: Int(rect.width), height: Int(rect.height), origin: rect.origin.applying(mapping), mapping: mapping, canvas: canvas,
                radius: Float(settings.diameter / 2), hardness: Float(settings.hardness), antialiasWidth: scale,
                spacing: spacing, settled: settled, tail: tail, permanent: tile.permanent)
        }
        // A wide dab touches several tiles: on the CPU kernel they are computed side by side, one per core.
        var computed = [Result<BrushCoverageResult, Error>?](repeating: nil, count: requests.count)
        if computer.isThreadSafe, requests.count > 1 {
            let backend = computer
            computed.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let out = out
                DispatchQueue.concurrentPerform(iterations: requests.count) { i in
                    out[i] = Result { try backend.render(requests[i]) }
                }
            }
        } else {
            for i in requests.indices { computed[i] = Result { try computer.render(requests[i]) } }
        }
        var results: [(Tile, BrushCoverageResult, CGContext, Int)] = []
        for (index, (tile, rect, context)) in tiles.enumerated() {
            results.append((tile, try computed[index]!.get(), context, Int(rect.width * rect.height)))
        }
        for (tile, result, context, count) in results {
            tile.permanent = result.permanent
            tile.preview = result.preview
            // CGContext owns its memory so makeImage's copy-on-write snapshots stay immutable.
            guard let destination = context.data else { throw ExportError.render }
            result.preview.withUnsafeBufferPointer { _ = memcpy(destination, $0.baseAddress!, min(count, $0.count)) }
        }
    }
}
