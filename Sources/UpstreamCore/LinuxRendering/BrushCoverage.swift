import Foundation
import CoreGraphics

struct BrushCoverageRequest {
    let width: Int
    let height: Int
    let origin: CGPoint
    let mapping: CGAffineTransform
    let canvas: CGSize
    let radius: Float
    let hardness: Float
    let antialiasWidth: Float
    let spacing: Float
    let settled: [SIMD4<Float>]
    let tail: [SIMD4<Float>]
    let permanent: [Float]
}

struct BrushCoverageResult {
    let permanent: [Float]
    let preview: [UInt8]
}

enum BrushCoverageFailure: Error { case invalidInput, unavailable }

/// Backend-independent, value-in/value-out contract. A failed computation must
/// not mutate input or publish partial output. The stroke owns tile state.
protocol BrushCoverageComputing: AnyObject {
    func render(_ request: BrushCoverageRequest) throws -> BrushCoverageResult
    /// Tiles may be computed concurrently (the CPU kernel); a GPU queue is fed one tile at a time.
    var isThreadSafe: Bool { get }
}
extension BrushCoverageComputing {
    var isThreadSafe: Bool { false }
}

/// One instance per stroke: once acceleration fails, that stroke stays on CPU.
/// The CPU receives the unchanged request, including settled density and tail.
final class AdaptiveBrushCoverage: BrushCoverageComputing {
    private var accelerator: BrushCoverageComputing?
    private let cpu: BrushCoverageComputing
    private(set) var fellBack = false
    var isThreadSafe: Bool { accelerator == nil }

    init(accelerator: BrushCoverageComputing?, cpu: BrushCoverageComputing = CPUBrushCoverage()) {
        self.accelerator = accelerator
        self.cpu = cpu
    }

    func render(_ request: BrushCoverageRequest) throws -> BrushCoverageResult {
        if let accelerator {
            do { return try accelerator.render(request) }
            catch BrushCoverageFailure.invalidInput { throw BrushCoverageFailure.invalidInput }
            catch { self.accelerator = nil; fellBack = true }
        }
        return try cpu.render(request)
    }
}

enum BrushCoverageBackends {
    static func cpu() -> BrushCoverageComputing { CPUBrushCoverage() }
    /// The GPU when there is one; COMPOSITOR_BRUSH_BACKEND=cpu (Settings' acceleration switch) keeps brushes on the
    /// native kernel, run tile-parallel across the cores.
    static func automatic() -> BrushCoverageComputing {
        if ProcessInfo.processInfo.environment["COMPOSITOR_BRUSH_BACKEND"] == "cpu" { return AdaptiveBrushCoverage(accelerator: nil) }
        return AdaptiveBrushCoverage(accelerator: VulkanBrushCoverage.shared)
    }
}
