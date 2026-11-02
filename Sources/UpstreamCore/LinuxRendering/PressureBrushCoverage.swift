import Foundation
import CompositorBrushBackend

/// Converts the value-based brush contract to the variable-tip native kernel. Pressure never changes shared brush
/// settings: each segment carries the radius and strength of its two endpoints, as upstream's Metal kernel does.
nonisolated func pressureCoverage(_ request: BrushCoverageRequest) throws -> BrushCoverageResult {
    let all = request.settled + request.tail
    guard (1...256).contains(request.width), (1...256).contains(request.height) else {
        throw BrushCoverageFailure.invalidInput
    }
    let count = request.width * request.height
    guard all.count <= 2048, request.permanent.count == count,
          request.dynamics.count == all.count, request.cap.isEmpty || request.cap.count == count else {
        throw BrushCoverageFailure.invalidInput
    }
    let segments = all.map { CompositorBrushSegment(x0: $0.x, y0: $0.y, x1: $0.z, y1: $0.w) }
    let dynamics = request.dynamics.map {
        CompositorBrushDynamics(radius0: $0.x, radius1: $0.y, strength0: $0.z, strength1: $0.w)
    }
    var uniforms = CompositorBrushUniforms(a: Float(request.mapping.a), b: Float(request.mapping.b),
        c: Float(request.mapping.c), d: Float(request.mapping.d),
        origin_x: Float(request.origin.x), origin_y: Float(request.origin.y), radius: request.radius,
        hardness: request.hardness, canvas_width: Float(request.canvas.width), canvas_height: Float(request.canvas.height),
        antialias_width: request.antialiasWidth, spacing: request.spacing,
        width: UInt32(request.width), height: UInt32(request.height),
        settled_count: UInt32(request.settled.count), segment_count: UInt32(all.count))
    var next = [Float](repeating: 0, count: count)
    var cap = [Float](repeating: 0, count: request.cap.count)
    var preview = [UInt8](repeating: 0, count: count)
    let code = segments.withUnsafeBufferPointer { segments in
        dynamics.withUnsafeBufferPointer { dynamics in
            request.permanent.withUnsafeBufferPointer { permanent in
                request.cap.withUnsafeBufferPointer { priorCap in
                    next.withUnsafeMutableBufferPointer { next in
                        cap.withUnsafeMutableBufferPointer { nextCap in
                            preview.withUnsafeMutableBufferPointer { preview in
                                compositor_brush_pressure_cpu(&uniforms, segments.baseAddress, dynamics.baseAddress,
                                    segments.count, permanent.baseAddress, priorCap.isEmpty ? nil : priorCap.baseAddress,
                                    count, next.baseAddress, nextCap.isEmpty ? nil : nextCap.baseAddress, preview.baseAddress)
                            }
                        }
                    }
                }
            }
        }
    }
    guard code == 0 else { throw BrushCoverageFailure.invalidInput }
    return BrushCoverageResult(permanent: next, preview: preview, cap: cap)
}
