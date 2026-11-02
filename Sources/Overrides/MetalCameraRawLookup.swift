// Linux replacement for Compositor/Rendering/MetalCameraRawLookup.swift.
// Vulkan evaluates the same composed table; upstream's CPU repair decides rounding-boundary pixels.
import Foundation
import Synchronization
import CompositorCameraRawBackend

nonisolated final class MetalCameraRawLookup: @unchecked Sendable {
    static let shared: MetalCameraRawLookup? = MetalCameraRawLookup()
    static let minimumPixels = 8_000_001
    private let backend: OpaquePointer
    private final class Buffers {
        let pixels: UnsafeMutablePointer<UInt8>
        let repair: UnsafeMutablePointer<UInt8>
        let bytes: Int
        let count: Int
        init(bytes: Int, count: Int) {
            self.bytes = bytes; self.count = count
            pixels = .allocate(capacity: bytes); repair = .allocate(capacity: count)
        }
        deinit { pixels.deallocate(); repair.deallocate() }
    }
    private let buffers = Mutex<Buffers?>(nil)
    private init?() {
        guard let backend = compositor_camera_raw_lookup_create() else { return nil }
        self.backend = backend
    }
    deinit { compositor_camera_raw_lookup_destroy(backend) }
    var deviceName: String { String(cString: compositor_camera_raw_lookup_device(backend)) }
    var submissions: UInt64 { compositor_camera_raw_lookup_submissions(backend) }

    func discardBuffers() {
        buffers.withLock { storage in
            storage = nil
            compositor_camera_raw_lookup_discard(backend)
        }
    }

    /// The original input, including row padding, is installed only after successful GPU work and CPU repair.
    func apply(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int, table: [Float], grid: Int) -> Bool {
        guard width > 0, height > 0, width <= Int(UInt32.max) / 4, height <= Int(UInt32.max),
              rowBytes >= width * 4, rowBytes <= Int(UInt32.max) / height, grid == 33,
              table.count == grid * grid * grid * 3,
              UInt64(width) * UInt64(height) <= compositor_camera_raw_lookup_max_pixels(backend),
              table.withUnsafeBufferPointer({ camera_raw_lookup_is_valid($0.baseAddress, Int32(grid)) != 0 }) else { return false }
        return buffers.withLock { storage in
            let bytes = rowBytes * height, count = width * height
            if storage == nil || storage!.bytes < bytes || storage!.count < count {
                storage = Buffers(bytes: bytes, count: count)
            }
            guard let ready = storage else { return false }
            let success = table.withUnsafeBufferPointer { lookup in
                compositor_camera_raw_lookup_apply(backend, pixels, ready.pixels, ready.repair,
                    UInt32(width), UInt32(height), UInt32(rowBytes), lookup.baseAddress, UInt32(grid))
            }
            guard success == 1 else { return false }
            table.withUnsafeBufferPointer {
                camera_raw_repair_lookup(ready.pixels, pixels, ready.repair, width, height, rowBytes, $0.baseAddress, Int32(grid))
            }
            memcpy(pixels, ready.pixels, bytes)
            return true
        }
    }
}
