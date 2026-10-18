import Foundation
import CompositorBrushBackend

/// This adapter is the only Swift layer aware of the native brush ABI.
nonisolated private func nativeCoverage(_ request: BrushCoverageRequest, context: OpaquePointer? = nil,
                            accelerated: Bool = false) throws -> BrushCoverageResult {
    guard (1...256).contains(request.width), (1...256).contains(request.height),
          request.settled.count <= 2048, request.tail.count <= 2048 - request.settled.count,
          request.permanent.count == request.width * request.height else { throw BrushCoverageFailure.invalidInput }
    let all = request.settled + request.tail
    let segments = all.map { CompositorBrushSegment(x0: $0.x, y0: $0.y, x1: $0.z, y1: $0.w) }
    var uniforms = CompositorBrushUniforms(a: Float(request.mapping.a), b: Float(request.mapping.b),
        c: Float(request.mapping.c), d: Float(request.mapping.d),
        origin_x: Float(request.origin.x), origin_y: Float(request.origin.y), radius: request.radius,
        hardness: request.hardness, canvas_width: Float(request.canvas.width), canvas_height: Float(request.canvas.height),
        antialias_width: request.antialiasWidth, spacing: request.spacing,
        width: UInt32(request.width), height: UInt32(request.height),
        settled_count: UInt32(request.settled.count), segment_count: UInt32(all.count))
    var permanent = [Float](repeating: 0, count: request.permanent.count)
    var preview = [UInt8](repeating: 0, count: request.permanent.count)
    let code = request.permanent.withUnsafeBufferPointer { source in
        segments.withUnsafeBufferPointer { segments in
            permanent.withUnsafeMutableBufferPointer { destination in
                preview.withUnsafeMutableBufferPointer { preview in
                    if accelerated {
                        return compositor_vulkan_brush_render(context, &uniforms, segments.baseAddress, segments.count,
                            source.baseAddress, source.count, destination.baseAddress, preview.baseAddress)
                    }
                    if request.radius >= 64, request.hardness < 1, request.height >= 128, !segments.isEmpty {
                        // A wide soft tip spends most of its time integrating each pixel. A stroke may
                        // touch only two tiles, so split their rows too instead of leaving cores idle.
                        let workers = 4
                        var codes = [Int32](repeating: 0, count: workers)
                        withUnsafePointer(to: &uniforms) { uniforms in
                            codes.withUnsafeMutableBufferPointer { codes in
                                // concurrentPerform joins before these buffer scopes end. Inputs are
                                // immutable; each worker owns separate output rows and one status slot.
                                nonisolated(unsafe) let uniforms = uniforms
                                nonisolated(unsafe) let segments = segments
                                nonisolated(unsafe) let source = source
                                nonisolated(unsafe) let destination = destination
                                nonisolated(unsafe) let preview = preview
                                nonisolated(unsafe) let codes = codes
                                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                                    codes[worker] = compositor_brush_cpu_rows(uniforms, segments.baseAddress, segments.count,
                                        source.baseAddress, source.count, destination.baseAddress, preview.baseAddress,
                                        UInt32(worker * request.height / workers), UInt32((worker + 1) * request.height / workers))
                                }
                            }
                        }
                        return codes.first(where: { $0 != 0 }) ?? 0
                    }
                    return compositor_brush_cpu(&uniforms, segments.baseAddress, segments.count,
                        source.baseAddress, source.count, destination.baseAddress, preview.baseAddress)
                }
            }
        }
    }
    guard code == 0 else { throw code == -1 ? BrushCoverageFailure.invalidInput : BrushCoverageFailure.unavailable }
    return BrushCoverageResult(permanent: permanent, preview: preview)
}

// Stateless and called by tile workers; its lifetime must not be tied to the UI actor.
nonisolated final class CPUBrushCoverage: BrushCoverageComputing {
    var isThreadSafe: Bool { true }
    func render(_ request: BrushCoverageRequest) throws -> BrushCoverageResult { try nativeCoverage(request) }
}

