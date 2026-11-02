import Foundation
import CoreGraphics
import CoreImageKernels

struct VulkanRasterStep {
    var operation: UInt32
    var source: Int
    var background: Int = 0
    var mask: Int = 0
    var channel: UInt32 = 0
    var parameters: [Float] = []
}

/// The optional hardware evaluator. A failed submission leaves the caller's CPU raster untouched.
final class VulkanRaster: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSLock()
    // Retaining storage prevents allocator address reuse; mutations trigger Swift's copy-on-write.
    private var inputs: [[Float]?] = [nil, nil, nil]
    private var generation: UInt64 = 0
    private var graphInputs: [[Float]] = []
    // Each cache has its own token: updating one cannot certify the other's storage.
    private var graphGeneration: UInt64 = 0
    private struct GeometryLeaf {
        let sources: [[Float]]
        let raster: Raster
    }
    private var geometryLeaves: [[UInt64]: GeometryLeaf] = [:]
    private var geometryFloatCount = 0
    private var failed = false
    private let graphsOnly: Bool
    var minimumGraphPixels: Int { graphsOnly ? 256 * 256 : 1 }
    init?(graphsOnly: Bool = false) {
        self.graphsOnly = graphsOnly
        guard let handle = compositor_vulkan_raster_create(0) else { return nil }
        self.handle = handle
    }
    deinit { compositor_vulkan_raster_destroy(handle) }
    var device: String { String(cString: compositor_vulkan_raster_device(handle)) }
    var deviceType: UInt32 { compositor_vulkan_raster_device_type(handle) }
    var submissions: UInt64 { compositor_vulkan_raster_submissions(handle) }
    var fusedSubmissions: UInt64 { compositor_vulkan_raster_fused_submissions(handle) }
    var uploadBytes: UInt64 { compositor_vulkan_raster_upload_bytes(handle) }
    var readbackBytes: UInt64 { compositor_vulkan_raster_readback_bytes(handle) }
    var backend: OpaquePointer { handle }
    var isAvailable: Bool { lock.lock(); defer { lock.unlock() }; return !failed && compositor_vulkan_raster_available(handle) != 0 }

    /// Immutable source storage is retained with its prepared pixels, preventing address reuse and enabling COW.
    func geometryLeaf(key: [UInt64], sources: [[Float]], evaluate: () -> Raster) -> Raster {
        lock.lock()
        let cached = geometryLeaves[key]
        lock.unlock()
        if let cached { return cached.raster }
        let raster = evaluate()
        // At most 128 MiB of source and result floats, and 64 distinct geometry preparations.
        let limit = 32 * 1024 * 1024
        let sourceCount = sources.reduce(0) { $0 + $1.count }
        guard sourceCount <= limit, raster.data.count <= limit - sourceCount else { return raster }
        let count = sourceCount + raster.data.count
        lock.lock()
        defer { lock.unlock() }
        if let cached = geometryLeaves[key] { return cached.raster }
        guard !failed else { return raster }
        if geometryLeaves.count >= 64 || geometryFloatCount > limit - count {
            geometryLeaves.removeAll(); geometryFloatCount = 0
        }
        geometryLeaves[key] = GeometryLeaf(sources: sources, raster: raster)
        geometryFloatCount += count
        return raster
    }

    func renderGraph(sources: [Raster], steps: [VulkanRasterStep]) -> Raster? {
        guard let first = sources.first, first.width > 0, first.height > 0,
              first.width <= 65_536, first.height <= 65_536,
              first.width * first.height >= minimumGraphPixels,
              sources.count <= 64, !steps.isEmpty, steps.count <= 128,
              sources.allSatisfy({ $0.rect == first.rect && $0.data.count == first.width * first.height * 4 }) else { return nil }
        var native: [CompositorVulkanRasterStep] = []
        for step in steps {
            let limit = sources.count + native.count
            guard (1...9).contains(step.operation), step.source >= 0, step.source < limit,
                  step.operation > 2 || (step.background >= 0 && step.background < limit),
                  step.operation != 2 || (step.mask >= 0 && step.mask < limit),
                  step.operation != 3 || step.parameters.count == 20,
                  step.operation != 4 || step.parameters.count == 8,
                  step.operation != 7 || step.parameters.count == 4,
                  step.operation != 8 || step.parameters.count == 8,
                  step.operation != 9 || step.parameters.count == 12,
                  step.parameters.count <= 20 else { return nil }
            var s = CompositorVulkanRasterStep()
            s.operation = step.operation; s.channel = step.channel; s.source = UInt32(step.source)
            s.background = step.operation <= 2 ? UInt32(step.background) : 0
            s.mask = step.operation == 2 ? UInt32(step.mask) : 0
            withUnsafeMutableBytes(of: &s.parameters) { destination in
                step.parameters.withUnsafeBytes { source in
                    if !source.isEmpty { destination.copyMemory(from: source) }
                }
            }
            native.append(s)
        }
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return nil }
        let data = sources.map(\.data)
        let uploads: [UInt8] = data.enumerated().map { index, values in
            guard index < graphInputs.count, graphInputs[index].count == values.count else { return 1 }
            return values.withUnsafeBufferPointer { current in
                graphInputs[index].withUnsafeBufferPointer { old in current.baseAddress == old.baseAddress ? 0 : 1 }
            }
        }
        var output = Raster(rect: first.rect, uninitialized: true)
        var pointers: [UnsafePointer<Float>?] = []
        func invoke(_ index: Int) -> Int32 {
            if index < data.count {
                return data[index].withUnsafeBufferPointer { buffer in
                    pointers.append(buffer.baseAddress)
                    defer { pointers.removeLast() }
                    return invoke(index + 1)
                }
            }
            return pointers.withUnsafeBufferPointer { p in
                native.withUnsafeBufferPointer { s in
                    uploads.withUnsafeBufferPointer { u in
                        output.data.withUnsafeMutableBufferPointer { o in
                            compositor_vulkan_raster_render_graph(handle, UInt32(first.width), UInt32(first.height),
                                p.baseAddress, UInt32(data.count), s.baseAddress, UInt32(native.count),
                                u.baseAddress, &graphGeneration, o.baseAddress)
                        }
                    }
                }
            }
        }
        let code = invoke(0)
        if code == 0 { graphInputs = data; return output }
        if code == -2 { failed = true }
        graphInputs = []
        return nil
    }

    func render(_ operation: UInt32, source: Raster, background: Raster? = nil, mask: Raster? = nil,
                channel: UInt32 = 0, parameters: [Float] = []) -> Raster? {
        guard !graphsOnly, (1...9).contains(operation),
              source.width > 0, source.height > 0, source.width <= 65_536, source.height <= 65_536,
              source.data.count == source.width * source.height * 4,
              background == nil || (background?.rect == source.rect && background?.data.count == source.data.count),
              mask == nil || (mask?.rect == source.rect && mask?.data.count == source.data.count),
              operation != 3 || parameters.count == 20, operation != 4 || parameters.count == 8,
              operation != 7 || parameters.count == 4, operation != 8 || parameters.count == 8,
              operation != 9 || parameters.count == 12 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return nil }
        let next: [[Float]?] = [source.data, background?.data, mask?.data]
        var uploadMask: UInt32 = 0
        for i in 0..<3 {
            guard let data = next[i] else { continue }
            let retained = inputs[i]
            let same = retained?.count == data.count && data.withUnsafeBufferPointer { current in
                retained!.withUnsafeBufferPointer { previous in current.baseAddress == previous.baseAddress }
            }
            if !same { uploadMask |= 1 << UInt32(i) }
        }
        var out = Raster(rect: source.rect, uninitialized: true)
        // Empty optional arrays yield nil pointers; the C boundary validates required inputs for each operation.
        let code = source.data.withUnsafeBufferPointer { s in
            (background?.data ?? []).withUnsafeBufferPointer { b in
                (mask?.data ?? []).withUnsafeBufferPointer { m in
                    parameters.withUnsafeBufferPointer { p in
                        out.data.withUnsafeMutableBufferPointer { o in
                            compositor_vulkan_raster_render_cached(handle, UInt32(source.width), UInt32(source.height),
                                operation, channel, s.baseAddress, background == nil ? nil : b.baseAddress,
                                mask == nil ? nil : m.baseAddress, parameters.isEmpty ? nil : p.baseAddress, o.baseAddress,
                                uploadMask, &generation)
                        }
                    }
                }
            }
        }
        if code == 0 { inputs = next; return out }
        if code == -2 { failed = true }
        inputs = [nil, nil, nil]
        return nil
    }
}

