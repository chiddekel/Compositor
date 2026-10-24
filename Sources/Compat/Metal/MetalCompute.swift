import Foundation
import CoreImageKernels

/// Executes supported compute entry points through the Linux raster driver. Unsupported shaders fail explicitly.
enum MetalCompute {
    private static let driver = DispersionDriver()
    static func execute(_ encoder: MTLComputeCommandEncoder) throws {
        if encoder.pipeline?.name == "vignette" || encoder.pipeline?.name == "tonalContrast" {
            try FinishingCompute.execute(encoder)
            return
        }
        if encoder.pipeline?.name == "bokeh" {
            try BokehCompute.execute(encoder)
            return
        }
        guard encoder.ended, encoder.pipeline?.name == "disperse",
              let source = encoder.textures[0], let destination = encoder.textures[1],
              let data = encoder.bytes[0], data.count >= 68,
              source.width > 0, source.height > 0, destination.width > 0, destination.height > 0,
              source.rgbaBytes.count == source.width * source.height * source.bytesPerPixel,
              [.rgba8Unorm, .rgba32Float].contains(source.pixelFormat),
              [.rgba8Unorm, .rgba32Float].contains(destination.pixelFormat) else {
            throw NSError(domain: "Compositor.MetalCompute", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported or incomplete compute command"])
        }
        func float(_ offset: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) } }
        func uint(_ offset: Int) -> Float { data.withUnsafeBytes { Float($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        let parameters: [Float] = [float(0), float(4), float(8), float(12), float(16), float(20), float(24),
            uint(28), uint(32), uint(36), uint(40), float(48), float(52), float(56), float(60), float(64),
            Float(source.width), Float(source.height), 0, 0]
        let samples: [Float]
        if source.pixelFormat == .rgba32Float {
            samples = source.rgbaBytes.withUnsafeBytes { bytes in
                (0..<(source.width * source.height * 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
        } else { samples = source.rgbaBytes.map { Float($0) / 255 } }
        var result = [Float](repeating: 0, count: destination.width * destination.height * 4)
        let code = driver.render(width: destination.width, height: destination.height, samples: samples,
                                 parameters: parameters, result: &result)
        guard code >= 0 else { throw NSError(domain: "Compositor.MetalCompute", code: Int(code)) }
        if destination.pixelFormat == .rgba32Float {
            destination.rgbaBytes = result.withUnsafeBytes { Array($0) }
        } else {
            destination.rgbaBytes = result.map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }
        }
    }
}

private final class DispersionDriver: @unchecked Sendable {
    private let lock = NSLock()
    private let handle = compositor_vulkan_raster_create(0)
    deinit { compositor_vulkan_raster_destroy(handle) }
    func render(width: Int, height: Int, samples: [Float], parameters: [Float], result: inout [Float]) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return samples.withUnsafeBufferPointer { input in
            parameters.withUnsafeBufferPointer { p in
                result.withUnsafeMutableBufferPointer { output in
                    compositor_dispersion_render(handle, UInt32(width), UInt32(height), input.baseAddress, p.baseAddress, output.baseAddress)
                }
            }
        }
    }
}