final class VulkanBrushCoverage: BrushCoverageComputing {
    static let shared = VulkanBrushCoverage()
    private let context: OpaquePointer
    let deviceName: String
    let deviceType: UInt32
    let driverVersion: UInt32

    init?() {
        guard let context = compositor_vulkan_brush_create() else { return nil }
        self.context = context
        deviceName = String(cString: compositor_vulkan_brush_device(context))
        deviceType = compositor_vulkan_brush_device_type(context)
        driverVersion = compositor_vulkan_brush_driver_version(context)
    }
    deinit { compositor_vulkan_brush_destroy(context) }
    func render(_ request: BrushCoverageRequest) throws -> BrushCoverageResult {
        try nativeCoverage(request, context: context, accelerated: true)
    }
}

extension VulkanBrushCoverage: BrushCoverageBatching {
    /// Every tile of one stroke event in one GPU submission (upstream's Metal encoder takes them all at once): a
    /// submission and fence wait per tile cost more than the CPU kernel for a wide soft tip.
    func renderAll(_ requests: [BrushCoverageRequest]) throws -> [BrushCoverageResult] {
        guard let first = requests.first else { return [] }
        let all = first.settled + first.tail
        guard requests.allSatisfy({ $0.settled == first.settled && $0.tail == first.tail }),
              all.count <= 2048, requests.allSatisfy({ (1...256).contains($0.width) && (1...256).contains($0.height)
                  && $0.permanent.count == $0.width * $0.height }) else { throw BrushCoverageFailure.invalidInput }
        let segments = all.map { CompositorBrushSegment(x0: $0.x, y0: $0.y, x1: $0.z, y1: $0.w) }
        // Outputs in buffers of their own (one array of arrays would be one exclusive access per tile, nested).
        let permanents = requests.map { UnsafeMutableBufferPointer<Float>.allocate(capacity: $0.permanent.count) }
        let previews = requests.map { UnsafeMutableBufferPointer<UInt8>.allocate(capacity: $0.permanent.count) }
        defer { permanents.forEach { $0.deallocate() }; previews.forEach { $0.deallocate() } }
        // Inputs stay pinned for the call by nested read-only scopes.
        func run(_ index: Int, _ jobs: inout [CompositorBrushTileJob]) -> Int32 {
            guard index < requests.count else {
                return segments.withUnsafeBufferPointer { s in
                    jobs.withUnsafeBufferPointer { j in
                        compositor_vulkan_brush_render_tiles(context, j.baseAddress, j.count, s.baseAddress, s.count)
                    }
                }
            }
            let request = requests[index]
            return request.permanent.withUnsafeBufferPointer { source in
                let uniforms = CompositorBrushUniforms(a: Float(request.mapping.a), b: Float(request.mapping.b),
                    c: Float(request.mapping.c), d: Float(request.mapping.d),
                    origin_x: Float(request.origin.x), origin_y: Float(request.origin.y), radius: request.radius,
                    hardness: request.hardness, canvas_width: Float(request.canvas.width),
                    canvas_height: Float(request.canvas.height), antialias_width: request.antialiasWidth,
                    spacing: request.spacing, width: UInt32(request.width), height: UInt32(request.height),
                    settled_count: UInt32(request.settled.count), segment_count: UInt32(all.count))
                jobs.append(CompositorBrushTileJob(uniforms: uniforms, permanent: source.baseAddress,
                    pixel_count: source.count, next: permanents[index].baseAddress, preview: previews[index].baseAddress))
                return run(index + 1, &jobs)
            }
        }
        var jobs: [CompositorBrushTileJob] = []
        jobs.reserveCapacity(requests.count)
        let code = run(0, &jobs)
        guard code == 0 else { throw code == -1 ? BrushCoverageFailure.invalidInput : BrushCoverageFailure.unavailable }
        return zip(permanents, previews).map { BrushCoverageResult(permanent: Array($0), preview: Array($1)) }
    }
}