/// An immutable device allocation in CI's bottom-up coordinates. Reads occur only at CPU consumers.
final class VulkanImage: @unchecked Sendable {
    let owner: VulkanRaster
    let handle: OpaquePointer
    let rect: CGRect
    init(owner: VulkanRaster, handle: OpaquePointer, rect: CGRect) {
        self.owner = owner; self.handle = handle; self.rect = rect
    }
    deinit { compositor_vulkan_image_destroy(handle) }
    func read() -> Raster? {
        var result = Raster(rect: rect, uninitialized: true)
        let code = result.data.withUnsafeMutableBufferPointer { compositor_vulkan_image_read(handle, $0.baseAddress) }
        return code == 0 ? result : nil
    }
}

extension VulkanRaster {
    var residentBytes: UInt64 { compositor_vulkan_raster_resident_bytes(handle) }
    var bokehSubmissions: UInt64 { compositor_vulkan_raster_bokeh_submissions(handle) }

    func uploadResident(_ raster: Raster) -> VulkanImage? {
        guard raster.width > 0, raster.height > 0, raster.width <= 65_536, raster.height <= 65_536,
              raster.data.count == raster.width * raster.height * 4 else { return nil }
        let image: OpaquePointer?
        if let bytes = NormalizedByteStorage.encode(raster.data) {
            image = bytes.withUnsafeBufferPointer {
                compositor_vulkan_image_upload_rgba8(handle, UInt32(raster.width), UInt32(raster.height), $0.baseAddress)
            }
        } else {
            image = raster.data.withUnsafeBufferPointer {
                compositor_vulkan_image_upload(handle, UInt32(raster.width), UInt32(raster.height), $0.baseAddress)
            }
        }
        return image.map { VulkanImage(owner: self, handle: $0, rect: raster.rect) }
    }

    func applyResident(_ operation: UInt32, source: VulkanImage, region: CGRect,
                       background: VulkanImage? = nil, mask: VulkanImage? = nil, channel: UInt32 = 0,
                       parameters: [Float] = []) -> VulkanImage? {
        guard source.owner === self, background == nil || background?.owner === self,
              mask == nil || mask?.owner === self, parameters.count <= 20,
              !region.isNull, region.width > 0, region.height > 0,
              region.width <= 65_536, region.height <= 65_536 else { return nil }
        let values = parameters + [Float](repeating: 0, count: 20 - parameters.count)
        let image = values.withUnsafeBufferPointer {
            compositor_vulkan_image_apply(handle, UInt32(region.width), UInt32(region.height), operation, channel,
                source.handle, background?.handle, mask?.handle, $0.baseAddress)
        }
        return image.map { VulkanImage(owner: self, handle: $0, rect: region) }
    }

    func placeResident(_ image: VulkanImage, region: CGRect, inverse: CGAffineTransform = .identity,
                       nearest: Bool = false, clamp: Bool = false) -> VulkanImage? {
        if region == image.rect && inverse == .identity && !clamp { return image }
        return applyResident(13, source: image, region: region, parameters: [
            Float(inverse.a), Float(inverse.b), Float(inverse.c), Float(inverse.d), Float(inverse.tx), Float(inverse.ty),
            Float(region.minX), Float(region.minY), Float(image.rect.minX), Float(image.rect.minY),
            nearest ? 1 : 0, clamp ? 1 : 0])
    }
}
